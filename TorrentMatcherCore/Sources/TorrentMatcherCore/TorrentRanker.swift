import Foundation

public struct RankerWeights: Codable, Hashable, Sendable {
    public var source: [SourceType: Int]
    public var resolution: [Resolution: Int]
    public var dynamicRange: [DynamicRange: Int]
    public var audioCodec: [AudioCodec: Int]
    public var channels: [ChannelLayout: Int]
    public var videoCodec: [VideoCodec: Int]
    public var ddpAtmosBonus: Int
    public var trueHDAtmosBonus: Int

    public static let appleTVDefault = RankerWeights(
        source: [.remux: 90, .bluray: 68, .webdl: 42, .webrip: 22, .unknown: 0],
        resolution: [.p2160: 100, .p1080: 92, .p720: 50, .sd: 30, .unknown: 10],
        dynamicRange: [.dolbyVision: 30, .hdr10plus: 27, .hdr10: 24, .hdr: 20, .unknown: 12, .sdr: -5],
        audioCodec: [.truehd: 42, .dtsHDMA: 36, .ddp: 32, .dd: 18, .aac: 6, .unknown: 0],
        channels: [.sevenOne: 32, .fiveOne: 24, .twoZero: 0, .unknown: 0],
        videoCodec: [.hevc: 20, .avc: 10, .unknown: 0],
        ddpAtmosBonus: 6,
        trueHDAtmosBonus: 0
    )
}

public enum TorrentRanker {
    public static func score(_ result: TorrentSearchResult, weights: RankerWeights = .appleTVDefault) -> RankedTorrentResult {
        let parsed = ReleaseParser.parse(result.title)

        if parsed.videoCodec == .av1 {
            return RankedTorrentResult(
                raw: result,
                parsed: parsed,
                score: Int.min / 2,
                notes: ["Excluded: AV1 is disabled for Apple TV compatibility"],
                excluded: true
            )
        }

        if result.seeders == 0 && result.leechers < 2 {
            return RankedTorrentResult(
                raw: result,
                parsed: parsed,
                score: Int.min / 2,
                notes: ["Excluded: no seeders and fewer than 2 leechers"],
                excluded: true
            )
        }

        var score = 0
        var notes: [String] = []

        func add<T: RawRepresentable>(_ label: String, _ value: T, _ points: Int?) where T.RawValue == String {
            let p = points ?? 0
            score += p
            notes.append("\(label): \(value.rawValue) (\(p >= 0 ? "+" : "")\(p))")
        }

        add("Resolution", parsed.resolution, weights.resolution[parsed.resolution])
        add("Source", parsed.sourceType, weights.source[parsed.sourceType])
        add("Audio codec", parsed.audioCodec, weights.audioCodec[parsed.audioCodec])
        add("Dynamic range", parsed.dynamicRange, weights.dynamicRange[parsed.dynamicRange])
        add("Channels", parsed.channels, weights.channels[parsed.channels])

        if parsed.audioCodec == .ddp && parsed.atmos {
            score += weights.ddpAtmosBonus
            notes.append("Atmos bonus: +\(weights.ddpAtmosBonus) for DDP Atmos on Apple TV")
        } else if parsed.audioCodec == .truehd && parsed.atmos {
            score += weights.trueHDAtmosBonus
            notes.append("Atmos bonus: +\(weights.trueHDAtmosBonus) because TrueHD Atmos will not pass through on Apple TV")
        }

        add("Video codec", parsed.videoCodec, weights.videoCodec[parsed.videoCodec])
        notes.append("Availability: \(result.seeders) seeders / \(result.leechers) leechers; used only for tie-breaks")

        return RankedTorrentResult(raw: result, parsed: parsed, score: score, notes: notes, excluded: false)
    }

    public static func rank(_ results: [TorrentSearchResult], hideExcluded: Bool = true, weights: RankerWeights = .appleTVDefault) -> [RankedTorrentResult] {
        var ranked = results.map { score($0, weights: weights) }
        if hideExcluded {
            ranked.removeAll { $0.excluded }
        }
        return ranked.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.raw.seeders > $1.raw.seeders
        }
    }
}
