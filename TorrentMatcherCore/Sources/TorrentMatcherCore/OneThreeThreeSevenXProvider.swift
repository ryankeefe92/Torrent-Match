import Foundation
#if canImport(WebKit)

public final class OneThreeThreeSevenXProvider: TorrentProvider, @unchecked Sendable {
    public let config: ProviderConfig

    public init(config: ProviderConfig) {
        self.config = config
    }

    public func search(
        _ query: String,
        onProgress: (@Sendable (_ addedResults: [TorrentSearchResult]) async -> Void)?
    ) async throws -> [TorrentSearchResult] {
        guard config.enabled else { return [] }
        guard !config.searchURLTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.missingURLTemplate(provider: config.name)
        }

        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let searchResult = await withTaskGroup(of: SearchTemplateResult.self) { group in
            for template in allSearchURLTemplates {
                group.addTask {
                    let urlString = template.replacingOccurrences(of: "{{query}}", with: encodedQuery)
                    guard let url = URL(string: urlString) else {
                        return SearchTemplateResult(results: [], error: ProviderError.invalidURL(urlString))
                    }

                    do {
                        let html = try await WebViewHTMLLoader().loadHTML(from: url)
                        let blocks = RegexTools.captureMatches(pattern: self.config.resultBlockPattern, in: html)
                        guard !blocks.isEmpty else {
                            return SearchTemplateResult(results: [], error: nil)
                        }
                        return SearchTemplateResult(
                            results: try await self.parseResults(from: blocks, referer: url, onProgress: onProgress),
                            error: nil
                        )
                    } catch {
                        return SearchTemplateResult(results: [], error: error)
                    }
                }
            }

            var lastError: Error?
            for await result in group {
                if !result.results.isEmpty {
                    group.cancelAll()
                    return result
                }
                if let error = result.error {
                    lastError = error
                }
            }

            return SearchTemplateResult(results: [], error: lastError)
        }

        if let error = searchResult.error {
            throw error
        }
        return searchResult.results
    }

    private var allSearchURLTemplates: [String] {
        [config.searchURLTemplate] + config.alternateSearchURLTemplates
    }

    private func parseResults(
        from blocks: [String],
        referer: URL,
        onProgress: (@Sendable (_ addedResults: [TorrentSearchResult]) async -> Void)?
    ) async throws -> [TorrentSearchResult] {
        var results: [TorrentSearchResult] = []
        for block in blocks {
            guard let title = RegexTools.firstCapture(pattern: config.titlePattern, in: block)?.htmlDecoded.cleanedText,
                  !title.isEmpty else { continue }

            let seedersCapture = RegexTools.firstCapture(pattern: config.seedersPattern, in: block)
            let leechersCapture = RegexTools.firstCapture(pattern: config.leechersPattern, in: block)
            let parsedSeeders = seedersCapture.flatMap(Int.init)
            let parsedLeechers = leechersCapture.flatMap(Int.init)

            let seeders = parsedSeeders ?? 0
            let leechers = parsedLeechers ?? 0

            // Only apply this low-activity drop heuristic when we successfully parsed both values.
            if parsedSeeders != nil && parsedLeechers != nil {
                guard !(seeders == 0 && leechers < 2) else { continue }
            }
            let size = config.sizePattern.flatMap { RegexTools.firstCapture(pattern: $0, in: block) }?.htmlDecoded.cleanedText

            let inlineMagnet = config.magnetPattern.flatMap { RegexTools.firstCapture(pattern: $0, in: block) }?.htmlDecoded
            let detailURL = extractDetailURL(from: block)

            let magnet: String?
            if let inlineMagnet {
                magnet = inlineMagnet
            } else if config.fetchMagnetFromDetailDuringSearch, let detailURL, config.magnetPattern != nil {
                magnet = try await fetchMagnet(from: detailURL, referer: referer)
            } else {
                magnet = nil
            }

            let result = TorrentSearchResult(
                title: title,
                magnet: magnet,
                detailURL: detailURL,
                seeders: seeders,
                leechers: leechers,
                provider: config.name,
                size: size
            )
            results.append(result)
            if let onProgress {
                await onProgress([result])
            }
        }
        return results
    }

    private func fetchMagnet(from detailURL: URL, referer: URL) async throws -> String? {
        let html = try await WebViewHTMLLoader().loadHTML(from: detailURL, referer: referer)
        guard let magnetPattern = config.magnetPattern else { return nil }
        return RegexTools.firstCapture(pattern: magnetPattern, in: html)?.htmlDecoded
    }

    public func fetchDetailMetadata(for result: TorrentSearchResult) async throws -> TorrentDetailMetadata? {
        guard let detailURL = result.detailURL else { return nil }
        guard config.detailMetadataPattern != nil || config.magnetPattern != nil else { return nil }

        let html = try await WebViewHTMLLoader().loadHTML(from: detailURL, referer: sameSiteHomeURL(for: detailURL))
        let metadataText = extractDetailMetadata(from: html) ?? fallbackDetailMetadata(from: html)
        let magnet = result.magnet?.isEmpty == false
            ? result.magnet
            : config.magnetPattern.flatMap { RegexTools.firstCapture(pattern: $0, in: html) }?.htmlDecoded

        let specs = TorrentDetailSpecParser.parse(
            metadataText,
            detailTitle: extractDetailPageTitle(from: html),
            fallbackTitle: result.title
        )
        guard metadataText?.isEmpty == false || magnet?.isEmpty == false else { return nil }
        return TorrentDetailMetadata(text: metadataText, specs: specs, magnet: magnet)
    }

    private func extractDetailURL(from block: String) -> URL? {
        guard let pattern = config.detailURLPattern,
              let raw = RegexTools.firstCapture(pattern: pattern, in: block)?.htmlDecoded,
              !raw.isEmpty else { return nil }
        if let absolute = URL(string: raw), absolute.scheme != nil { return absolute }
        guard let base = config.detailBaseURL, let baseURL = URL(string: base) else { return nil }
        return URL(string: raw, relativeTo: baseURL)?.absoluteURL
    }

    private func extractDetailMetadata(from html: String) -> String? {
        guard let pattern = config.detailMetadataPattern,
              let raw = RegexTools.firstCapture(pattern: pattern, in: html)?.htmlDecoded.readableMetadataText,
              Self.looksLikeUsefulDetailMetadata(raw) else { return nil }
        return raw
    }

    private func fallbackDetailMetadata(from html: String) -> String? {
        let candidates = [
            #"<a\s+name=[\"']description[\"'][^>]*>[\s\S]*?(?:<legend[^>]*>[\s\S]*?</legend>)?([\s\S]*?)(?=<a\s+name=[\"']usercomments[\"']|<div[^>]+id=[\"']usercomments[\"']|$)"#,
            #"<pre[^>]*>([\s\S]*?)</pre>"#,
            #"<textarea[^>]*>([\s\S]*?)</textarea>"#,
            #"<div[^>]+(?:id|class)=[\"'][^\"']*(?:media[\s_-]?info|nfo|description|technical|file[\s_-]?info|torrent[\s_-]?info)[^\"']*[\"'][^>]*>([\s\S]*?)</div>"#,
            #"<section[^>]+(?:id|class)=[\"'][^\"']*(?:media[\s_-]?info|nfo|description|technical|file[\s_-]?info|torrent[\s_-]?info)[^\"']*[\"'][^>]*>([\s\S]*?)</section>"#
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

    private func sameSiteHomeURL(for url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return URL(string: "\(scheme)://\(host)/")
    }
}

private struct SearchTemplateResult: Sendable {
    let results: [TorrentSearchResult]
    let error: Error?
}
#endif
