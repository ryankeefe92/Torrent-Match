import Foundation

public enum ReleaseParser {
    public static func parse(_ title: String) -> ParsedRelease {
        let upper = title.uppercased()

        let resolution: Resolution
        if upper.contains("2160P") || upper.contains("4K") {
            resolution = .p2160
        } else if upper.contains("1080P") {
            resolution = .p1080
        } else if upper.contains("720P") {
            resolution = .p720
        } else if upper.contains("576P") || upper.contains("540P") || upper.contains("480P") || upper.contains("SD") {
            resolution = .sd
        } else {
            resolution = .unknown
        }

        let sourceType: SourceType
        if upper.contains("REMUX") {
            sourceType = .remux
        } else if upper.contains("WEB-DL") || upper.contains("WEBDL") {
            sourceType = .webdl
        } else if upper.contains("WEBRIP") || upper.contains("WEB-RIP") {
            sourceType = .webrip
        } else if upper.contains("UHD") || upper.contains("BLURAY") || upper.contains("BLU-RAY") || upper.contains("BDRIP") {
            sourceType = .bluray
        } else {
            sourceType = .unknown
        }

        let dynamicRange: DynamicRange
        if upper.contains("DOLBY.VISION") || upper.contains("DOLBY VISION") || upper.contains("DOVI") || containsToken("DV", in: upper) {
            dynamicRange = .dolbyVision
        } else if upper.contains("HDR10+") || upper.contains("HDR10PLUS") {
            dynamicRange = .hdr10plus
        } else if upper.contains("HDR10") {
            dynamicRange = .hdr10
        } else if upper.contains("HDR") {
            dynamicRange = .hdr
        } else if upper.contains("SDR") {
            dynamicRange = .sdr
        } else if (upper.contains("UHD") && (upper.contains("BLURAY") || upper.contains("BLU-RAY") || upper.contains("REMUX"))) {
            // Ryan's rule: UHD BluRay/REMUX without explicit SDR/HDR tag should be treated as HDR.
            dynamicRange = .hdr
        } else {
            dynamicRange = .unknown
        }

        let videoCodec: VideoCodec
        if upper.contains("AV1") {
            videoCodec = .av1
        } else if upper.contains("HEVC") || upper.contains("X265") || upper.contains("H265") || upper.contains("H.265") {
            videoCodec = .hevc
        } else if upper.contains("X264") || upper.contains("H264") || upper.contains("H.264") || upper.contains("AVC") {
            videoCodec = .avc
        } else {
            videoCodec = .unknown
        }

        let audioCodec: AudioCodec
        if upper.contains("TRUEHD") || upper.contains("TRUE-HD") {
            audioCodec = .truehd
        } else if upper.contains("DTS-HD") || upper.contains("DTSHD") || upper.contains("DTS-HD.MA") || upper.contains("DTS HD MA") {
            audioCodec = .dtsHDMA
        } else if upper.contains("DDP") || upper.contains("EAC3") || upper.contains("E-AC-3") || upper.contains("EAC-3") {
            audioCodec = .ddp
        } else if upper.contains("DD5.1") || upper.contains("DD 5.1") || upper.contains("AC3") || upper.contains("AC-3") {
            audioCodec = .dd
        } else if upper.contains("AAC") {
            audioCodec = .aac
        } else {
            audioCodec = .unknown
        }

        let channels: ChannelLayout
        if matches(#"(^|[^A-Z0-9])(7[\.\s]?1|8CH|8 CH)([^A-Z0-9]|$)"#, in: upper) {
            channels = .sevenOne
        } else if matches(#"(^|[^A-Z0-9])(5[\.\s]?1|6CH|6 CH)([^A-Z0-9]|$)"#, in: upper) {
            channels = .fiveOne
        } else if matches(#"(^|[^A-Z0-9])(2[\.\s]?0|2CH|2 CH|STEREO)([^A-Z0-9]|$)"#, in: upper) {
            channels = .twoZero
        } else {
            channels = .unknown
        }

        let atmos = upper.contains("ATMOS")

        return ParsedRelease(
            sourceType: sourceType,
            resolution: resolution,
            dynamicRange: dynamicRange,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            channels: channels,
            atmos: atmos
        )
    }

    private static func containsToken(_ token: String, in text: String) -> Bool {
        let pattern = "(^|[^A-Z0-9])" + NSRegularExpression.escapedPattern(for: token) + "([^A-Z0-9]|$)"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
