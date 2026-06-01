import Foundation
#if canImport(WebKit)

public final class OneThreeThreeSevenXProvider: TorrentProvider, @unchecked Sendable {
    public let config: ProviderConfig

    public init(config: ProviderConfig) {
        self.config = config
    }

    public func search(_ query: String) async throws -> [TorrentSearchResult] {
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
                            results: try await self.parseResults(from: blocks, referer: url),
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

    private func parseResults(from blocks: [String], referer: URL) async throws -> [TorrentSearchResult] {
        var results: [TorrentSearchResult] = []
        for block in blocks {
            guard let title = RegexTools.firstCapture(pattern: config.titlePattern, in: block)?.htmlDecoded.cleanedText,
                  !title.isEmpty else { continue }

            let seeders = RegexTools.firstCapture(pattern: config.seedersPattern, in: block).flatMap(Int.init) ?? 0
            let leechers = RegexTools.firstCapture(pattern: config.leechersPattern, in: block).flatMap(Int.init) ?? 0
            guard !(seeders == 0 && leechers < 2) else { continue }
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

            results.append(TorrentSearchResult(
                title: title,
                magnet: magnet,
                detailURL: detailURL,
                seeders: seeders,
                leechers: leechers,
                provider: config.name,
                size: size
            ))
        }
        return results
    }

    private func fetchMagnet(from detailURL: URL, referer: URL) async throws -> String? {
        let html = try await WebViewHTMLLoader().loadHTML(from: detailURL, referer: referer)
        guard let magnetPattern = config.magnetPattern else { return nil }
        return RegexTools.firstCapture(pattern: magnetPattern, in: html)?.htmlDecoded
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

private struct SearchTemplateResult: Sendable {
    let results: [TorrentSearchResult]
    let error: Error?
}
#endif
