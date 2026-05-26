import Foundation

public struct TorrentSearchResult: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let magnet: String?
    public let detailURL: URL?
    public let seeders: Int
    public let leechers: Int
    public let provider: String

    public init(
        id: UUID = UUID(),
        title: String,
        magnet: String?,
        detailURL: URL?,
        seeders: Int,
        leechers: Int,
        provider: String
    ) {
        self.id = id
        self.title = title
        self.magnet = magnet
        self.detailURL = detailURL
        self.seeders = seeders
        self.leechers = leechers
        self.provider = provider
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
    case remux, bluray, webdl, webrip, unknown
}

public enum Resolution: String, Codable, Sendable {
    case p2160 = "2160p"
    case p1080 = "1080p"
    case p720 = "720p"
    case sd
    case unknown
}

public enum DynamicRange: String, Codable, Sendable {
    case dolbyVision = "dolby_vision"
    case hdr10plus
    case hdr10
    case hdr
    case unknown
    case sdr
}

public enum VideoCodec: String, Codable, Sendable {
    case hevc, avc, av1, unknown
}

public enum AudioCodec: String, Codable, Sendable {
    case truehd, dtsHDMA = "dts_hd_ma", ddp, dd, aac, unknown
}

public enum ChannelLayout: String, Codable, Sendable {
    case sevenOne = "7.1"
    case fiveOne = "5.1"
    case twoZero = "2.0"
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

    public init(
        sourceType: SourceType,
        resolution: Resolution,
        dynamicRange: DynamicRange,
        videoCodec: VideoCodec,
        audioCodec: AudioCodec,
        channels: ChannelLayout,
        atmos: Bool
    ) {
        self.sourceType = sourceType
        self.resolution = resolution
        self.dynamicRange = dynamicRange
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.channels = channels
        self.atmos = atmos
    }
}
