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
            let key = result.title.normalizedProperInsensitiveDedupeKey
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
        let lhsWithMergedMetadata = mergedWinner(lhs, withMetadataFrom: rhs)
        let rhsWithMergedMetadata = mergedWinner(rhs, withMetadataFrom: lhs)
        let lhsProper = lhsWithMergedMetadata.title.isProperReleaseTokenPresent
        let rhsProper = rhsWithMergedMetadata.title.isProperReleaseTokenPresent

        if lhsProper != rhsProper {
            return lhsProper ? lhsWithMergedMetadata : rhsWithMergedMetadata
        }

        let lhsHasMagnet = lhsWithMergedMetadata.magnet?.isEmpty == false
        let rhsHasMagnet = rhsWithMergedMetadata.magnet?.isEmpty == false

        if lhsHasMagnet != rhsHasMagnet {
            return lhsHasMagnet ? lhsWithMergedMetadata : rhsWithMergedMetadata
        }

        let lhsRanked = TorrentRanker.score(lhsWithMergedMetadata, weights: weights)
        let rhsRanked = TorrentRanker.score(rhsWithMergedMetadata, weights: weights)

        if lhsRanked.excluded != rhsRanked.excluded {
            return lhsRanked.excluded ? rhsWithMergedMetadata : lhsWithMergedMetadata
        }

        if lhsRanked.score != rhsRanked.score {
            return lhsRanked.score >= rhsRanked.score ? lhsWithMergedMetadata : rhsWithMergedMetadata
        }

        if lhsWithMergedMetadata.seeders != rhsWithMergedMetadata.seeders {
            return lhsWithMergedMetadata.seeders >= rhsWithMergedMetadata.seeders ? lhsWithMergedMetadata : rhsWithMergedMetadata
        }

        return lhsWithMergedMetadata
    }

    private static func mergedWinner(_ winner: TorrentSearchResult, withMetadataFrom other: TorrentSearchResult) -> TorrentSearchResult {
        TorrentSearchResult(
            id: winner.id,
            title: winner.title,
            detailMetadata: winner.detailMetadata ?? other.detailMetadata,
            detailSpecs: winner.detailSpecs?.mergedMissingFields(from: other.detailSpecs) ?? other.detailSpecs,
            magnet: winner.magnet ?? other.magnet,
            detailURL: winner.detailURL ?? other.detailURL,
            seeders: winner.seeders,
            leechers: winner.leechers,
            provider: winner.provider,
            size: winner.size ?? other.size
        )
    }
}
