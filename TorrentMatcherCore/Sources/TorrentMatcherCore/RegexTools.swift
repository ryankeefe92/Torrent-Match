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
