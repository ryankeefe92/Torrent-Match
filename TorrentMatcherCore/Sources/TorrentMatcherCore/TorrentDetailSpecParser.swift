import Foundation

public enum TorrentDetailSpecParser {
    public static func parse(_ text: String?, detailTitle: String? = nil, fallbackTitle: String? = nil) -> TorrentDetailSpecs? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }

        let sections = expandedAudioSections(from: parseSections(from: text))
        let general = sections.first { $0.kind == .general }
        let videoSections = sections.filter { $0.kind == .video }
        let video = videoSections.first
        let audioTracks = sections.filter { $0.kind == .audio }
        let bestEnglishAudio = bestEnglishTrack(from: audioTracks)
        let hasOnlyExplicitNonEnglishAudioTracks = audioTracksContainOnlyExplicitNonEnglish(audioTracks)
        var calculatedFields = Set<String>()

        let fullName = cleanedName(
            firstValue(for: ["Complete name", "File name", "Filename", "General"], in: general) ??
                firstValue(for: ["Complete name", "File name", "Filename", "General"], in: sections.first) ??
                releaseNameCandidate(from: text) ??
                firstValue(for: ["Name", "Title"], in: general) ??
                firstValue(for: ["Name", "Title"], in: sections.first) ??
                detailTitle
        )
        let freeText = freeTextSpecs(from: text)
        let parsedVideoBitrate = firstBitrateValue(for: ["Bit rate", "Bitrate", "BitRate", "Nominal bit rate", "Nominal bitrate"], in: video) ?? freeText.videoBitrate
        let parsedResolution = resolutionValues(firstValue(for: ["Resolution", "Aspect"], in: video)) ?? freeText.resolution
        let rawParsedWidth = pixelValue(firstValue(for: ["Width"], in: video)) ?? parsedResolution?.width
        let rawParsedHeight = pixelValue(firstValue(for: ["Height"], in: video)) ?? parsedResolution?.height
        let parsedAspectRatio = aspectRatioValue(firstValue(for: ["Display aspect ratio", "Aspect ratio", "Display AR", "DAR", "Aspect"], in: video)) ??
            freeText.aspectRatio
        let sanitizedResolution = sanitizedResolution(
            width: rawParsedWidth,
            height: rawParsedHeight,
            aspectRatio: parsedAspectRatio,
            title: fullName ?? fallbackTitle
        )
        let parsedWidth = sanitizedResolution.width
        let parsedHeight = sanitizedResolution.height
        if sanitizedResolution.calculatedWidth { calculatedFields.insert("resolutionWidth") }
        if sanitizedResolution.calculatedHeight { calculatedFields.insert("resolutionHeight") }
        let derivedResolution = resolutionFromAspectRatio(aspectRatio: parsedAspectRatio, width: parsedWidth, height: parsedHeight)
        let width = parsedWidth ?? derivedResolution?.width
        let height = parsedHeight ?? derivedResolution?.height
        if parsedWidth == nil, width != nil { calculatedFields.insert("resolutionWidth") }
        if parsedHeight == nil, height != nil { calculatedFields.insert("resolutionHeight") }
        let videoFrameRate = firstValue(for: ["Frame rate", "Framerate"], in: video) ??
            firstValue(for: ["Aspect"], in: video).flatMap { frameRateLabel(in: $0) } ??
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
        let structuredAudioBitrates = audioTracks.compactMap(audioTrackBitrateLabel)
        let allAudioBitrates = structuredAudioBitrates + freeTextAudioBitrateLabels(freeText.allAudioBitrates, excluding: structuredAudioBitrates)
        let totalAudioBitrateKbps = totalBitrateKbps(from: allAudioBitrates)
        let totalAudioBitrate = totalAudioBitrateKbps.map(displayBitrate)
        if totalAudioBitrate != nil { calculatedFields.insert("totalAudioTrackBitrate") }
        let parsedOverallBitrate = firstBitrateValue(for: ["Overall bit rate", "Overall bitrate", "Total bit rate", "Total bitrate", "Format"], in: general) ??
            firstBitrateValue(for: ["Overall bit rate", "Overall bitrate", "Total bit rate", "Total bitrate"], in: video) ??
            freeText.overallBitrate
        let fileSizeBytes = movieFileSizeBytesExcludingSubtitles(from: text)
        let parsedRuntime = firstValue(for: ["Duration", "Runtime"], in: general) ??
            firstValue(for: ["Length"], in: general).flatMap { runtimeLabel(in: $0) } ??
            firstValue(for: ["Duration", "Runtime"], in: video) ??
            freeText.runtime
        let runtimeSeconds = runtimeSeconds(from: parsedRuntime)
        let fileDerivedOverallBitrate = calculatedOverallBitrate(fileSizeBytes: fileSizeBytes, runtimeSeconds: runtimeSeconds)
        let overallBitrate = parsedOverallBitrate ?? fileDerivedOverallBitrate
        if parsedOverallBitrate == nil, overallBitrate != nil { calculatedFields.insert("overallBitrate") }
        let totalSubtitleBitrateKbps = totalSubtitleBitrateKbps(from: sections)
        let calculatedVideoBitrate = parsedVideoBitrate == nil ? calculatedVideoBitrate(overallBitrate: overallBitrate, totalAudioBitrateKbps: totalAudioBitrateKbps, totalSubtitleBitrateKbps: totalSubtitleBitrateKbps) : nil
        let videoBitrate = parsedVideoBitrate ?? calculatedVideoBitrate
        if calculatedVideoBitrate != nil {
            calculatedFields.insert("videoBitrate")
            calculatedFields.insert("calculatedVideoBitrate")
        }
        let parsedBestEnglishAudioBitrate = firstBitrateValue(for: ["Bit rate", "Bitrate", "BitRate"], in: bestEnglishAudio) ??
            bestEnglishAudio.flatMap { bitrateLabel(in: $0.name) } ??
            freeText.bestEnglishAudioBitrate ??
            bestEnglishAudioBitrate(fromLabels: allAudioBitrates)
        let calculatedBestEnglishAudioBitrate = parsedBestEnglishAudioBitrate == nil ? calculatedAudioBitrate(overallBitrate: overallBitrate, videoBitrate: parsedVideoBitrate, totalSubtitleBitrateKbps: totalSubtitleBitrateKbps) : nil
        if calculatedBestEnglishAudioBitrate != nil { calculatedFields.insert("bestEnglishAudioBitrate") }
        let runtime = parsedRuntime

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
            bestEnglishAudioBitrate: parsedBestEnglishAudioBitrate ?? calculatedBestEnglishAudioBitrate,
            bestEnglishAudioSampleRate: sampleRateLabel(in: bestEnglishAudio) ?? freeText.bestEnglishAudioSampleRate,
            allAudioTrackBitrates: allAudioBitrates,
            totalAudioTrackBitrate: totalAudioBitrate,
            calculatedVideoBitrate: calculatedVideoBitrate,
            overallBitrate: overallBitrate,
            runtime: runtime,
            calculatedFields: calculatedFields,
            releaseHintText: releaseHints,
            hasBestEnglishAudioDetails: hasBestEnglishAudioDetails,
            hasOnlyExplicitNonEnglishAudioTracks: hasOnlyExplicitNonEnglishAudioTracks,
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
        guard !isSubtitleCandidate,
              !lower.contains("sample"),
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

    var isSubtitleCandidate: Bool {
        let lower = label.lowercased()
        let subtitleExtensions = [".srt", ".ass", ".ssa", ".vtt", ".sub", ".idx", ".sup"]
        return lower.contains("subtitle") ||
            lower.contains("subs") ||
            subtitleExtensions.contains { lower.contains($0) }
    }
}

private extension DetailMediaSection {
    var isSubtitleSection: Bool {
        guard kind == .other else { return false }
        let normalized = name.lowercased()
        return normalized.contains("subtitle") ||
            normalized.contains("text")
    }
}

private extension TorrentDetailSpecParser {
    static func parseSections(from text: String) -> [DetailMediaSection] {
        var sections: [DetailMediaSection] = []
        var current = DetailMediaSection(name: "General", kind: .general)

        for rawLine in logicalMediaInfoLines(from: text) {
            let line = cleanedLine(rawLine)
            guard !line.isEmpty else { continue }

            if !line.contains(":"),
               !line.contains("="),
               let header = sectionHeader(from: line) {
                if !current.fields.isEmpty {
                    sections.append(current)
                }
                current = header
                continue
            }

            guard let separatorRange = line.range(of: #"\s*[:=]\s*"#, options: .regularExpression) else { continue }
            let key = String(line[..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[separatorRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty, let header = sectionHeader(from: key) {
                if !current.fields.isEmpty {
                    sections.append(current)
                }
                current = header
                continue
            }
            if normalizeKey(key) == "general" {
                current.add(key: "General", value: value)
                continue
            }
            if let keyedSection = keyedMediaSection(fromKey: key, value: value) {
                if !current.fields.isEmpty {
                    sections.append(current)
                }
                current = keyedSection
                continue
            }
            if let audioKey = canonicalAudioFieldKey(for: key) {
                if current.kind != .audio {
                    if !current.fields.isEmpty {
                        sections.append(current)
                    }
                    current = DetailMediaSection(name: "Audio", kind: .audio)
                }
                current.add(key: audioKey, value: value)
                continue
            }
            if let audioKey = inferredAudioFieldKey(key: key, value: value, currentKind: current.kind) {
                if current.kind != .audio {
                    if !current.fields.isEmpty {
                        sections.append(current)
                    }
                    current = DetailMediaSection(name: "Audio", kind: .audio)
                }
                current.add(key: audioKey, value: value)
                continue
            }
            if let videoKey = canonicalVideoFieldKey(for: key) {
                if current.kind != .video {
                    if !current.fields.isEmpty {
                        sections.append(current)
                    }
                    current = DetailMediaSection(name: "Video", kind: .video)
                }
                current.add(key: videoKey, value: value)
                continue
            }
            if let videoKey = inferredVideoFieldKey(key: key, value: value, currentKind: current.kind) {
                if current.kind != .video {
                    if !current.fields.isEmpty {
                        sections.append(current)
                    }
                    current = DetailMediaSection(name: "Video", kind: .video)
                }
                current.add(key: videoKey, value: value)
                continue
            }
            current.add(key: key, value: value)
        }

        if !current.fields.isEmpty {
            sections.append(current)
        }
        return sections
    }

    static func logicalMediaInfoLines(from text: String) -> [String] {
        var lines: [String] = []
        var current: String?

        func flushCurrent() {
            if let value = current?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                lines.append(value)
            }
            current = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let cleaned = cleanedLine(rawLine)
            guard !cleaned.isEmpty else {
                flushCurrent()
                continue
            }

            let splitAudioRows = cleaned
                .replacingOccurrences(of: #"(?i)\s+(?=Audio\s*#?\s*0?\d+\s*:)"#, with: "\n", options: .regularExpression)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            for part in splitAudioRows {
                if startsLogicalMediaInfoLine(part) {
                    flushCurrent()
                    current = part
                } else if let existing = current, shouldAppendAsContinuation(part, to: existing) {
                    current = "\(existing) \(part)"
                } else {
                    flushCurrent()
                    current = part
                }
            }
        }

        flushCurrent()
        return lines
    }

    static func startsLogicalMediaInfoLine(_ line: String) -> Bool {
        if sectionHeader(from: line) != nil {
            return true
        }
        if line.range(of: #"(?i)^Audio\s*#?\s*0?\d+\s*[:=]"#, options: .regularExpression) != nil {
            return true
        }
        if line.range(of: #"(?i)^\{?[A-Z][A-Za-z0-9 /&().#-]{0,42}\}?\s*[:=]"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    static func shouldAppendAsContinuation(_ line: String, to existing: String) -> Bool {
        let existingLower = existing.lowercased()
        if existingLower.range(of: #"audio\s*#?\s*0?\d+\s*[:=]"#, options: .regularExpression) != nil {
            return true
        }
        if existingLower.contains("bit rate") || existingLower.contains("bitrate") {
            return bitrateLabel(in: existing) == nil && bitrateLabel(in: "\(existing) \(line)") != nil
        }
        return false
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
        if normalized == "subtitle" ||
            normalized.hasPrefix("subtitle ") ||
            normalized.hasPrefix("text ") ||
            normalized.contains(" subtitle") {
            return DetailMediaSection(name: line, kind: .other)
        }
        return nil
    }

    static func keyedMediaSection(fromKey key: String, value: String) -> DetailMediaSection? {
        if canonicalVideoFieldKey(for: key) != nil {
            return nil
        }
        if let audio = audioSection(fromKey: key, value: value) {
            return audio
        }

        let normalizedKey = normalizeKey(key)
        if normalizedKey == "video" ||
            normalizedKey.hasPrefix("video ") ||
            normalizedKey.range(of: #"^video[0-9]+$"#, options: .regularExpression) != nil {
            var section = DetailMediaSection(name: "\(key) \(value)", kind: .video)
            if let format = videoCodecToken(from: value) ?? codecLabel(fromDescriptor: value) {
                section.add(key: "Format", value: format)
            }
            if !isNonTrackBitrateKey(normalizedKey), let bitrate = bitrateLabel(in: value) {
                section.add(key: "Bit rate", value: bitrate)
            }
            return section
        }

        if normalizedKey == "text" ||
            normalizedKey.hasPrefix("text ") ||
            normalizedKey == "subtitle" ||
            normalizedKey.hasPrefix("subtitle ") {
            var section = DetailMediaSection(name: "\(key) \(value)", kind: .other)
            section.add(key: "Format", value: value)
            return section
        }

        return nil
    }

    static func canonicalAudioFieldKey(for key: String) -> String? {
        switch normalizeKey(key) {
        case "audio format", "audio codec":
            return "Format"
        case "audio bitrate", "audio bit rate":
            return "Bit rate"
        case "audio language":
            return "Language"
        case "audio channels", "channel count":
            return "Channel(s)"
        case "title name":
            return "Title"
        default:
            return nil
        }
    }

    static func inferredAudioFieldKey(key: String, value: String, currentKind: DetailMediaSection.Kind) -> String? {
        guard currentKind != .other else { return nil }
        let normalizedKey = normalizeKey(key)
        let audioKeyHint = normalizedKey.contains("audio")
        guard currentKind == .audio || audioKeyHint else { return nil }
        let genericCodecKey = ["format", "codec", "codec info", "commercial name", "kind"].contains(normalizedKey)

        if genericCodecKey || audioKeyHint || normalizedKey.contains("codec") || normalizedKey.contains("format") {
            if codecLabel(fromDescriptor: value) != nil {
                return normalizedKey == "commercial name" ? "Commercial name" : "Format"
            }
        }
        if (normalizedKey.contains("channel") || normalizedKey.contains("layout")),
           channelLayoutToken(value) != nil {
            return "Channel(s)"
        }
        if isTrackBitrateKey(normalizedKey),
           bitrateLabel(in: value) != nil {
            return "Bit rate"
        }
        if normalizedKey.contains("sample"),
           sampleRateLabel(in: value) != nil {
            return "Sampling rate"
        }
        if normalizedKey.contains("language"),
           normalizedLanguageLabel(value) != nil {
            return "Language"
        }
        if (normalizedKey == "title" || normalizedKey == "name"),
           currentKind == .audio,
           codecLabel(fromDescriptor: value) != nil {
            return "Title"
        }
        return nil
    }

    static func canonicalVideoFieldKey(for key: String) -> String? {
        switch normalizeKey(key) {
        case "video format":
            return "Format"
        case "video format info":
            return "Codec info"
        case "video bitrate", "video bit rate":
            return "Bit rate"
        default:
            return nil
        }
    }

    static func inferredVideoFieldKey(key: String, value: String, currentKind: DetailMediaSection.Kind) -> String? {
        guard currentKind != .other else { return nil }
        let normalizedKey = normalizeKey(key)
        let videoKeyHint = normalizedKey.contains("video")
        guard currentKind == .video || videoKeyHint else { return nil }
        let genericCodecKey = ["format", "codec", "codec info"].contains(normalizedKey)

        if (genericCodecKey || videoKeyHint),
           videoCodecToken(from: value) != nil {
            return genericCodecKey ? "Format" : "Codec info"
        }
        if isTrackBitrateKey(normalizedKey),
           bitrateLabel(in: value) != nil {
            return "Bit rate"
        }
        return nil
    }

    static func audioSection(fromKey key: String, value: String) -> DetailMediaSection? {
        guard canonicalAudioFieldKey(for: key) == nil else { return nil }
        let normalizedKey = normalizeKey(key)
        guard normalizedKey == "audio" ||
            normalizedKey.hasPrefix("audio ") ||
            normalizedKey.range(of: #"^audio[0-9]+$"#, options: .regularExpression) != nil else { return nil }

        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedValue.isEmpty else { return nil }

        var section = DetailMediaSection(name: "\(key) \(normalizedValue)", kind: .audio)
        if normalizedValue.range(of: #"(?i)(^|[^a-z])eng(?:lish)?([^a-z]|$)"#, options: .regularExpression) != nil {
            section.add(key: "Language", value: "English")
        }
        if let format = codecLabel(fromDescriptor: normalizedValue) {
            section.add(key: "Format", value: format)
        }
        if let channel = channelLayoutToken(fromDescriptor: normalizedValue) {
            section.add(key: "Channel(s)", value: channel)
        }
        if !isNonTrackBitrateKey(normalizedKey), let bitrate = bitrateLabel(in: normalizedValue) {
            section.add(key: "Bit rate", value: bitrate)
        }
        if let sampleRate = sampleRateLabel(in: normalizedValue) {
            section.add(key: "Sampling rate", value: sampleRate)
        }
        if let language = languageLabel(fromDescriptor: normalizedValue) {
            section.add(key: "Language", value: language)
        }
        return section
    }

    static func isInlineAudioTrack(_ value: String) -> Bool {
        bitrateLabel(in: value) != nil ||
            (codecLabel(fromDescriptor: value) != nil && channelLayoutToken(fromDescriptor: value) != nil)
    }

    static func isTrackBitrateKey(_ normalizedKey: String) -> Bool {
        (normalizedKey == "bitrate" ||
            normalizedKey == "bit rate" ||
            normalizedKey == "nominal bitrate" ||
            normalizedKey == "nominal bit rate" ||
            normalizedKey == "rate") &&
            !isNonTrackBitrateKey(normalizedKey)
    }

    static func isNonTrackBitrateKey(_ normalizedKey: String) -> Bool {
        normalizedKey.contains("overall") ||
            normalizedKey.contains("total") ||
            normalizedKey.contains("maximum") ||
            normalizedKey.contains("max")
    }

    static func expandedAudioSections(from sections: [DetailMediaSection]) -> [DetailMediaSection] {
        sections.flatMap { section -> [DetailMediaSection] in
            guard section.kind == .audio else { return [section] }
            return splitCompoundAudioSection(section)
        }
    }

    static func splitCompoundAudioSection(_ section: DetailMediaSection) -> [DetailMediaSection] {
        let bitrateParts = splitParallelValues(firstValue(for: ["Bit rate", "Bitrate", "BitRate"], in: section))
        let channelParts = splitParallelValues(firstValue(for: ["Channel(s)", "Channels", "Channel Count"], in: section))
        let compressionParts = splitParallelValues(firstValue(for: ["Compression mode"], in: section))
        let nameSegments = splitCompoundAudioName(section.name)

        let count = [bitrateParts.count, channelParts.count, compressionParts.count, nameSegments.count].max() ?? 0
        guard count > 1 else { return [section] }

        return (0..<count).map { index in
            let name = nameSegments[safe: index] ?? section.name
            var split = DetailMediaSection(name: name, kind: .audio)

            for (key, values) in section.fields {
                switch key {
                case normalizeKey("Bit rate"), normalizeKey("Bitrate"), normalizeKey("BitRate"):
                    if let value = bitrateParts[safe: index] ?? nameSegments[safe: index].flatMap(bitrateLabel) ?? (nameSegments.isEmpty ? values.first : nil) {
                        split.add(key: key, value: value)
                    }
                case normalizeKey("Channel(s)"), normalizeKey("Channels"), normalizeKey("Channel Count"):
                    if let value = channelParts[safe: index] ?? nameSegments[safe: index].flatMap(channelLayoutToken(fromDescriptor:)) ?? (nameSegments.isEmpty ? values.first : nil) {
                        split.add(key: key, value: value)
                    }
                case normalizeKey("Compression mode"):
                    if let value = compressionParts[safe: index] ?? (compressionParts.isEmpty ? values.first : nil) {
                        split.add(key: key, value: value)
                    }
                case normalizeKey("Format"), normalizeKey("Codec"), normalizeKey("Codec info"), normalizeKey("Audio Codec"):
                    let format = nameSegments[safe: index].flatMap(codecLabel(fromDescriptor:)) ?? values.first
                    if let compression = compressionParts[safe: index], compression.localizedCaseInsensitiveContains("lossy"),
                       format?.range(of: #"(?i)DTS[- ]?HD"#, options: .regularExpression) != nil {
                        split.add(key: key, value: "DTS")
                    } else if let format {
                        split.add(key: key, value: format)
                    }
                default:
                    values.forEach { split.add(key: key, value: $0) }
                }
            }

            if firstValue(for: ["Format", "Codec", "Codec info", "Audio Codec"], in: split) == nil,
               let format = codecLabel(fromDescriptor: name) {
                split.add(key: "Format", value: format)
            }
            if firstValue(for: ["Channel(s)", "Channels", "Channel Count"], in: split) == nil,
               let channel = channelLayoutToken(fromDescriptor: name) {
                split.add(key: "Channel(s)", value: channel)
            }
            if firstValue(for: ["Bit rate", "Bitrate", "BitRate"], in: split) == nil,
               let bitrate = bitrateLabel(in: name) {
                split.add(key: "Bit rate", value: bitrate)
            }
            if sampleRateLabel(in: split) == nil,
               let sampleRate = sampleRateLabel(in: name) {
                split.add(key: "Sampling rate", value: sampleRate)
            }
            return split
        }
    }

    static func splitParallelValues(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        let normalized = raw.replacingOccurrences(of: #"\s+/\s+"#, with: "\n", options: .regularExpression)
        let pieces = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return pieces.count > 1 ? pieces : []
    }

    static func splitCompoundAudioName(_ name: String) -> [String] {
        let normalized = name
            .replacingOccurrences(of: #"\s*/\s*(?=(?:English|Eng\b|Audio|Dolby|TrueHD|DTS|DD|AAC|MP3|AC-?3|E-?AC-?3|PCM)\b)"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        let pieces = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return pieces.count > 1 ? pieces : []
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

    static func firstBitrateValue(for keys: [String], in section: DetailMediaSection?) -> String? {
        guard let section else { return nil }
        for key in keys {
            let values = section.fields[normalizeKey(key)] ?? []
            for value in values {
                if let bitrate = bitrateLabel(in: value) {
                    return bitrate
                }
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
                !isNonTrackBitrateKey(normalizeKey(line.components(separatedBy: CharacterSet(charactersIn: ":=")).first ?? line)) &&
                (lower.contains("bit rate") || lower.contains("bitrate")) &&
                (lower.contains("kb/s") || lower.contains("kbps") || lower.contains("mb/s") || lower.contains("mbps"))
        }
        let audioLine = text.components(separatedBy: .newlines)
            .map(cleanedLine)
            .first { line in
                let lower = line.lowercased()
                return lower.contains("english") &&
                    !isNonTrackBitrateKey(normalizeKey(line.components(separatedBy: CharacterSet(charactersIn: ":=")).first ?? line)) &&
                    (lower.contains("kb/s") || lower.contains("kbps") || lower.contains("mb/s") || lower.contains("mbps"))
            }
        let looseAudioBitrates = looseAudioBitrateLabels(from: text)

        return FreeTextSpecs(
            resolution: resolutionValues(firstRegexCapture(#"(?i)(\d[\d ]{2,7}\s*(?:pixels?|px)?\s*[x×]\s*\d[\d ]{2,7})"#, in: compact)),
            videoBitrate: videoBitrateLine.flatMap(bitrateLabel),
            frameRate: firstRegexCapture(#"(?i)(?:frame\s*rate|framerate)\s*[:=]\s*([A-Z]*\s*\d+(?:\.\d+)?(?:\s*\([^\)]*\))?\s*FPS?)"#, in: compact) ??
                firstRegexCapture(#"(?i)\b(\d{2,3}(?:\.\d{2,3})\s*FPS)\b"#, in: compact),
            bitDepth: bitDepthValue(from: compact),
            crf: tokenValue(named: "crf", in: compact) ?? firstRegexCapture(#"(?i)\bCRF\s*[:=]?\s*(\d+(?:\.\d+)?)\b"#, in: compact),
            preset: tokenValue(named: "preset", in: compact) ?? firstRegexCapture(#"(?i)\bpreset\s*[:=]\s*([A-Za-z0-9_-]+)"#, in: compact),
            passes: tokenValue(named: "pass", in: compact).flatMap(passDisplayValue) ??
                firstRegexCapture(#"(?i)\b([12])[\s-]*pass(?:es)?\b"#, in: compact).flatMap(passDisplayValue),
            colorGamut: firstRegexCapture(#"(?i)\b(BT\.?2020|BT\.?709|DCI-?P3|Display\s*P3)\b"#, in: compact),
            dolbyVisionProfile: extractDolbyVisionProfile(from: compact),
            aspectRatio: firstRegexCapture(#"(?i)(?:display\s*ar|display\s*aspect\s*ratio|aspect\s*ratio|dar)\}?\s*[:=]\s*([0-9.]+\s*(?:\|\s*)?[0-9.]*:?[0-9.]*)"#, in: compact),
            bestEnglishAudioBitrate: audioLine.flatMap(bitrateLabel),
            bestEnglishAudioSampleRate: firstRegexCapture(#"(?i)(?:sampling\s*rate|sample\s*rate|samplerate)\s*[:=]\s*(\d+(?:\.\d+)?\s*kHz)"#, in: compact),
            allAudioBitrates: looseAudioBitrates,
            overallBitrate: firstRegexCapture(#"(?i)(?:overall|total)\s*(?:bit\s*rate|bitrate)\s*[:=]\s*([^:;\n\r]{0,50}?(?:[kmgt]i?b/s|[kmgt]bps|b/s))"#, in: compact).flatMap(bitrateLabel),
            runtime: firstRegexCapture(#"(?i)(?:duration|runtime|run\s*time)\s*[:=]\s*([0-9]{1,2}\s*h(?:ours?)?\s*[0-9]{1,2}\s*m(?:in(?:utes?)?)?(?:\s*[0-9]{1,2}\s*s(?:ec(?:onds?)?)?)?)"#, in: compact) ??
                firstRegexCapture(#"(?i)(?:duration|runtime|run\s*time)\s*[:=]\s*([0-9]{1,2}:[0-9]{2}(?::[0-9]{2}(?:\.\d+)?)?)"#, in: compact)
        )
    }

    static func releaseNameCandidate(from text: String) -> String? {
        for rawLine in text.components(separatedBy: .newlines) {
            var line = cleanedLine(rawLine)
            guard !line.isEmpty,
                  !line.lowercased().hasPrefix("source"),
                  !line.lowercased().hasPrefix("note"),
                  !line.lowercased().hasPrefix("https://"),
                  !line.lowercased().hasPrefix("http://") else { continue }
            if let separatorRange = line.range(of: #"\s*[:=]\s*"#, options: .regularExpression) {
                let key = String(line[..<separatorRange.lowerBound])
                let value = String(line[separatorRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if ["name", "title", "file name", "filename", "complete name"].contains(normalizeKey(key)),
                   !value.isEmpty {
                    line = value
                } else {
                    continue
                }
            }
            let upper = line.uppercased()
            let hasReleaseSignal = upper.contains("1080P") ||
                upper.contains("2160P") ||
                upper.contains("720P") ||
                upper.contains("BLURAY") ||
                upper.range(of: #"(^|[^A-Z0-9])WEB[\s._-]?DL([^A-Z0-9]|$)"#, options: .regularExpression) != nil ||
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

    static func sanitizedResolution(
        width: String?,
        height: String?,
        aspectRatio: String?,
        title: String?
    ) -> (width: String?, height: String?, calculatedWidth: Bool, calculatedHeight: Bool) {
        let widthNumber = integer(from: width)
        let heightNumber = integer(from: height)

        if let widthNumber,
           let heightNumber,
           isPlausibleResolution(width: widthNumber, height: heightNumber) {
            return (width, height, false, false)
        }

        let hasMalformedPair = widthNumber != nil && heightNumber != nil
        if let repaired = repairedResolution(width: widthNumber, height: heightNumber, aspectRatio: aspectRatio, title: title) {
            return ("\(repaired.width) px", "\(repaired.height) px", repaired.calculatedWidth, repaired.calculatedHeight)
        }

        if hasMalformedPair, let titleResolution = resolutionFromTitle(title) {
            return ("\(titleResolution.width) px", "\(titleResolution.height) px", true, true)
        }

        if let widthNumber, isPlausibleSingleDimension(widthNumber) {
            return ("\(widthNumber) px", nil, false, false)
        }
        if let heightNumber, isPlausibleSingleDimension(heightNumber) {
            return (nil, "\(heightNumber) px", false, false)
        }
        return (nil, nil, false, false)
    }

    static func repairedResolution(
        width: Int?,
        height: Int?,
        aspectRatio: String?,
        title: String?
    ) -> (width: Int, height: Int, calculatedWidth: Bool, calculatedHeight: Bool)? {
        if let width,
           isPlausibleSingleDimension(width),
           let ratio = preferredAspectRatio(aspectRatio: aspectRatio) {
            let calculatedHeight = Int(round(Double(width) / ratio))
            if isPlausibleResolution(width: width, height: calculatedHeight) {
                return (width, calculatedHeight, false, true)
            }
        }

        if let height,
           isPlausibleSingleDimension(height),
           let ratio = preferredAspectRatio(aspectRatio: aspectRatio) {
            let calculatedWidth = Int(round(Double(height) * ratio))
            if isPlausibleResolution(width: calculatedWidth, height: height) {
                return (calculatedWidth, height, true, false)
            }
        }

        return nil
    }

    static func preferredAspectRatio(aspectRatio: String?) -> Double? {
        if let components = aspectRatioComponents(from: aspectRatio) {
            let ratio = components.width / components.height
            if isNearStandardAspectRatio(ratio) {
                return ratio
            }
        }
        return nil
    }

    static func resolutionFromTitle(_ title: String?) -> (width: Int, height: Int)? {
        let upper = title?.uppercased() ?? ""
        if upper.range(of: #"(^|[^A-Z0-9])(?:2160P|(?<!DS)4K|UHD)([^A-Z0-9]|$)"#, options: .regularExpression) != nil {
            return (3_840, 2_160)
        }
        if upper.range(of: #"(^|[^A-Z0-9])1080P([^A-Z0-9]|$)"#, options: .regularExpression) != nil {
            return (1_920, 1_080)
        }
        if upper.range(of: #"(^|[^A-Z0-9])720P([^A-Z0-9]|$)"#, options: .regularExpression) != nil {
            return (1_280, 720)
        }
        if upper.range(of: #"(^|[^A-Z0-9])(?:576P|540P|480P)([^A-Z0-9]|$)"#, options: .regularExpression) != nil {
            return (720, 480)
        }
        return nil
    }

    static func isPlausibleResolution(width: Int, height: Int) -> Bool {
        guard isPlausibleSingleDimension(width),
              isPlausibleSingleDimension(height) else { return false }
        let ratio = Double(max(width, height)) / Double(min(width, height))
        return ratio <= 3.0 && isNearStandardAspectRatio(Double(width) / Double(height))
    }

    static func isPlausibleSingleDimension(_ value: Int) -> Bool {
        (240...8_192).contains(value)
    }

    static func isNearStandardAspectRatio(_ ratio: Double) -> Bool {
        let normalized = ratio >= 1 ? ratio : 1 / ratio
        let standards = [4.0 / 3.0, 16.0 / 9.0, 1.85, 2.0, 2.20, 2.35, 2.39, 2.40, 2.76]
        return standards.contains { abs(normalized - $0) <= max(0.08, $0 * 0.06) }
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
        guard lower.contains("dolby vision") ||
            lower.contains("dovi") ||
            lower.contains("dvhe") ||
            lower.contains("dvh1") ||
            text.range(of: #"(?i)\bDV[\._-]?P[0-9]+\b"#, options: .regularExpression) != nil else {
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

    static func bestEnglishTrack(from audioTracks: [DetailMediaSection]) -> DetailMediaSection? {
        let englishTracks = audioTracks.filter(isEnglishAudioTrack)
        return englishTracks.max { audioTrackScore($0) < audioTrackScore($1) } ??
            audioTracks.max { audioTrackScore($0) < audioTrackScore($1) }
    }

    static func audioTracksContainOnlyExplicitNonEnglish(_ tracks: [DetailMediaSection]) -> Bool {
        guard !tracks.isEmpty else { return false }
        return tracks.allSatisfy { hasExplicitAudioLanguage($0) && !isEnglishAudioTrack($0) }
    }

    static func hasExplicitAudioLanguage(_ track: DetailMediaSection) -> Bool {
        firstValue(for: ["Language"], in: track)?.nilIfEmpty != nil ||
            languageLabel(fromDescriptor: track.name) != nil ||
            firstValue(for: ["Title", "Title name"], in: track).flatMap(languageLabel(fromDescriptor:)) != nil
    }

    static func isEnglishAudioTrack(_ track: DetailMediaSection) -> Bool {
        let name = track.name.lowercased()
        let language = firstValue(for: ["Language", "Audio language"], in: track)?.lowercased() ?? ""
        let title = firstValue(for: ["Title", "Title name"], in: track)?.lowercased() ?? ""
        return name.contains("english") ||
            name.range(of: #"(^|[^a-z])eng([^a-z]|$)"#, options: .regularExpression) != nil ||
            language.contains("english") ||
            language == "eng" ||
            language.hasPrefix("en") ||
            title.contains("english") ||
            title.contains(" eng ")
    }

    static func audioTrackScore(_ track: DetailMediaSection) -> Int {
        let format = audioDescriptor(for: track)
        let bitrate = bitrateKbps(firstValue(for: ["Bit rate", "Bitrate"], in: track) ?? bitrateLabel(in: track.name)) ?? 0
        let channels = channelCount(firstValue(for: ["Channel(s)", "Channels", "Channel Count", "Infos"], in: track)) ?? channelCount(fromDescriptor: format) ?? 0
        let atmos = format.contains("JOC") || format.contains("ATMOS")
        let isDDP = isDolbyDigitalPlus(format)
        let scoredChannels = channels == 0 && isDDP && atmos ? 6 : channels
        return audioTrackPriority(format: format, channels: scoredChannels, atmos: atmos) * 10_000 + scoredChannels * 10_000 + bitrate * 4
    }

    static func audioTrackPriority(format: String, channels: Int, atmos: Bool) -> Int {
        let isDDP = isDolbyDigitalPlus(format)
        let isLossless = isTrueHDDescriptor(format) ||
            format.contains("DTS-HD MA") ||
            format.contains("DTS HD MA") ||
            format.contains("DTS-HD MASTER") ||
            format.contains("PCM")
        if isDDP && atmos && channels >= 8 { return 110 }
        if isDDP && atmos && channels >= 6 { return 109 }
        if isLossless && channels >= 8 { return 100 }
        if isLossless && channels >= 6 { return 95 }
        if isDDP && channels >= 8 { return 90 }
        if isDDP && channels >= 6 { return 85 }
        if format.contains("DTS") && channels >= 6 { return 80 }
        if (format.contains("AC-3") || format.contains("AC3") || format.contains("A_AC3") || format.contains("DOLBY DIGITAL")) && channels >= 6 { return 72 }
        if format.contains("AAC") && channels >= 8 { return 70 }
        if format.contains("AAC") && channels >= 6 { return 68 }
        if channels == 2 { return 60 }
        if channels == 1 { return 50 }
        return 10
    }

    static func audioTrackBitrateLabel(_ track: DetailMediaSection) -> String? {
        guard let bitrate = firstValue(for: ["Bit rate", "Bitrate", "BitRate"], in: track) ?? bitrateLabel(in: track.name) else { return nil }
        let language = firstValue(for: ["Language", "Audio language"], in: track).flatMap(normalizedLanguageLabel)
        let rawFormat = firstValue(for: ["Format", "Codec", "Codec info", "Audio Codec"], in: track)
        let format = rawFormat.flatMap { raw in
            raw.uppercased().hasPrefix("A_") ? codecLabel(fromDescriptor: raw) : raw
        } ?? rawFormat ?? codecLabel(fromDescriptor: track.name)
        let label = [language, format]
            .compactMap { $0?.nilIfEmpty }
            .joined(separator: " ")
        return label.isEmpty ? bitrate : "\(label): \(bitrate)"
    }

    static func totalBitrateKbps(from tracks: [DetailMediaSection]) -> Int? {
        let values = tracks.compactMap { bitrateKbps(firstValue(for: ["Bit rate", "Bitrate", "BitRate"], in: $0) ?? bitrateLabel(in: $0.name)) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    static func totalBitrateKbps(from labels: [String]) -> Int? {
        let values = labels.compactMap(bitrateKbps)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    static func bestEnglishAudioBitrate(fromLabels labels: [String]) -> String? {
        let englishLabels = labels.filter { label in
            label.range(of: #"(?i)(^|[^a-z])eng(?:lish)?([^a-z]|$)"#, options: .regularExpression) != nil
        }
        return (englishLabels.first ?? (labels.count == 1 ? labels.first : nil)).flatMap(bitrateLabel)
    }

    static func freeTextAudioBitrateLabels(_ labels: [String], excluding structuredLabels: [String]) -> [String] {
        let seenStructured = Set(structuredLabels.map(audioBitrateDedupeKey))
        var seenLoose = Set<String>()
        return labels.filter { label in
            let key = audioBitrateDedupeKey(label)
            return !seenStructured.contains(key) && seenLoose.insert(key).inserted
        }
    }

    static func audioBitrateDedupeKey(_ label: String) -> String {
        label
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func calculatedVideoBitrate(overallBitrate: String?, totalAudioBitrateKbps: Int?, totalSubtitleBitrateKbps: Int? = nil) -> String? {
        guard let totalAudioBitrateKbps,
              let overallKbps = bitrateKbps(overallBitrate),
              overallKbps > totalAudioBitrateKbps else { return nil }
        let trackOverheadKbps = totalAudioBitrateKbps + (totalSubtitleBitrateKbps ?? 0)
        guard overallKbps > trackOverheadKbps else { return nil }
        return displayBitrate(overallKbps - trackOverheadKbps)
    }

    static func calculatedAudioBitrate(overallBitrate: String?, videoBitrate: String?, totalSubtitleBitrateKbps: Int? = nil) -> String? {
        guard let overallKbps = bitrateKbps(overallBitrate),
              let videoKbps = bitrateKbps(videoBitrate),
              overallKbps > videoKbps else { return nil }
        let trackOverheadKbps = videoKbps + (totalSubtitleBitrateKbps ?? 0)
        guard overallKbps > trackOverheadKbps else { return nil }
        return displayBitrate(overallKbps - trackOverheadKbps)
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

    static func aspectRatioValue(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let decimal = firstRegexCapture(#"\(([0-9]+(?:\.[0-9]+)?)\)"#, in: raw),
           raw.range(of: #"(?i)\d+\s*(?:pixels?|px)?\s*[x×]\s*\d+"#, options: .regularExpression) != nil {
            return "\(decimal):1"
        }
        return raw
    }

    static func frameRateLabel(in raw: String?) -> String? {
        guard let raw else { return nil }
        if let value = firstRegexCapture(#"(?i)\bat\s*([0-9]+(?:\.[0-9]+)?\s*fps?)"#, in: raw) {
            return value
        }
        return firstRegexCapture(#"(?i)\b([0-9]+(?:\.[0-9]+)?\s*fps?)"#, in: raw)
    }

    static func runtimeLabel(in raw: String?) -> String? {
        guard let raw else { return nil }
        let source = firstRegexCapture(#"(?i)\bfor\s+(.+)$"#, in: raw) ?? raw
        return firstRegexCapture(#"(?i)([0-9]{1,2}\s*h(?:ours?)?\s*[0-9]{1,2}\s*m(?:in(?:utes?)?)?(?:\s*[0-9]{1,2}\s*s(?:ec(?:onds?)?)?)?(?:\s*[0-9]{1,3}\s*ms)?)"#, in: source) ??
            firstRegexCapture(#"(?i)([0-9]{1,2}:[0-9]{2}(?::[0-9]{2}(?:\.\d+)?)?)"#, in: source)
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

    static func movieFileSizeBytesExcludingSubtitles(from text: String) -> Double? {
        let entries = fileSizeEntries(from: text)
        if let largestMainFile = entries
            .filter(\.isMainMovieCandidate)
            .max(by: { $0.bytes < $1.bytes }) {
            return largestMainFile.bytes
        }
        if let generalSize = entries
            .filter({ $0.label.lowercased().contains("file size") || $0.label.lowercased().contains("filesize") })
            .max(by: { $0.bytes < $1.bytes }) {
            return max(1, generalSize.bytes - subtitleFileSizeBytes(from: entries))
        }
        return entries.count == 1 ? entries.first?.bytes : nil
    }

    static func subtitleFileSizeBytes(from entries: [FileSizeEntry]) -> Double {
        entries
            .filter(\.isSubtitleCandidate)
            .map(\.bytes)
            .reduce(0, +)
    }

    static func totalSubtitleBitrateKbps(from sections: [DetailMediaSection]) -> Int? {
        let values = sections
            .filter(\.isSubtitleSection)
            .compactMap { firstBitrateValue(for: ["Bit rate", "Bitrate", "BitRate"], in: $0) }
            .compactMap(bitrateKbps)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
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
                guard !isNonTrackBitrateKey(normalizeKey(line.components(separatedBy: CharacterSet(charactersIn: ":=")).first ?? line)) else { return nil }
                if isAudioKeyValueLine(line) { return nil }
                if !line.contains(":") && !line.contains("="), sectionHeader(from: line)?.kind == .audio { return nil }
                guard let rawBitrate = bitrateLabel(in: line) else { return nil }
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
        if upper.contains("VC-1") || upper.contains("VC 1") { return "VC-1" }
        if upper.contains("MPEG VIDEO") || upper.contains("MPEG-2") || upper.contains("MPEG 2") { return "MPEG-2" }
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
        let format = audioDescriptor(for: track)
        let atmos = format.contains("JOC") || format.contains("ATMOS")
        let channels = channelLayoutToken(firstValue(for: ["Channel(s)", "Channels", "Channel Count", "Infos"], in: track)) ??
            channelLayoutToken(fromDescriptor: format) ??
            (isDolbyDigitalPlus(format) && atmos ? "5.1" : nil)

        let codec: String?
        if isTrueHDDescriptor(format) {
            codec = "TrueHD"
        } else if format.contains("DTS-HD HRA") || format.contains("DTS HD HRA") || format.contains("DTS-HD HIGH RESOLUTION") {
            codec = "DTS-HD HRA"
        } else if format.contains("DTS-HD") || format.contains("DTS HD") {
            codec = "DTS-HD MA"
        } else if format.contains("PCM") {
            codec = "PCM"
        } else if isDolbyDigitalPlus(format) {
            codec = "DDP"
        } else if format.contains("DTS") {
            codec = "DTS"
        } else if format.contains("AC-3") || format.contains("AC3") || format.contains("A_AC3") {
            codec = "DD"
        } else if format.contains("HE-AAC") || format.contains("HE AAC") || format.contains("HEAAC") || format.contains("AAC-HE") || format.contains("AAC HE") {
            codec = "HE-AAC"
        } else if format.range(of: #"(^|[^A-Z0-9])OPUS([^A-Z0-9]|$)"#, options: .regularExpression) != nil {
            codec = "Opus"
        } else if format.contains("AAC") {
            codec = "AAC"
        } else if format.range(of: #"(^|[^A-Z0-9])MP3([^A-Z0-9]|$)"#, options: .regularExpression) != nil ||
            format.contains("MPEG AUDIO") ||
            format.contains("MPEG-1 LAYER 3") ||
            format.contains("MPEG LAYER 3") {
            codec = "MP3"
        } else if atmos {
            codec = "DDP"
        } else {
            codec = nil
        }

        let inferredBareAtmos = atmos && codec == "DDP" && !isDolbyDigitalPlus(format)
        let includeAtmos = atmos && !inferredBareAtmos
        return [codec, channels, includeAtmos ? "Atmos" : nil]
            .compactMap { $0 }
            .joined(separator: " ")
            .nilIfEmpty
    }

    static func audioDescriptor(for track: DetailMediaSection) -> String {
        ([track.name] + ["Format", "Codec", "Codec info", "Audio Codec", "Commercial name", "Title", "Title name", "Infos"]
            .compactMap { firstValue(for: [$0], in: track) }
        )
            .joined(separator: " ")
            .uppercased()
    }

    static func isTrueHDDescriptor(_ format: String) -> Bool {
        format.contains("TRUEHD") ||
            format.contains("TRUE-HD") ||
            format.contains("TRUHD") ||
            format.contains("TRU-HD") ||
            format.contains("MLP FBA") ||
            format.contains("A_TRUEHD")
    }

    static func isDolbyDigitalPlus(_ format: String) -> Bool {
        format.contains("E-AC-3") ||
            format.contains("EAC3") ||
            format.contains("EAC-3") ||
            format.contains("DD+") ||
            format.range(of: #"(^|[^A-Z0-9])DDP([^A-Z0-9]|$)"#, options: .regularExpression) != nil ||
            format.contains("DOLBY DIGITAL PLUS")
    }

    static func channelLayoutToken(_ raw: String?) -> String? {
        guard let count = channelCount(raw) else { return nil }
        if count >= 8 { return "7.1" }
        if count >= 6 { return "5.1" }
        if count == 2 { return "2.0" }
        if count == 1 { return "1.0" }
        return nil
    }

    static func channelLayoutToken(fromDescriptor raw: String) -> String? {
        if raw.range(of: #"(?i)(^|[^0-9])(?:7\.1\s*CH|7\.1|8\s*CH)([^0-9]|$)"#, options: .regularExpression) != nil { return "7.1" }
        if raw.range(of: #"(?i)(^|[^0-9])(?:5\.1\s*CH|5\.1|6\s*CH)([^0-9]|$)"#, options: .regularExpression) != nil { return "5.1" }
        if raw.range(of: #"(?i)(^|[^0-9])(?:2\.0\s*CH|2\.0|2\s*CH)([^0-9]|$)"#, options: .regularExpression) != nil { return "2.0" }
        if raw.range(of: #"(?i)(^|[^0-9.])(?:1\.0\s*CH|1\.0|1\s*CH|MONO)([^0-9]|$)"#, options: .regularExpression) != nil { return "1.0" }
        return nil
    }

    static func channelCount(fromDescriptor raw: String) -> Int? {
        switch channelLayoutToken(fromDescriptor: raw) {
        case "7.1": return 8
        case "5.1": return 6
        case "2.0": return 2
        case "1.0": return 1
        default: return nil
        }
    }

    static func codecLabel(fromDescriptor raw: String?) -> String? {
        let upper = raw?.uppercased() ?? ""
        if isTrueHDDescriptor(upper) { return "TrueHD" }
        if upper.contains("DTS-HD HRA") || upper.contains("DTS HD HRA") || upper.contains("DTS-HD HIGH RESOLUTION") { return "DTS-HD HRA" }
        if upper.contains("DTS-HD MA") || upper.contains("DTS HD MA") || upper.contains("DTS-HD MASTER") { return "DTS-HD MA" }
        if upper.contains("DTS-HD") || upper.contains("DTS HD") { return "DTS-HD MA" }
        if upper.contains("PCM") { return "PCM" }
        if isDolbyDigitalPlus(upper) { return "E-AC-3" }
        if upper.range(of: #"(^|[^A-Z0-9])DTS([^A-Z0-9]|$)"#, options: .regularExpression) != nil { return "DTS" }
        if upper.contains("A_AC3") ||
            upper.contains("DOLBY AC3") ||
            upper.contains("DOLBY DIGITAL") ||
            upper.contains("DOLBY SURROUND") ||
            upper.range(of: #"(^|[^A-Z0-9])(?:AC-?3|DD)(?:\s*[0-9]\.[0-9])?([^A-Z0-9]|$)"#, options: .regularExpression) != nil {
            return "AC-3"
        }
        if upper.contains("HE-AAC") || upper.contains("HE AAC") || upper.contains("HEAAC") || upper.contains("AAC-HE") || upper.contains("AAC HE") { return "HE-AAC" }
        if upper.range(of: #"(^|[^A-Z0-9])OPUS([^A-Z0-9]|$)"#, options: .regularExpression) != nil { return "Opus" }
        if upper.contains("AAC") { return "AAC" }
        if upper.range(of: #"(^|[^A-Z0-9])MP3([^A-Z0-9]|$)"#, options: .regularExpression) != nil ||
            upper.contains("MPEG AUDIO") ||
            upper.contains("MPEG-1 LAYER 3") ||
            upper.contains("MPEG LAYER 3") {
            return "MP3"
        }
        return nil
    }

    static func languageLabel(fromDescriptor raw: String?) -> String? {
        let text = raw ?? ""
        let languagePatterns: [(String, String)] = [
            (#"(?i)(^|[^a-z])en([^a-z]|$)"#, "English"),
            (#"(?i)(^|[^a-z])eng(?:lish)?([^a-z]|$)"#, "English"),
            (#"(?i)(^|[^a-z])spa(?:nish)?([^a-z]|$)"#, "Spanish"),
            (#"(?i)(^|[^a-z])cze(?:ch)?([^a-z]|$)"#, "Czech"),
            (#"(?i)(^|[^a-z])fre(?:nch)?([^a-z]|$)"#, "French"),
            (#"(?i)(^|[^a-z])ger(?:man)?([^a-z]|$)"#, "German"),
            (#"(?i)(^|[^a-z])ita(?:lian)?([^a-z]|$)"#, "Italian"),
            (#"(?i)(^|[^a-z])por(?:tuguese)?([^a-z]|$)"#, "Portuguese"),
            (#"(?i)(^|[^a-z])pol(?:ish)?([^a-z]|$)"#, "Polish"),
            (#"(?i)(^|[^a-z])rus(?:sian)?([^a-z]|$)"#, "Russian"),
            (#"(?i)(^|[^a-z])jpn|japanese([^a-z]|$)"#, "Japanese")
        ]
        for (pattern, language) in languagePatterns where text.range(of: pattern, options: .regularExpression) != nil {
            return language
        }
        return nil
    }

    static func normalizedLanguageLabel(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed
            .replacingOccurrences(of: #"\[[^\]]+\]|\([^\)]+\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let codeLabels = [
            "en": "English",
            "eng": "English",
            "spa": "Spanish",
            "cze": "Czech",
            "fre": "French",
            "ger": "German",
            "ita": "Italian",
            "por": "Portuguese",
            "pol": "Polish",
            "rus": "Russian",
            "jpn": "Japanese"
        ]
        if let label = codeLabels[normalized.lowercased()] {
            return label
        }
        return trimmed
    }

    static func isAudioKeyValueLine(_ line: String) -> Bool {
        guard let separatorRange = line.range(of: #"\s*[:=]\s*"#, options: .regularExpression) else { return false }
        let key = String(line[..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKey = normalizeKey(key)
        return normalizedKey == "audio" ||
            normalizedKey.hasPrefix("audio ") ||
            normalizedKey.range(of: #"^audio[0-9]+$"#, options: .regularExpression) != nil
    }

    static func sampleRateLabel(in track: DetailMediaSection?) -> String? {
        guard let track else { return nil }
        return firstValue(for: ["Sampling rate", "Sample rate", "Samplerate"], in: track) ??
            firstValue(for: ["Infos"], in: track).flatMap(sampleRateLabel) ??
            sampleRateLabel(in: track.name) ??
            firstValue(for: ["Title"], in: track).flatMap(sampleRateLabel)
    }

    static func sampleRateLabel(in raw: String?) -> String? {
        guard let raw else { return nil }
        if let value = firstRegexCapture(#"(?i)([0-9]+(?:\.[0-9]+)?\s*kHz)"#, in: raw) {
            return value
        }
        if let value = firstRegexCapture(#"(?i)([0-9]{4,6})\s*Hz"#, in: raw) {
            return "\(value) Hz"
        }
        return nil
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

    static func bitrateLabel(in raw: String?) -> String? {
        guard let raw else { return nil }
        let pattern = #"(?i)((?:VBR|CBR|ABR)?\s*(?<![0-9.])[0-9]+(?:\s[0-9]{3})*(?:\.[0-9]+)?\s*(?:[kmgt]i?b/s|[kmgt]bps|b/s))"#
        return firstRegexCapture(pattern, in: raw)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func channelCount(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        if raw.range(of: #"(?i)(^|[^0-9])7\.1([^0-9]|$)"#, options: .regularExpression) != nil { return 8 }
        if raw.range(of: #"(?i)(^|[^0-9])5\.1([^0-9]|$)"#, options: .regularExpression) != nil { return 6 }
        if raw.range(of: #"(?i)(^|[^0-9])2\.0([^0-9]|$)"#, options: .regularExpression) != nil { return 2 }
        if raw.range(of: #"(?i)\bstereo\b"#, options: .regularExpression) != nil { return 2 }
        if raw.range(of: #"(?i)\bmono\b"#, options: .regularExpression) != nil { return 1 }
        guard let captured = firstRegexCapture(#"([0-9]+)"#, in: raw) else { return nil }
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
