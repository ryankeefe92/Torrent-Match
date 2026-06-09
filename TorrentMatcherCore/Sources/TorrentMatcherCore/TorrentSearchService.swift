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

public struct RankedSearchUpdate: Sendable {
    public let results: [RankedTorrentResult]
    public let foundSoFar: Int

    public init(results: [RankedTorrentResult], foundSoFar: Int) {
        self.results = results
        self.foundSoFar = foundSoFar
    }
}

public final class TorrentSearchService: @unchecked Sendable {
    private let providers: [TorrentProvider]
    private let weights: RankerWeights
    private let providerTimeoutSeconds: Int
    private let magnetResolveTimeoutSeconds: Int
    private let magnetCache = MagnetResolutionCache()
    private let detailCache = DetailMetadataCache()

    public init(
        configs: [ProviderConfig],
        weights: RankerWeights = .appleTVDefault,
        providerTimeoutSeconds: Int = 30,
        magnetResolveTimeoutSeconds: Int = 35
    ) {
        self.providers = configs.map(Self.provider(for:))
        self.weights = weights
        self.providerTimeoutSeconds = providerTimeoutSeconds
        self.magnetResolveTimeoutSeconds = magnetResolveTimeoutSeconds
    }

    public init(
        providers: [TorrentProvider],
        weights: RankerWeights = .appleTVDefault,
        providerTimeoutSeconds: Int = 30,
        magnetResolveTimeoutSeconds: Int = 35
    ) {
        self.providers = providers
        self.weights = weights
        self.providerTimeoutSeconds = providerTimeoutSeconds
        self.magnetResolveTimeoutSeconds = magnetResolveTimeoutSeconds
    }

    public func searchAndRank(_ query: String) async -> [RankedTorrentResult] {
        let rawResults = await searchAll(query)
        return TorrentRanker.rank(rawResults, hideExcluded: true, weights: weights)
    }

    public func searchAndRankReport(_ query: String) async -> RankedSearchReport {
        let report = await searchReport(query, onProgress: nil, onUpdate: nil)
        return RankedSearchReport(
            results: rankVisibleResults(report.results, matching: query, weights: weights),
            failures: report.failures
        )
    }

    public func searchAndRankReport(
        _ query: String,
        onProgress: (@Sendable (_ foundSoFar: Int) -> Void)?
    ) async -> RankedSearchReport {
        let report = await searchReport(query, onProgress: onProgress, onUpdate: nil)
        return RankedSearchReport(
            results: rankVisibleResults(report.results, matching: query, weights: weights),
            failures: report.failures
        )
    }

    public func searchAndRankReport(
        _ query: String,
        onUpdate: (@Sendable (_ update: RankedSearchUpdate) -> Void)?
    ) async -> RankedSearchReport {
        let report = await searchReport(query, onProgress: nil, onUpdate: onUpdate)
        return RankedSearchReport(
            results: rankVisibleResults(report.results, matching: query, weights: weights),
            failures: report.failures
        )
    }

    public func searchAll(_ query: String) async -> [TorrentSearchResult] {
        let report = await searchReport(query, onProgress: nil, onUpdate: nil)
        return report.results
    }

    public func resolveMagnet(for result: TorrentSearchResult) async throws -> String? {
        if let magnet = result.magnet, !magnet.isEmpty {
            return magnet
        }
        guard let provider = providers.first(where: { $0.config.name == result.provider }) else {
            return result.magnet
        }

        let operation = { @Sendable in
            try await self.withProviderTimeout(
                provider: provider,
                seconds: max(1, self.magnetResolveTimeoutSeconds)
            ) {
                try await provider.resolveMagnet(for: result)
            }
        }

        guard let cacheKey = magnetCacheKey(for: result) else {
            return try await operation()
        }
        return try await magnetCache.value(for: cacheKey, operation: operation)
    }

    public func fetchDetailMetadata(for result: TorrentSearchResult) async throws -> TorrentDetailMetadata? {
        guard let provider = providers.first(where: { $0.config.name == result.provider }) else {
            return nil
        }

        let operation = { @Sendable in
            try await self.withProviderTimeout(
                provider: provider,
                seconds: max(1, self.magnetResolveTimeoutSeconds)
            ) {
                try await provider.fetchDetailMetadata(for: result)
            }
        }

        guard let cacheKey = magnetCacheKey(for: result) else {
            return try await operation()
        }
        return try await detailCache.value(for: cacheKey, operation: operation)
    }

    private func magnetCacheKey(for result: TorrentSearchResult) -> String? {
        if let detailURL = result.detailURL {
            return "\(result.provider)|\(detailURL.absoluteString)"
        }
        return nil
    }

    private func searchReport(
        _ query: String,
        onProgress: (@Sendable (_ foundSoFar: Int) -> Void)?,
        onUpdate: (@Sendable (_ update: RankedSearchUpdate) -> Void)?
    ) async -> (results: [TorrentSearchResult], failures: [ProviderFailure]) {
        let progressTracker = SearchProgressTracker(query: query, weights: weights)
        let collected = await withTaskGroup(of: ([TorrentSearchResult], ProviderFailure?).self) { group in
            for provider in providers {
                group.addTask {
                    let partialCollector = PartialResultCollector()
                    do {
                        return (
                            try await self.searchWithTimeout(provider: provider, query: query) { addedResults in
                                await partialCollector.append(addedResults)
                                let update = await progressTracker.append(addedResults)
                                if let onProgress {
                                    onProgress(update.foundSoFar)
                                }
                                if let onUpdate {
                                    onUpdate(update)
                                }
                            },
                            nil
                        )
                    }
                    catch {
                        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                        print("Provider failed: \(provider.config.name) - \(message)")
                        return (
                            await partialCollector.snapshot(),
                            ProviderFailure(providerName: provider.config.name, message: message)
                        )
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
        return (dedupe(filterResults(collected.0, matching: query)), collected.1)
    }

    private func searchWithTimeout(
        provider: TorrentProvider,
        query: String,
        onProgress: (@Sendable (_ addedResults: [TorrentSearchResult]) async -> Void)?
    ) async throws -> [TorrentSearchResult] {
        try await searchWithTimeout(provider: provider, query: query, timeoutOverride: nil, onProgress: onProgress)
    }

    private func searchWithTimeout(
        provider: TorrentProvider,
        query: String,
        timeoutOverride: Int?,
        onProgress: (@Sendable (_ addedResults: [TorrentSearchResult]) async -> Void)? = nil
    ) async throws -> [TorrentSearchResult] {
        let seconds = timeoutOverride ?? effectiveTimeout(for: provider, cap: providerTimeoutSeconds)
        return try await withProviderTimeout(provider: provider, seconds: seconds) {
            try await provider.search(query, onProgress: onProgress)
        }
    }

    private func effectiveTimeout(for provider: TorrentProvider, cap: Int) -> Int {
        guard let providerTimeout = provider.config.timeoutSeconds else {
            return cap
        }
        return max(1, min(providerTimeout, cap))
    }

    private func withProviderTimeout<T: Sendable>(
        provider: TorrentProvider,
        seconds: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                throw ProviderError.timedOut(provider: provider.config.name, seconds: seconds)
            }

            do {
                guard let result = try await group.next() else {
                    group.cancelAll()
                    throw ProviderError.timedOut(provider: provider.config.name, seconds: seconds)
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func dedupe(_ results: [TorrentSearchResult]) -> [TorrentSearchResult] {
        dedupeResults(results, weights: weights)
    }

    private func filterResults(_ results: [TorrentSearchResult], matching query: String) -> [TorrentSearchResult] {
        filterSearchResults(results, matching: query)
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

private actor SearchProgressTracker {
    private let query: String
    private let weights: RankerWeights
    private var results: [TorrentSearchResult] = []

    init(query: String, weights: RankerWeights) {
        self.query = query
        self.weights = weights
    }

    func append(_ addedResults: [TorrentSearchResult]) -> RankedSearchUpdate {
        results.append(contentsOf: addedResults)
        let ranked = rankVisibleResults(results, matching: query, weights: weights)
        return RankedSearchUpdate(results: ranked, foundSoFar: ranked.count)
    }
}

private actor PartialResultCollector {
    private var results: [TorrentSearchResult] = []

    func append(_ addedResults: [TorrentSearchResult]) {
        results.append(contentsOf: addedResults)
    }

    func snapshot() -> [TorrentSearchResult] {
        results
    }
}

private func filterSearchResults(_ results: [TorrentSearchResult], matching query: String) -> [TorrentSearchResult] {
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

private func dedupeResults(_ results: [TorrentSearchResult], weights: RankerWeights) -> [TorrentSearchResult] {
    TorrentResultDedupe.dedupe(results, weights: weights)
}

private func rankVisibleResults(
    _ results: [TorrentSearchResult],
    matching query: String,
    weights: RankerWeights
) -> [RankedTorrentResult] {
    let filtered = filterSearchResults(results, matching: query)
    let deduped = dedupeResults(filtered, weights: weights)
    return TorrentRanker.rank(deduped, hideExcluded: true, weights: weights)
}

private actor MagnetResolutionCache {
    private var resolved: [String: String] = [:]
    private var inFlight: [String: Task<String?, Error>] = [:]

    func value(
        for key: String,
        operation: @escaping @Sendable () async throws -> String?
    ) async throws -> String? {
        if let magnet = resolved[key] {
            return magnet
        }
        if let task = inFlight[key] {
            return try await task.value
        }

        let task = Task {
            try await operation()
        }
        inFlight[key] = task

        do {
            let magnet = try await task.value
            if let magnet, !magnet.isEmpty {
                resolved[key] = magnet
            }
            inFlight[key] = nil
            return magnet
        } catch {
            inFlight[key] = nil
            throw error
        }
    }
}

private actor DetailMetadataCache {
    private var resolved: [String: TorrentDetailMetadata] = [:]
    private var inFlight: [String: Task<TorrentDetailMetadata?, Error>] = [:]

    func value(
        for key: String,
        operation: @escaping @Sendable () async throws -> TorrentDetailMetadata?
    ) async throws -> TorrentDetailMetadata? {
        if let metadata = resolved[key] {
            return metadata
        }
        if let task = inFlight[key] {
            return try await task.value
        }

        let task = Task {
            try await operation()
        }
        inFlight[key] = task

        do {
            let metadata = try await task.value
            if let metadata {
                resolved[key] = metadata
            }
            inFlight[key] = nil
            return metadata
        } catch {
            inFlight[key] = nil
            throw error
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

        for startIndex in titleTokens.indices {
            guard titleTokens[startIndex] == queryTitleTokens[0] else { continue }
            if let endIndex = matchedQueryTitleEndIndex(
                titleTokens: titleTokens,
                queryTitleTokens: queryTitleTokens,
                startingAt: startIndex
            ), titleMatchesExpectedReleaseContinuation(
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
              !queryTitleTokens.isEmpty else { return [] }

        var years: [String] = []
        for startIndex in titleTokens.indices {
            guard titleTokens[startIndex] == queryTitleTokens[0],
                  let endIndex = matchedQueryTitleEndIndex(
                    titleTokens: titleTokens,
                    queryTitleTokens: queryTitleTokens,
                    startingAt: startIndex
                  ) else { continue }

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

    private func matchedQueryTitleEndIndex(
        titleTokens: [String],
        queryTitleTokens: [String],
        startingAt startIndex: Int
    ) -> Int? {
        var titleIndex = startIndex
        var queryIndex = 0

        while titleIndex < titleTokens.count && queryIndex < queryTitleTokens.count {
            let titleToken = titleTokens[titleIndex]
            let queryToken = queryTitleTokens[queryIndex]
            if titleToken == queryToken {
                titleIndex += 1
                queryIndex += 1
                continue
            }

            if queryIndex > 0 && Self.isIntraTitleBridgeToken(titleToken) {
                titleIndex += 1
                continue
            }

            return nil
        }

        guard queryIndex == queryTitleTokens.count else { return nil }
        return titleIndex
    }

    private static func isTitleYearBridgeToken(_ token: String) -> Bool {
        [
            "a", "an", "and", "anniversary", "collector", "collectors", "criterion", "cut", "dc", "directors",
            "director", "edition", "extended", "final", "for", "in", "of", "on", "part", "pt", "remaster",
            "remastered", "restored", "restoration", "s", "special", "the", "theatrical", "to", "ultimate",
            "uncut", "unrated"
        ].contains(token) || token.range(of: #"^\d+(?:st|nd|rd|th)$"#, options: .regularExpression) != nil
    }

    private static func isIntraTitleBridgeToken(_ token: String) -> Bool {
        isTitleYearBridgeToken(token) || [
            "chapter", "episode", "la", "le"
        ].contains(token)
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
            "HDRIP", "DVDRIP", "HMAX", "REMUX", "HDR", "DV", "DOVI", "X264", "X265",
            "H264", "H265", "DDP", "TRUEHD", "DTS"
        ]
        return movieMarkers.contains(where: upper.contains)
    }
}
