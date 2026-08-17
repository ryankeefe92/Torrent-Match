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
    public let sequence: Int

    public init(results: [RankedTorrentResult], foundSoFar: Int, sequence: Int = 0) {
        self.results = results
        self.foundSoFar = foundSoFar
        self.sequence = sequence
    }
}

public final class TorrentSearchService: @unchecked Sendable {
    private let providers: [TorrentProvider]
    private let providerTimeoutSeconds: Int
    private let magnetResolveTimeoutSeconds: Int
    private let magnetCache = MagnetResolutionCache()
    private let detailCache = DetailMetadataCache()

    public init(
        configs: [ProviderConfig],
        providerTimeoutSeconds: Int = 30,
        magnetResolveTimeoutSeconds: Int = 35
    ) {
        self.providers = configs.map(Self.provider(for:))
        self.providerTimeoutSeconds = providerTimeoutSeconds
        self.magnetResolveTimeoutSeconds = magnetResolveTimeoutSeconds
    }

    public init(
        providers: [TorrentProvider],
        providerTimeoutSeconds: Int = 30,
        magnetResolveTimeoutSeconds: Int = 35
    ) {
        self.providers = providers
        self.providerTimeoutSeconds = providerTimeoutSeconds
        self.magnetResolveTimeoutSeconds = magnetResolveTimeoutSeconds
    }

    public func searchAndRank(_ query: String) async -> [RankedTorrentResult] {
        await searchAndRank(.movie(query))
    }

    public func searchAndRank(_ request: TorrentSearchRequest) async -> [RankedTorrentResult] {
        let rawResults = await searchAll(request)
        return TorrentRanker.rank(
            rawResults,
            hideExcluded: true,
            profile: request.rankingProfile
        )
    }

    public func searchAndRankReport(_ query: String) async -> RankedSearchReport {
        await searchAndRankReport(.movie(query))
    }

    public func searchAndRankReport(_ request: TorrentSearchRequest) async -> RankedSearchReport {
        let report = await searchReport(request, onProgress: nil, onUpdate: nil)
        let results = await applyRuntimeFallbacks(to: report.results, request: request)
        return RankedSearchReport(
            results: rankVisibleResults(results, matching: request),
            failures: report.failures
        )
    }

    public func searchAndRankReport(
        _ query: String,
        onProgress: (@Sendable (_ foundSoFar: Int) -> Void)?
    ) async -> RankedSearchReport {
        await searchAndRankReport(.movie(query), onProgress: onProgress)
    }

    public func searchAndRankReport(
        _ request: TorrentSearchRequest,
        onProgress: (@Sendable (_ foundSoFar: Int) -> Void)?
    ) async -> RankedSearchReport {
        let report = await searchReport(request, onProgress: onProgress, onUpdate: nil)
        let results = await applyRuntimeFallbacks(to: report.results, request: request)
        return RankedSearchReport(
            results: rankVisibleResults(results, matching: request),
            failures: report.failures
        )
    }

    public func searchAndRankReport(
        _ query: String,
        onUpdate: (@Sendable (_ update: RankedSearchUpdate) -> Void)?
    ) async -> RankedSearchReport {
        await searchAndRankReport(.movie(query), onUpdate: onUpdate)
    }

    public func searchAndRankReport(
        _ request: TorrentSearchRequest,
        onUpdate: (@Sendable (_ update: RankedSearchUpdate) -> Void)?
    ) async -> RankedSearchReport {
        let report = await searchReport(request, onProgress: nil, onUpdate: onUpdate)
        let results = await applyRuntimeFallbacks(to: report.results, request: request)
        return RankedSearchReport(
            results: rankVisibleResults(results, matching: request),
            failures: report.failures
        )
    }

    public func searchAll(_ query: String) async -> [TorrentSearchResult] {
        await searchAll(.movie(query))
    }

    public func searchAll(_ request: TorrentSearchRequest) async -> [TorrentSearchResult] {
        let report = await searchReport(request, onProgress: nil, onUpdate: nil)
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
        _ request: TorrentSearchRequest,
        onProgress: (@Sendable (_ foundSoFar: Int) -> Void)?,
        onUpdate: (@Sendable (_ update: RankedSearchUpdate) -> Void)?
    ) async -> (results: [TorrentSearchResult], failures: [ProviderFailure]) {
        let progressTracker = SearchProgressTracker(request: request)
        let collected = await withTaskGroup(of: ([TorrentSearchResult], ProviderFailure?).self) { group in
            for provider in providers {
                guard let providerQueries = request.providerQueries(for: provider.config.id),
                      let providerQuery = providerQueries.first else {
                    continue
                }
                group.addTask {
                    let partialCollector = PartialResultCollector(profile: request.rankingProfile)
                    let providerRequest = TorrentProviderSearchRequest(
                        query: providerQuery,
                        queryVariants: providerQueries,
                        target: request.target
                    )
                    do {
                        return (
                            try await self.searchWithTimeout(provider: provider, request: providerRequest) { addedResults in
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
        return (
            dedupe(
                filterResults(collected.0, matching: request),
                profile: request.rankingProfile
            ),
            collected.1
        )
    }

    private func searchWithTimeout(
        provider: TorrentProvider,
        request: TorrentProviderSearchRequest,
        onProgress: (@Sendable (_ addedResults: [TorrentSearchResult]) async -> Void)?
    ) async throws -> [TorrentSearchResult] {
        try await searchWithTimeout(provider: provider, request: request, timeoutOverride: nil, onProgress: onProgress)
    }

    private func searchWithTimeout(
        provider: TorrentProvider,
        request: TorrentProviderSearchRequest,
        timeoutOverride: Int?,
        onProgress: (@Sendable (_ addedResults: [TorrentSearchResult]) async -> Void)? = nil
    ) async throws -> [TorrentSearchResult] {
        let seconds = timeoutOverride ?? effectiveTimeout(for: provider, cap: providerTimeoutSeconds)
        return try await withProviderTimeout(provider: provider, seconds: seconds) {
            try await provider.search(request, onProgress: onProgress)
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

    private func dedupe(
        _ results: [TorrentSearchResult],
        profile: TorrentRankingProfile
    ) -> [TorrentSearchResult] {
        dedupeResults(results, profile: profile)
    }

    private func filterResults(
        _ results: [TorrentSearchResult],
        matching request: TorrentSearchRequest
    ) -> [TorrentSearchResult] {
        filterSearchResults(results, matching: request)
    }

    private func applyRuntimeFallbacks(
        to results: [TorrentSearchResult],
        request: TorrentSearchRequest
    ) async -> [TorrentSearchResult] {
        guard case .movie(let query) = request.target else {
            return results
        }
        let queryRuntime = await MovieCatalog.shared.runtime(for: query)?.displayText
        var enriched: [TorrentSearchResult] = []
        enriched.reserveCapacity(results.count)

        for result in results {
            let existingRuntime = result.detailSpecs?.runtime?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let runtimeLookupTitle = result.detailSpecs?.fullTorrentName ??
                result.detailSpecs?.releaseHintText ??
                result.title
            let runtime: String?
            if let existingRuntime {
                runtime = existingRuntime
            } else if runtimeLookupTitle.isKnownRuntimeCompatibleCut {
                let titleRuntime = queryRuntime == nil ? await MovieCatalog.shared.runtime(for: result.title)?.displayText : nil
                runtime = queryRuntime ?? titleRuntime
            } else {
                runtime = await OnlineRuntimeLookup.shared.runtime(for: runtimeLookupTitle, query: query)?.displayText
            }

            guard let runtime else {
                enriched.append(result)
                continue
            }

            let overallBitrate = result.detailSpecs?.overallBitrate == nil ? calculatedOverallBitrate(size: result.size, runtime: runtime) : nil
            guard existingRuntime == nil || overallBitrate != nil else {
                enriched.append(result)
                continue
            }
            let specs = (result.detailSpecs ?? TorrentDetailSpecs()).withFallbackRuntime(runtime, overallBitrate: overallBitrate)
            enriched.append(TorrentSearchResult(
                id: result.id,
                title: result.title,
                detailMetadata: result.detailMetadata,
                detailSpecs: specs,
                magnet: result.magnet,
                detailURL: result.detailURL,
                seeders: result.seeders,
                leechers: result.leechers,
                provider: result.provider,
                size: result.size
            ))
        }
        return enriched
    }

    private func calculatedOverallBitrate(size: String?, runtime: String) -> String? {
        guard let sizeBytes = fileSizeBytes(size),
              let runtimeSeconds = runtimeSeconds(from: runtime),
              runtimeSeconds > 0 else { return nil }
        let kbps = Int((sizeBytes * 8) / runtimeSeconds / 1_000)
        guard kbps > 0 else { return nil }
        return displayBitrate(kbps)
    }

    private static func provider(for config: ProviderConfig) -> TorrentProvider {
        switch config.id {
        case "pirate-bay":
            return PirateBayAPIProvider(config: config)
        case "eztv":
            return EZTVAPIProvider(config: config)
        case "magnetz":
            return MagnetzAPIProvider(config: config)
        case "yts":
            return YTSAPIProvider(config: config)
        default:
            return RegexHTMLProvider(config: config)
        }
    }
}

private actor SearchProgressTracker {
    private let request: TorrentSearchRequest
    private var results: [TorrentSearchResult] = []
    private var sequence = 0

    init(request: TorrentSearchRequest) {
        self.request = request
    }

    func append(_ addedResults: [TorrentSearchResult]) -> RankedSearchUpdate {
        results = dedupeResults(
            results + addedResults,
            profile: request.rankingProfile
        )
        sequence += 1
        let ranked = rankVisibleResults(results, matching: request)
        return RankedSearchUpdate(results: ranked, foundSoFar: ranked.count, sequence: sequence)
    }
}

private actor PartialResultCollector {
    private let profile: TorrentRankingProfile
    private var results: [TorrentSearchResult] = []

    init(profile: TorrentRankingProfile) {
        self.profile = profile
    }

    func append(_ addedResults: [TorrentSearchResult]) {
        results = dedupeResults(results + addedResults, profile: profile)
    }

    func snapshot() -> [TorrentSearchResult] {
        results
    }
}

private func filterSearchResults(
    _ results: [TorrentSearchResult],
    matching request: TorrentSearchRequest
) -> [TorrentSearchResult] {
    switch request.target {
    case .movie(let query):
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
    case .tvEpisode, .tvSeasonPack:
        return results.filter {
            TVReleaseParser.matches($0.title, target: request.target)
        }
    }
}

private func dedupeResults(
    _ results: [TorrentSearchResult],
    profile: TorrentRankingProfile
) -> [TorrentSearchResult] {
    TorrentResultDedupe.dedupe(results, profile: profile)
}

private func rankVisibleResults(
    _ results: [TorrentSearchResult],
    matching request: TorrentSearchRequest
) -> [RankedTorrentResult] {
    let filtered = filterSearchResults(results, matching: request)
    let deduped = dedupeResults(filtered, profile: request.rankingProfile)
    return TorrentRanker.rank(
        deduped,
        hideExcluded: true,
        profile: request.rankingProfile
    )
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var isKnownRuntimeCompatibleCut: Bool {
        range(
            of: #"(?i)(^|[^a-z0-9])(dc|director'?s?\s*cut|extended|unrated|uncut|alternate\s*cut|assembly\s*cut|final\s*cut|special\s*edition|roadshow|redux|criterion\s*cut)([^a-z0-9]|$)"#,
            options: .regularExpression
        ) == nil
    }
}

private func displayBitrate(_ kbps: Int) -> String {
    if kbps >= 1_000 {
        let mbps = Double(kbps) / 1_000
        let value = mbps >= 10 ? String(format: "%.0f", mbps) : String(format: "%.2f", mbps)
        return "\(value) Mb/s (\(kbps) kb/s)"
    }
    return "\(kbps) kb/s"
}

private func fileSizeBytes(_ raw: String?) -> Double? {
    guard let raw else { return nil }
    let normalized = raw.replacingOccurrences(of: ",", with: ".")
    let pattern = #"(?i)([0-9]+(?:\.[0-9]+)?)\s*([kmgt]i?b|[kmgt]b)\b"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)),
          match.numberOfRanges > 2,
          let valueRange = Range(match.range(at: 1), in: normalized),
          let unitRange = Range(match.range(at: 2), in: normalized),
          let value = Double(normalized[valueRange]) else { return nil }
    switch String(normalized[unitRange]).lowercased() {
    case "kib": return value * 1_024
    case "mib": return value * pow(1_024, 2)
    case "gib": return value * pow(1_024, 3)
    case "tib": return value * pow(1_024, 4)
    case "kb": return value * 1_000
    case "mb": return value * pow(1_000, 2)
    case "gb": return value * pow(1_000, 3)
    case "tb": return value * pow(1_000, 4)
    default: return nil
    }
}

private func runtimeSeconds(from raw: String?) -> Double? {
    guard let raw else { return nil }
    let normalized = raw.lowercased()
        .replacingOccurrences(of: #","#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let hmsPattern = #"^([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}(?:\.[0-9]+)?))?$"#
    if let captures = regexCaptures(hmsPattern, in: normalized), captures.count >= 2 {
        let first = Double(captures[safe: 0] ?? "") ?? 0
        let second = Double(captures[safe: 1] ?? "") ?? 0
        let third = Double(captures[safe: 2] ?? "") ?? 0
        return captures.count >= 3 ? first * 3600 + second * 60 + third : first * 60 + second
    }
    let hours = Double(firstRegexCapture(#"([0-9]+(?:\.[0-9]+)?)\s*h"#, in: normalized) ?? "") ?? 0
    let minutes = Double(firstRegexCapture(#"([0-9]+(?:\.[0-9]+)?)\s*m"#, in: normalized) ?? "") ?? 0
    let seconds = Double(firstRegexCapture(#"([0-9]+(?:\.[0-9]+)?)\s*s"#, in: normalized) ?? "") ?? 0
    let total = hours * 3600 + minutes * 60 + seconds
    return total > 0 ? total : nil
}

private func firstRegexCapture(_ pattern: String, in text: String) -> String? {
    regexCaptures(pattern, in: text)?.first
}

private func regexCaptures(_ pattern: String, in text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else { return nil }
    return (1..<match.numberOfRanges).compactMap { index in
        guard let captureRange = Range(match.range(at: index), in: text) else { return nil }
        return String(text[captureRange])
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
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
