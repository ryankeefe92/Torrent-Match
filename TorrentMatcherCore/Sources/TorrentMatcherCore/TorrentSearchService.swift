import Foundation

public final class TorrentSearchService: @unchecked Sendable {
    private let providers: [TorrentProvider]
    private let weights: RankerWeights

    public init(configs: [ProviderConfig], weights: RankerWeights = .appleTVDefault) {
        self.providers = configs.map { RegexHTMLProvider(config: $0) }
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

    public func searchAll(_ query: String) async -> [TorrentSearchResult] {
        let results = await withTaskGroup(of: [TorrentSearchResult].self) { group in
            for provider in providers {
                group.addTask {
                    do { return try await provider.search(query) }
                    catch {
                        print("Provider failed: \(provider.config.name) - \(error)")
                        return []
                    }
                }
            }

            var collected: [TorrentSearchResult] = []
            for await providerResults in group { collected.append(contentsOf: providerResults) }
            return collected
        }
        return dedupe(results)
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
}
