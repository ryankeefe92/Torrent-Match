import Foundation

public final class PirateBayAPIProvider: TorrentProvider, @unchecked Sendable {
    public let config: ProviderConfig
    private let session: URLSession

    public init(config: ProviderConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func search(_ query: String) async throws -> [TorrentSearchResult] {
        guard config.enabled else { return [] }
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = config.searchURLTemplate.replacingOccurrences(of: "{{query}}", with: encodedQuery)
        guard let url = URL(string: urlString) else { throw ProviderError.invalidURL(urlString) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.badStatus(provider: config.name, status: http.statusCode)
        }

        let payload = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        if payload.contains("cf-mitigated") || payload.contains("Just a moment...") || payload.contains("<html") {
            throw ProviderError.accessBlocked(provider: config.name, reason: "API returned HTML instead of JSON")
        }

        let results = try JSONDecoder().decode([PirateBayAPITorrent].self, from: data)
        return results.compactMap { torrent in
            guard let title = torrent.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  torrent.id != "0" else {
                return nil
            }

            let seeders = Int(torrent.seeders ?? "") ?? 0
            let leechers = Int(torrent.leechers ?? "") ?? 0
            guard !(seeders == 0 && leechers < 2) else { return nil }

            let magnet = torrent.infoHash.flatMap(makeMagnet(infoHash:))
            let detailURL = URL(string: "https://thepiratebay.org/description.php?id=\(torrent.id)")

            return TorrentSearchResult(
                title: title,
                magnet: magnet,
                detailURL: detailURL,
                seeders: seeders,
                leechers: leechers,
                provider: config.name
            )
        }
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
}

private struct PirateBayAPITorrent: Decodable {
    let id: String
    let name: String?
    let infoHash: String?
    let leechers: String?
    let seeders: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case infoHash = "info_hash"
        case leechers
        case seeders
    }
}
