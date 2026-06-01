import Foundation

public final class RegexHTMLProvider: TorrentProvider, @unchecked Sendable {
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
        guard !config.searchURLTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.missingURLTemplate(provider: config.name)
        }

        let encodedQueries = encodedSearchQueries(query)
        let searchResult = await withTaskGroup(of: SearchTemplateResult.self) { group in
            for hostTemplates in searchTemplateGroups() {
                group.addTask {
                    await self.searchTemplateGroup(
                        hostTemplates,
                        encodedQueries: encodedQueries,
                        onProgress: onProgress
                    )
                }
            }

            var collectedResults: [TorrentSearchResult] = []
            var lastError: Error?
            for await result in group {
                if !result.results.isEmpty {
                    if self.prefersFirstUsableTemplateGroup {
                        group.cancelAll()
                        return result
                    }
                    collectedResults.append(contentsOf: result.results)
                }
                if let error = result.error {
                    lastError = error
                }
            }

            if !collectedResults.isEmpty {
                return SearchTemplateResult(results: collectedResults, error: nil)
            }

            return SearchTemplateResult(results: [], error: lastError)
        }

        if let error = searchResult.error {
            throw error
        }
        return searchResult.results
    }

    public func resolveMagnet(for result: TorrentSearchResult) async throws -> String? {
        if let magnet = result.magnet, !magnet.isEmpty {
            return magnet
        }
        guard let detailURL = result.detailURL,
              let magnetPattern = config.magnetPattern else {
            return nil
        }
        let html = try await fetchText(
            detailURL,
            referer: sameSiteHomeURL(for: detailURL),
            timeoutSeconds: 35
        )
        return RegexTools.firstCapture(pattern: magnetPattern, in: html)?.htmlDecoded
    }

    private var allSearchURLTemplates: [String] {
        [config.searchURLTemplate] + config.alternateSearchURLTemplates
    }

    private var prefersFirstUsableTemplateGroup: Bool {
        config.id == "1337x"
    }

    private func searchTemplateGroups() -> [[String]] {
        let grouped = Dictionary(grouping: allSearchURLTemplates) { template in
            URL(string: template)?.host ?? template
        }

        return grouped
            .sorted { lhs, rhs in
                let lhsIsPrimary = lhs.value.contains(config.searchURLTemplate)
                let rhsIsPrimary = rhs.value.contains(config.searchURLTemplate)
                if lhsIsPrimary != rhsIsPrimary {
                    return lhsIsPrimary && !rhsIsPrimary
                }
                return lhs.key < rhs.key
            }
            .map(\.value)
    }

    private func searchTemplateGroup(
        _ templates: [String],
        encodedQueries: [String],
        onProgress: (@Sendable (_ addedResults: [TorrentSearchResult]) async -> Void)?
    ) async -> SearchTemplateResult {
        await withTaskGroup(of: SearchTemplateResult.self) { group in
            for encodedQuery in encodedQueries {
                for template in templates {
                    group.addTask {
                        do {
                            let results = try await self.fetchSearchResults(
                                template: template,
                                encodedQuery: encodedQuery,
                                onProgress: onProgress
                            )
                            return SearchTemplateResult(results: results, error: nil)
                        } catch {
                            return SearchTemplateResult(results: [], error: error)
                        }
                    }
                }
            }

            var collectedResults: [TorrentSearchResult] = []
            var lastError: Error?
            for await result in group {
                if !result.results.isEmpty {
                    collectedResults.append(contentsOf: result.results)
                    if self.prefersFirstUsableTemplateGroup {
                        // 1337x can have many slow/blocked templates; once any template yields parseable
                        // rows we return immediately and cancel the rest.
                        group.cancelAll()
                        return SearchTemplateResult(results: collectedResults, error: nil)
                    }
                }
                if let error = result.error {
                    lastError = error
                }
            }

            if !collectedResults.isEmpty {
                return SearchTemplateResult(results: collectedResults, error: nil)
            }
            return SearchTemplateResult(results: [], error: lastError)
        }
    }

    private func fetchSearchResults(
        template: String,
        encodedQuery: String,
        onProgress: (@Sendable (_ addedResults: [TorrentSearchResult]) async -> Void)?
    ) async throws -> [TorrentSearchResult] {
        let pageCount = searchPageCount(for: template)
        let requestTimeoutSeconds = searchRequestTimeoutSeconds()

        if pageCount == 1 {
            let url = try searchURL(template: template, encodedQuery: encodedQuery, page: 1)
            let html = try await fetchText(url, timeoutSeconds: requestTimeoutSeconds)
            let blocks = RegexTools.captureMatches(pattern: config.resultBlockPattern, in: html)
            return try await parseResults(from: blocks, onProgress: onProgress)
        }

        let pageFetch = await withTaskGroup(of: SearchPageEvent.self) { group in
            for page in 1...pageCount {
                group.addTask {
                    do {
                        let url = try self.searchURL(template: template, encodedQuery: encodedQuery, page: page)
                        let html = try await self.fetchText(url, timeoutSeconds: requestTimeoutSeconds)
                        let blocks = RegexTools.captureMatches(pattern: self.config.resultBlockPattern, in: html)
                        return .page(SearchPageResult(page: page, results: try await self.parseResults(from: blocks, onProgress: onProgress), errorMessage: nil))
                    } catch {
                        return .page(SearchPageResult(page: page, results: [], errorMessage: self.errorMessage(from: error)))
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(self.searchCollectionTimeoutSeconds()) * 1_000_000_000)
                return .timeout
            }

            var resultsByPage: [Int: [TorrentSearchResult]] = [:]
            var pagesSeen: Set<Int> = []
            var firstErrorMessage: String?
            var hitCollectionTimeout = false
            for await event in group {
                switch event {
                case .page(let result):
                    resultsByPage[result.page] = result.results
                    pagesSeen.insert(result.page)
                    if firstErrorMessage == nil {
                        firstErrorMessage = result.errorMessage
                    }
                    if pagesSeen.count >= pageCount {
                        // All page fetches have completed; don't wait for the collection timeout task.
                        group.cancelAll()
                    }
                case .timeout:
                    hitCollectionTimeout = true
                    group.cancelAll()
                }
            }

            return (
                results: (1...pageCount).flatMap { resultsByPage[$0] ?? [] },
                firstErrorMessage: firstErrorMessage,
                hitCollectionTimeout: hitCollectionTimeout
            )
        }

        if !pageFetch.results.isEmpty {
            return pageFetch.results
        }
        if pageFetch.hitCollectionTimeout {
            throw ProviderError.timedOut(provider: config.name, seconds: searchCollectionTimeoutSeconds())
        }
        if let firstErrorMessage = pageFetch.firstErrorMessage {
            throw ProviderError.accessBlocked(provider: config.name, reason: firstErrorMessage)
        }
        return []
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

    private func parseResults(
        from blocks: [String],
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
            // Some providers change markup; defaulting to 0/0 and then dropping silently causes false-empty searches.
            if parsedSeeders != nil && parsedLeechers != nil {
                guard !(seeders == 0 && leechers < 2) else { continue }
            }
            let size = config.sizePattern.flatMap { RegexTools.firstCapture(pattern: $0, in: block) }?.htmlDecoded.cleanedText

            let inlineMagnet = config.magnetPattern.flatMap { RegexTools.firstCapture(pattern: $0, in: block) }?.htmlDecoded
            let detailURL = extractDetailURL(from: block)

            let magnet: String?
            if let inlineMagnet {
                magnet = inlineMagnet
            } else if config.fetchMagnetFromDetailDuringSearch, let detailURL, let magnetPattern = config.magnetPattern {
                let detailHTML = try? await fetchText(detailURL, referer: sameSiteHomeURL(for: detailURL))
                magnet = detailHTML.flatMap { RegexTools.firstCapture(pattern: magnetPattern, in: $0) }?.htmlDecoded
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

    private func fetchText(_ url: URL, referer: URL? = nil, timeoutSeconds: Int? = nil) async throws -> String {
        do {
            let (data, response) = try await session.data(for: makeRequest(url: url, referer: referer, timeoutSeconds: timeoutSeconds))
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

    private func makeRequest(url: URL, referer: URL? = nil, timeoutSeconds: Int? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(timeoutSeconds ?? config.timeoutSeconds ?? 20)
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

    private func sameSiteHomeURL(for url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return URL(string: "\(scheme)://\(host)/")
    }

    private func encodedSearchQueries(_ query: String) -> [String] {
        searchQueryVariants(query)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0 }
            .uniquedPreservingOrder()
    }

    private func searchQueryVariants(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [query] }
        guard config.id == "1337x" else { return [trimmed] }

        let tokens = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard tokens.count > 1,
              ["a", "an", "the"].contains(tokens[0].lowercased()) else {
            return [trimmed]
        }

        return [trimmed, tokens.dropFirst().joined(separator: " ")]
    }

    private func searchRequestTimeoutSeconds() -> Int {
        let providerTimeout = config.timeoutSeconds ?? 20
        return max(5, providerTimeout - 2)
    }

    private func searchCollectionTimeoutSeconds() -> Int {
        let providerTimeout = config.timeoutSeconds ?? 20
        return max(5, providerTimeout - 3)
    }
}

private struct SearchPageResult: Sendable {
    let page: Int
    let results: [TorrentSearchResult]
    let errorMessage: String?
}

private enum SearchPageEvent: Sendable {
    case page(SearchPageResult)
    case timeout
}

private struct SearchTemplateResult: Sendable {
    let results: [TorrentSearchResult]
    let error: Error?
}

private extension Array where Element: Hashable {
    func uniquedPreservingOrder() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
