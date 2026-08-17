import Foundation

public final class EZTVAPIProvider: TorrentProvider, @unchecked Sendable {
    public let config: ProviderConfig
    private let session: URLSession

    public init(config: ProviderConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func search(
        _ query: String,
        onProgress: (@Sendable (_ addedResults: [TorrentSearchResult]) async -> Void)?
    ) async throws -> [TorrentSearchResult] {
        try await search(
            imdbID: query,
            target: nil,
            onProgress: onProgress
        )
    }

    public func search(
        _ request: TorrentProviderSearchRequest,
        onProgress: (@Sendable (_ addedResults: [TorrentSearchResult]) async -> Void)?
    ) async throws -> [TorrentSearchResult] {
        guard request.target.rankingProfile == .television else { return [] }
        return try await search(
            imdbID: request.query,
            target: request.target,
            onProgress: onProgress
        )
    }

    private func search(
        imdbID: String,
        target: TorrentSearchTarget?,
        onProgress: (@Sendable (_ addedResults: [TorrentSearchResult]) async -> Void)?
    ) async throws -> [TorrentSearchResult] {
        guard config.enabled else { return [] }
        let numericID = normalizedIMDbID(imdbID)
        guard !numericID.isEmpty else { return [] }

        var page = 1
        var collected: [TorrentSearchResult] = []
        var foundTarget = false

        while page <= 100 {
            let payload = try await fetchPage(imdbID: numericID, page: page)
            let pageResults = payload.torrents.compactMap(makeResult)
            let matchingResults: [TorrentSearchResult]
            if let target {
                matchingResults = pageResults.filter { TVReleaseParser.matches($0.title, target: target) }
            } else {
                matchingResults = pageResults
            }

            if !matchingResults.isEmpty {
                foundTarget = true
                collected.append(contentsOf: matchingResults)
                if let onProgress {
                    await onProgress(matchingResults)
                }
            } else if foundTarget {
                // Releases for one episode or pack are normally adjacent in EZTV's newest-first feed.
                // One empty page after the match prevents scanning a show's complete history.
                break
            }

            guard target != nil else { break }
            let limit = max(1, payload.limit)
            let totalPages = max(1, Int(ceil(Double(payload.torrentsCount) / Double(limit))))
            if page >= totalPages || payload.torrents.isEmpty {
                break
            }
            page += 1
        }

        return collected
    }

    private func fetchPage(imdbID: String, page: Int) async throws -> EZTVSearchResponse {
        let urlValue = config.searchURLTemplate
            .replacingOccurrences(of: "{{query}}", with: imdbID)
            .replacingOccurrences(of: "{{page}}", with: String(page))
        guard let url = URL(string: urlValue) else {
            throw ProviderError.invalidURL(urlValue)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(config.timeoutSeconds ?? 30)
        request.setValue("Mozilla/5.0 (Torrent Match)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.badStatus(provider: config.name, status: http.statusCode)
        }
        return try JSONDecoder().decode(EZTVSearchResponse.self, from: data)
    }

    private func makeResult(_ torrent: EZTVTorrent) -> TorrentSearchResult? {
        guard let title = [torrent.filename, torrent.title]
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else {
            return nil
        }

        let magnet: String?
        if let value = torrent.magnetURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            magnet = value
        } else if let hash = torrent.hash?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !hash.isEmpty {
            magnet = makeMagnet(infoHash: hash, displayName: title)
        } else {
            magnet = nil
        }

        return TorrentSearchResult(
            title: title,
            magnet: magnet,
            detailURL: [torrent.episodeURL, torrent.torrentURL]
                .compactMap { $0.flatMap(URL.init(string:)) }
                .first,
            seeders: max(0, torrent.seeds),
            leechers: max(0, torrent.peers),
            provider: config.name,
            size: torrent.sizeBytes.flatMap(formattedByteSize)
        )
    }

    private func normalizedIMDbID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let numeric = trimmed.lowercased().hasPrefix("tt")
            ? String(trimmed.dropFirst(2))
            : trimmed
        return numeric.allSatisfy(\.isNumber) ? numeric : ""
    }

    private func makeMagnet(infoHash: String, displayName: String) -> String {
        var components = URLComponents()
        components.scheme = "magnet"
        components.queryItems = [
            URLQueryItem(name: "xt", value: "urn:btih:\(infoHash)"),
            URLQueryItem(name: "dn", value: displayName),
            URLQueryItem(name: "tr", value: "udp://tracker.opentrackr.org:1337/announce"),
            URLQueryItem(name: "tr", value: "udp://tracker.torrent.eu.org:451/announce"),
            URLQueryItem(name: "tr", value: "udp://open.stealth.si:80/announce")
        ]
        return components.string ?? "magnet:?xt=urn:btih:\(infoHash)"
    }

    private func formattedByteSize(_ bytes: Int64) -> String? {
        guard bytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.includesCount = true
        return formatter.string(fromByteCount: bytes)
    }
}

private struct EZTVSearchResponse: Decodable {
    let torrentsCount: Int
    let limit: Int
    let page: Int
    let torrents: [EZTVTorrent]

    private enum CodingKeys: String, CodingKey {
        case torrentsCount = "torrents_count"
        case limit
        case page
        case torrents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        torrentsCount = container.decodeFlexibleInt(forKey: .torrentsCount) ?? 0
        limit = container.decodeFlexibleInt(forKey: .limit) ?? 100
        page = container.decodeFlexibleInt(forKey: .page) ?? 1
        torrents = try container.decodeIfPresent([EZTVTorrent].self, forKey: .torrents) ?? []
    }
}

private struct EZTVTorrent: Decodable {
    let filename: String?
    let title: String?
    let hash: String?
    let magnetURL: String?
    let torrentURL: String?
    let episodeURL: String?
    let seeds: Int
    let peers: Int
    let sizeBytes: Int64?

    private enum CodingKeys: String, CodingKey {
        case filename
        case title
        case hash
        case magnetURL = "magnet_url"
        case torrentURL = "torrent_url"
        case episodeURL = "episode_url"
        case seeds
        case peers
        case sizeBytes = "size_bytes"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filename = container.decodeFlexibleString(forKey: .filename)
        title = container.decodeFlexibleString(forKey: .title)
        hash = container.decodeFlexibleString(forKey: .hash)
        magnetURL = container.decodeFlexibleString(forKey: .magnetURL)
        torrentURL = container.decodeFlexibleString(forKey: .torrentURL)
        episodeURL = container.decodeFlexibleString(forKey: .episodeURL)
        seeds = container.decodeFlexibleInt(forKey: .seeds) ?? 0
        peers = container.decodeFlexibleInt(forKey: .peers) ?? 0
        sizeBytes = container.decodeFlexibleInt64(forKey: .sizeBytes)
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    func decodeFlexibleInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    func decodeFlexibleInt64(forKey key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Int64(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int64(value)
        }
        return nil
    }
}
