import Foundation

public struct TorrentSearchResult: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let detailMetadata: String?
    public let detailSpecs: TorrentDetailSpecs?
    public let magnet: String?
    public let detailURL: URL?
    public let seeders: Int
    public let leechers: Int
    public let provider: String
    public let size: String?

    public init(
        id: UUID = UUID(),
        title: String,
        detailMetadata: String? = nil,
        detailSpecs: TorrentDetailSpecs? = nil,
        magnet: String?,
        detailURL: URL?,
        seeders: Int,
        leechers: Int,
        provider: String,
        size: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detailMetadata = detailMetadata
        self.detailSpecs = detailSpecs
        self.magnet = magnet
        self.detailURL = detailURL
        self.seeders = seeders
        self.leechers = leechers
        self.provider = provider
        self.size = size
    }
}

public struct TorrentDetailMetadata: Hashable, Sendable {
    public let text: String?
    public let specs: TorrentDetailSpecs?
    public let magnet: String?

    public init(text: String?, specs: TorrentDetailSpecs? = nil, magnet: String? = nil) {
        self.text = text
        self.specs = specs
        self.magnet = magnet
    }
}

public struct TorrentDetailSpecs: Hashable, Codable, Sendable {
    public let fullTorrentName: String?
    public let videoBitrate: String?
    public let resolutionWidth: String?
    public let resolutionHeight: String?
    public let frameRate: String?
    public let bitDepth: String?
    public let crf: String?
    public let preset: String?
    public let encodingPasses: String?
    public let colorGamut: String?
    public let dolbyVisionProfile: String?
    public let aspectRatio: String?
    public let bestEnglishAudioBitrate: String?
    public let bestEnglishAudioSampleRate: String?
    public let allAudioTrackBitrates: [String]
    public let totalAudioTrackBitrate: String?
    public let calculatedVideoBitrate: String?
    public let overallBitrate: String?
    public let runtime: String?
    public let calculatedFields: Set<String>
    public let releaseHintText: String?
    public let hasBestEnglishAudioDetails: Bool
    public let hasDynamicRangeDetails: Bool

    public init(
        fullTorrentName: String? = nil,
        videoBitrate: String? = nil,
        resolutionWidth: String? = nil,
        resolutionHeight: String? = nil,
        frameRate: String? = nil,
        bitDepth: String? = nil,
        crf: String? = nil,
        preset: String? = nil,
        encodingPasses: String? = nil,
        colorGamut: String? = nil,
        dolbyVisionProfile: String? = nil,
        aspectRatio: String? = nil,
        bestEnglishAudioBitrate: String? = nil,
        bestEnglishAudioSampleRate: String? = nil,
        allAudioTrackBitrates: [String] = [],
        totalAudioTrackBitrate: String? = nil,
        calculatedVideoBitrate: String? = nil,
        overallBitrate: String? = nil,
        runtime: String? = nil,
        calculatedFields: Set<String> = [],
        releaseHintText: String? = nil,
        hasBestEnglishAudioDetails: Bool = false,
        hasDynamicRangeDetails: Bool = false
    ) {
        self.fullTorrentName = fullTorrentName
        self.videoBitrate = videoBitrate
        self.resolutionWidth = resolutionWidth
        self.resolutionHeight = resolutionHeight
        self.frameRate = frameRate
        self.bitDepth = bitDepth
        self.crf = crf
        self.preset = preset
        self.encodingPasses = encodingPasses
        self.colorGamut = colorGamut
        self.dolbyVisionProfile = dolbyVisionProfile
        self.aspectRatio = aspectRatio
        self.bestEnglishAudioBitrate = bestEnglishAudioBitrate
        self.bestEnglishAudioSampleRate = bestEnglishAudioSampleRate
        self.allAudioTrackBitrates = allAudioTrackBitrates
        self.totalAudioTrackBitrate = totalAudioTrackBitrate
        self.calculatedVideoBitrate = calculatedVideoBitrate
        self.overallBitrate = overallBitrate
        self.runtime = runtime
        self.calculatedFields = calculatedFields
        self.releaseHintText = releaseHintText
        self.hasBestEnglishAudioDetails = hasBestEnglishAudioDetails
        self.hasDynamicRangeDetails = hasDynamicRangeDetails
    }

    public var hasDisplayableFields: Bool {
        fullTorrentName?.isEmpty == false ||
            videoBitrate?.isEmpty == false ||
            resolutionWidth?.isEmpty == false ||
            resolutionHeight?.isEmpty == false ||
            frameRate?.isEmpty == false ||
            bitDepth?.isEmpty == false ||
            crf?.isEmpty == false ||
            preset?.isEmpty == false ||
            encodingPasses?.isEmpty == false ||
            colorGamut?.isEmpty == false ||
            dolbyVisionProfile?.isEmpty == false ||
            aspectRatio?.isEmpty == false ||
            bestEnglishAudioBitrate?.isEmpty == false ||
            bestEnglishAudioSampleRate?.isEmpty == false ||
            !allAudioTrackBitrates.isEmpty ||
            totalAudioTrackBitrate?.isEmpty == false ||
            calculatedVideoBitrate?.isEmpty == false ||
            overallBitrate?.isEmpty == false ||
            runtime?.isEmpty == false
    }

    public var hasDetailPageMetadataFields: Bool {
        fullTorrentName?.isEmpty == false ||
            (videoBitrate?.isEmpty == false && !isCalculated("videoBitrate")) ||
            resolutionWidth?.isEmpty == false ||
            resolutionHeight?.isEmpty == false ||
            (frameRate?.isEmpty == false && !isCalculated("frameRate")) ||
            bitDepth?.isEmpty == false ||
            crf?.isEmpty == false ||
            preset?.isEmpty == false ||
            encodingPasses?.isEmpty == false ||
            colorGamut?.isEmpty == false ||
            dolbyVisionProfile?.isEmpty == false ||
            bestEnglishAudioBitrate?.isEmpty == false ||
            bestEnglishAudioSampleRate?.isEmpty == false ||
            !allAudioTrackBitrates.isEmpty ||
            totalAudioTrackBitrate?.isEmpty == false ||
            releaseHintText?.isEmpty == false ||
            hasBestEnglishAudioDetails ||
            hasDynamicRangeDetails
    }

    public func isCalculated(_ field: String) -> Bool {
        calculatedFields.contains(field)
    }

    public func mergedMissingFields(from other: TorrentDetailSpecs?) -> TorrentDetailSpecs {
        guard let other else { return self }
        var mergedCalculatedFields = calculatedFields
        mergedCalculatedFields.formUnion(other.calculatedFields)
        let mergedVideoBitrate = preferredValue(for: "videoBitrate", fallback: other.videoBitrate, fallbackIsCalculated: other.isCalculated("videoBitrate"))
        let mergedOverallBitrate = preferredValue(for: "overallBitrate", fallback: other.overallBitrate, fallbackIsCalculated: other.isCalculated("overallBitrate"))
        let mergedRuntime = preferredValue(for: "runtime", fallback: other.runtime, fallbackIsCalculated: other.isCalculated("runtime"))
        if videoBitrate?.isEmpty == false, !isCalculated("videoBitrate") {
            mergedCalculatedFields.remove("videoBitrate")
        }
        if overallBitrate?.isEmpty == false, !isCalculated("overallBitrate") {
            mergedCalculatedFields.remove("overallBitrate")
        }
        if runtime?.isEmpty == false, !isCalculated("runtime") {
            mergedCalculatedFields.remove("runtime")
        }
        if mergedVideoBitrate == other.videoBitrate, other.videoBitrate?.isEmpty == false, !other.isCalculated("videoBitrate") {
            mergedCalculatedFields.remove("videoBitrate")
        }
        if mergedOverallBitrate == other.overallBitrate, other.overallBitrate?.isEmpty == false, !other.isCalculated("overallBitrate") {
            mergedCalculatedFields.remove("overallBitrate")
        }
        if mergedRuntime == other.runtime, other.runtime?.isEmpty == false, !other.isCalculated("runtime") {
            mergedCalculatedFields.remove("runtime")
        }
        return TorrentDetailSpecs(
            fullTorrentName: fullTorrentName ?? other.fullTorrentName,
            videoBitrate: mergedVideoBitrate,
            resolutionWidth: resolutionWidth ?? other.resolutionWidth,
            resolutionHeight: resolutionHeight ?? other.resolutionHeight,
            frameRate: frameRate ?? other.frameRate,
            bitDepth: bitDepth ?? other.bitDepth,
            crf: crf ?? other.crf,
            preset: preset ?? other.preset,
            encodingPasses: encodingPasses ?? other.encodingPasses,
            colorGamut: colorGamut ?? other.colorGamut,
            dolbyVisionProfile: dolbyVisionProfile ?? other.dolbyVisionProfile,
            aspectRatio: aspectRatio ?? other.aspectRatio,
            bestEnglishAudioBitrate: bestEnglishAudioBitrate ?? other.bestEnglishAudioBitrate,
            bestEnglishAudioSampleRate: bestEnglishAudioSampleRate ?? other.bestEnglishAudioSampleRate,
            allAudioTrackBitrates: allAudioTrackBitrates.isEmpty ? other.allAudioTrackBitrates : allAudioTrackBitrates,
            totalAudioTrackBitrate: totalAudioTrackBitrate ?? other.totalAudioTrackBitrate,
            calculatedVideoBitrate: calculatedVideoBitrate ?? other.calculatedVideoBitrate,
            overallBitrate: mergedOverallBitrate,
            runtime: mergedRuntime,
            calculatedFields: mergedCalculatedFields,
            releaseHintText: releaseHintText ?? other.releaseHintText,
            hasBestEnglishAudioDetails: hasBestEnglishAudioDetails || other.hasBestEnglishAudioDetails,
            hasDynamicRangeDetails: hasDynamicRangeDetails || other.hasDynamicRangeDetails
        )
    }

    private func preferredValue(for field: String, fallback: String?, fallbackIsCalculated: Bool) -> String? {
        let preferred: String?
        switch field {
        case "videoBitrate": preferred = videoBitrate
        case "overallBitrate": preferred = overallBitrate
        case "runtime": preferred = runtime
        default: preferred = nil
        }
        guard let preferred, !preferred.isEmpty else { return fallback }
        if isCalculated(field), let fallback, !fallback.isEmpty, !fallbackIsCalculated {
            return fallback
        }
        return preferred
    }

    public func withFallbackRuntime(_ runtime: String, overallBitrate: String? = nil) -> TorrentDetailSpecs {
        var mergedCalculatedFields = calculatedFields
        if self.runtime == nil {
            mergedCalculatedFields.insert("runtime")
        }
        if frameRate == nil {
            mergedCalculatedFields.insert("frameRate")
        }
        if self.overallBitrate == nil, overallBitrate != nil {
            mergedCalculatedFields.insert("overallBitrate")
        }
        return TorrentDetailSpecs(
            fullTorrentName: fullTorrentName,
            videoBitrate: videoBitrate,
            resolutionWidth: resolutionWidth,
            resolutionHeight: resolutionHeight,
            frameRate: frameRate ?? "23.976 FPS",
            bitDepth: bitDepth,
            crf: crf,
            preset: preset,
            encodingPasses: encodingPasses,
            colorGamut: colorGamut,
            dolbyVisionProfile: dolbyVisionProfile,
            aspectRatio: aspectRatio,
            bestEnglishAudioBitrate: bestEnglishAudioBitrate,
            bestEnglishAudioSampleRate: bestEnglishAudioSampleRate,
            allAudioTrackBitrates: allAudioTrackBitrates,
            totalAudioTrackBitrate: totalAudioTrackBitrate,
            calculatedVideoBitrate: calculatedVideoBitrate,
            overallBitrate: self.overallBitrate ?? overallBitrate,
            runtime: self.runtime ?? runtime,
            calculatedFields: mergedCalculatedFields,
            releaseHintText: releaseHintText,
            hasBestEnglishAudioDetails: hasBestEnglishAudioDetails,
            hasDynamicRangeDetails: hasDynamicRangeDetails
        )
    }
}

public struct RankedTorrentResult: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let raw: TorrentSearchResult
    public let parsed: ParsedRelease
    public let score: Int
    public let notes: [String]
    public let excluded: Bool

    public init(raw: TorrentSearchResult, parsed: ParsedRelease, score: Int, notes: [String], excluded: Bool) {
        self.id = raw.id
        self.raw = raw
        self.parsed = parsed
        self.score = score
        self.notes = notes
        self.excluded = excluded
    }
}

public struct VideoQualityBreakdown: Hashable, Sendable {
    public let bitrateKbps: Int
    public let bitrateSourceLabel: String
    public let bitrateIsEstimated: Bool
    public let codec: VideoCodec
    public let codecFactor: Double
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let adjustedBPPPF: Double
    public let compressionHealth: Double

    public init(
        bitrateKbps: Int,
        bitrateSourceLabel: String,
        bitrateIsEstimated: Bool,
        codec: VideoCodec,
        codecFactor: Double,
        width: Int,
        height: Int,
        frameRate: Double,
        adjustedBPPPF: Double,
        compressionHealth: Double
    ) {
        self.bitrateKbps = bitrateKbps
        self.bitrateSourceLabel = bitrateSourceLabel
        self.bitrateIsEstimated = bitrateIsEstimated
        self.codec = codec
        self.codecFactor = codecFactor
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.adjustedBPPPF = adjustedBPPPF
        self.compressionHealth = compressionHealth
    }
}

public struct AudioQualityBreakdown: Hashable, Sendable {
    public let bitrateKbps: Int?
    public let bitrateSourceLabel: String?
    public let bitrateIsEstimated: Bool
    public let codec: AudioCodec
    public let codecFactor: Double
    public let channels: ChannelLayout
    public let effectiveChannelCount: Double
    public let density: Double?
    public let compressionHealth: Double

    public init(
        bitrateKbps: Int?,
        bitrateSourceLabel: String? = nil,
        bitrateIsEstimated: Bool = false,
        codec: AudioCodec,
        codecFactor: Double,
        channels: ChannelLayout,
        effectiveChannelCount: Double,
        density: Double?,
        compressionHealth: Double
    ) {
        self.bitrateKbps = bitrateKbps
        self.bitrateSourceLabel = bitrateSourceLabel
        self.bitrateIsEstimated = bitrateIsEstimated
        self.codec = codec
        self.codecFactor = codecFactor
        self.channels = channels
        self.effectiveChannelCount = effectiveChannelCount
        self.density = density
        self.compressionHealth = compressionHealth
    }
}

public struct QualityScoreBreakdown: Hashable, Sendable {
    public let parsed: ParsedRelease
    public let video: VideoQualityBreakdown
    public let audio: AudioQualityBreakdown

    public init(parsed: ParsedRelease, video: VideoQualityBreakdown, audio: AudioQualityBreakdown) {
        self.parsed = parsed
        self.video = video
        self.audio = audio
    }
}

public enum SourceType: String, Codable, Sendable {
    case remux, bluray, webdl, webrip, dvd, hdtv, cam, unknown
}

public enum Resolution: String, Codable, Sendable {
    case p2160 = "2160p"
    case p1080 = "1080p"
    case likely1080 = "likely_1080p"
    case p720 = "720p"
    case sd
    case unknown
}

public enum DynamicRange: String, Codable, Sendable {
    case dolbyVision = "dolby_vision"
    case hdr10plus
    case hdr10
    case hdr
    case likelyHDR = "likely_hdr"
    case unknown
    case sdr
}

public enum VideoCodec: String, Codable, Sendable {
    case hevc, avc, vc1, mpeg2, av1, unknown
}

public enum AudioCodec: String, Codable, Sendable {
    case truehd, dtsHDMA = "dts_hd_ma", dtsHDHRA = "dts_hd_hra", pcm, ddp, dts, dd, aac, unknown
}

public enum ChannelLayout: String, Codable, Sendable {
    case sevenOne = "7.1"
    case fiveOne = "5.1"
    case twoZero = "2.0"
    case mono
    case unknown
}

public struct ParsedRelease: Hashable, Codable, Sendable {
    public let sourceType: SourceType
    public let resolution: Resolution
    public let dynamicRange: DynamicRange
    public let videoCodec: VideoCodec
    public let audioCodec: AudioCodec
    public let channels: ChannelLayout
    public let atmos: Bool
    public let imax: Bool

    public init(
        sourceType: SourceType,
        resolution: Resolution,
        dynamicRange: DynamicRange,
        videoCodec: VideoCodec,
        audioCodec: AudioCodec,
        channels: ChannelLayout,
        atmos: Bool,
        imax: Bool = false
    ) {
        self.sourceType = sourceType
        self.resolution = resolution
        self.dynamicRange = dynamicRange
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.channels = channels
        self.atmos = atmos
        self.imax = imax
    }
}
