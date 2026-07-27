import Foundation

public enum TorrentRanker {
    private static let maxRawScore = 1_108.5821108088064
    private static let correctedReleaseScoreWindow = 5

    public static func qualityBreakdown(for result: TorrentSearchResult) -> QualityScoreBreakdown {
        let titleParsed = ReleaseParser.parse(result.title)
        let detailParsed = result.detailSpecs?.releaseHintText.map { ReleaseParser.parse($0) }
        let parsed = titleParsed.mergedWithDetail(parsed: detailParsed, specs: result.detailSpecs)
        return qualityBreakdown(for: result, parsed: parsed)
    }

    public static func score(_ result: TorrentSearchResult) -> RankedTorrentResult {
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

        if upperTitle.range(of: #"(^|[^A-Z0-9])RIFF[\s._-]*TRAX([^A-Z0-9]|$)"#, options: .regularExpression) != nil ||
            upperTitle.range(of: #"(^|[^A-Z0-9])RIFFTRAX([^A-Z0-9]|$)"#, options: .regularExpression) != nil {
            return RankedTorrentResult(
                raw: result,
                parsed: parsed,
                score: Int.min / 2,
                notes: ["Excluded: RiffTrax release"],
                excluded: true
            )
        }

        if result.detailSpecs?.hasOnlyExplicitNonEnglishAudioTracks == true {
            return RankedTorrentResult(
                raw: result,
                parsed: parsed,
                score: Int.min / 2,
                notes: ["Excluded: audio tracks are explicitly non-English only"],
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
        if !isAcceptedVideoCodec(codec) {
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
            let suffix = detail.map { " - \($0)" } ?? ""
            notes.append("\(label): \(formatSignedPoints(points))\(suffix)")
        }

        let breakdown = qualityBreakdown(for: result, parsed: parsed)
        let video = breakdown.video
        let audio = breakdown.audio
        add(
            "Picture quality",
            video.score,
            detail: "\(video.width)x\(video.height),  \(video.bitrateKbps) kb/s \(video.bitrateSourceLabel), density \(formatMultiplier(video.densityRatio)), \(videoDensityOperation(video))"
        )

        let gate = presentationGate(effectiveVideoHealth: video.compressionHealth)
        notes.append(
            "Presentation gate: \(formatMultiplier(gate)) - effective video health \(formatMultiplier(video.compressionHealth))"
        )
        let effectiveDynamicRange = dynamicRangeForScoring(parsed: parsed)
        add("Dynamic range", dynamicRangeScore(effectiveDynamicRange) * gate, detail: effectiveDynamicRange.rawValue)
        if let dvProfile = dolbyVisionProfileText(result),
           let adjustment = dolbyVisionProfileAdjustment(
               dvProfile,
               dynamicRange: effectiveDynamicRange
           ),
           adjustment != 0 {
            add("Dolby Vision profile", adjustment * gate, detail: dvProfile)
        }

        let bitDepth = bitDepthScore(result: result, parsed: parsed)
        add("Bit depth", bitDepth.points * gate, detail: bitDepth.detail)

        let colorGamut = colorGamutScore(result: result, parsed: parsed)
        add("Color gamut", colorGamut.points * gate, detail: colorGamut.detail)

        let expandedAspectRatio = hasExpandedAspectRatioSignal(result: result, parsed: parsed)
        add(
            "Expanded aspect ratio",
            (expandedAspectRatio ? 15.0 : 0) * gate,
            detail: expandedAspectRatio ? "explicit IMAX/open matte/expanded aspect ratio" : nil
        )

        add(
            "Encoding",
            encodingScore(parsed: parsed, specs: result.detailSpecs) * gate,
            detail: encodingDetail(specs: result.detailSpecs)
        )

        var audioDetails = [parsed.channels.rawValue, audioCodecLabel(parsed.audioCodec)]
        if let bitrate = audio.bitrateKbps {
            audioDetails.append("\(bitrate) kb/s \(audio.bitrateSourceLabel ?? "")".trimmingCharacters(in: .whitespaces))
        }
        if let density = audio.density {
            audioDetails.append("density \(formatMultiplier(density)) kb/ch")
            audioDetails.append("health \(formatMultiplier(audio.compressionHealth))")
        } else if audio.isLossless {
            audioDetails.append("lossless")
        }
        audioDetails.append("layout \(Int(audio.channelBaseScore.rounded()))")
        audioDetails.append("density \(formatSignedScore(audio.densityAdjustmentScore))")
        if audio.atmosBonusScore > 0 {
            audioDetails.append("Atmos \(formatSignedScore(audio.atmosBonusScore))")
        }
        if audio.atmosReliefScore > 0.05 {
            audioDetails.append("7.1 relief \(formatSignedScore(audio.atmosReliefScore))")
        }
        add("Audio experience", audio.score, detail: audioDetails.joined(separator: ", "))

        add(
            "Source",
            Double(sourceScore(parsed, specs: result.detailSpecs)),
            detail: sourceScoreDetail(parsed, specs: result.detailSpecs)
        )
        add("Weak source penalty", Double(lowQualitySourcePenalty(in: upperTitle)), detail: lowQualitySourceLabel(in: upperTitle))
        let codecPenalty = videoCodecCompatibilityPenalty(codec)
        if codecPenalty != 0 {
            add("Video codec compatibility", Double(codecPenalty), detail: codec.rawValue)
        }

        notes.append("Availability: \(result.seeders) seeders / \(result.leechers) leechers; seeders used only for exact score ties")
        notes.append("Raw quality score: \(Int(rawScore.rounded())) / \(Int(maxRawScore.rounded()))")

        let displayScore = Int((rawScore / maxRawScore * 1_000).rounded())
        return RankedTorrentResult(raw: result, parsed: parsed, score: displayScore, notes: notes, excluded: false)
    }

    public static func rank(_ results: [TorrentSearchResult], hideExcluded: Bool = true) -> [RankedTorrentResult] {
        var ranked = results.map { score($0) }
        if hideExcluded {
            ranked.removeAll { $0.excluded }
        }
        ranked.sort {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            if $0.raw.seeders != $1.raw.seeders {
                return $0.raw.seeders > $1.raw.seeders
            }
            return $0.raw.title < $1.raw.title
        }
        return promoteCorrectedReleases(in: ranked)
    }
}

private extension TorrentRanker {
    struct VideoBitrateSource {
        let kbps: Int
        let estimated: Bool
        let label: String
        let usedEstimatedAudio: Bool
    }

    struct AudioBitrateSource {
        let kbps: Int?
        let estimated: Bool
        let label: String?
    }

    struct AudioScoreComponents {
        let channelBase: Double
        let densityAdjustment: Double
        let atmosBonus: Double
        let atmosRelief: Double
        let compressionHealth: Double
        let score: Double
        let isLossless: Bool
    }

    enum VideoCurve {
        static let collapseRatio = 0.20
        static let additiveRatio = 0.32
        static let collapseHealth = 0.09
        static let collapseSlope = 1.88
        static let collapseCurvature = 37.76
        static let adjustmentMaximum = 50.0
        static let adjustmentRate = 2.3294025485891
    }

    enum AudioCurve {
        static let transparentDensity = 160.0
        static let densityReferenceBase = 300.0
        static let lossyDensityBonusMaximum = 13.0
        static let lossyDensityBonusScale = 84.5
        static let collapseDensity = 32.0
        static let acceptableDensity = 64.0
        static let collapseHealth = 0.09
        static let acceptableHealth = 0.62
        static let collapseSlope = 0.01175
        static let collapseCurvature = 0.001475
        static let fullHealthSlope = (lossyDensityBonusMaximum / lossyDensityBonusScale) / densityReferenceBase
        static let tailWidth = transparentDensity - acceptableDensity
        static let tailLinearWeight = tailWidth * fullHealthSlope
        static let tailQuadraticWeight = 1 - acceptableHealth - tailLinearWeight
        static let acceptableSlope = (2 * tailQuadraticWeight + tailLinearWeight) / tailWidth
        static let acceptableCurvature = -2 * tailQuadraticWeight / (tailWidth * tailWidth)

        static let surroundDensityFloor = -300.0
        static let surroundCollapsePower = 6.873467331845618
        static let surroundAnchorDensities = [32.0, 64.0, 96.0, 112.0, 132.57142857142858, 160.0]
        static let surroundAnchorAdjustments = [
            -272.06649995840667,
            -128.06649995840667,
            -54.65274725274725,
            -30.29262930428054,
            -9.652747252747249,
            0.0
        ]
        static let surroundAnchorSlopes = [
            6.0,
            3.0,
            1.5883595441037144,
            1.4566551994546242,
            0.55,
            lossyDensityBonusMaximum / lossyDensityBonusScale
        ]

        static let atmosGateStart = 32.0
        static let atmosGateFull = 96.0
        static let atmosGateAtCollapse = 0.005
        static let atmosCrossoverDensity = 112.0
        static let reliefMaximum = 11.4
        static let reliefEndDensity = transparentDensity
        static let reliefTailStartScore = 389.10737069571945
        static let reliefTailStartSlope = 1.4566551994546242
        static let reliefTailEndSlope = lossyDensityBonusMaximum / lossyDensityBonusScale
        static let reliefTailPower = 4.4340249000173335
    }

    struct VideoDimensions {
        let width: Int
        let height: Int
        let exact: Bool
    }

    static func videoCodec(parsed: ParsedRelease) -> VideoCodec {
        parsed.videoCodec
    }

    static func qualityBreakdown(for result: TorrentSearchResult, parsed: ParsedRelease) -> QualityScoreBreakdown {
        let dimensions = videoDimensions(parsed: parsed, specs: result.detailSpecs)
        let frameRate = frameRate(from: result.detailSpecs) ?? 24
        let bitrateSource = videoBitrateKbps(result: result, parsed: parsed)
        let codecFactor = videoCodecFactor(parsed.videoCodec, width: dimensions.width, height: dimensions.height)
        let adjustedBPPPF = Double(bitrateSource.kbps) * 1_000 * codecFactor / Double(max(dimensions.width, 1)) / Double(max(dimensions.height, 1)) / frameRate
        let targetBPPPF = videoTargetBPPPF(width: dimensions.width, height: dimensions.height)
        let densityRatio = adjustedBPPPF / targetBPPPF
        let pictureBase = resolutionPotential(
            parsed: parsed,
            specs: result.detailSpecs,
            width: dimensions.width,
            height: dimensions.height
        )
        let pictureScore = videoPictureScore(
            resolutionPotential: pictureBase,
            densityRatio: densityRatio
        )
        let compressionHealth = pictureBase > 0 ? pictureScore / pictureBase : 0

        let audioBitrateSource = audioBitrateKbps(result: result, parsed: parsed, videoBitrate: bitrateSource)
        let audioBitrate = audioBitrateSource.kbps
        let effectiveChannels = effectiveChannelCount(parsed.channels)
        let audioCodecFactor = audioCodecDensityFactor(
            parsed.audioCodec,
            rawBitrateKbpsPerEffectiveChannel: audioBitrate.map { Double($0) / effectiveChannels }
        )
        let audioDensity = audioDensity(codec: parsed.audioCodec, bitrateKbps: audioBitrate, channels: parsed.channels)
        let audioScore = audioScoreComponents(
            codec: parsed.audioCodec,
            bitrateKbps: audioBitrate,
            channels: parsed.channels,
            atmos: parsed.atmos
        )

        return QualityScoreBreakdown(
            parsed: parsed,
            video: VideoQualityBreakdown(
                bitrateKbps: bitrateSource.kbps,
                bitrateSourceLabel: bitrateSource.label,
                bitrateIsEstimated: bitrateSource.estimated,
                codec: parsed.videoCodec,
                codecFactor: codecFactor,
                width: dimensions.width,
                height: dimensions.height,
                frameRate: frameRate,
                adjustedBPPPF: adjustedBPPPF,
                targetBPPPF: targetBPPPF,
                densityRatio: densityRatio,
                resolutionPotentialScore: pictureBase,
                densityAdjustmentScore: pictureScore - pictureBase,
                score: pictureScore,
                compressionHealth: compressionHealth
            ),
            audio: AudioQualityBreakdown(
                bitrateKbps: audioBitrate,
                bitrateSourceLabel: audioBitrateSource.label,
                bitrateIsEstimated: audioBitrateSource.estimated,
                codec: parsed.audioCodec,
                codecFactor: audioCodecFactor,
                channels: parsed.channels,
                effectiveChannelCount: effectiveChannels,
                density: audioDensity,
                compressionHealth: audioScore.compressionHealth,
                channelBaseScore: audioScore.channelBase,
                densityAdjustmentScore: audioScore.densityAdjustment,
                atmosBonusScore: audioScore.atmosBonus,
                atmosReliefScore: audioScore.atmosRelief,
                score: audioScore.score,
                isLossless: audioScore.isLossless
            )
        )
    }

    static func isAcceptedVideoCodec(_ codec: VideoCodec) -> Bool {
        switch codec {
        case .hevc, .avc, .vc1, .mpeg2:
            return true
        case .av1, .unknown:
            return false
        }
    }

    static func videoBitrateKbps(result: TorrentSearchResult, parsed: ParsedRelease) -> VideoBitrateSource {
        if let videoBitrate = bitrateKbps(result.detailSpecs?.videoBitrate) {
            let isCalculated = result.detailSpecs?.isCalculated("videoBitrate") == true
            return VideoBitrateSource(kbps: videoBitrate, estimated: false, label: isCalculated ? "derived" : "explicit", usedEstimatedAudio: false)
        }
        if let calculated = bitrateKbps(result.detailSpecs?.calculatedVideoBitrate) {
            return VideoBitrateSource(kbps: calculated, estimated: false, label: "derived", usedEstimatedAudio: false)
        }
        if let derived = derivedVideoBitrateFromSizeRuntimeAndAudio(result: result, parsed: parsed) {
            return VideoBitrateSource(kbps: derived.kbps, estimated: false, label: "calculated from size ÷ runtime - audio", usedEstimatedAudio: derived.usedEstimatedAudio)
        }
        let estimated = estimatedVideoBitrateKbps(result: result, parsed: parsed)
        return VideoBitrateSource(kbps: estimated.kbps, estimated: true, label: estimated.label, usedEstimatedAudio: false)
    }

    static func derivedVideoBitrateFromSizeRuntimeAndAudio(result: TorrentSearchResult, parsed: ParsedRelease) -> (kbps: Int, usedEstimatedAudio: Bool)? {
        guard let overall = overallBitrateKbps(result: result),
              let audio = audioBitrateForVideoDerivation(result: result, parsed: parsed),
              audio.kbps > 0,
              overall > audio.kbps else { return nil }
        return (overall - audio.kbps, audio.estimated)
    }

    static func estimatedVideoBitrateKbps(result: TorrentSearchResult, parsed: ParsedRelease) -> (kbps: Int, label: String) {
        let sourceEstimate: Int
        switch (parsed.resolution, parsed.sourceType) {
        case (.p2160, .remux): sourceEstimate = 55_000
        case (.p2160, .bluray): sourceEstimate = 22_000
        case (.p2160, .webdl): sourceEstimate = 16_000
        case (.p2160, .webrip): sourceEstimate = 10_000
        case (.p1080, .remux), (.likely1080, .remux): sourceEstimate = 28_000
        case (.p1080, .bluray), (.likely1080, .bluray): sourceEstimate = 10_000
        case (.p1080, .webdl), (.likely1080, .webdl): sourceEstimate = 7_000
        case (.p1080, .webrip), (.likely1080, .webrip): sourceEstimate = 5_000
        case (.p720, .bluray), (.p720, .webdl), (.p720, .webrip): sourceEstimate = 4_000
        case (_, .dvd): sourceEstimate = 5_000
        case (_, .hdtv): sourceEstimate = 4_000
        case (_, .cam): sourceEstimate = 2_000
        case (.p2160, _): sourceEstimate = 12_000
        case (.p1080, _), (.likely1080, _): sourceEstimate = 6_000
        case (.p720, _): sourceEstimate = 4_000
        case (.sd, _): sourceEstimate = 2_000
        case (.unknown, _): sourceEstimate = 5_000
        }
        guard let overall = overallBitrateKbps(result: result) else {
            return (sourceEstimate, "estimated")
        }
        let share = result.title.containsStandaloneMultiToken ? 0.80 : 0.90
        return (max(1, Int(Double(overall) * share)), "estimated from overall bitrate")
    }

    static func videoDimensions(parsed: ParsedRelease, specs: TorrentDetailSpecs?) -> VideoDimensions {
        if let width = integer(from: specs?.resolutionWidth),
           let height = integer(from: specs?.resolutionHeight),
           width > 0,
           height > 0,
           plausibleResolution(width: width, height: height) {
            return VideoDimensions(width: width, height: height, exact: true)
        }
        switch parsed.resolution {
        case .p2160: return VideoDimensions(width: 3_840, height: 2_160, exact: false)
        case .p1080, .likely1080: return VideoDimensions(width: 1_920, height: 1_080, exact: false)
        case .p720: return VideoDimensions(width: 1_280, height: 720, exact: false)
        case .sd: return VideoDimensions(width: 720, height: 480, exact: false)
        case .unknown: return VideoDimensions(width: 1_920, height: 1_080, exact: false)
        }
    }

    static func resolutionPotential(parsed: ParsedRelease, specs: TorrentDetailSpecs?, width: Int, height: Int) -> Double {
        let hasExactDimensions = specs?.resolutionWidth != nil && specs?.resolutionHeight != nil
        if width >= 3_000 || height >= 1_600 { return 530.5821108088064 }
        if width >= 1_600 || height >= 900 { return 438.2775504412965 }
        if width >= 1_200 || height >= 650 { return 373.1430180814573 }
        if width >= 700 || height >= 430 { return 272 }
        if width <= 640 || height <= 360 { return 0 }
        if hasExactDimensions { return 35 }
        if parsed.resolution == .p2160 { return 530.5821108088064 }
        if parsed.resolution == .p1080 || parsed.resolution == .likely1080 { return 438.2775504412965 }
        if parsed.resolution == .p720 { return 373.1430180814573 }
        if parsed.resolution == .unknown { return 200 }
        return 35
    }

    static func videoTargetBPPPF(width: Int, height: Int) -> Double {
        if width >= 3_000 || height >= 1_600 { return 0.22830916943592783 }
        if width >= 1_600 || height >= 900 { return 0.32 }
        if width >= 1_200 || height >= 650 { return 0.4396999884624547 }
        return 0.6249538322674953
    }

    static func videoCodecFactor(_ codec: VideoCodec, width: Int, height: Int) -> Double {
        switch codec {
        case .mpeg2: return 0.55
        case .vc1: return 0.75
        case .avc, .unknown: return 1.0
        case .hevc:
            if width >= 3_000 || height >= 1_600 { return 1.75 }
            if width >= 1_600 || height >= 900 { return 1.50 }
            if width >= 1_200 || height >= 650 { return 1.35 }
            return 1.25
        case .av1: return 1.0
        }
    }

    static func videoPictureScore(resolutionPotential: Double, densityRatio: Double) -> Double {
        guard resolutionPotential > 0 else { return 0 }

        if densityRatio <= VideoCurve.collapseRatio {
            return resolutionPotential * videoCollapseHealth(densityRatio)
        }

        if densityRatio >= VideoCurve.additiveRatio {
            return max(0, resolutionPotential + videoDensityAdjustment(densityRatio))
        }

        let width = VideoCurve.additiveRatio - VideoCurve.collapseRatio
        return quinticHermite(
            progress: (densityRatio - VideoCurve.collapseRatio) / width,
            width: width,
            startValue: resolutionPotential * VideoCurve.collapseHealth,
            startSlope: resolutionPotential * VideoCurve.collapseSlope,
            startCurvature: resolutionPotential * VideoCurve.collapseCurvature,
            endValue: max(
                0,
                resolutionPotential + videoDensityAdjustment(VideoCurve.additiveRatio)
            ),
            endSlope: videoDensityAdjustmentSlope(VideoCurve.additiveRatio),
            endCurvature: videoDensityAdjustmentCurvature(VideoCurve.additiveRatio)
        )
    }

    static func videoCollapseHealth(_ densityRatio: Double) -> Double {
        guard densityRatio > 0 else { return 0 }
        return quinticHermite(
            progress: min(1, densityRatio / VideoCurve.collapseRatio),
            width: VideoCurve.collapseRatio,
            startValue: 0,
            startSlope: 0,
            startCurvature: 0,
            endValue: VideoCurve.collapseHealth,
            endSlope: VideoCurve.collapseSlope,
            endCurvature: VideoCurve.collapseCurvature
        )
    }

    static func videoDensityAdjustment(_ densityRatio: Double) -> Double {
        VideoCurve.adjustmentMaximum *
            (1 - exp(-VideoCurve.adjustmentRate * (densityRatio - 1)))
    }

    static func videoDensityAdjustmentSlope(_ densityRatio: Double) -> Double {
        VideoCurve.adjustmentMaximum *
            VideoCurve.adjustmentRate *
            exp(-VideoCurve.adjustmentRate * (densityRatio - 1))
    }

    static func videoDensityAdjustmentCurvature(_ densityRatio: Double) -> Double {
        -VideoCurve.adjustmentRate * videoDensityAdjustmentSlope(densityRatio)
    }

    static func videoDensityOperation(_ video: VideoQualityBreakdown) -> String {
        if video.densityRatio <= VideoCurve.collapseRatio {
            return "collapse \(formatMultiplier(video.compressionHealth))x"
        }
        if video.densityRatio < VideoCurve.additiveRatio {
            return "transition \(formatSignedScore(video.densityAdjustmentScore))"
        }
        return "shared density \(formatSignedScore(video.densityAdjustmentScore))"
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
        case .hdr10: return 43
        case .hdr: return 37
        case .likelyHDR: return 26
        case .unknown, .sdr: return 0
        }
    }

    static func dolbyVisionProfileText(_ result: TorrentSearchResult) -> String? {
        if let profile = result.detailSpecs?.dolbyVisionProfile?.nonEmptyString {
            return profile
        }
        let text = [result.title, result.detailSpecs?.releaseHintText]
            .compactMap { $0 }
            .joined(separator: " ")
        return dolbyVisionProfileFromText(text)
    }

    static func dolbyVisionProfileAdjustment(
        _ rawProfile: String?,
        dynamicRange: DynamicRange
    ) -> Double? {
        guard dynamicRange == .dolbyVision,
              let profile = rawProfile?.uppercased() else {
            return nil
        }
        if profile.range(
            of: #"PROFILE\s*7|PROFILE\s*07|DVH[EI][\._-]?07|DV[\._-]?P7"#,
            options: .regularExpression
        ) != nil {
            return dynamicRangeScore(.hdr10) - dynamicRangeScore(.dolbyVision)
        }
        return 0
    }

    static func dolbyVisionProfileFromText(_ text: String) -> String? {
        guard text.range(
            of: #"(?i)\b(?:dolby vision|dovi|dvhe|dvh1|DV[\._-]?P[0-9]+)\b"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        if let profile = firstRegexCapture(#"(?i)\bDV[\._-]?P([0-9]+)\b"#, in: text) {
            return "Profile \(profile)"
        }
        if let dvhe = firstRegexCapture(#"(?i)\b(?:dvhe|dvh1)[\._-]?(\d{2})\b"#, in: text) {
            let numeric = String(Int(dvhe) ?? 0)
            return "Profile \(numeric) (\(dvhe))"
        }
        if let profile = firstRegexCapture(#"(?i)\bprofile\s*([0-9]+)\b"#, in: text) {
            return "Profile \(profile)"
        }
        return "Dolby Vision"
    }

    static func presentationGate(effectiveVideoHealth: Double) -> Double {
        let progress = min(1, max(0, (effectiveVideoHealth - 0.35) / 0.45))
        return quinticSmootherstep(progress)
    }

    static func bitDepthScore(
        result: TorrentSearchResult,
        parsed: ParsedRelease
    ) -> (points: Double, detail: String?) {
        let upper = presentationMetadataText(result).uppercased()
        let explicitDepth: Int?
        if upper.range(of: #"(^|[^0-9])12[\s._-]?BIT(S)?([^0-9]|$)"#, options: .regularExpression) != nil {
            explicitDepth = 12
        } else if upper.range(of: #"(^|[^0-9])10[\s._-]?BIT(S)?([^0-9]|$)"#, options: .regularExpression) != nil {
            explicitDepth = 10
        } else if upper.range(of: #"(^|[^0-9])8[\s._-]?BIT(S)?([^0-9]|$)"#, options: .regularExpression) != nil {
            explicitDepth = 8
        } else {
            explicitDepth = nil
        }

        let inferredMinimum = hasGuaranteedWideColorHDR(parsed.dynamicRange) ? 10 : nil
        let depth = max(explicitDepth ?? 0, inferredMinimum ?? 0)
        let isHDR = isHDRPresentation(parsed.dynamicRange)
        let points: Double
        switch (depth, isHDR) {
        case (12..., true): points = 15
        case (12..., false): points = 9
        case (10..., true): points = 11
        case (10..., false): points = 6
        default: points = 0
        }

        let detail: String?
        if depth > 0 {
            detail = "\(depth)-bit \(isHDR ? "HDR" : "SDR")" +
                (explicitDepth == nil ? " (HDR minimum)" : "")
        } else {
            detail = result.detailSpecs?.bitDepth
        }
        return (points, detail)
    }

    static func colorGamutScore(
        result: TorrentSearchResult,
        parsed: ParsedRelease
    ) -> (points: Double, detail: String?) {
        let upper = presentationMetadataText(result).uppercased()
        if upper.range(
            of: #"(^|[^A-Z0-9])(?:BT[\s._-]?2020|REC[\s._-]?2020)([^A-Z0-9]|$)"#,
            options: .regularExpression
        ) != nil {
            return (10, "BT.2020")
        }
        if upper.range(
            of: #"(^|[^A-Z0-9])(?:DCI[\s._-]?)?(?:DISPLAY[\s._-]?)?P3([^A-Z0-9]|$)"#,
            options: .regularExpression
        ) != nil {
            return (8, "P3")
        }
        if hasGuaranteedWideColorHDR(parsed.dynamicRange) {
            return (8, "P3 minimum inferred from \(parsed.dynamicRange.rawValue)")
        }
        return (0, result.detailSpecs?.colorGamut)
    }

    static func hasGuaranteedWideColorHDR(_ dynamicRange: DynamicRange) -> Bool {
        switch dynamicRange {
        case .dolbyVision, .hdr10plus, .hdr10:
            return true
        case .hdr, .likelyHDR, .unknown, .sdr:
            return false
        }
    }

    static func isHDRPresentation(_ dynamicRange: DynamicRange) -> Bool {
        switch dynamicRange {
        case .dolbyVision, .hdr10plus, .hdr10, .hdr, .likelyHDR:
            return true
        case .unknown, .sdr:
            return false
        }
    }

    static func hasExpandedAspectRatioSignal(
        result: TorrentSearchResult,
        parsed: ParsedRelease
    ) -> Bool {
        if parsed.imax { return true }
        let upper = presentationMetadataText(result).uppercased()
        return upper.range(
            of: #"(^|[^A-Z0-9])OPEN[\s._-]*MATTE([^A-Z0-9]|$)"#,
            options: .regularExpression
        ) != nil ||
            upper.range(
                of: #"(^|[^A-Z0-9])EXPANDED[\s._-]*(?:ASPECT(?:[\s._-]*RATIO)?|RATIO)([^A-Z0-9]|$)"#,
                options: .regularExpression
            ) != nil
    }

    static func encodingScore(parsed: ParsedRelease, specs: TorrentDetailSpecs?) -> Double {
        guard parsed.sourceType != .remux else { return 0 }

        let crfScore: Double
        if let crf = Double(firstNumber(in: specs?.crf) ?? "") {
            if crf <= 17 { crfScore = 2 }
            else if crf <= 19 { crfScore = 1.5 }
            else if crf <= 21 { crfScore = 1 }
            else { crfScore = 0 }
        } else {
            crfScore = 0
        }

        let twoPassScore: Double
        if specs?.encodingPasses?.range(
            of: #"(^|[^0-9])2(?:[\s._-]*PASS(?:ES)?)?([^0-9]|$)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            twoPassScore = 2
        } else {
            twoPassScore = 0
        }

        let presetScore: Double
        let preset = specs?.preset?.lowercased() ?? ""
        if preset.contains("veryslow") { presetScore = 3 }
        else if preset.contains("slower") { presetScore = 2.5 }
        else if preset.contains("slow") { presetScore = 2 }
        else { presetScore = 0 }

        return min(5, max(crfScore, twoPassScore) + presetScore)
    }

    static func encodingDetail(specs: TorrentDetailSpecs?) -> String? {
        return [specs?.crf.map { "CRF \($0)" }, specs?.preset, specs?.encodingPasses]
            .compactMap { $0 }
            .joined(separator: ", ")
            .nonEmptyString
    }

    static func presentationMetadataText(_ result: TorrentSearchResult) -> String {
        [
            result.title,
            result.detailMetadata,
            result.detailSpecs?.fullTorrentName,
            result.detailSpecs?.releaseHintText,
            result.detailSpecs?.bitDepth,
            result.detailSpecs?.colorGamut
        ]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    static func audioBitrateKbps(result: TorrentSearchResult, parsed: ParsedRelease, videoBitrate: VideoBitrateSource) -> AudioBitrateSource {
        if let bitrate = bitrateKbps(result.detailSpecs?.bestEnglishAudioBitrate) {
            let isCalculated = result.detailSpecs?.isCalculated("bestEnglishAudioBitrate") == true
            return AudioBitrateSource(kbps: bitrate, estimated: false, label: isCalculated ? "derived" : "explicit")
        }
        if videoBitrate.usedEstimatedAudio,
           let estimated = estimatedAudioBitrateKbps(parsed: parsed) {
            return AudioBitrateSource(kbps: estimated, estimated: true, label: "estimated")
        }
        if !videoBitrate.estimated,
           let overall = overallBitrateKbps(result: result),
           overall > videoBitrate.kbps {
            return AudioBitrateSource(kbps: overall - videoBitrate.kbps, estimated: false, label: "derived from overall-video")
        }
        let estimated = estimatedAudioBitrateKbps(parsed: parsed)
        return AudioBitrateSource(kbps: estimated, estimated: estimated != nil, label: estimated.map { _ in "estimated" })
    }

    static func audioBitrateForVideoDerivation(result: TorrentSearchResult, parsed: ParsedRelease) -> (kbps: Int, estimated: Bool)? {
        if let total = totalAudioBitrateKbps(specs: result.detailSpecs) {
            return (total, false)
        }
        if parsed.audioCodec != .unknown,
           parsed.channels != .unknown,
           let estimated = estimatedAudioBitrateKbps(parsed: parsed) {
            return (estimated, true)
        }
        return nil
    }

    static func estimatedAudioBitrateKbps(parsed: ParsedRelease) -> Int? {
        switch (parsed.audioCodec, parsed.channels) {
        case (.truehd, .sevenOne): return 4_500
        case (.truehd, .fiveOne): return 3_500
        case (.truehd, _): return 3_000
        case (.dtsHDMA, .sevenOne): return 4_000
        case (.dtsHDMA, .fiveOne): return 3_000
        case (.dtsHDMA, _): return 2_500
        case (.pcm, .sevenOne): return 6_912
        case (.pcm, .fiveOne): return 4_608
        case (.pcm, .twoZero): return 1_536
        case (.pcm, _): return 2_304
        case (.dtsHDHRA, .sevenOne): return 3_000
        case (.dtsHDHRA, .fiveOne): return 2_000
        case (.dtsHDHRA, .twoZero): return 1_000
        case (.dtsHDHRA, .mono): return 512
        case (.dtsHDHRA, _): return 1_500
        case (.ddp, .sevenOne): return parsed.atmos ? 1_536 : 1_024
        case (.ddp, .fiveOne): return parsed.atmos ? 768 : 640
        case (.ddp, .twoZero): return 256
        case (.ddp, .mono): return 128
        case (.dts, .sevenOne): return 2_012
        case (.dts, .fiveOne): return 1_509
        case (.dts, .twoZero): return 768
        case (.dts, .mono): return 384
        case (.dd, .sevenOne): return 768
        case (.dd, .fiveOne): return 640
        case (.dd, .twoZero): return 384
        case (.dd, .mono): return 192
        case (.aac, .fiveOne), (.aac, .sevenOne): return 384
        case (.aac, .twoZero): return 192
        case (.aac, .mono): return 96
        case (.heAAC, .fiveOne), (.heAAC, .sevenOne): return 256
        case (.heAAC, .twoZero): return 128
        case (.heAAC, .mono): return 64
        case (.opus, .fiveOne), (.opus, .sevenOne): return 384
        case (.opus, .twoZero): return 160
        case (.opus, .mono): return 80
        case (.mp3, .sevenOne), (.mp3, .fiveOne): return 320
        case (.mp3, .twoZero): return 192
        case (.mp3, .mono): return 96
        case (_, .twoZero): return 192
        case (_, .mono): return 96
        case (.unknown, .sevenOne): return 768
        case (.unknown, .fiveOne): return 384
        case (.unknown, .unknown): return 192
        case (_, .unknown): return estimatedStereoAudioBitrateKbps(codec: parsed.audioCodec, atmos: parsed.atmos)
        }
    }

    static func estimatedStereoAudioBitrateKbps(codec: AudioCodec, atmos: Bool) -> Int? {
        switch codec {
        case .truehd: return 3_000
        case .dtsHDMA: return 2_500
        case .pcm: return 1_536
        case .dtsHDHRA: return 1_000
        case .ddp: return 256
        case .dts: return 768
        case .dd: return 384
        case .aac: return 192
        case .heAAC: return 128
        case .opus: return 160
        case .mp3: return 192
        case .unknown: return 192
        }
    }

    static func audioDensity(codec: AudioCodec, bitrateKbps: Int?, channels: ChannelLayout) -> Double? {
        guard !codec.isLosslessForDensity else { return nil }
        guard let bitrateKbps else { return nil }
        let effectiveChannels = effectiveChannelCount(channels)
        let rawBitratePerEffectiveChannel = Double(bitrateKbps) / effectiveChannels
        return Double(bitrateKbps) * audioCodecDensityFactor(
            codec,
            rawBitrateKbpsPerEffectiveChannel: rawBitratePerEffectiveChannel
        ) / effectiveChannels
    }

    static func audioCodecDensityFactor(
        _ codec: AudioCodec,
        rawBitrateKbpsPerEffectiveChannel: Double?
    ) -> Double {
        guard let rawBitrateKbpsPerEffectiveChannel else { return 1.0 }

        let factors: [Double]
        switch codec {
        case .dd: factors = [1.00, 1.00, 1.00, 1.00, 1.00, 1.00, 1.00, 1.00]
        case .ddp: factors = [1.90, 1.75, 1.65, 1.55, 1.47, 1.40, 1.33, 1.28]
        case .aac: factors = [1.60, 1.50, 1.45, 1.40, 1.36, 1.32, 1.28, 1.23]
        case .heAAC: factors = [2.80, 2.50, 2.25, 2.05, 1.85, 1.70, 1.50, 1.35]
        case .opus: factors = [2.20, 2.05, 1.90, 1.75, 1.62, 1.52, 1.42, 1.35]
        case .mp3: factors = [0.70, 0.75, 0.78, 0.80, 0.82, 0.83, 0.84, 0.85]
        case .dts: factors = [0.25, 0.27, 0.29, 0.30, 0.31, 0.31, 0.30, 0.30]
        case .dtsHDHRA: factors = [0.40, 0.42, 0.44, 0.45, 0.46, 0.47, 0.47, 0.45]
        case .truehd, .dtsHDMA, .pcm, .unknown: return 1.0
        }

        let rowBitrates: [Double] = [40, 60, 80, 100, 125, 150, 200, 300]
        if rawBitrateKbpsPerEffectiveChannel <= rowBitrates[0] { return factors[0] }
        if rawBitrateKbpsPerEffectiveChannel >= rowBitrates[7] { return factors[7] }

        for upperIndex in 1..<rowBitrates.count {
            let upperBitrate = rowBitrates[upperIndex]
            guard rawBitrateKbpsPerEffectiveChannel <= upperBitrate else { continue }
            let lowerIndex = upperIndex - 1
            let lowerBitrate = rowBitrates[lowerIndex]
            let progress = (rawBitrateKbpsPerEffectiveChannel - lowerBitrate) / (upperBitrate - lowerBitrate)
            return factors[lowerIndex] + (factors[upperIndex] - factors[lowerIndex]) * progress
        }
        return factors[7]
    }

    static func audioCodecLabel(_ codec: AudioCodec) -> String {
        switch codec {
        case .truehd: return "TrueHD"
        case .dtsHDMA: return "DTS-HD MA"
        case .dtsHDHRA: return "DTS-HD HRA"
        case .pcm: return "PCM"
        case .ddp: return "DDP"
        case .dts: return "DTS"
        case .dd: return "AC3"
        case .aac: return "AAC-LC"
        case .heAAC: return "HE-AAC"
        case .opus: return "Opus"
        case .mp3: return "MP3"
        case .unknown: return "Unknown"
        }
    }

    static func channelPotential(_ channels: ChannelLayout) -> Double {
        switch channels {
        case .sevenOne: return 345
        case .fiveOne: return 300
        case .twoZero, .unknown: return 60
        case .mono: return 10
        }
    }

    static func effectiveChannelCount(_ channels: ChannelLayout) -> Double {
        switch channels {
        case .sevenOne: return 7.25
        case .fiveOne: return 5.25
        case .twoZero, .unknown: return 2
        case .mono: return 1
        }
    }

    static func audioScoreComponents(
        codec: AudioCodec,
        bitrateKbps: Int?,
        channels: ChannelLayout,
        atmos: Bool
    ) -> AudioScoreComponents {
        let channelBase = channelPotential(channels)
        if codec.isLosslessForDensity {
            let densityAdjustment = audioLosslessDensityBonus(channelBase: channelBase)
            return AudioScoreComponents(
                channelBase: channelBase,
                densityAdjustment: densityAdjustment,
                atmosBonus: 0,
                atmosRelief: 0,
                compressionHealth: 1,
                score: channelBase + densityAdjustment,
                isLossless: true
            )
        }

        let density = audioDensity(codec: codec, bitrateKbps: bitrateKbps, channels: channels) ?? AudioCurve.acceptableDensity
        let bedScore = audioBedScore(channels: channels, density: density)
        let usableAtmos = codec == .ddp && atmos && (channels == .fiveOne || channels == .sevenOne)
        let atmosBonus = usableAtmos ? audioAtmosBonus(channels: channels, density: density) : 0
        let atmosRelief = usableAtmos && channels == .sevenOne ? audioSevenOneAtmosRelief(density: density) : 0
        return AudioScoreComponents(
            channelBase: channelBase,
            densityAdjustment: bedScore - channelBase,
            atmosBonus: atmosBonus,
            atmosRelief: atmosRelief,
            compressionHealth: audioDensityHealth(density),
            score: bedScore + atmosBonus + atmosRelief,
            isLossless: false
        )
    }

    static func audioBedScore(channels: ChannelLayout, density: Double) -> Double {
        let channelBase = channelPotential(channels)
        guard channels == .fiveOne || channels == .sevenOne else {
            return audioBaseWithDensity(channelBase: channelBase, density: density)
        }

        let additiveScore = max(0, channelBase + audioSurroundDensityAdjustment(density: density))
        let multipliedScore = channelBase * audioDensityHealth(density)
        let additiveBlend = audioSurroundAdditiveBlend(density: density)
        return multipliedScore + (additiveScore - multipliedScore) * additiveBlend
    }

    static func audioSurroundAdditiveBlend(density: Double) -> Double {
        if density <= AudioCurve.collapseDensity { return 0 }
        if density >= AudioCurve.acceptableDensity { return 1 }
        let progress = (density - AudioCurve.collapseDensity) /
            (AudioCurve.acceptableDensity - AudioCurve.collapseDensity)
        return quinticSmootherstep(progress)
    }

    static func audioSurroundDensityAdjustment(density: Double) -> Double {
        if density <= 0 { return AudioCurve.surroundDensityFloor }

        let firstDensity = AudioCurve.surroundAnchorDensities[0]
        let firstAdjustment = AudioCurve.surroundAnchorAdjustments[0]
        if density < firstDensity {
            let progress = density / firstDensity
            return AudioCurve.surroundDensityFloor +
                (firstAdjustment - AudioCurve.surroundDensityFloor) *
                pow(progress, AudioCurve.surroundCollapsePower)
        }

        if density <= AudioCurve.transparentDensity {
            var interval = AudioCurve.surroundAnchorDensities.count - 2
            for index in 0..<(AudioCurve.surroundAnchorDensities.count - 1) {
                if density <= AudioCurve.surroundAnchorDensities[index + 1] {
                    interval = index
                    break
                }
            }

            let startDensity = AudioCurve.surroundAnchorDensities[interval]
            let endDensity = AudioCurve.surroundAnchorDensities[interval + 1]
            let width = endDensity - startDensity
            let progress = (density - startDensity) / width
            let startSlope = AudioCurve.surroundAnchorSlopes[interval]
            let endSlope = AudioCurve.surroundAnchorSlopes[interval + 1]
            return AudioCurve.surroundAnchorAdjustments[interval] + width * (
                startSlope * progress +
                (endSlope - startSlope) * integratedCubicSmoothstep(progress)
            )
        }

        return AudioCurve.lossyDensityBonusMaximum *
            tanh((density - AudioCurve.transparentDensity) / AudioCurve.lossyDensityBonusScale)
    }

    static func audioBaseWithDensity(channelBase: Double, density: Double) -> Double {
        max(0, channelBase + audioRawDensityAdjustment(channelBase: channelBase, density: density))
    }

    static func audioRawDensityAdjustment(channelBase: Double, density: Double) -> Double {
        if density <= AudioCurve.transparentDensity {
            let adjustmentScale = min(1, channelBase / AudioCurve.densityReferenceBase)
            return adjustmentScale * AudioCurve.densityReferenceBase * (audioDensityHealth(density) - 1)
        }
        return audioDensityBonus(channelBase: channelBase, density: density)
    }

    static func audioDensityBonus(channelBase: Double, density: Double) -> Double {
        guard density > AudioCurve.transparentDensity else { return 0 }
        let profile: (maximum: Double, scale: Double)
        if channelBase <= 10 {
            profile = (2, 390)
        } else if channelBase <= 60 {
            profile = (4, 130)
        } else {
            profile = (AudioCurve.lossyDensityBonusMaximum, AudioCurve.lossyDensityBonusScale)
        }
        return profile.maximum * tanh((density - AudioCurve.transparentDensity) / profile.scale)
    }

    static func audioLosslessDensityBonus(channelBase: Double) -> Double {
        if channelBase <= 10 { return 5 }
        if channelBase <= 60 { return 9 }
        return 18
    }

    static func audioDensityHealth(_ density: Double) -> Double {
        if density <= 0 { return 0 }
        if density >= AudioCurve.transparentDensity { return 1 }

        if density <= AudioCurve.collapseDensity {
            return quinticHermite(
                progress: density / AudioCurve.collapseDensity,
                width: AudioCurve.collapseDensity,
                startValue: 0,
                startSlope: 0,
                startCurvature: 0,
                endValue: AudioCurve.collapseHealth,
                endSlope: AudioCurve.collapseSlope,
                endCurvature: AudioCurve.collapseCurvature
            )
        }

        if density <= AudioCurve.acceptableDensity {
            let width = AudioCurve.acceptableDensity - AudioCurve.collapseDensity
            return quinticHermite(
                progress: (density - AudioCurve.collapseDensity) / width,
                width: width,
                startValue: AudioCurve.collapseHealth,
                startSlope: AudioCurve.collapseSlope,
                startCurvature: AudioCurve.collapseCurvature,
                endValue: AudioCurve.acceptableHealth,
                endSlope: AudioCurve.acceptableSlope,
                endCurvature: AudioCurve.acceptableCurvature
            )
        }

        let remaining = (AudioCurve.transparentDensity - density) / AudioCurve.tailWidth
        return 1 - AudioCurve.tailQuadraticWeight * remaining * remaining - AudioCurve.tailLinearWeight * remaining
    }

    static func audioAtmosUsability(density: Double) -> Double {
        if density <= 0 { return 0 }
        if density <= AudioCurve.atmosGateStart {
            return AudioCurve.atmosGateAtCollapse * quinticSmootherstep(density / AudioCurve.atmosGateStart)
        }
        let progress = min(
            1,
            max(0, (density - AudioCurve.atmosGateStart) / (AudioCurve.atmosGateFull - AudioCurve.atmosGateStart))
        )
        return AudioCurve.atmosGateAtCollapse +
            (1 - AudioCurve.atmosGateAtCollapse) * quinticSmootherstep(progress)
    }

    static func audioAtmosBonus(channels: ChannelLayout, density: Double) -> Double {
        let fullBonus: Double
        switch channels {
        case .fiveOne: fullBonus = 90
        case .sevenOne: fullBonus = 63
        case .mono, .twoZero, .unknown: return 0
        }
        return fullBonus * audioAtmosUsability(density: density)
    }

    static func audioSevenOneAtmosRelief(density: Double) -> Double {
        guard density > 0, density < AudioCurve.reliefEndDensity else { return 0 }
        let baseline = audioSevenOneAtmosScoreWithoutRelief(density: density)

        if density <= AudioCurve.atmosCrossoverDensity {
            let progress = density / AudioCurve.atmosCrossoverDensity
            return AudioCurve.reliefMaximum * quinticSmootherstep(progress) *
                audioAtmosUsability(density: density)
        }

        let width = AudioCurve.reliefEndDensity - AudioCurve.atmosCrossoverDensity
        let progress = (density - AudioCurve.atmosCrossoverDensity) / width
        let integratedSlope = AudioCurve.reliefTailEndSlope * progress +
            (AudioCurve.reliefTailStartSlope - AudioCurve.reliefTailEndSlope) *
            (1 - pow(1 - progress, AudioCurve.reliefTailPower + 1)) /
            (AudioCurve.reliefTailPower + 1)
        let targetScore = AudioCurve.reliefTailStartScore + width * integratedSlope
        return max(0, targetScore - baseline)
    }

    static func audioSevenOneAtmosScoreWithoutRelief(density: Double) -> Double {
        audioBedScore(channels: .sevenOne, density: density) +
            audioAtmosBonus(channels: .sevenOne, density: density)
    }

    static func quinticSmootherstep(_ progress: Double) -> Double {
        let progress2 = progress * progress
        let progress3 = progress2 * progress
        return progress3 * (10 - 15 * progress + 6 * progress2)
    }

    static func integratedCubicSmoothstep(_ progress: Double) -> Double {
        pow(progress, 3) - 0.5 * pow(progress, 4)
    }

    static func quinticHermite(
        progress: Double,
        width: Double,
        startValue: Double,
        startSlope: Double,
        startCurvature: Double,
        endValue: Double,
        endSlope: Double,
        endCurvature: Double
    ) -> Double {
        let t2 = progress * progress
        let t3 = t2 * progress
        let t4 = t3 * progress
        let t5 = t4 * progress
        let h00 = 1 - 10 * t3 + 15 * t4 - 6 * t5
        let h10 = progress - 6 * t3 + 8 * t4 - 3 * t5
        let h20 = 0.5 * (t2 - 3 * t3 + 3 * t4 - t5)
        let h01 = 10 * t3 - 15 * t4 + 6 * t5
        let h11 = -4 * t3 + 7 * t4 - 3 * t5
        let h21 = 0.5 * (t3 - 2 * t4 + t5)
        return h00 * startValue +
            h10 * width * startSlope +
            h20 * width * width * startCurvature +
            h01 * endValue +
            h11 * width * endSlope +
            h21 * width * width * endCurvature
    }

    static func sourceScore(_ parsed: ParsedRelease, specs: TorrentDetailSpecs? = nil) -> Int {
        let resolution = resolutionForScoring(parsed: parsed, specs: specs)
        let isUHD = resolution == .p2160 ||
            isUHDSourceSignal(parsed: parsed, text: specs?.releaseHintText)
        switch parsed.sourceType {
        case .remux:
            return isUHD ? 17 : 14
        case .bluray:
            return isUHD ? 7 : 5
        case .webdl:
            return 3
        case .webrip:
            return 1
        case .dvd, .hdtv, .cam, .unknown:
            return 0
        }
    }

    static func sourceScoreDetail(_ parsed: ParsedRelease, specs: TorrentDetailSpecs?) -> String {
        let resolution = resolutionForScoring(parsed: parsed, specs: specs)
        let isUHD = resolution == .p2160 ||
            isUHDSourceSignal(parsed: parsed, text: specs?.releaseHintText)
        switch parsed.sourceType {
        case .remux:
            return isUHD ? "UHD remux" : "Blu-ray remux"
        case .bluray:
            return isUHD ? "UHD disc encode" : "Blu-ray disc encode"
        case .webdl:
            return "WEB-DL"
        case .webrip:
            return "WEBRip"
        case .hdtv:
            return "HDTV"
        case .dvd:
            return "DVD"
        case .cam:
            return "weak source"
        case .unknown:
            return "unknown"
        }
    }

    static func resolutionForScoring(parsed: ParsedRelease, specs: TorrentDetailSpecs?) -> Resolution {
        guard let width = integer(from: specs?.resolutionWidth),
              let height = integer(from: specs?.resolutionHeight),
              width > 0,
              height > 0,
              plausibleResolution(width: width, height: height) else {
            return parsed.resolution
        }
        if width >= 3_000 || height >= 1_600 { return .p2160 }
        if width >= 1_600 || height >= 900 { return .p1080 }
        if width >= 1_200 || height >= 650 { return .p720 }
        return .sd
    }

    static func lowQualitySourcePenalty(in upper: String) -> Int {
        if upper.range(of: #"(^|[^A-Z0-9])(HDCAM|CAM[\s._-]?RIP|CAM)([^A-Z0-9]|$)"#, options: .regularExpression) != nil { return -240 }
        if upper.range(of: #"(^|[^A-Z0-9])(TELESYNC|HD[\s._-]?TS|TS)([^A-Z0-9]|$)"#, options: .regularExpression) != nil { return -200 }
        if upper.range(of: #"(^|[^A-Z0-9])(TELECINE|HD[\s._-]?TC|TC)([^A-Z0-9]|$)"#, options: .regularExpression) != nil { return -150 }
        if upper.range(
            of: #"(^|[^A-Z0-9])(DVD[\s._-]?SCR|BD[\s._-]?SCR|SCR|SCREENER)([^A-Z0-9]|$)"#,
            options: .regularExpression
        ) != nil { return -80 }
        return 0
    }

    static func lowQualitySourceLabel(in upper: String) -> String? {
        let penalty = lowQualitySourcePenalty(in: upper)
        if penalty == -240 { return "CAM/HDCAM" }
        if penalty == -200 { return "Telesync" }
        if penalty == -150 { return "Telecine" }
        if penalty == -80 { return "Screener" }
        return nil
    }

    static func videoCodecCompatibilityPenalty(_ codec: VideoCodec) -> Int {
        switch codec {
        case .vc1: return -24
        case .mpeg2: return -20
        case .hevc, .avc, .av1, .unknown: return 0
        }
    }

    static func isUHDSourceSignal(parsed: ParsedRelease, text: String?) -> Bool {
        let upper = text?.uppercased() ?? ""
        let hasDiscSource = parsed.sourceType == .bluray ||
            parsed.sourceType == .remux ||
            upper.range(of: #"(^|[^A-Z0-9])(UHD[\s\.-]?BLU[\s\.-]?RAY|BLU[\s\.-]?RAY|BDREMUX|BDRIP|BRRIP)([^A-Z0-9]|$)"#, options: .regularExpression) != nil
        guard hasDiscSource else { return false }
        if parsed.resolution == .p2160 { return true }
        switch parsed.dynamicRange {
        case .dolbyVision, .hdr10plus, .hdr10, .hdr, .likelyHDR:
            return true
        case .unknown, .sdr:
            break
        }
        return upper.range(of: #"(^|[^0-9])(?:10|12)[\s-]?BIT(S)?([^0-9]|$)"#, options: .regularExpression) != nil ||
            upper.contains("DOLBY VISION") ||
            upper.contains("DOVI") ||
            upper.contains("HDR10") ||
            upper.range(of: #"(^|[^A-Z0-9])HDR([^A-Z0-9]|$)"#, options: .regularExpression) != nil
    }

    static func plausibleResolution(width: Int, height: Int) -> Bool {
        guard (240...8_192).contains(width),
              (240...8_192).contains(height) else { return false }
        let ratio = Double(max(width, height)) / Double(min(width, height))
        return ratio <= 3.0
    }

    static func overallBitrateKbps(result: TorrentSearchResult) -> Int? {
        if let explicit = bitrateKbps(result.detailSpecs?.overallBitrate) {
            return explicit
        }
        guard let sizeBytes = fileSizeBytes(result.size),
              let runtimeSeconds = runtimeSeconds(from: result.detailSpecs?.runtime),
              runtimeSeconds > 0 else { return nil }
        let kbps = Int((sizeBytes * 8) / runtimeSeconds / 1_000)
        return kbps > 0 ? kbps : nil
    }

    static func totalAudioBitrateKbps(specs: TorrentDetailSpecs?) -> Int? {
        if let total = bitrateKbps(specs?.totalAudioTrackBitrate) {
            return total
        }
        let values = specs?.allAudioTrackBitrates.compactMap(bitrateKbps) ?? []
        guard !values.isEmpty else { return bitrateKbps(specs?.bestEnglishAudioBitrate) }
        return values.reduce(0, +)
    }

    static func frameRate(from specs: TorrentDetailSpecs?) -> Double? {
        Double(firstNumber(in: specs?.frameRate) ?? "")
    }

    static func runtimeSeconds(from raw: String?) -> Double? {
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

    static func bitrateKbps(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let normalized = raw.replacingOccurrences(of: #","#, with: "", options: .regularExpression).lowercased()
        let pattern = #"(?i)(?:VBR|CBR|ABR)?\s*(?<![0-9.])([0-9]+(?:\s[0-9]{3})*(?:\.[0-9]+)?)\s*([kmgt]i?b/s|[kmgt]bps|b/s)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: normalized, range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)).last,
              match.numberOfRanges > 2,
              let valueRange = Range(match.range(at: 1), in: normalized),
              let unitRange = Range(match.range(at: 2), in: normalized),
              let value = Double(normalized[valueRange].replacingOccurrences(of: " ", with: "")) else { return nil }
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

    static func firstRegexCapture(_ pattern: String, in text: String) -> String? {
        regexCaptures(pattern, in: text)?.first
    }

    static func regexCaptures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let captureRange = Range(match.range(at: index), in: text) else { return nil }
            return String(text[captureRange])
        }
    }

    static func promoteCorrectedReleases(
        in ranked: [RankedTorrentResult]
    ) -> [RankedTorrentResult] {
        var promoted = ranked
        var index = 0
        while index < promoted.count {
            let current = promoted[index]
            let key = current.raw.preferredTitle.normalizedCorrectionInsensitiveDedupeKey
            let currentPriority = current.raw.preferredTitle.correctionReleasePriority
            var preferredIndex: Int?

            if !key.isEmpty, index + 1 < promoted.count {
                for candidateIndex in (index + 1)..<promoted.count {
                    let candidate = promoted[candidateIndex]
                    guard candidate.raw.preferredTitle.normalizedCorrectionInsensitiveDedupeKey == key,
                          candidate.raw.preferredTitle.correctionReleasePriority > currentPriority,
                          abs(candidate.score - current.score) <= correctedReleaseScoreWindow else {
                        continue
                    }
                    if let existingIndex = preferredIndex {
                        let existing = promoted[existingIndex]
                        if candidate.raw.preferredTitle.correctionReleasePriority >
                            existing.raw.preferredTitle.correctionReleasePriority {
                            preferredIndex = candidateIndex
                        }
                    } else {
                        preferredIndex = candidateIndex
                    }
                }
            }

            if let preferredIndex {
                let preferred = promoted.remove(at: preferredIndex)
                promoted.insert(preferred, at: index)
            }
            index += 1
        }
        return promoted
    }

    static func formatMultiplier(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func formatSignedPoints(_ value: Double) -> String {
        let normalized = abs(value) < 0.005 ? 0 : value
        var formatted = String(format: "%+.2f", normalized)
        while formatted.last == "0" {
            formatted.removeLast()
        }
        if formatted.last == "." {
            formatted.removeLast()
        }
        return formatted
    }

    static func formatSignedScore(_ value: Double) -> String {
        String(format: "%+.1f", value)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension String {
    var nonEmptyString: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var containsStandaloneMultiToken: Bool {
        range(of: #"(^|[^A-Za-z0-9])multi([^A-Za-z0-9]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

private extension AudioCodec {
    var isLosslessForDensity: Bool {
        switch self {
        case .truehd, .dtsHDMA, .pcm:
            return true
        case .dtsHDHRA, .ddp, .dts, .dd, .aac, .heAAC, .opus, .mp3, .unknown:
            return false
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
        let hasDetailReleaseName = specs?.fullTorrentName?.isEmpty == false
        let hasDynamicRangeSignal = specs?.hasDynamicRangeDetails == true || hasDetailReleaseName
        let hasAudioSignal = specs?.hasBestEnglishAudioDetails == true || hasDetailReleaseName
        return ParsedRelease(
            sourceType: detail.sourceType != .unknown ? detail.sourceType : sourceType,
            resolution: detail.resolution != .unknown ? detail.resolution : resolution,
            dynamicRange: detail.dynamicRange != .unknown && hasDynamicRangeSignal ? detail.dynamicRange : dynamicRange,
            videoCodec: detail.videoCodec != .unknown ? detail.videoCodec : videoCodec,
            audioCodec: detail.audioCodec != .unknown && hasAudioSignal ? detail.audioCodec : audioCodec,
            channels: detail.channels != .unknown && hasAudioSignal ? detail.channels : channels,
            atmos: hasAudioSignal ? detail.atmos : atmos,
            imax: detail.imax || imax
        )
    }
}
