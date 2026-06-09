import Foundation

public enum TorrentDetailSpecParser {
    public static func parse(_ text: String?, detailTitle: String? = nil, fallbackTitle: String? = nil) -> TorrentDetailSpecs? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }

        let sections = parseSections(from: text)
        let general = sections.first { $0.kind == .general }
        let videoSections = sections.filter { $0.kind == .video }
        let video = videoSections.first
        let audioTracks = sections.filter { $0.kind == .audio }
        let bestEnglishAudio = bestEnglishTrack(from: audioTracks)
        var calculatedFields = Set<String>()

        let fullName = cleanedName(
            firstValue(for: ["Complete name", "File name", "Filename", "Name", "Title"], in: general) ??
                firstValue(for: ["Complete name", "File name", "Filename", "Name", "Title"], in: sections.first) ??
                releaseNameCandidate(from: text) ??
                detailTitle
        )
        let freeText = freeTextSpecs(from: text)
        let parsedVideoBitrate = firstValue(for: ["Bit rate", "Bitrate", "BitRate"], in: video) ?? freeText.videoBitrate
        let parsedResolution = resolutionValues(firstValue(for: ["Resolution"], in: video)) ?? freeText.resolution
        let parsedWidth = pixelValue(firstValue(for: ["Width"], in: video)) ?? parsedResolution?.width
        let parsedHeight = pixelValue(firstValue(for: ["Height"], in: video)) ?? parsedResolution?.height
        let parsedAspectRatio = firstValue(for: ["Display aspect ratio", "Aspect ratio", "Display AR", "DAR"], in: video) ??
            freeText.aspectRatio
        let derivedResolution = resolutionFromAspectRatio(aspectRatio: parsedAspectRatio, width: parsedWidth, height: parsedHeight)
        let width = parsedWidth ?? derivedResolution?.width
        let height = parsedHeight ?? derivedResolution?.height
        if parsedWidth == nil, width != nil { calculatedFields.insert("resolutionWidth") }
        if parsedHeight == nil, height != nil { calculatedFields.insert("resolutionHeight") }
        let videoFrameRate = firstValue(for: ["Frame rate", "Framerate"], in: video) ??
            firstValue(for: ["Frame rate", "Framerate"], in: general) ??
            freeText.frameRate
        let encoder = firstValue(for: ["Encoder", "Writing library"], in: video)
        let bitDepth = firstValue(for: ["Bit depth"], in: video) ?? bitDepthValue(from: encoder) ?? freeText.bitDepth
        let encodingSettings = firstValue(for: ["Encoding settings", "Encoder settings"], in: video) ?? encoder
        let crf = firstValue(for: ["CRF", "crf"], in: video) ?? tokenValue(named: "crf", in: encodingSettings) ?? freeText.crf
        let preset = firstValue(for: ["Preset"], in: video) ?? tokenValue(named: "preset", in: encodingSettings) ?? freeText.preset
        let passes = firstValue(for: ["Passes", "Encoding passes", "Pass"], in: video) ??
            tokenValue(named: "pass", in: encodingSettings).flatMap(passDisplayValue) ??
            freeText.passes
        let colorGamut = firstValue(for: ["Color primaries", "Colour primaries", "Color gamut", "Colour gamut"], in: video) ??
            tokenValue(named: "colorprim", in: encodingSettings) ??
            tokenValue(named: "colourprim", in: encodingSettings) ??
            freeText.colorGamut
        let hdrFormat = firstValue(for: ["HDR format", "HDR_Format"], in: video)
        let dolbyVisionProfile = firstValue(for: ["Dolby Vision profile", "DV profile"], in: video) ??
            freeText.dolbyVisionProfile ??
            extractDolbyVisionProfile(from: hdrFormat ?? text)
        let derivedAspectRatio = aspectRatioFromDimensions(width: width, height: height)
        let aspectRatio = parsedAspectRatio ?? derivedAspectRatio
        if parsedAspectRatio == nil, aspectRatio != nil { calculatedFields.insert("aspectRatio") }
        let allAudioBitrates = uniqued(audioTracks.compactMap(audioTrackBitrateLabel) + freeText.allAudioBitrates)
        let totalAudioBitrateKbps = totalBitrateKbps(from: allAudioBitrates)
        let totalAudioBitrate = totalAudioBitrateKbps.map(displayBitrate)
        if totalAudioBitrate != nil { calculatedFields.insert("totalAudioTrackBitrate") }
        let parsedOverallBitrate = firstValue(for: ["Overall bit rate", "Overall bitrate"], in: general) ??
            firstValue(for: ["Overall bit rate", "Overall bitrate"], in: video) ??
            freeText.overallBitrate
        let fileSizeBytes = mainMovieFileSizeBytes(from: text)
        let runtimeSeconds = runtimeSeconds(from: firstValue(for: ["Duration", "Runtime"], in: general) ??
            firstValue(for: ["Duration", "Runtime"], in: video) ??
            freeText.runtime)
        let fileDerivedOverallBitrate = calculatedOverallBitrate(fileSizeBytes: fileSizeBytes, runtimeSeconds: runtimeSeconds)
        let overallBitrate = parsedOverallBitrate ?? fileDerivedOverallBitrate
        if parsedOverallBitrate == nil, overallBitrate != nil { calculatedFields.insert("overallBitrate") }
        let calculatedVideoBitrate = calculatedVideoBitrate(overallBitrate: overallBitrate, totalAudioBitrateKbps: totalAudioBitrateKbps)
        let videoBitrate = parsedVideoBitrate ?? calculatedVideoBitrate
        if parsedVideoBitrate == nil, videoBitrate != nil { calculatedFields.insert("videoBitrate") }
        if calculatedVideoBitrate != nil { calculatedFields.insert("calculatedVideoBitrate") }
        let runtime = firstValue(for: ["Duration", "Runtime"], in: general) ??
            firstValue(for: ["Duration", "Runtime"], in: video) ??
            freeText.runtime

        let releaseHints = releaseHintText(
            fullName: fullName,
            fallbackTitle: fallbackTitle,
            width: width,
            height: height,
            videoFormat: firstValue(for: ["Format", "Codec", "Codec info"], in: video),
            hdrFormat: hdrFormat,
            dolbyVisionProfile: dolbyVisionProfile,
            audioTrack: bestEnglishAudio
        )
        let hasBestEnglishAudioDetails = audioToken(from: bestEnglishAudio) != nil
        let hasDynamicRangeDetails = hdrFormat?.isEmpty == false || dolbyVisionProfile?.isEmpty == false

        let specs = TorrentDetailSpecs(
            fullTorrentName: fullName,
            videoBitrate: videoBitrate,
            resolutionWidth: width,
            resolutionHeight: height,
            frameRate: videoFrameRate,
            bitDepth: bitDepth,
            crf: crf,
            preset: preset,
            encodingPasses: passes,
            colorGamut: colorGamut,
            dolbyVisionProfile: dolbyVisionProfile,
            aspectRatio: aspectRatio,
            bestEnglishAudioBitrate: firstValue(for: ["Bit rate", "Bitrate", "BitRate"], in: bestEnglishAudio) ?? freeText.bestEnglishAudioBitrate,
            bestEnglishAudioSampleRate: firstValue(for: ["Sampling rate", "Sample rate", "Samplerate"], in: bestEnglishAudio) ?? freeText.bestEnglishAudioSampleRate,
            allAudioTrackBitrates: allAudioBitrates,
            totalAudioTrackBitrate: totalAudioBitrate,
            calculatedVideoBitrate: calculatedVideoBitrate,
            overallBitrate: overallBitrate,
            runtime: runtime,
            calculatedFields: calculatedFields,
            releaseHintText: releaseHints,
            hasBestEnglishAudioDetails: hasBestEnglishAudioDetails,
            hasDynamicRangeDetails: hasDynamicRangeDetails
        )

        return specs.hasDisplayableFields || releaseHints?.isEmpty == false ? specs : nil
    }
}

private struct DetailMediaSection {
    enum Kind {
        case general
        case video
        case audio
        case other
    }

    let name: String
    let kind: Kind
    var fields: [String: [String]] = [:]

    mutating func add(key: String, value: String) {
        let normalized = normalizeKey(key)
        guard !normalized.isEmpty, !value.isEmpty else { return }
        fields[normalized, default: []].append(value)
    }
}

private struct FreeTextSpecs {
    var resolution: (width: String?, height: String?)?
    var videoBitrate: String?
    var frameRate: String?
    var bitDepth: String?
    var crf: String?
    var preset: String?
    var passes: String?
    var colorGamut: String?
    var dolbyVisionProfile: String?
    var aspectRatio: String?
    var bestEnglishAudioBitrate: String?
    var bestEnglishAudioSampleRate: String?
    var allAudioBitrates: [String]
    var overallBitrate: String?
    var runtime: String?
}

private struct FileSizeEntry {
    let label: String
    let bytes: Double

    var isMainMovieCandidate: Bool {
        let lower = label.lowercased()
        guard !lower.contains("sample"),
              !lower.contains("trailer"),
              !lower.contains("subtitle"),
              !lower.contains("subs"),
              !lower.contains("nfo"),
              !lower.contains("screenshot"),
              !lower.contains("screens"),
              !lower.contains("proof") else { return false }

        let movieExtensions = [".mkv", ".mp4", ".m4v", ".avi", ".mov", ".ts", ".m2ts"]
        return movieExtensions.contains { lower.contains($0) } ||
            lower.contains("movie") ||
            lower.contains("feature") ||
            lower.contains("main")
    }
}

private extension TorrentDetailSpecParser {
    static func parseSections(from text: String) -> [DetailMediaSection] {
        var sections: [DetailMediaSection] = []
        var current = DetailMediaSection(name: "General", kind: .general)

        for rawLine in text.components(separatedBy: .newlines) {
            let line = cleanedLine(rawLine)
            guard !line.isEmpty else { continue }

            if let header = sectionHeader(from: line) {
                if !current.fields.isEmpty {
                    sections.append(current)
                }
                current = header
                continue
            }

            guard let separatorRange = line.range(of: #"\s*[:=]\s*"#, options: .regularExpression) else { continue }
            let key = String(line[..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[separatorRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            current.add(key: key, value: value)
        }

        if !current.fields.isEmpty {
            sections.append(current)
        }
        return sections
    }

    static func sectionHeader(from line: String) -> DetailMediaSection? {
        let normalized = line
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9 ]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized == "general" {
            return DetailMediaSection(name: line, kind: .general)
        }
        if normalized == "video" || normalized.hasPrefix("video ") || normalized.hasPrefix("videoid") {
            return DetailMediaSection(name: line, kind: .video)
        }
        if normalized == "audio" || normalized.hasPrefix("audio ") || normalized.hasPrefix("audioid") || normalized.contains(" audio") {
            return DetailMediaSection(name: line, kind: .audio)
        }
        return nil
    }

    static func firstValue(for keys: [String], in section: DetailMediaSection?) -> String? {
        guard let section else { return nil }
        for key in keys {
            if let value = section.fields[normalizeKey(key)]?.first?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func cleanedName(_ name: String?) -> String? {
        guard var name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        if let slash = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            name = String(name[name.index(after: slash)...])
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func freeTextSpecs(from text: String) -> FreeTextSpecs {
        let compact = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: .newlines).map(cleanedLine)
        let videoBitrateLine = lines.first { line in
            let lower = line.lowercased()
            return lower.contains("video") &&
                (lower.contains("bit rate") || lower.contains("bitrate")) &&
                (lower.contains("kb/s") || lower.contains("kbps") || lower.contains("mb/s") || lower.contains("mbps"))
        }
        let audioLine = text.components(separatedBy: .newlines)
            .map(cleanedLine)
            .first { line in
                let lower = line.lowercased()
                return lower.contains("english") && (lower.contains("kb/s") || lower.contains("kbps") || lower.contains("mb/s") || lower.contains("mbps"))
            }
        let looseAudioBitrates = looseAudioBitrateLabels(from: text)

        return FreeTextSpecs(
            resolution: resolutionValues(firstRegexCapture(#"(?i)(\d[\d ]{2,7}\s*(?:pixels?|px)?\s*[x×]\s*\d[\d ]{2,7})"#, in: compact)),
            videoBitrate: videoBitrateLine.flatMap {
                firstRegexCapture(#"(?i)(?:bit\s*rate|bitrate)\s*[:=]\s*((?:VBR|CBR|ABR)?\s*\d[\d ]*(?:\.\d+)?\s*(?:[kmgt]i?b/s|[kmgt]bps|b/s))"#, in: $0)
            },
            frameRate: firstRegexCapture(#"(?i)(?:frame\s*rate|framerate)\s*[:=]\s*([A-Z]*\s*\d+(?:\.\d+)?(?:\s*\([^\)]*\))?\s*FPS?)"#, in: compact) ??
                firstRegexCapture(#"(?i)\b(\d{2,3}(?:\.\d{2,3})\s*FPS)\b"#, in: compact),
            bitDepth: bitDepthValue(from: compact),
            crf: tokenValue(named: "crf", in: compact) ?? firstRegexCapture(#"(?i)\bCRF\s*[:=]?\s*(\d+(?:\.\d+)?)\b"#, in: compact),
            preset: tokenValue(named: "preset", in: compact) ?? firstRegexCapture(#"(?i)\bpreset\s*[:=]\s*([A-Za-z0-9_-]+)"#, in: compact),
            passes: tokenValue(named: "pass", in: compact).flatMap(passDisplayValue) ??
                firstRegexCapture(#"(?i)\b([12])\s*pass(?:es)?\b"#, in: compact).flatMap(passDisplayValue),
            colorGamut: firstRegexCapture(#"(?i)\b(BT\.?2020|BT\.?709|DCI-?P3|Display\s*P3)\b"#, in: compact),
            dolbyVisionProfile: extractDolbyVisionProfile(from: compact),
            aspectRatio: firstRegexCapture(#"(?i)(?:display\s*ar|display\s*aspect\s*ratio|aspect\s*ratio|dar)\s*[:=]\s*([0-9.]+\s*(?:\|\s*)?[0-9.]*:?[0-9.]*)"#, in: compact),
            bestEnglishAudioBitrate: audioLine.flatMap {
                firstRegexCapture(#"(?i)((?:VBR|CBR|ABR)?\s*\d[\d ]*(?:\.\d+)?\s*(?:[kmgt]i?b/s|[kmgt]bps|b/s))"#, in: $0)
            },
            bestEnglishAudioSampleRate: firstRegexCapture(#"(?i)(?:sampling\s*rate|sample\s*rate|samplerate)\s*[:=]\s*(\d+(?:\.\d+)?\s*kHz)"#, in: compact),
            allAudioBitrates: looseAudioBitrates,
            overallBitrate: firstRegexCapture(#"(?i)overall\s*(?:bit\s*rate|bitrate)\s*[:=]\s*((?:VBR|CBR|ABR)?\s*\d[\d ]*(?:\.\d+)?\s*(?:[kmgt]i?b/s|[kmgt]bps|b/s))"#, in: compact),
            runtime: firstRegexCapture(#"(?i)(?:duration|runtime|run\s*time)\s*[:=]\s*([0-9]{1,2}\s*h(?:ours?)?\s*[0-9]{1,2}\s*m(?:in(?:utes?)?)?(?:\s*[0-9]{1,2}\s*s(?:ec(?:onds?)?)?)?)"#, in: compact) ??
                firstRegexCapture(#"(?i)(?:duration|runtime|run\s*time)\s*[:=]\s*([0-9]{1,2}:[0-9]{2}(?::[0-9]{2}(?:\.\d+)?)?)"#, in: compact)
        )
    }

    static func releaseNameCandidate(from text: String) -> String? {
        for rawLine in text.components(separatedBy: .newlines).prefix(12) {
            let line = cleanedLine(rawLine)
            guard !line.isEmpty,
                  !line.lowercased().hasPrefix("source"),
                  !line.lowercased().hasPrefix("note"),
                  !line.lowercased().hasPrefix("https://"),
                  !line.lowercased().hasPrefix("http://") else { continue }
            let upper = line.uppercased()
            let hasReleaseSignal = upper.contains("1080P") ||
                upper.contains("2160P") ||
                upper.contains("720P") ||
                upper.contains("BLURAY") ||
                upper.contains("WEB-DL") ||
                upper.contains("WEBDL") ||
                upper.contains("WEBRIP") ||
                upper.contains("REMUX") ||
                upper.contains("X264") ||
                upper.contains("X265") ||
                upper.contains("HEVC") ||
                upper.contains("H.264") ||
                upper.contains("H.265")
            if hasReleaseSignal {
                return line
            }
        }
        return nil
    }

    static func pixelValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let digits = raw.replacingOccurrences(of: #"[^0-9]"#, with: "", options: .regularExpression)
        guard !digits.isEmpty else { return raw.nilIfEmpty }
        return "\(digits) px"
    }

    static func resolutionValues(_ raw: String?) -> (width: String?, height: String?)? {
        guard let raw else { return nil }
        let normalized = raw
            .replacingOccurrences(of: #","#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let pattern = #"(?i)(\d[\d ]{2,7})\s*(?:pixels?|px)?\s*[x×]\s*(\d[\d ]{2,7})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)),
              match.numberOfRanges > 2,
              let widthRange = Range(match.range(at: 1), in: normalized),
              let heightRange = Range(match.range(at: 2), in: normalized) else {
            return nil
        }
        let width = normalized[widthRange].replacingOccurrences(of: #"[^0-9]"#, with: "", options: .regularExpression)
        let height = normalized[heightRange].replacingOccurrences(of: #"[^0-9]"#, with: "", options: .regularExpression)
        return ("\(width) px", "\(height) px")
    }

    static func tokenValue(named name: String, in text: String?) -> String? {
        guard let text else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?i)(?:^|[\s:/,])"# + escaped + #"\s*=\s*([^,\s/]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func bitDepthValue(from text: String?) -> String? {
        guard let text,
              let captured = firstRegexCapture(#"(?i)\b(8|10|12)[\s-]?bits?\b"#, in: text) ??
                firstRegexCapture(#"(?i)\b(8|10|12)bit\b"#, in: text) else {
            return nil
        }
        return "\(captured) bits"
    }

    static func passDisplayValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "1" { return "1 pass" }
        if trimmed == "2" { return "2 passes" }
        return trimmed
    }

    static func extractDolbyVisionProfile(from text: String) -> String? {
        let lower = text.lowercased()
        guard lower.contains("dolby vision") || lower.contains("dovi") || lower.contains("dvhe") || lower.contains("dvh1") else {
            return nil
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

    static func bestEnglishTrack(from audioTracks: [DetailMediaSection]) -> DetailMediaSection? {
        let englishTracks = audioTracks.filter(isEnglishAudioTrack)
        return englishTracks.max { audioTrackScore($0) < audioTrackScore($1) }
    }

    static func isEnglishAudioTrack(_ track: DetailMediaSection) -> Bool {
        let language = firstValue(for: ["Language"], in: track)?.lowercased() ?? ""
        let title = firstValue(for: ["Title"], in: track)?.lowercased() ?? ""
        return language.contains("english") ||
            language == "eng" ||
            language.hasPrefix("en") ||
            title.contains("english") ||
            title.contains(" eng ")
    }

    static func audioTrackScore(_ track: DetailMediaSection) -> Int {
        let format = firstValue(for: ["Format", "Codec", "Codec info", "Commercial name"], in: track)?.uppercased() ?? ""
        let bitrate = bitrateKbps(firstValue(for: ["Bit rate", "Bitrate"], in: track)) ?? 0
        let channels = channelCount(firstValue(for: ["Channel(s)", "Channels"], in: track)) ?? 0
        return audioCodecPriority(format) * 1_000_000 + bitrate * 100 + channels
    }

    static func audioCodecPriority(_ format: String) -> Int {
        if format.contains("TRUEHD") { return 9 }
        if format.contains("DTS-HD") || format.contains("DTS HD") { return 8 }
        if format.contains("PCM") { return 7 }
        if format.contains("E-AC-3") || format.contains("EAC3") || format.contains("DD+") { return 6 }
        if format.contains("DTS") { return 5 }
        if format.contains("AC-3") || format.contains("AC3") { return 4 }
        if format.contains("AAC") { return 3 }
        return 1
    }

    static func audioTrackBitrateLabel(_ track: DetailMediaSection) -> String? {
        guard let bitrate = firstValue(for: ["Bit rate", "Bitrate", "BitRate"], in: track) else { return nil }
        let language = firstValue(for: ["Language"], in: track)
        let format = firstValue(for: ["Format", "Codec", "Codec info"], in: track)
        let label = [language, format]
            .compactMap { $0?.nilIfEmpty }
            .joined(separator: " ")
        return label.isEmpty ? bitrate : "\(label): \(bitrate)"
    }

    static func totalBitrateKbps(from tracks: [DetailMediaSection]) -> Int? {
        let values = tracks.compactMap { bitrateKbps(firstValue(for: ["Bit rate", "Bitrate", "BitRate"], in: $0)) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    static func totalBitrateKbps(from labels: [String]) -> Int? {
        let values = labels.compactMap(bitrateKbps)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    static func calculatedVideoBitrate(overallBitrate: String?, totalAudioBitrateKbps: Int?) -> String? {
        guard let totalAudioBitrateKbps,
              let overallKbps = bitrateKbps(overallBitrate),
              overallKbps > totalAudioBitrateKbps else { return nil }
        return displayBitrate(overallKbps - totalAudioBitrateKbps)
    }

    static func calculatedOverallBitrate(fileSizeBytes: Double?, runtimeSeconds: Double?) -> String? {
        guard let fileSizeBytes,
              let runtimeSeconds,
              runtimeSeconds > 0 else { return nil }
        let kbps = Int((fileSizeBytes * 8) / runtimeSeconds / 1_000)
        guard kbps > 0 else { return nil }
        return displayBitrate(kbps)
    }

    static func aspectRatioFromDimensions(width: String?, height: String?) -> String? {
        guard let width = integer(from: width),
              let height = integer(from: height),
              width > 0,
              height > 0 else { return nil }
        let divisor = greatestCommonDivisor(width, height)
        let simplifiedWidth = width / divisor
        let simplifiedHeight = height / divisor
        let decimal = Double(width) / Double(height)
        return "\(simplifiedWidth):\(simplifiedHeight) (\(String(format: "%.2f", decimal)):1)"
    }

    static func resolutionFromAspectRatio(aspectRatio: String?, width: String?, height: String?) -> (width: String?, height: String?)? {
        guard let ratio = aspectRatioComponents(from: aspectRatio) else { return nil }
        if let widthValue = integer(from: width), height == nil {
            let calculatedHeight = Int(round(Double(widthValue) * ratio.height / ratio.width))
            return ("\(widthValue) px", "\(calculatedHeight) px")
        }
        if let heightValue = integer(from: height), width == nil {
            let calculatedWidth = Int(round(Double(heightValue) * ratio.width / ratio.height))
            return ("\(calculatedWidth) px", "\(heightValue) px")
        }
        return nil
    }

    static func aspectRatioComponents(from raw: String?) -> (width: Double, height: Double)? {
        guard let raw else { return nil }
        if let left = firstRegexCapture(#"([0-9]+(?:\.[0-9]+)?)\s*:\s*[0-9]+(?:\.[0-9]+)?"#, in: raw),
           let right = firstRegexCapture(#"[0-9]+(?:\.[0-9]+)?\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, in: raw),
           let width = Double(left),
           let height = Double(right),
           width > 0,
           height > 0 {
            return (width, height)
        }
        if let decimal = Double(firstRegexCapture(#"([0-9]+(?:\.[0-9]+)?)"#, in: raw) ?? ""),
           decimal > 0 {
            return (decimal, 1)
        }
        return nil
    }

    static func runtimeSeconds(from raw: String?) -> Double? {
        guard let raw else { return nil }
        let normalized = raw.lowercased()
            .replacingOccurrences(of: #","#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let hms = regexCaptures(#"^([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}(?:\.[0-9]+)?))?$"#, in: normalized) {
            let first = Double(hms[safe: 0] ?? "") ?? 0
            let second = Double(hms[safe: 1] ?? "") ?? 0
            let third = Double(hms[safe: 2] ?? "") ?? 0
            return hms.count >= 3 ? first * 3600 + second * 60 + third : first * 60 + second
        }
        let hours = Double(firstRegexCapture(#"([0-9]+(?:\.[0-9]+)?)\s*h"#, in: normalized) ?? "") ?? 0
        let minutes = Double(firstRegexCapture(#"([0-9]+(?:\.[0-9]+)?)\s*m"#, in: normalized) ?? "") ?? 0
        let seconds = Double(firstRegexCapture(#"([0-9]+(?:\.[0-9]+)?)\s*s"#, in: normalized) ?? "") ?? 0
        let total = hours * 3600 + minutes * 60 + seconds
        return total > 0 ? total : nil
    }

    static func mainMovieFileSizeBytes(from text: String) -> Double? {
        let entries = fileSizeEntries(from: text)
        if let largestMainFile = entries
            .filter(\.isMainMovieCandidate)
            .max(by: { $0.bytes < $1.bytes }) {
            return largestMainFile.bytes
        }
        if let generalSize = entries
            .filter({ $0.label.lowercased().contains("file size") || $0.label.lowercased().contains("filesize") })
            .max(by: { $0.bytes < $1.bytes }) {
            return generalSize.bytes
        }
        return entries.count == 1 ? entries.first?.bytes : nil
    }

    static func fileSizeEntries(from text: String) -> [FileSizeEntry] {
        text.components(separatedBy: .newlines).compactMap { rawLine in
            let line = cleanedLine(rawLine)
            guard let capture = regexCaptures(#"(?i)(.*?)([0-9]+(?:[\.,][0-9]+)?)\s*([kmgt]i?b|[kmgt]b)\b(?!/s|ps)"#, in: line),
                  capture.count >= 3,
                  let value = Double(capture[1].replacingOccurrences(of: ",", with: ".")) else { return nil }
            let label = capture[0].trimmingCharacters(in: CharacterSet(charactersIn: " :=-|").union(.whitespacesAndNewlines))
            let unit = capture[2]
            let bytes = bytesFromFileSize(value: value, unit: unit)
            return FileSizeEntry(label: label, bytes: bytes)
        }
    }

    static func bytesFromFileSize(value: Double, unit: String) -> Double {
        switch unit.lowercased() {
        case "kib": return value * 1_024
        case "mib": return value * pow(1_024, 2)
        case "gib": return value * pow(1_024, 3)
        case "tib": return value * pow(1_024, 4)
        case "kb": return value * 1_000
        case "mb": return value * pow(1_000, 2)
        case "gb": return value * pow(1_000, 3)
        case "tb": return value * pow(1_000, 4)
        default: return value
        }
    }

    static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var a = abs(lhs)
        var b = abs(rhs)
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return max(a, 1)
    }

    static func displayBitrate(_ kbps: Int) -> String {
        if kbps >= 1_000 {
            let mbps = Double(kbps) / 1_000
            let value = mbps == floor(mbps) ? String(Int(mbps)) : String(format: "%.2f", mbps)
            return "\(value) Mb/s (\(kbps) kb/s)"
        }
        return "\(kbps) kb/s"
    }

    static func looseAudioBitrateLabels(from text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map(cleanedLine)
            .compactMap { line in
                let lower = line.lowercased()
                guard lower.contains("audio") || lower.contains("english") || lower.contains("commentary") else { return nil }
                guard let rawBitrate = firstRegexCapture(#"(?i)((?:VBR|CBR|ABR)?\s*\d[\d ]*(?:\.\d+)?\s*(?:[kmgt]i?b/s|[kmgt]bps|b/s))"#, in: line) else { return nil }
                let bitrate = rawBitrate.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = line.replacingOccurrences(of: rawBitrate, with: "")
                    .replacingOccurrences(of: #"(?i)\b(?:bit\s*rate|bitrate)\b\s*[:=]?"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " :-|").union(.whitespacesAndNewlines))
                return label.isEmpty ? bitrate : "\(label): \(bitrate)"
            }
    }

    static func releaseHintText(
        fullName: String?,
        fallbackTitle: String?,
        width: String?,
        height: String?,
        videoFormat: String?,
        hdrFormat: String?,
        dolbyVisionProfile: String?,
        audioTrack: DetailMediaSection?
    ) -> String? {
        var tokens: [String] = []
        if let fullName {
            tokens.append(fullName)
        } else if let fallbackTitle {
            tokens.append(fallbackTitle)
        }
        if let resolutionToken = resolutionToken(width: width, height: height) {
            tokens.append(resolutionToken)
        }
        if let videoCodecToken = videoCodecToken(from: videoFormat) {
            tokens.append(videoCodecToken)
        }
        if let dynamicRangeToken = dynamicRangeToken(hdrFormat: hdrFormat, dolbyVisionProfile: dolbyVisionProfile) {
            tokens.append(dynamicRangeToken)
        }
        if let audioToken = audioToken(from: audioTrack) {
            tokens.append(audioToken)
        }
        return tokens.joined(separator: " ").nilIfEmpty
    }

    static func resolutionToken(width: String?, height: String?) -> String? {
        let widthNumber = integer(from: width)
        let heightNumber = integer(from: height)
        if (widthNumber ?? 0) >= 3000 || (heightNumber ?? 0) >= 1600 { return "2160p" }
        if (widthNumber ?? 0) >= 1600 || (heightNumber ?? 0) >= 900 { return "1080p" }
        if (widthNumber ?? 0) >= 1200 || (heightNumber ?? 0) >= 650 { return "720p" }
        if widthNumber != nil || heightNumber != nil { return "SD" }
        return nil
    }

    static func videoCodecToken(from format: String?) -> String? {
        let upper = format?.uppercased() ?? ""
        if upper.contains("AV1") { return "AV1" }
        if upper.contains("HEVC") || upper.contains("H.265") || upper.contains("H265") { return "HEVC" }
        if upper.contains("AVC") || upper.contains("H.264") || upper.contains("H264") { return "AVC" }
        return nil
    }

    static func dynamicRangeToken(hdrFormat: String?, dolbyVisionProfile: String?) -> String? {
        let upper = [hdrFormat, dolbyVisionProfile]
            .compactMap { $0 }
            .joined(separator: " ")
            .uppercased()
        if upper.contains("DOLBY VISION") || upper.contains("DOVI") || upper.contains("DVHE") || upper.contains("DVH1") {
            return "DOVI"
        }
        if upper.contains("HDR10+") { return "HDR10+" }
        if upper.contains("HDR10") { return "HDR10" }
        if upper.contains("HDR") { return "HDR" }
        return nil
    }

    static func audioToken(from track: DetailMediaSection?) -> String? {
        guard let track else { return nil }
        let format = firstValue(for: ["Format", "Codec", "Codec info", "Commercial name"], in: track)?.uppercased() ?? ""
        let atmos = format.contains("JOC") || format.contains("ATMOS") || (firstValue(for: ["Title"], in: track)?.uppercased().contains("ATMOS") == true)
        let channels = channelLayoutToken(firstValue(for: ["Channel(s)", "Channels"], in: track)) ??
            ((format.contains("E-AC-3") || format.contains("EAC3") || format.contains("DD+")) && atmos ? "5.1" : nil)

        let codec: String?
        if format.contains("TRUEHD") {
            codec = "TrueHD"
        } else if format.contains("DTS-HD") || format.contains("DTS HD") {
            codec = "DTS-HD MA"
        } else if format.contains("PCM") {
            codec = "PCM"
        } else if format.contains("E-AC-3") || format.contains("EAC3") || format.contains("DD+") {
            codec = "DDP"
        } else if format.contains("DTS") {
            codec = "DTS"
        } else if format.contains("AC-3") || format.contains("AC3") {
            codec = "DD"
        } else if format.contains("AAC") {
            codec = "AAC"
        } else {
            codec = nil
        }

        return [codec, channels, atmos ? "Atmos" : nil]
            .compactMap { $0 }
            .joined(separator: " ")
            .nilIfEmpty
    }

    static func channelLayoutToken(_ raw: String?) -> String? {
        guard let count = channelCount(raw) else { return nil }
        if count >= 8 { return "7.1" }
        if count >= 6 { return "5.1" }
        if count == 2 { return "2.0" }
        if count == 1 { return "1.0" }
        return nil
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

    static func channelCount(_ raw: String?) -> Int? {
        guard let raw,
              let captured = firstRegexCapture(#"([0-9]+)"#, in: raw) else { return nil }
        return Int(captured)
    }

    static func integer(from raw: String?) -> Int? {
        guard let raw else { return nil }
        let digits = raw.replacingOccurrences(of: #"[^0-9]"#, with: "", options: .regularExpression)
        return Int(digits)
    }

    static func firstRegexCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func regexCaptures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > 1 else { return nil }
        let captures = (1..<match.numberOfRanges).compactMap { index -> String? in
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        return captures.isEmpty ? nil : captures
    }

    static func uniqued(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    static func cleanedLine(_ line: String) -> String {
        line
            .replacingOccurrences(of: #"^[\s\-\*•|]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func normalizeKey(_ key: String) -> String {
    key.lowercased()
        .replacingOccurrences(of: #"\([^\)]*\)"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"[_\-]+"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"[^a-z0-9 ]+"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
