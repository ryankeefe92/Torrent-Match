import Foundation

public final class PirateBayAPIProvider: TorrentProvider, @unchecked Sendable {
    public let config: ProviderConfig
    private let session: URLSession

    public init(config: ProviderConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func fetchDetailMetadata(for result: TorrentSearchResult) async throws -> TorrentDetailMetadata? {
        guard let detailURL = result.detailURL else { return nil }

        if let apiURL = apiDetailURL(for: detailURL) {
            let (data, response) = try await session.data(for: makeRequest(url: apiURL))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ProviderError.badStatus(provider: config.name, status: http.statusCode)
            }

            let payload = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            if payload.contains("cf-mitigated") || payload.contains("Just a moment...") || payload.contains("<html") {
                throw ProviderError.accessBlocked(provider: config.name, reason: "API returned HTML instead of JSON")
            }

            let details = try JSONDecoder().decode(PirateBayAPITorrentDetails.self, from: data)
            let description = details.descr?.htmlDecoded.readableMetadataText
            if let description, Self.looksLikeUsefulDetailMetadata(description) {
                let specs = TorrentDetailSpecParser.parse(description, fallbackTitle: result.title)
                return TorrentDetailMetadata(text: description, specs: specs, magnet: result.magnet)
            }
        }

        let (data, response) = try await session.data(for: makeRequest(url: detailURL))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.badStatus(provider: config.name, status: http.statusCode)
        }

        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        if html.contains("cf-mitigated") || html.contains("Just a moment...") {
            throw ProviderError.accessBlocked(provider: config.name, reason: "Cloudflare challenge")
        }

        guard let metadata = fallbackDetailMetadata(from: html) else { return nil }
        let specs = TorrentDetailSpecParser.parse(
            metadata,
            detailTitle: extractDetailPageTitle(from: html),
            fallbackTitle: result.title
        )
        return TorrentDetailMetadata(text: metadata, specs: specs, magnet: result.magnet)
    }

    public func search(
        _ query: String,
        onProgress: (@Sendable (_ addedResults: [TorrentSearchResult]) async -> Void)?
    ) async throws -> [TorrentSearchResult] {
        guard config.enabled else { return [] }
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let templates = [config.searchURLTemplate] + config.alternateSearchURLTemplates

        let outcome = await withTaskGroup(of: Result<[TorrentSearchResult], Error>.self) { group in
            for template in templates {
                group.addTask {
                    do {
                        return .success(try await self.search(template: template, encodedQuery: encodedQuery, onProgress: onProgress))
                    } catch {
                        return .failure(error)
                    }
                }
            }

            var results: [TorrentSearchResult] = []
            var firstError: Error?
            for await categoryResult in group {
                switch categoryResult {
                case .success(let categoryResults):
                    results.append(contentsOf: categoryResults)
                case .failure(let error):
                    if firstError == nil {
                        firstError = error
                    }
                }
            }

            if results.isEmpty, let firstError {
                return Result<[TorrentSearchResult], Error>.failure(firstError)
            }
            return Result<[TorrentSearchResult], Error>.success(results)
        }

        switch outcome {
        case .success(let results):
            return results
        case .failure(let error):
            throw error
        }
    }

    private func search(
        template: String,
        encodedQuery: String,
        onProgress: (@Sendable (_ addedResults: [TorrentSearchResult]) async -> Void)?
    ) async throws -> [TorrentSearchResult] {
        let urlString = template.replacingOccurrences(of: "{{query}}", with: encodedQuery)
        guard let url = URL(string: urlString) else { throw ProviderError.invalidURL(urlString) }

        let (data, response) = try await session.data(for: makeRequest(url: url))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.badStatus(provider: config.name, status: http.statusCode)
        }

        let payload = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        if payload.contains("cf-mitigated") || payload.contains("Just a moment...") || payload.contains("<html") {
            throw ProviderError.accessBlocked(provider: config.name, reason: "API returned HTML instead of JSON")
        }

        let results = try JSONDecoder().decode([PirateBayAPITorrent].self, from: data)
        var output: [TorrentSearchResult] = []
        output.reserveCapacity(results.count)

        for torrent in results {
            guard let title = torrent.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  torrent.id != "0" else {
                continue
            }

            let seeders = Int(torrent.seeders ?? "") ?? 0
            let leechers = Int(torrent.leechers ?? "") ?? 0
            guard !(seeders == 0 && leechers < 2) else { continue }

            let magnet = torrent.infoHash.flatMap(makeMagnet(infoHash:))
            let detailURL = URL(string: "https://thepiratebay.org/description.php?id=\(torrent.id)")

            let result = TorrentSearchResult(
                title: title,
                magnet: magnet,
                detailURL: detailURL,
                seeders: seeders,
                leechers: leechers,
                provider: config.name,
                size: torrent.size.flatMap(Self.formattedByteSize)
            )
            output.append(result)
            if let onProgress {
                await onProgress([result])
            }
        }
        return output
    }

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(config.timeoutSeconds ?? 20)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func apiDetailURL(for detailURL: URL) -> URL? {
        guard let components = URLComponents(url: detailURL, resolvingAgainstBaseURL: false),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              !id.isEmpty else { return nil }

        let apiBaseURL = config.searchURLTemplate
            .split(separator: "?")
            .first
            .flatMap { URL(string: String($0)) }
            .flatMap { URL(string: "/", relativeTo: $0)?.absoluteURL }
            ?? URL(string: "https://apibay.org/")
        guard let apiBaseURL else { return nil }
        return URL(string: "t.php?id=\(id)", relativeTo: apiBaseURL)?.absoluteURL
    }

    private func makeMagnet(infoHash: String) -> String {
        let trackers = [
            "udp://tracker.opentrackr.org:1337/announce",
            "udp://open.stealth.si:80/announce",
            "udp://tracker.torrent.eu.org:451/announce",
            "udp://exodus.desync.com:6969/announce",
            "udp://tracker.moeking.me:6969/announce"
        ]
        let trackerQuery = trackers
            .map { "tr=\($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0)" }
            .joined(separator: "&")
        let displayName = config.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? config.name
        return "magnet:?xt=urn:btih:\(infoHash)&dn=\(displayName)&\(trackerQuery)"
    }

    private static func formattedByteSize(_ rawValue: String) -> String? {
        guard let bytes = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              bytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.includesCount = true
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func fallbackDetailMetadata(from html: String) -> String? {
        let candidates = [
            #"<pre[^>]*>([\s\S]*?)</pre>"#,
            #"<textarea[^>]*>([\s\S]*?)</textarea>"#,
            #"<div[^>]+(?:id|class)=[\"'][^\"']*(?:media[\s_-]?info|nfo|description|technical|file[\s_-]?info|torrent[\s_-]?info|details?)[^\"']*[\"'][^>]*>([\s\S]*?)</div>"#,
            #"<section[^>]+(?:id|class)=[\"'][^\"']*(?:media[\s_-]?info|nfo|description|technical|file[\s_-]?info|torrent[\s_-]?info|details?)[^\"']*[\"'][^>]*>([\s\S]*?)</section>"#
        ]

        let bestBlock = candidates
            .flatMap { RegexTools.captureMatches(pattern: $0, in: html) }
            .map { $0.htmlDecoded.readableMetadataText }
            .filter(Self.looksLikeUsefulDetailMetadata)
            .max { Self.metadataSignalScore($0) < Self.metadataSignalScore($1) }

        if let bestBlock {
            return bestBlock
        }

        let pageText = RegexTools.firstCapture(pattern: #"<body[^>]*>([\s\S]*?)</body>"#, in: html)?
            .htmlDecoded
            .readableMetadataText
        guard let pageText,
              Self.looksLikeUsefulDetailMetadata(pageText) else { return nil }
        return pageText
    }

    private func extractDetailPageTitle(from html: String) -> String? {
        let candidates = [
            #"<h1[^>]*>([\s\S]*?)</h1>"#,
            #"<h2[^>]*>([\s\S]*?)</h2>"#,
            #"<title[^>]*>([\s\S]*?)</title>"#
        ]

        return candidates
            .compactMap { RegexTools.firstCapture(pattern: $0, in: html)?.htmlDecoded.readableMetadataText.cleanedDetailPageTitle }
            .first { !$0.isEmpty }
    }

    private static func looksLikeUsefulDetailMetadata(_ text: String) -> Bool {
        let normalized = text.lowercased()
        guard text.count >= 40 else { return false }
        guard !isBoilerplateDetailText(normalized) else { return false }
        return [
            "mediainfo", "media info", "general", "video", "audio", "duration",
            "bit rate", "bitrate", "codec", "format", "resolution", "width",
            "height", "frame rate", "channel", "hdr", "dolby", "dts", "truehd"
        ].contains { normalized.contains($0) }
    }

    private static func isBoilerplateDetailText(_ normalized: String) -> Bool {
        [
            "your report will be reviewed",
            "moderation team",
            "report this torrent",
            "report torrent",
            "dmca",
            "captcha"
        ].contains { normalized.contains($0) }
    }

    private static func metadataSignalScore(_ text: String) -> Int {
        let normalized = text.lowercased()
        let signals = [
            "mediainfo", "media info", "general", "video", "audio", "duration",
            "bit rate", "bitrate", "codec", "format", "resolution", "width",
            "height", "frame rate", "channel", "hdr", "dolby", "dts", "truehd"
        ]
        return signals.reduce(0) { score, signal in
            score + (normalized.contains(signal) ? 1 : 0)
        } + min(text.count / 500, 10)
    }
}

private struct PirateBayAPITorrent: Decodable {
    let id: String
    let name: String?
    let infoHash: String?
    let leechers: String?
    let seeders: String?
    let size: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case infoHash = "info_hash"
        case leechers
        case seeders
        case size
    }
}

private struct PirateBayAPITorrentDetails: Decodable {
    let descr: String?
}
