import Foundation

public enum TorrentResultDedupe {
    public static func dedupe(_ results: [TorrentSearchResult], weights: RankerWeights = .appleTVDefault) -> [TorrentSearchResult] {
        let byHash = dedupeByInfoHash(results, weights: weights)
        return dedupeByNormalizedTitle(byHash, weights: weights)
    }

    private static func dedupeByInfoHash(_ results: [TorrentSearchResult], weights: RankerWeights) -> [TorrentSearchResult] {
        var output: [TorrentSearchResult] = []
        output.reserveCapacity(results.count)

        var indexByHash: [String: Int] = [:]
        indexByHash.reserveCapacity(results.count)

        for result in results {
            guard let hash = result.magnet?.infoHashFromMagnet?.lowercased(), !hash.isEmpty else {
                output.append(result)
                continue
            }

            if let existingIndex = indexByHash[hash] {
                output[existingIndex] = preferredDuplicate(between: output[existingIndex], and: result, weights: weights)
            } else {
                indexByHash[hash] = output.count
                output.append(result)
            }
        }

        return output
    }

    private static func dedupeByNormalizedTitle(_ results: [TorrentSearchResult], weights: RankerWeights) -> [TorrentSearchResult] {
        var output: [TorrentSearchResult] = []
        output.reserveCapacity(results.count)

        var indexByTitle: [String: Int] = [:]
        indexByTitle.reserveCapacity(results.count)

        for result in results {
            let key = result.title.normalizedDedupeKey
            guard !key.isEmpty else {
                output.append(result)
                continue
            }

            if let existingIndex = indexByTitle[key] {
                output[existingIndex] = preferredDuplicate(between: output[existingIndex], and: result, weights: weights)
            } else {
                indexByTitle[key] = output.count
                output.append(result)
            }
        }

        return output
    }

    private static func preferredDuplicate(between lhs: TorrentSearchResult, and rhs: TorrentSearchResult, weights: RankerWeights) -> TorrentSearchResult {
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
}

