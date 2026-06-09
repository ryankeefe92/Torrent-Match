import Foundation

public enum ReleaseParser {
    public static func parse(_ title: String) -> ParsedRelease {
        let upper = title.uppercased()
        let hasExplicit2160p = upper.contains("2160P") || upper.contains("4K")
        let hasExplicit1080p = upper.contains("1080P")
        let hasExplicit720p = upper.contains("720P")
        let hasBluRay = containsAnyToken(["BLURAY", "BLU-RAY", "BDRIP", "BDREMUX", "BRRIP", "BR-RIP", "BR RIP"], in: upper)
        let hasRemux = containsAnyToken(["REMUX", "BDREMUX", "BD REMUX"], in: upper)
        let hasUHD = containsAnyToken(["UHD"], in: upper) || (hasExplicit2160p && (hasBluRay || hasRemux))
        let hasHDRip = matches(#"(^|[^A-Z0-9])(HD[\s\.-]?RIP)([^A-Z0-9]|$)"#, in: upper)
        let hasHDTV = containsAnyToken(["HDTV"], in: upper) || hasHDRip

        let resolution: Resolution
        if hasExplicit2160p {
            resolution = .p2160
        } else if hasExplicit1080p {
            resolution = .p1080
        } else if hasExplicit720p {
            resolution = .p720
        } else if upper.contains("576P") || upper.contains("540P") || upper.contains("480P") || containsToken("SD", in: upper) {
            resolution = .sd
        } else if hasUHD {
            resolution = .p2160
        } else if hasHDTV {
            resolution = .p720
        } else if hasBluRay {
            resolution = .likely1080
        } else {
            resolution = .unknown
        }

        let sourceType: SourceType
        if hasRemux {
            sourceType = .remux
        } else if upper.contains("WEB-DL") || upper.contains("WEBDL") {
            sourceType = .webdl
        } else if upper.contains("WEBRIP") || upper.contains("WEB-RIP") {
            sourceType = .webrip
        } else if hasBluRay || hasUHD {
            sourceType = .bluray
        } else if containsAnyToken(["DVDRIP", "DVDR", "DVD"], in: upper) {
            sourceType = .dvd
        } else if hasHDTV {
            sourceType = .hdtv
        } else if containsAnyToken(["HDCAM", "CAM", "TELESYNC", "TS", "TELECINE", "TC"], in: upper) {
            sourceType = .cam
        } else {
            sourceType = .unknown
        }

        let dynamicRange: DynamicRange
        if upper.contains("DOLBY.VISION") || upper.contains("DOLBY VISION") || upper.contains("DOVI") || containsToken("DV", in: upper) {
            dynamicRange = .dolbyVision
        } else if upper.contains("HDR10+") || upper.contains("HDR10PLUS") {
            dynamicRange = .hdr10plus
        } else if containsHDR10(in: upper) {
            dynamicRange = .hdr10
        } else if containsToken("HDR", in: upper) {
            dynamicRange = .hdr
        } else if upper.contains("SDR") {
            dynamicRange = .sdr
        } else if hasUHD {
            dynamicRange = .likelyHDR
        } else if hasBluRay {
            dynamicRange = .sdr
        } else {
            dynamicRange = .unknown
        }

        let videoCodec: VideoCodec
        if containsAnyToken(["AV1", "AV-1", "A V1"], in: upper) {
            videoCodec = .av1
        } else if upper.contains("HEVC") || upper.contains("X265") || upper.contains("H265") || upper.contains("H.265") {
            videoCodec = .hevc
        } else if upper.contains("X264") || upper.contains("H264") || upper.contains("H.264") || upper.contains("AVC") {
            videoCodec = .avc
        } else if hasRemux && (hasUHD || hasExplicit2160p) {
            videoCodec = .hevc
        } else {
            videoCodec = .unknown
        }

        var channels = detectChannels(in: upper)

        var audioCodec: AudioCodec
        if upper.contains("TRUEHD") || upper.contains("TRUE-HD") {
            audioCodec = .truehd
        } else if containsAnyToken(["LPCM", "PCM"], in: upper) {
            audioCodec = .pcm
        } else if containsAnyToken(["DTS-MA5 1", "DTS-MA7 1", "DTS-HDMA5 1", "DTS-HDMA7 1"], in: upper) ||
            containsAnyToken(["DTS MA5 1", "DTS MA7 1", "DTS HDMA5 1", "DTS HDMA7 1"], in: upper) ||
            containsAnyToken(["DTS-MA5.1", "DTS-MA7.1", "DTS-HDMA5.1", "DTS-HDMA7.1"], in: upper) ||
            containsAnyToken(["DTS MA5.1", "DTS MA7.1", "DTS HDMA5.1", "DTS HDMA7.1"], in: upper) ||
            upper.contains("DTS-HD") ||
            upper.contains("DTSHD") ||
            upper.contains("DTS-HD.MA") ||
            upper.contains("DTS HD MA") ||
            upper.contains("DTS:X") ||
            containsAnyToken(["DTS-X", "DTS X"], in: upper) {
            audioCodec = .dtsHDMA
        } else if upper.contains("DDP") ||
            containsToken("DD+", in: upper) ||
            upper.contains("EAC3") || upper.contains("E-AC-3") || upper.contains("EAC-3") ||
            upper.contains("DOLBY DIGITAL PLUS") {
            audioCodec = .ddp
        } else if containsToken("DTS", in: upper) {
            audioCodec = .dts
        } else if matches(#"(^|[^A-Z0-9])DD[\.\s_-]?(7[\.\s]?1|5[\.\s]?1|2[\.\s]?0|1\.0|1CH|1 CH)([^A-Z0-9]|$)"#, in: upper) ||
            upper.contains("DD5.1") ||
            upper.contains("DD 5.1") ||
            upper.contains("DD2.0") ||
            upper.contains("DD 2.0") ||
            containsToken("DD", in: upper) ||
            upper.contains("DOLBYD") ||
            upper.contains("DOLBY DIGITAL") ||
            upper.contains("AC3") || upper.contains("AC-3") {
            audioCodec = .dd
        } else if upper.contains("AAC") {
            audioCodec = .aac
        } else {
            audioCodec = .unknown
        }

        if hasRemux && audioCodec == .unknown {
            audioCodec = .dd
        }

        if audioCodec == .dd && channels == .sevenOne {
            audioCodec = .ddp
        }
        if audioCodec == .dtsHDMA && channels == .unknown {
            channels = .fiveOne
        }
        if audioCodec == .ddp && channels == .unknown && (upper.contains("DDPA") || upper.contains("DDP ATMOS") || upper.contains("DDP+ATMOS")) {
            channels = .fiveOne
        }

        let atmosTokenPresent = containsToken("ATMOS", in: upper) || upper.contains("DDPA")
        let inferredDDPFromAtmosContext = atmosTokenPresent && audioCodec == .unknown && (channels == .fiveOne || channels == .sevenOne || channels == .unknown)
        if inferredDDPFromAtmosContext {
            audioCodec = .ddp
        }
        let inferredChannelsFromAtmosContext = atmosTokenPresent && channels == .unknown
        if inferredChannelsFromAtmosContext {
            channels = .fiveOne
        }
        let atmos = atmosTokenPresent && !inferredDDPFromAtmosContext && (audioCodec == .ddp || audioCodec == .truehd)
        let imax = containsToken("IMAX", in: upper)

        return ParsedRelease(
            sourceType: sourceType,
            resolution: resolution,
            dynamicRange: dynamicRange,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            channels: channels,
            atmos: atmos,
            imax: imax
        )
    }

    private static func containsToken(_ token: String, in text: String) -> Bool {
        let pattern = "(^|[^A-Z0-9])" + NSRegularExpression.escapedPattern(for: token) + "([^A-Z0-9]|$)"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func containsAnyToken(_ tokens: [String], in text: String) -> Bool {
        tokens.contains { containsToken($0, in: text) }
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func containsHDR10(in text: String) -> Bool {
        containsToken("HDR10", in: text) ||
            matches(#"(^|[^A-Z0-9])HDR[\.\s_-]*10[\.\s_-]*(BIT)?([^A-Z0-9]|$)"#, in: text) ||
            matches(#"(^|[^A-Z0-9])10[\.\s_-]*BIT[\.\s_-]*HDR([^A-Z0-9]|$)"#, in: text)
    }

    private static func detectChannels(in upper: String) -> ChannelLayout {
        let audioPrefix = #"(TRUEHD|TRUE-HD|LPCM|PCM|DDP|EAC3|E-AC-3|EAC-3|DD|AC3|AC-3|DTSHD|DTS-HDMA|DTS-HD(?:\.MA)?|DTS-MA|DTS HDMA|DTS HD MA|DTS MA|DTS|ATMOS)"#

        if matches(#"(^|[^A-Z0-9])(7\.1|8CH|8 CH)([^A-Z0-9]|$)"#, in: upper) ||
            matches(audioPrefix + #"[\.\s_-]?(7[\.\s]?1)([^A-Z0-9]|$)"#, in: upper) {
            return .sevenOne
        }

        if matches(#"(^|[^A-Z0-9])(5\.1|6CH|6 CH)([^A-Z0-9]|$)"#, in: upper) ||
            matches(audioPrefix + #"[\.\s_-]?(5[\.\s]?1)([^A-Z0-9]|$)"#, in: upper) {
            return .fiveOne
        }

        if matches(#"(^|[^A-Z0-9])(2\.0|2CH|2 CH|STEREO)([^A-Z0-9]|$)"#, in: upper) ||
            matches(audioPrefix + #"[\.\s_-]?(2[\.\s]?0)([^A-Z0-9]|$)"#, in: upper) {
            return .twoZero
        }

        if matches(#"(^|[^A-Z0-9])(1\.0|1CH|1 CH|MONO)([^A-Z0-9]|$)"#, in: upper) ||
            matches(audioPrefix + #"[\.\s_-]?(1\.0|1CH|1 CH)([^A-Z0-9]|$)"#, in: upper) {
            return .mono
        }

        return .unknown
    }
}
