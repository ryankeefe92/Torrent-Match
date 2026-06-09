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
    public var topTierUHDRemuxBonus: Int
    public var imaxBonus: Int

    public static let appleTVDefault = RankerWeights(
        source: [.remux: 90, .bluray: 68, .webdl: 42, .webrip: 22, .dvd: 16, .hdtv: 14, .cam: 7, .unknown: 22],
        resolution: [.p2160: 100, .p1080: 85, .likely1080: 80, .p720: 50, .sd: 30, .unknown: 10],
        dynamicRange: [.dolbyVision: 21, .hdr10plus: 19, .hdr10: 16, .hdr: 12, .likelyHDR: 10, .unknown: 8, .sdr: 8],
        audioCodec: [.truehd: 42, .dtsHDMA: 42, .pcm: 42, .ddp: 35, .dts: 30, .dd: 21, .aac: 12, .unknown: 12],
        channels: [.sevenOne: 32, .fiveOne: 24, .twoZero: 5, .mono: 0, .unknown: 4],
        videoCodec: [.hevc: 16, .avc: 8, .unknown: 0],
        ddpAtmosBonus: 9,
        trueHDAtmosBonus: 0,
        topTierUHDRemuxBonus: 100,
        imaxBonus: 13
    )
}

public enum TorrentRanker {
    public static func score(_ result: TorrentSearchResult, weights: RankerWeights = .appleTVDefault) -> RankedTorrentResult {
        let titleParsed = ReleaseParser.parse(result.title)
        let detailParsed = result.detailSpecs?.releaseHintText.map { ReleaseParser.parse($0) }
        let parsed = titleParsed.mergedWithDetail(parsed: detailParsed, specs: result.detailSpecs)
        let exclusionText = result.exclusionText

        let upperTitle = exclusionText.uppercased()
        if upperTitle.range(of: #"(^|[^A-Z0-9])(VC(?:\s|-)?1|DIV-?X|X(?:\s|-)?VID|WMV(?:3)?)([^A-Z0-9]|$)"#, options: .regularExpression) != nil ||
            upperTitle.contains("WINDOWS MEDIA VIDEO") {
            return RankedTorrentResult(
                raw: result,
                parsed: parsed,
                score: Int.min / 2,
                notes: ["Excluded: unsupported legacy codec in title"],
                excluded: true
            )
        }

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

        if parsed.imax {
            score += weights.imaxBonus
            notes.append("IMAX bonus: +\(weights.imaxBonus)")
        }

        if parsed.sourceType == .remux && parsed.resolution == .p2160 {
            score += weights.topTierUHDRemuxBonus
            notes.append("Top tier bonus: +\(weights.topTierUHDRemuxBonus) for UHD Remux")
        }

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

private extension TorrentSearchResult {
    var exclusionText: String {
        var parts = [title]
        if let detailText = detailSpecs?.releaseHintText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !detailText.isEmpty {
            parts.append(detailText)
        }
        return parts.joined(separator: " ")
    }
}

private extension ParsedRelease {
    func mergedWithDetail(parsed detail: ParsedRelease?, specs: TorrentDetailSpecs?) -> ParsedRelease {
        guard let detail else { return self }
        return ParsedRelease(
            sourceType: detail.sourceType != .unknown ? detail.sourceType : sourceType,
            resolution: detail.resolution != .unknown ? detail.resolution : resolution,
            dynamicRange: detail.dynamicRange != .unknown && specs?.hasDynamicRangeDetails == true ? detail.dynamicRange : dynamicRange,
            videoCodec: detail.videoCodec != .unknown ? detail.videoCodec : videoCodec,
            audioCodec: detail.audioCodec != .unknown && specs?.hasBestEnglishAudioDetails == true ? detail.audioCodec : audioCodec,
            channels: detail.channels != .unknown && specs?.hasBestEnglishAudioDetails == true ? detail.channels : channels,
            atmos: specs?.hasBestEnglishAudioDetails == true ? detail.atmos : atmos,
            imax: detail.imax || imax
        )
    }
}
