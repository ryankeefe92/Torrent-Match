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
        let templates = [config.searchURLTemplate] + config.alternateSearchURLTemplates

        let outcome = await withTaskGroup(of: Result<[TorrentSearchResult], Error>.self) { group in
            for template in templates {
                group.addTask {
                    do {
                        return .success(try await self.search(template: template, encodedQuery: encodedQuery))
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

    private func search(template: String, encodedQuery: String) async throws -> [TorrentSearchResult] {
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
        return results.compactMap { torrent -> TorrentSearchResult? in
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
                provider: config.name,
                size: torrent.size.flatMap(Self.formattedByteSize)
            )
        }
    }

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(config.timeoutSeconds ?? 20)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        return request
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
