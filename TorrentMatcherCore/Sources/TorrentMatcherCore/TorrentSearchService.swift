import Foundation

public struct ProviderFailure: Hashable, Sendable {
    public let providerName: String
    public let message: String

    public init(providerName: String, message: String) {
        self.providerName = providerName
        self.message = message
    }
}

public struct RankedSearchReport: Sendable {
    public let results: [RankedTorrentResult]
    public let failures: [ProviderFailure]

    public init(results: [RankedTorrentResult], failures: [ProviderFailure]) {
        self.results = results
        self.failures = failures
    }
}

public final class TorrentSearchService: @unchecked Sendable {
    private let providers: [TorrentProvider]
    private let weights: RankerWeights
    private let providerTimeoutSeconds: Int

    public init(configs: [ProviderConfig], weights: RankerWeights = .appleTVDefault, providerTimeoutSeconds: Int = 20) {
        self.providers = configs.map(Self.provider(for:))
        self.weights = weights
        self.providerTimeoutSeconds = providerTimeoutSeconds
    }

    public init(providers: [TorrentProvider], weights: RankerWeights = .appleTVDefault, providerTimeoutSeconds: Int = 20) {
        self.providers = providers
        self.weights = weights
        self.providerTimeoutSeconds = providerTimeoutSeconds
    }

    public func searchAndRank(_ query: String) async -> [RankedTorrentResult] {
        let rawResults = await searchAll(query)
        return TorrentRanker.rank(rawResults, hideExcluded: true, weights: weights)
    }

    public func searchAndRankReport(_ query: String) async -> RankedSearchReport {
        let report = await searchReport(query)
        return RankedSearchReport(
            results: TorrentRanker.rank(report.results, hideExcluded: true, weights: weights),
            failures: report.failures
        )
    }

    public func searchAll(_ query: String) async -> [TorrentSearchResult] {
        let report = await searchReport(query)
        return report.results
    }

    public func resolveMagnet(for result: TorrentSearchResult) async throws -> String? {
        guard let provider = providers.first(where: { $0.config.name == result.provider }) else {
            return result.magnet
        }
        return try await provider.resolveMagnet(for: result)
    }

    private func searchReport(_ query: String) async -> (results: [TorrentSearchResult], failures: [ProviderFailure]) {
        let collected = await withTaskGroup(of: ([TorrentSearchResult], ProviderFailure?).self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        return (try await self.searchWithTimeout(provider: provider, query: query), nil)
                    }
                    catch {
                        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                        print("Provider failed: \(provider.config.name) - \(message)")
                        return ([], ProviderFailure(providerName: provider.config.name, message: message))
                    }
                }
            }

            var collected: [TorrentSearchResult] = []
            var failures: [ProviderFailure] = []
            for await outcome in group {
                collected.append(contentsOf: outcome.0)
                if let failure = outcome.1 {
                    failures.append(failure)
                }
            }
            return (collected, failures)
        }
        let filtered = filterResults(collected.0, matching: query)
        return (dedupe(filtered), collected.1)
    }

    private func searchWithTimeout(provider: TorrentProvider, query: String) async throws -> [TorrentSearchResult] {
        try await searchWithTimeout(provider: provider, query: query, timeoutOverride: nil)
    }

    private func searchWithTimeout(
        provider: TorrentProvider,
        query: String,
        timeoutOverride: Int?
    ) async throws -> [TorrentSearchResult] {
        let timeoutSeconds = timeoutOverride ?? provider.config.timeoutSeconds ?? providerTimeoutSeconds
        return try await withThrowingTaskGroup(of: [TorrentSearchResult].self) { group in
            group.addTask {
                try await provider.search(query)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                throw ProviderError.timedOut(provider: provider.config.name, seconds: timeoutSeconds)
            }

            let results = try await group.next() ?? []
            group.cancelAll()
            return results
        }
    }

    private func dedupe(_ results: [TorrentSearchResult]) -> [TorrentSearchResult] {
        var bestByKey: [String: TorrentSearchResult] = [:]
        var order: [String] = []

        for result in results {
            let key = result.magnet?.infoHashFromMagnet?.lowercased() ?? result.title.normalizedDedupeKey
            if let existing = bestByKey[key] {
                bestByKey[key] = preferredDuplicate(between: existing, and: result)
            } else {
                bestByKey[key] = result
                order.append(key)
            }
        }

        return order.compactMap { bestByKey[$0] }
    }

    private func preferredDuplicate(between lhs: TorrentSearchResult, and rhs: TorrentSearchResult) -> TorrentSearchResult {
        let lhsHasMagnet = lhs.magnet?.isEmpty == false
        let rhsHasMagnet = rhs.magnet?.isEmpty == false

        if lhsHasMagnet != rhsHasMagnet {
            return lhsHasMagnet ? lhs : rhs
        }

        let lhsRanked = TorrentRanker.score(lhs, weights: weights)
        let rhsRanked = TorrentRanker.score(rhs, weights: weights)

        if lhsRanked.excluded != rhsRanked.excluded {
            return lhsRanked.excluded ? rhs : lhs
        }

        if lhsRanked.score != rhsRanked.score {
            return lhsRanked.score >= rhsRanked.score ? lhs : rhs
        }

        if lhs.seeders != rhs.seeders {
            return lhs.seeders >= rhs.seeders ? lhs : rhs
        }

        return lhs
    }

    private func filterResults(_ results: [TorrentSearchResult], matching query: String) -> [TorrentSearchResult] {
        let queryTokens = query.searchMatchTokens
        guard !queryTokens.isEmpty else { return results }
        return results.filter { result in
            guard result.title.matchesSearchQueryTokens(queryTokens),
                  result.title.matchesMovieTitleIdentity(queryTokens: queryTokens) else { return false }
            if result.provider == "1337x" {
                return result.title.isLikelyMovieReleaseTitle
            }
            return true
        }
    }

    private static func provider(for config: ProviderConfig) -> TorrentProvider {
        switch config.id {
        case "pirate-bay":
            return PirateBayAPIProvider(config: config)
        default:
            return RegexHTMLProvider(config: config)
        }
    }
}

private extension String {
    var searchMatchTokens: [String] {
        lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    func matchesSearchQueryTokens(_ queryTokens: [String]) -> Bool {
        let titleTokens = searchMatchTokens
        guard !titleTokens.isEmpty else { return false }

        let normalizedTitle = titleTokens.joined(separator: " ")
        let normalizedQuery = queryTokens.joined(separator: " ")
        if normalizedTitle.contains(normalizedQuery) {
            return true
        }

        var titleIndex = 0
        for queryToken in queryTokens {
            var found = false
            while titleIndex < titleTokens.count {
                if titleTokens[titleIndex] == queryToken {
                    found = true
                    titleIndex += 1
                    break
                }
                titleIndex += 1
            }
            if !found {
                return false
            }
        }
        return true
    }

    func matchesMovieTitleIdentity(queryTokens: [String]) -> Bool {
        let titleTokens = searchMatchTokens
        guard !titleTokens.isEmpty else { return false }

        let queryYear = queryTokens.first(where: Self.isReleaseYearToken)
        let queryTitleTokens = queryTokens.filter { !Self.isReleaseYearToken($0) }
        guard !queryTitleTokens.isEmpty else {
            guard let queryYear else { return true }
            return titleTokens.contains(queryYear)
        }
        guard queryTitleTokens.count <= titleTokens.count else { return false }

        for startIndex in 0...(titleTokens.count - queryTitleTokens.count) {
            let endIndex = startIndex + queryTitleTokens.count
            guard titleTokens[startIndex..<endIndex].elementsEqual(queryTitleTokens) else { continue }
            if titleMatchesExpectedReleaseContinuation(
                titleTokens: titleTokens,
                after: endIndex,
                requiredYear: queryYear
            ) {
                return true
            }
        }

        return false
    }

    private func titleMatchesExpectedReleaseContinuation(
        titleTokens: [String],
        after index: Int,
        requiredYear: String?
    ) -> Bool {
        if let requiredYear {
            var currentIndex = index
            while currentIndex < titleTokens.count {
                let token = titleTokens[currentIndex]
                if token == requiredYear { return true }
                if !Self.isTitleYearBridgeToken(token) { return false }
                currentIndex += 1
            }
            return false
        }

        var currentIndex = index
        guard currentIndex < titleTokens.count else { return false }

        while currentIndex < titleTokens.count {
            if Self.isReleaseYearToken(titleTokens[currentIndex]) ||
                Self.isReleaseMarker(in: titleTokens, at: currentIndex) {
                return true
            }
            if !Self.isTitleYearBridgeToken(titleTokens[currentIndex]) {
                return false
            }
            currentIndex += 1
        }

        return false
    }

    static func isReleaseYearToken(_ token: String) -> Bool {
        guard token.count == 4,
              let year = Int(token),
              year >= 1900 else { return false }
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        return year <= currentYear + 1
    }

    func movieIdentityYears(queryTokens: [String]) -> [String] {
        let titleTokens = searchMatchTokens
        let queryTitleTokens = queryTokens.filter { !Self.isReleaseYearToken($0) }
        guard !titleTokens.isEmpty,
              !queryTitleTokens.isEmpty,
              queryTitleTokens.count <= titleTokens.count else { return [] }

        var years: [String] = []
        for startIndex in 0...(titleTokens.count - queryTitleTokens.count) {
            let endIndex = startIndex + queryTitleTokens.count
            guard titleTokens[startIndex..<endIndex].elementsEqual(queryTitleTokens) else { continue }

            var currentIndex = endIndex
            while currentIndex < titleTokens.count {
                let token = titleTokens[currentIndex]
                if Self.isReleaseYearToken(token) {
                    years.append(token)
                    break
                }
                if !Self.isTitleYearBridgeToken(token) {
                    break
                }
                currentIndex += 1
            }
        }
        return years
    }

    private static func isTitleYearBridgeToken(_ token: String) -> Bool {
        [
            "anniversary", "collector", "collectors", "criterion", "cut", "dc", "directors", "director", "edition",
            "extended", "final", "remaster", "remastered", "restored", "restoration",
            "s", "special", "the", "theatrical", "ultimate", "uncut", "unrated"
        ].contains(token) || token.range(of: #"^\d+(?:st|nd|rd|th)$"#, options: .regularExpression) != nil
    }

    private static func isReleaseMarker(in tokens: [String], at index: Int) -> Bool {
        let token = tokens[index]
        if token.hasSuffix("p"), Int(token.dropLast()) != nil {
            return true
        }

        if token == "web", tokens.indices.contains(index + 1), tokens[index + 1] == "dl" {
            return true
        }

        if token == "blu", tokens.indices.contains(index + 1), tokens[index + 1] == "ray" {
            return true
        }

        return [
            "aac", "atmos", "av1", "avc", "bdrip", "bluray", "brrip", "cam", "dovi",
            "dts", "dvd", "dvdrip", "h264", "h265", "hdcam", "hdr", "hdrip", "hdts",
            "hevc", "proper", "repack", "remux", "sdr", "tc", "truehd", "ts", "uhd",
            "webdl", "webrip", "x264", "x265"
        ].contains(token)
    }

    var isLikelyMovieReleaseTitle: Bool {
        let upper = uppercased()

        // Reject common TV-style patterns from the broad 1337x search.
        let tvPatterns = [
            #"(?:^|[^A-Z0-9])S\d{1,2}E\d{1,2}(?:[^A-Z0-9]|$)"#,
            #"(?:^|[^A-Z0-9])SEASON(?:[^A-Z0-9]|\s)*\d{1,2}(?:[^A-Z0-9]|$)"#,
            #"(?:^|[^A-Z0-9])EP(?:ISODE)?(?:[^A-Z0-9]|\s)*\d{1,3}(?:[^A-Z0-9]|$)"#,
            #"(?:^|[^A-Z0-9])\d{1,2}X\d{1,2}(?:[^A-Z0-9]|$)"#
        ]
        if tvPatterns.contains(where: { upper.range(of: $0, options: .regularExpression) != nil }) {
            return false
        }

        let hasYear = upper.range(of: #"(?:^|[^A-Z0-9])(?:19|20)\d{2}(?:[^A-Z0-9]|$)"#, options: .regularExpression) != nil
        if hasYear {
            return true
        }

        let movieMarkers = [
            "2160P", "1080P", "720P", "BLURAY", "BDRIP", "WEBRIP", "WEB-DL", "WEBDL",
            "HDRIP", "DVDRIP", "HMAX", "REMUX", "HDR", "DV", "DOVI"
        ]
        return movieMarkers.contains(where: upper.contains)
    }
}
