import Foundation

public final class MagnetzAPIProvider: TorrentProvider, @unchecked Sendable {
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
        guard config.enabled else { return [] }
        let encodedQuery = query.encodedURLQueryValue
        let pageCount = max(1, config.searchPageCount ?? 1)

        return try await withThrowingTaskGroup(of: (Int, [TorrentSearchResult]).self) { group in
            for page in 1...pageCount {
                group.addTask {
                    let url = try self.searchURL(encodedQuery: encodedQuery, page: page)
                    let response: MagnetzSearchResponse = try await self.fetch(url)
                    let results = response.data.map {
                        TorrentSearchResult(
                            title: $0.name,
                            magnet: $0.magnetLink,
                            detailURL: URL(string: $0.webURL),
                            seeders: max(0, $0.seeders),
                            leechers: max(0, $0.leechers),
                            provider: self.config.name,
                            size: $0.humanSize
                        )
                    }
                    if let onProgress, !results.isEmpty {
                        await onProgress(results)
                    }
                    return (page, results)
                }
            }

            var resultsByPage: [Int: [TorrentSearchResult]] = [:]
            for try await (page, results) in group {
                resultsByPage[page] = results
            }
            return (1...pageCount).flatMap { resultsByPage[$0] ?? [] }
        }
    }

    private func searchURL(encodedQuery: String, page: Int) throws -> URL {
        let value = config.searchURLTemplate
            .replacingOccurrences(of: "{{query}}", with: encodedQuery)
            .replacingOccurrences(of: "{{page}}", with: String(page))
        guard let url = URL(string: value) else {
            throw ProviderError.invalidURL(value)
        }
        return url
    }

    private func fetch<Response: Decodable>(_ url: URL) async throws -> Response {
        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(config.timeoutSeconds ?? 20)
        request.setValue("Mozilla/5.0 (Torrent Match)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.badStatus(provider: config.name, status: http.statusCode)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

private struct MagnetzSearchResponse: Decodable {
    let data: [MagnetzSearchHit]
}

private struct MagnetzSearchHit: Decodable {
    let name: String
    let magnetLink: String
    let humanSize: String
    let seeders: Int
    let leechers: Int
    let webURL: String

    private enum CodingKeys: String, CodingKey {
        case name
        case magnetLink = "magnet_link"
        case humanSize = "human_size"
        case seeders
        case leechers
        case webURL = "web_url"
    }
}

private extension String {
    var encodedURLQueryValue: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
