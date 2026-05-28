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

        let encodedQuery = encodedSearchQuery(query)
        var lastError: Error?

        for template in allSearchURLTemplates {
            do {
                let results = try await fetchSearchResults(template: template, encodedQuery: encodedQuery)
                if !results.isEmpty { return results }
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }
        return []
    }

    public func resolveMagnet(for result: TorrentSearchResult) async throws -> String? {
        if let magnet = result.magnet, !magnet.isEmpty {
            return magnet
        }
        guard let detailURL = result.detailURL,
              let magnetPattern = config.magnetPattern else {
            return nil
        }
        let html = try await fetchText(detailURL)
        return RegexTools.firstCapture(pattern: magnetPattern, in: html)?.htmlDecoded
    }

    private var allSearchURLTemplates: [String] {
        [config.searchURLTemplate] + config.alternateSearchURLTemplates
    }

    private func fetchSearchResults(template: String, encodedQuery: String) async throws -> [TorrentSearchResult] {
        let pageCount = searchPageCount(for: template)

        if pageCount == 1 {
            let url = try searchURL(template: template, encodedQuery: encodedQuery, page: 1)
            let html = try await fetchText(url)
            let blocks = RegexTools.captureMatches(pattern: config.resultBlockPattern, in: html)
            return try await parseResults(from: blocks)
        }

        let pageFetch = await withTaskGroup(of: SearchPageResult.self) { group in
            for page in 1...pageCount {
                group.addTask {
                    do {
                        let url = try self.searchURL(template: template, encodedQuery: encodedQuery, page: page)
                        let html = try await self.fetchText(url)
                        let blocks = RegexTools.captureMatches(pattern: self.config.resultBlockPattern, in: html)
                        return SearchPageResult(page: page, results: try await self.parseResults(from: blocks), errorMessage: nil)
                    } catch {
                        return SearchPageResult(page: page, results: [], errorMessage: self.errorMessage(from: error))
                    }
                }
            }

            var resultsByPage: [Int: [TorrentSearchResult]] = [:]
            var firstErrorMessage: String?
            for await result in group {
                resultsByPage[result.page] = result.results
                if firstErrorMessage == nil {
                    firstErrorMessage = result.errorMessage
                }
            }

            return (
                results: (1...pageCount).flatMap { resultsByPage[$0] ?? [] },
                firstErrorMessage: firstErrorMessage
            )
        }

        if pageFetch.results.isEmpty, let firstErrorMessage = pageFetch.firstErrorMessage {
            throw ProviderError.accessBlocked(provider: config.name, reason: firstErrorMessage)
        }
        return pageFetch.results
    }

    private func searchPageCount(for template: String) -> Int {
        guard template.contains("{{page}}") else { return 1 }
        return max(1, config.searchPageCount ?? 1)
    }

    private func searchURL(template: String, encodedQuery: String, page: Int) throws -> URL {
        let urlString = template
            .replacingOccurrences(of: "{{query}}", with: encodedQuery)
            .replacingOccurrences(of: "{{page}}", with: String(page))
        guard let url = URL(string: urlString) else {
            throw ProviderError.invalidURL(urlString)
        }
        return url
    }

    private func parseResults(from blocks: [String]) async throws -> [TorrentSearchResult] {
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
            } else if config.fetchMagnetFromDetailDuringSearch, let detailURL, let magnetPattern = config.magnetPattern {
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
        do {
            let (data, response) = try await session.data(for: makeRequest(url: url))
            return try validateResponse(data: data, response: response)
        } catch let error as ProviderError {
            if case .badStatus(_, 403) = error, let retried = try await retryAfterBootstrap(url: url) {
                return retried
            }
            throw error
        }
    }

    private func retryAfterBootstrap(url: URL) async throws -> String? {
        guard let host = url.host,
              let scheme = url.scheme,
              let homeURL = URL(string: "\(scheme)://\(host)/") else {
            return nil
        }

        let bootstrapRequest = makeRequest(url: homeURL, referer: homeURL)
        _ = try? await session.data(for: bootstrapRequest)

        let retriedRequest = makeRequest(url: url, referer: homeURL)
        let (data, response) = try await session.data(for: retriedRequest)
        return try validateResponse(data: data, response: response)
    }

    private func makeRequest(url: URL, referer: URL? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(config.timeoutSeconds ?? 20)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        return request
    }

    private func validateResponse(data: Data, response: URLResponse) throws -> String {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.badStatus(provider: config.name, status: http.statusCode)
        }
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        if html.contains("cf-mitigated") || html.contains("Just a moment...") || html.contains("challenges.cloudflare.com") {
            throw ProviderError.accessBlocked(provider: config.name, reason: "Cloudflare challenge")
        }
        return html
    }

    private func errorMessage(from error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func extractDetailURL(from block: String) -> URL? {
        guard let pattern = config.detailURLPattern,
              let raw = RegexTools.firstCapture(pattern: pattern, in: block)?.htmlDecoded,
              !raw.isEmpty else { return nil }
        if let absolute = URL(string: raw), absolute.scheme != nil { return absolute }
        guard let base = config.detailBaseURL, let baseURL = URL(string: base) else { return nil }
        return URL(string: raw, relativeTo: baseURL)?.absoluteURL
    }

    private func encodedSearchQuery(_ query: String) -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard config.id == "1337x" else { return encoded }

        return encoded.replacingOccurrences(of: "%20", with: "+")
    }
}

private struct SearchPageResult: Sendable {
    let page: Int
    let results: [TorrentSearchResult]
    let errorMessage: String?
}
