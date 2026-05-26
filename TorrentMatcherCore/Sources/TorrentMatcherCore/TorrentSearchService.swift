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

    public init(configs: [ProviderConfig], weights: RankerWeights = .appleTVDefault) {
        self.providers = configs.map(Self.provider(for:))
        self.weights = weights
    }

    public init(providers: [TorrentProvider], weights: RankerWeights = .appleTVDefault) {
        self.providers = providers
        self.weights = weights
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

    private func searchReport(_ query: String) async -> (results: [TorrentSearchResult], failures: [ProviderFailure]) {
        let collected = await withTaskGroup(of: ([TorrentSearchResult], ProviderFailure?).self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        return (try await provider.search(query), nil)
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
        return (dedupe(collected.0), collected.1)
    }

    private func dedupe(_ results: [TorrentSearchResult]) -> [TorrentSearchResult] {
        var seen = Set<String>()
        var output: [TorrentSearchResult] = []
        for result in results {
            let key = result.magnet?.infoHashFromMagnet?.lowercased() ?? result.title.normalizedDedupeKey
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            output.append(result)
        }
        return output
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
