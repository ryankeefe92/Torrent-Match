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

    public func isCalculated(_ field: String) -> Bool {
        calculatedFields.contains(field)
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
    case hevc, avc, av1, unknown
}

public enum AudioCodec: String, Codable, Sendable {
    case truehd, dtsHDMA = "dts_hd_ma", pcm, ddp, dts, dd, aac, unknown
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
