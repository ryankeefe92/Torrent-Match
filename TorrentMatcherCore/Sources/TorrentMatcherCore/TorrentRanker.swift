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
        audioCodec: [.truehd: 42, .dtsHDMA: 42, .dtsHDHRA: 36, .pcm: 42, .ddp: 35, .dts: 30, .dd: 21, .aac: 12, .unknown: 12],
        channels: [.sevenOne: 32, .fiveOne: 24, .twoZero: 5, .mono: 0, .unknown: 4],
        videoCodec: [.hevc: 16, .avc: 8, .vc1: -30, .mpeg2: -25, .unknown: 0],
        ddpAtmosBonus: 9,
        trueHDAtmosBonus: 0,
        topTierUHDRemuxBonus: 100,
        imaxBonus: 13
    )
}

public enum TorrentRanker {
    private static let maxRawScore = 855.0
    private static let seedTieThreshold = 5

    public static func score(_ result: TorrentSearchResult, weights: RankerWeights = .appleTVDefault) -> RankedTorrentResult {
        let titleParsed = ReleaseParser.parse(result.title)
        let detailParsed = result.detailSpecs?.releaseHintText.map { ReleaseParser.parse($0) }
        let parsed = titleParsed.mergedWithDetail(parsed: detailParsed, specs: result.detailSpecs)
        let exclusionText = result.exclusionText

        let upperTitle = exclusionText.uppercased()
        if upperTitle.range(of: #"(^|[^A-Z0-9])(DIV-?X|X(?:\s|-)?VID|WMV(?:3)?)([^A-Z0-9]|$)"#, options: .regularExpression) != nil ||
            upperTitle.contains("WINDOWS MEDIA VIDEO") {
            return RankedTorrentResult(
                raw: result,
                parsed: parsed,
                score: Int.min / 2,
                notes: ["Excluded: unsupported video codec"],
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

        let codec = videoCodec(parsed: parsed)
        if codec == .unknown && explicitlyUnsupportedCodec(in: upperTitle) {
            return RankedTorrentResult(
                raw: result,
                parsed: parsed,
                score: Int.min / 2,
                notes: ["Excluded: unsupported video codec"],
                excluded: true
            )
        }

        var rawScore = 0.0
        var notes: [String] = []

        func add(_ label: String, _ points: Double, detail: String? = nil) {
            rawScore += points
            let rounded = Int(points.rounded())
            let suffix = detail.map { " - \($0)" } ?? ""
            notes.append("\(label): \(rounded >= 0 ? "+" : "")\(rounded)\(suffix)")
        }

        let dimensions = videoDimensions(parsed: parsed, specs: result.detailSpecs)
        let frameRate = frameRate(from: result.detailSpecs) ?? 23.976
        let bitrateSource = videoBitrateKbps(result: result, parsed: parsed)
        let codecFactor = videoCodecFactor(codec)
        let adjustedBPPPF = Double(bitrateSource.kbps) * 1_000 * codecFactor / Double(max(dimensions.width, 1)) / Double(max(dimensions.height, 1)) / frameRate
        let compressionHealth = videoCompressionHealth(adjustedBPPPF)
        let pictureScore = resolutionPotential(parsed: parsed, width: dimensions.width, height: dimensions.height) *
            compressionHealth *
            (bitrateSource.estimated ? 0.84 : 1.0)
        add(
            "Picture quality",
            pictureScore,
            detail: "\(dimensions.width)x\(dimensions.height), \(bitrateSource.kbps) kb/s \(bitrateSource.label), health \(formatMultiplier(compressionHealth))"
        )

        let effectiveDynamicRange = dynamicRangeForScoring(parsed: parsed)
        add("Dynamic range", dynamicRangeScore(effectiveDynamicRange), detail: effectiveDynamicRange.rawValue)
        if let dvPenalty = dolbyVisionProfilePenalty(result.detailSpecs), dvPenalty != 0 {
            add("Dolby Vision profile", Double(dvPenalty), detail: result.detailSpecs?.dolbyVisionProfile)
        }

        add("Bit depth", Double(bitDepthScore(result: result)), detail: result.detailSpecs?.bitDepth)
        add("Color gamut", Double(colorGamutScore(result.detailSpecs?.colorGamut)), detail: result.detailSpecs?.colorGamut)

        if parsed.imax {
            add("Expanded aspect ratio", 15, detail: "explicit IMAX/open matte/expanded aspect ratio")
        }

        add("Encode/remux signal", Double(encodeRemuxScore(parsed: parsed, specs: result.detailSpecs)), detail: encodeRemuxDetail(parsed: parsed, specs: result.detailSpecs))
        add("Video bitrate headroom", Double(videoHeadroomScore(parsed: parsed, bitrateKbps: bitrateSource.kbps)), detail: "\(bitrateSource.kbps) kb/s")

        let audioHealth = audioCompressionHealth(codec: parsed.audioCodec, bitrateKbps: audioBitrateKbps(result: result, parsed: parsed), channels: parsed.channels)
        let audioExperience = channelPotential(parsed.channels) * audioHealth
        add("Audio channel experience", audioExperience, detail: "\(parsed.channels.rawValue), health \(formatMultiplier(audioHealth))")
        add("Audio codec quality", Double(audioCodecQualityScore(parsed.audioCodec)), detail: parsed.audioCodec.rawValue)
        if parsed.audioCodec == .ddp && parsed.atmos {
            add("Object audio", 30, detail: "DDP Atmos")
        } else {
            add("Object audio", 0, detail: parsed.atmos ? "not Apple TV-usable object audio" : nil)
        }
        add("Sample rate", Double(sampleRateScore(result.detailSpecs?.bestEnglishAudioSampleRate)), detail: result.detailSpecs?.bestEnglishAudioSampleRate)

        add("Source context", Double(sourceContextScore(parsed)), detail: parsed.sourceType.rawValue)
        add("Low-quality source penalty", Double(lowQualitySourcePenalty(in: upperTitle)), detail: lowQualitySourceLabel(in: upperTitle))
        add("Video codec compatibility", Double(videoCompatibilityPenalty(codec)), detail: codec.rawValue)

        notes.append("Availability: \(result.seeders) seeders / \(result.leechers) leechers; used only for tie-breaks")
        notes.append("Raw quality score: \(Int(rawScore.rounded())) / \(Int(maxRawScore))")

        let displayScore = Int((rawScore / maxRawScore * 1_000).rounded())
        return RankedTorrentResult(raw: result, parsed: parsed, score: displayScore, notes: notes, excluded: false)
    }

    public static func rank(_ results: [TorrentSearchResult], hideExcluded: Bool = true, weights: RankerWeights = .appleTVDefault) -> [RankedTorrentResult] {
        var ranked = results.map { score($0, weights: weights) }
        if hideExcluded {
            ranked.removeAll { $0.excluded }
        }
        return ranked.sorted {
            let scoreDelta = abs($0.score - $1.score)
            if scoreDelta > seedTieThreshold {
                return $0.score > $1.score
            }
            if $0.raw.seeders != $1.raw.seeders {
                return $0.raw.seeders > $1.raw.seeders
            }
            let lhsSource = sourceContextScore($0.parsed)
            let rhsSource = sourceContextScore($1.parsed)
            if lhsSource != rhsSource {
                return lhsSource > rhsSource
            }
            if let lhsSize = fileSizeBytes($0.raw.size), let rhsSize = fileSizeBytes($1.raw.size), lhsSize != rhsSize {
                return lhsSize < rhsSize
            }
            return $0.raw.title < $1.raw.title
        }
    }
}

private extension TorrentRanker {
    struct VideoBitrateSource {
        let kbps: Int
        let estimated: Bool
        let label: String
    }

    static func videoCodec(parsed: ParsedRelease) -> VideoCodec {
        parsed.videoCodec
    }

    static func explicitlyUnsupportedCodec(in upper: String) -> Bool {
        upper.range(of: #"(^|[^A-Z0-9])(AV1|AV-1|A\s?V1|DIV-?X|X(?:\s|-)?VID|WMV(?:3)?)([^A-Z0-9]|$)"#, options: .regularExpression) != nil ||
            upper.contains("WINDOWS MEDIA VIDEO")
    }

    static func videoBitrateKbps(result: TorrentSearchResult, parsed: ParsedRelease) -> VideoBitrateSource {
        if let videoBitrate = bitrateKbps(result.detailSpecs?.videoBitrate) {
            let isCalculated = result.detailSpecs?.isCalculated("videoBitrate") == true
            return VideoBitrateSource(kbps: videoBitrate, estimated: false, label: isCalculated ? "derived" : "explicit")
        }
        if let calculated = bitrateKbps(result.detailSpecs?.calculatedVideoBitrate) {
            return VideoBitrateSource(kbps: calculated, estimated: false, label: "derived")
        }
        let estimated = estimatedVideoBitrateKbps(parsed: parsed)
        return VideoBitrateSource(kbps: estimated, estimated: true, label: "estimated")
    }

    static func estimatedVideoBitrateKbps(parsed: ParsedRelease) -> Int {
        switch (parsed.resolution, parsed.sourceType) {
        case (.p2160, .remux): return 55_000
        case (.p2160, .bluray): return 22_000
        case (.p2160, .webdl): return 16_000
        case (.p2160, .webrip): return 10_000
        case (.p1080, .remux), (.likely1080, .remux): return 28_000
        case (.p1080, .bluray), (.likely1080, .bluray): return 10_000
        case (.p1080, .webdl), (.likely1080, .webdl): return 7_000
        case (.p1080, .webrip), (.likely1080, .webrip): return 5_000
        case (.p720, .bluray), (.p720, .webdl), (.p720, .webrip): return 4_000
        case (_, .dvd): return 5_000
        case (_, .hdtv): return 4_000
        case (_, .cam): return 2_000
        case (.p2160, _): return 12_000
        case (.p1080, _), (.likely1080, _): return 6_000
        case (.p720, _): return 4_000
        case (.sd, _): return 2_000
        case (.unknown, _): return 5_000
        }
    }

    static func videoDimensions(parsed: ParsedRelease, specs: TorrentDetailSpecs?) -> (width: Int, height: Int) {
        if let width = integer(from: specs?.resolutionWidth),
           let height = integer(from: specs?.resolutionHeight),
           width > 0,
           height > 0 {
            return (width, height)
        }
        switch parsed.resolution {
        case .p2160: return (3_840, 2_160)
        case .p1080, .likely1080: return (1_920, 1_080)
        case .p720: return (1_280, 720)
        case .sd: return (720, 480)
        case .unknown: return (1_920, 1_080)
        }
    }

    static func resolutionPotential(parsed: ParsedRelease, width: Int, height: Int) -> Double {
        if width >= 3_000 || height >= 1_600 || parsed.resolution == .p2160 { return 500 }
        if width >= 1_600 || height >= 900 || parsed.resolution == .p1080 || parsed.resolution == .likely1080 { return 380 }
        if width >= 1_200 || height >= 650 || parsed.resolution == .p720 { return 250 }
        if parsed.resolution == .unknown { return 200 }
        return 130
    }

    static func videoCodecFactor(_ codec: VideoCodec) -> Double {
        switch codec {
        case .mpeg2: return 0.55
        case .vc1: return 0.75
        case .avc, .unknown: return 1.0
        case .hevc: return 1.65
        case .av1: return 1.0
        }
    }

    static func videoCompressionHealth(_ adjustedBPPPF: Double) -> Double {
        piecewiseMultiplier(
            adjustedBPPPF,
            points: [
                (0.025, 0.35),
                (0.050, 0.50),
                (0.080, 0.65),
                (0.120, 0.80),
                (0.180, 0.90),
                (0.300, 0.97),
                (0.450, 1.00)
            ]
        )
    }

    static func dynamicRangeForScoring(parsed: ParsedRelease) -> DynamicRange {
        if parsed.videoCodec == .avc {
            switch parsed.dynamicRange {
            case .dolbyVision, .hdr10plus, .hdr10, .hdr:
                return .sdr
            case .likelyHDR, .unknown, .sdr:
                return parsed.dynamicRange
            }
        }
        return parsed.dynamicRange
    }

    static func dynamicRangeScore(_ dynamicRange: DynamicRange) -> Double {
        switch dynamicRange {
        case .dolbyVision: return 50
        case .hdr10plus: return 46
        case .hdr10: return 44
        case .hdr: return 32
        case .likelyHDR: return 25
        case .unknown, .sdr: return 0
        }
    }

    static func dolbyVisionProfilePenalty(_ specs: TorrentDetailSpecs?) -> Int? {
        guard let profile = specs?.dolbyVisionProfile?.uppercased() else { return nil }
        if profile.range(of: #"PROFILE\s*7|PROFILE\s*07|DVH[EI][\._-]?07"#, options: .regularExpression) != nil {
            return -6
        }
        return 0
    }

    static func bitDepthScore(result: TorrentSearchResult) -> Int {
        let text = [result.detailSpecs?.bitDepth, result.detailSpecs?.releaseHintText, result.title]
            .compactMap { $0 }
            .joined(separator: " ")
            .uppercased()
        if text.range(of: #"(^|[^0-9])12[\s-]?BIT(S)?([^0-9]|$)"#, options: .regularExpression) != nil { return 20 }
        if text.range(of: #"(^|[^0-9])10[\s-]?BIT(S)?([^0-9]|$)"#, options: .regularExpression) != nil { return 15 }
        return 0
    }

    static func colorGamutScore(_ raw: String?) -> Int {
        let upper = raw?.uppercased() ?? ""
        if upper.contains("2020") { return 15 }
        if upper.contains("P3") { return 10 }
        return 0
    }

    static func encodeRemuxScore(parsed: ParsedRelease, specs: TorrentDetailSpecs?) -> Int {
        if parsed.sourceType == .remux { return 15 }
        var score = 0
        if let crf = Double(firstNumber(in: specs?.crf) ?? "") {
            if crf <= 17 { score += 7 }
            else if crf <= 19 { score += 5 }
            else if crf <= 21 { score += 3 }
        }
        let preset = specs?.preset?.lowercased() ?? ""
        if preset.contains("veryslow") { score += 5 }
        else if preset.contains("slower") { score += 4 }
        else if preset.contains("slow") { score += 3 }
        if specs?.encodingPasses?.lowercased().contains("2") == true {
            score += 3
        }
        return min(score, 15)
    }

    static func encodeRemuxDetail(parsed: ParsedRelease, specs: TorrentDetailSpecs?) -> String? {
        if parsed.sourceType == .remux { return "remux" }
        return [specs?.crf.map { "CRF \($0)" }, specs?.preset, specs?.encodingPasses]
            .compactMap { $0 }
            .joined(separator: ", ")
            .nonEmptyString
    }

    static func videoHeadroomScore(parsed: ParsedRelease, bitrateKbps: Int) -> Int {
        let healthy: Int
        let veryHigh: Int
        switch parsed.resolution {
        case .p2160:
            healthy = 22_000
            veryHigh = 50_000
        case .p1080, .likely1080:
            healthy = 10_000
            veryHigh = 25_000
        case .p720:
            healthy = 4_000
            veryHigh = 8_000
        case .sd:
            healthy = 5_000
            veryHigh = 8_000
        case .unknown:
            healthy = 6_000
            veryHigh = 14_000
        }
        if bitrateKbps >= veryHigh { return 15 }
        if bitrateKbps >= healthy { return 8 }
        return 0
    }

    static func audioBitrateKbps(result: TorrentSearchResult, parsed: ParsedRelease) -> Int? {
        if let bitrate = bitrateKbps(result.detailSpecs?.bestEnglishAudioBitrate) {
            return bitrate
        }
        switch (parsed.audioCodec, parsed.channels) {
        case (.truehd, _), (.dtsHDMA, _), (.pcm, _):
            return nil
        case (.dtsHDHRA, .sevenOne): return 3_000
        case (.dtsHDHRA, _): return 2_000
        case (.ddp, .sevenOne): return parsed.atmos ? 1_536 : 1_024
        case (.ddp, .fiveOne): return parsed.atmos ? 768 : 640
        case (.dts, _): return 1_509
        case (.dd, .sevenOne): return 768
        case (.dd, .fiveOne): return 640
        case (.aac, .fiveOne), (.aac, .sevenOne): return 384
        case (.aac, .twoZero): return 192
        case (_, .twoZero): return 192
        case (_, .mono): return 96
        case (.unknown, .sevenOne): return 768
        case (.unknown, .fiveOne): return 384
        case (_, .unknown): return nil
        }
    }

    static func audioCompressionHealth(codec: AudioCodec, bitrateKbps: Int?, channels: ChannelLayout) -> Double {
        if codec == .truehd || codec == .dtsHDMA || codec == .pcm {
            return 0.98
        }
        guard let bitrateKbps else { return 0.65 }
        let density = Double(bitrateKbps) * audioCodecDensityFactor(codec) / effectiveChannelCount(channels)
        return piecewiseMultiplier(
            density,
            points: [
                (48, 0.35),
                (64, 0.50),
                (96, 0.65),
                (128, 0.80),
                (180, 0.90),
                (250, 0.97),
                (320, 1.00)
            ]
        )
    }

    static func audioCodecDensityFactor(_ codec: AudioCodec) -> Double {
        switch codec {
        case .dd: return 1.00
        case .aac: return 1.05
        case .dts: return 1.10
        case .ddp: return 1.35
        case .dtsHDHRA: return 1.45
        case .truehd, .dtsHDMA, .pcm, .unknown: return 1.0
        }
    }

    static func channelPotential(_ channels: ChannelLayout) -> Double {
        switch channels {
        case .sevenOne: return 150
        case .fiveOne: return 115
        case .twoZero, .unknown: return 30
        case .mono: return 10
        }
    }

    static func effectiveChannelCount(_ channels: ChannelLayout) -> Double {
        switch channels {
        case .sevenOne: return 8
        case .fiveOne: return 6
        case .twoZero, .unknown: return 2
        case .mono: return 1
        }
    }

    static func audioCodecQualityScore(_ codec: AudioCodec) -> Int {
        switch codec {
        case .truehd: return 15
        case .dtsHDMA, .pcm: return 14
        case .dtsHDHRA: return 10
        case .ddp: return 9
        case .dts: return 7
        case .dd: return 5
        case .aac: return 3
        case .unknown: return 2
        }
    }

    static func sampleRateScore(_ raw: String?) -> Int {
        guard let value = Double(firstNumber(in: raw) ?? "") else { return 0 }
        if value >= 96 { return 5 }
        if value >= 48 { return 2 }
        return 0
    }

    static func sourceContextScore(_ parsed: ParsedRelease) -> Int {
        switch parsed.sourceType {
        case .remux where parsed.resolution == .p2160:
            return 25
        case .bluray where parsed.resolution == .p2160:
            return 18
        case .remux:
            return 15
        case .bluray:
            return 8
        case .webdl:
            return 6
        case .webrip:
            return 2
        case .dvd, .hdtv, .cam, .unknown:
            return 0
        }
    }

    static func lowQualitySourcePenalty(in upper: String) -> Int {
        if upper.range(of: #"(^|[^A-Z0-9])(HDCAM|CAM)([^A-Z0-9]|$)"#, options: .regularExpression) != nil { return -150 }
        if upper.range(of: #"(^|[^A-Z0-9])(TELESYNC|TS)([^A-Z0-9]|$)"#, options: .regularExpression) != nil { return -130 }
        if upper.range(of: #"(^|[^A-Z0-9])(TELECINE|TC)([^A-Z0-9]|$)"#, options: .regularExpression) != nil { return -100 }
        if upper.range(of: #"(^|[^A-Z0-9])(SCR|SCREENER)([^A-Z0-9]|$)"#, options: .regularExpression) != nil { return -60 }
        return 0
    }

    static func lowQualitySourceLabel(in upper: String) -> String? {
        let penalty = lowQualitySourcePenalty(in: upper)
        if penalty == -150 { return "CAM" }
        if penalty == -130 { return "TS/Telesync" }
        if penalty == -100 { return "TC/Telecine" }
        if penalty == -60 { return "Screener" }
        return nil
    }

    static func videoCompatibilityPenalty(_ codec: VideoCodec) -> Int {
        switch codec {
        case .vc1: return -30
        case .mpeg2: return -25
        case .hevc, .avc, .av1, .unknown: return 0
        }
    }

    static func frameRate(from specs: TorrentDetailSpecs?) -> Double? {
        Double(firstNumber(in: specs?.frameRate) ?? "")
    }

    static func bitrateKbps(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let normalized = raw.replacingOccurrences(of: #"[, ]+"#, with: "", options: .regularExpression).lowercased()
        let pattern = #"([0-9]+(?:\.[0-9]+)?)([kmgt]i?b/s|[kmgt]bps|b/s)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: normalized, range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)).last,
              match.numberOfRanges > 2,
              let valueRange = Range(match.range(at: 1), in: normalized),
              let unitRange = Range(match.range(at: 2), in: normalized),
              let value = Double(normalized[valueRange]) else { return nil }
        let unit = String(normalized[unitRange])
        if unit.contains("mb/s") || unit.contains("mbps") { return Int(value * 1_000) }
        if unit == "b/s" { return Int(value / 1_000) }
        return Int(value)
    }

    static func fileSizeBytes(_ raw: String?) -> Double? {
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

    static func integer(from raw: String?) -> Int? {
        guard let raw else { return nil }
        let digits = raw.replacingOccurrences(of: #"[^0-9]"#, with: "", options: .regularExpression)
        return Int(digits)
    }

    static func firstNumber(in raw: String?) -> String? {
        guard let raw else { return nil }
        let pattern = #"([0-9]+(?:\.[0-9]+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..<raw.endIndex, in: raw)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: raw) else { return nil }
        return String(raw[range])
    }

    static func piecewiseMultiplier(_ value: Double, points: [(Double, Double)]) -> Double {
        guard let first = points.first else { return 0 }
        if value <= first.0 { return first.1 }
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            if value <= current.0 {
                let progress = (value - previous.0) / (current.0 - previous.0)
                return previous.1 + progress * (current.1 - previous.1)
            }
        }
        return points.last?.1 ?? first.1
    }

    static func formatMultiplier(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

private extension String {
    var nonEmptyString: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
