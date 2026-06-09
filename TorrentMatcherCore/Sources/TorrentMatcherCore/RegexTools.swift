import Foundation

public enum RegexTools {
    public static func captureMatches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1, let captureRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captureRange])
        }
    }

    public static func firstCapture(pattern: String, in text: String) -> String? {
        captureMatches(pattern: pattern, in: text).first
    }
}

public extension String {
    var htmlDecoded: String {
        var value = self
        let entities: [String: String] = [
            "&amp;": "&", "&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "
        ]
        for (entity, replacement) in entities {
            value = value.replacingOccurrences(of: entity, with: replacement)
        }
        return value
    }

    var cleanedText: String {
        self
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var readableMetadataText: String {
        self
            .replacingOccurrences(of: #"<\s*br\s*/?\s*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</\s*(?:div|p|li|tr|pre|section|article)\s*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t\f\r]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s+"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var cleanedDetailPageTitle: String {
        let cleaned = self.cleanedText
            .replacingOccurrences(of: #"(?i)^\s*download\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+[-|]\s+(?:TorrentGalaxy|1337x|The Pirate Bay|TPB).*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+torrent\s+download\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+torrent\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+download\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = cleaned.lowercased()
        if normalized.contains("latest top torrents") ||
            normalized.contains("search for category") ||
            normalized.contains("free fast download") ||
            normalized == "torrentgalaxy" ||
            normalized == "1337x" ||
            normalized == "the pirate bay" {
            return ""
        }
        return cleaned
    }

    var normalizedDedupeKey: String {
        self.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: ".", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    var infoHashFromMagnet: String? {
        guard let range = self.range(of: #"btih:([A-Fa-f0-9]{40}|[A-Za-z2-7]{32})"#, options: .regularExpression) else { return nil }
        return String(self[range]).replacingOccurrences(of: "btih:", with: "")
    }
}
