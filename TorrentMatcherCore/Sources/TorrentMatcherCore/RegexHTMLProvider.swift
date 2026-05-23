import Foundation

public final class RegexHTMLProvider: TorrentProvider, @unchecked Sendable {
    public let config: ProviderConfig
    private let session: URLSession

    public init(config: ProviderConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func search(_ query: String) async throws -> [TorrentSearchResult] {
        guard config.enabled else { return [] }
        guard !config.searchURLTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.missingURLTemplate(provider: config.name)
        }

        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = config.searchURLTemplate.replacingOccurrences(of: "{{query}}", with: encodedQuery)
        guard let url = URL(string: urlString) else { throw ProviderError.invalidURL(urlString) }

        let html = try await fetchText(url)
        let blocks = RegexTools.captureMatches(pattern: config.resultBlockPattern, in: html)

        var results: [TorrentSearchResult] = []
        for block in blocks {
            guard let title = RegexTools.firstCapture(pattern: config.titlePattern, in: block)?.htmlDecoded.cleanedText,
                  !title.isEmpty else { continue }

            let seeders = RegexTools.firstCapture(pattern: config.seedersPattern, in: block).flatMap(Int.init) ?? 0
            let leechers = RegexTools.firstCapture(pattern: config.leechersPattern, in: block).flatMap(Int.init) ?? 0
            guard !(seeders == 0 && leechers < 2) else { continue }

            let inlineMagnet = config.magnetPattern.flatMap { RegexTools.firstCapture(pattern: $0, in: block) }?.htmlDecoded
            let detailURL = extractDetailURL(from: block)

            let magnet: String?
            if let inlineMagnet {
                magnet = inlineMagnet
            } else if let detailURL, let magnetPattern = config.magnetPattern {
                let detailHTML = try? await fetchText(detailURL)
                magnet = detailHTML.flatMap { RegexTools.firstCapture(pattern: magnetPattern, in: $0) }?.htmlDecoded
            } else {
                magnet = nil
            }

            results.append(TorrentSearchResult(
                title: title,
                magnet: magnet,
                detailURL: detailURL,
                seeders: seeders,
                leechers: leechers,
                provider: config.name
            ))
        }
        return results
    }

    private func fetchText(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.badStatus(provider: config.name, status: http.statusCode)
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private func extractDetailURL(from block: String) -> URL? {
        guard let pattern = config.detailURLPattern,
              let raw = RegexTools.firstCapture(pattern: pattern, in: block)?.htmlDecoded,
              !raw.isEmpty else { return nil }
        if let absolute = URL(string: raw), absolute.scheme != nil { return absolute }
        guard let base = config.detailBaseURL, let baseURL = URL(string: base) else { return nil }
        return URL(string: raw, relativeTo: baseURL)?.absoluteURL
    }
}
