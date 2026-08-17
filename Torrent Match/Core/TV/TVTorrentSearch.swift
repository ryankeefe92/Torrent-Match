import Foundation

public enum TorrentRankingProfile: String, Codable, Hashable, Sendable {
    case movie
    case television
}

public struct TVSeriesIdentity: Hashable, Codable, Sendable {
    public let title: String
    public let year: Int?
    public let imdbID: String?
    public let aliases: [String]

    public init(
        title: String,
        year: Int? = nil,
        imdbID: String? = nil,
        aliases: [String] = []
    ) {
        self.title = title
        self.year = year
        self.imdbID = imdbID
        self.aliases = aliases
    }

    public var imdbNumericID: String? {
        guard let imdbID = imdbID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !imdbID.isEmpty else { return nil }
        let numeric = imdbID.lowercased().hasPrefix("tt")
            ? String(imdbID.dropFirst(2))
            : imdbID
        guard !numeric.isEmpty, numeric.allSatisfy(\.isNumber) else { return nil }
        return numeric
    }

    fileprivate var searchTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate var matchingTitles: [String] {
        [title] + aliases
    }
}

public struct TVEpisodeIdentifier: Hashable, Codable, Sendable, Comparable {
    public let season: Int
    public let episode: Int

    public init(season: Int, episode: Int) {
        self.season = max(0, season)
        self.episode = max(0, episode)
    }

    public var releaseToken: String {
        String(format: "S%02dE%02d", season, episode)
    }

    public static func < (lhs: TVEpisodeIdentifier, rhs: TVEpisodeIdentifier) -> Bool {
        if lhs.season != rhs.season {
            return lhs.season < rhs.season
        }
        return lhs.episode < rhs.episode
    }
}

public enum TVReleaseCoverage: Hashable, Codable, Sendable {
    case episodes(Set<TVEpisodeIdentifier>)
    case seasons(Set<Int>)
    case completeSeries

    public var episodes: Set<TVEpisodeIdentifier> {
        guard case .episodes(let episodes) = self else { return [] }
        return episodes
    }

    public var seasons: Set<Int> {
        guard case .seasons(let seasons) = self else { return [] }
        return seasons
    }

    public var isSeasonPack: Bool {
        switch self {
        case .seasons, .completeSeries:
            return true
        case .episodes:
            return false
        }
    }

    public var isAggregate: Bool {
        switch self {
        case .episodes(let episodes):
            return episodes.count > 1
        case .seasons, .completeSeries:
            return true
        }
    }

    public func contains(_ episode: TVEpisodeIdentifier) -> Bool {
        switch self {
        case .episodes(let episodes):
            return episodes.contains(episode)
        case .seasons(let seasons):
            return seasons.contains(episode.season)
        case .completeSeries:
            return true
        }
    }
}

public struct ParsedTVRelease: Hashable, Codable, Sendable {
    public let seriesTitle: String
    public let coverage: TVReleaseCoverage

    public init(seriesTitle: String, coverage: TVReleaseCoverage) {
        self.seriesTitle = seriesTitle
        self.coverage = coverage
    }
}

public enum TorrentSearchTarget: Hashable, Codable, Sendable {
    case movie(query: String)
    case tvEpisode(series: TVSeriesIdentity, episode: TVEpisodeIdentifier)
    case tvSeasonPack(series: TVSeriesIdentity, season: Int)

    public var rankingProfile: TorrentRankingProfile {
        switch self {
        case .movie:
            return .movie
        case .tvEpisode, .tvSeasonPack:
            return .television
        }
    }

    public var providerQuery: String {
        switch self {
        case .movie(let query):
            return query
        case .tvEpisode(let series, let episode):
            return "\(series.searchTitle) \(episode.releaseToken)"
        case .tvSeasonPack(let series, let season):
            return "\(series.searchTitle) \(String(format: "S%02d", max(0, season)))"
        }
    }

    public var tvSeries: TVSeriesIdentity? {
        switch self {
        case .movie:
            return nil
        case .tvEpisode(let series, _), .tvSeasonPack(let series, _):
            return series
        }
    }
}

public struct TorrentSearchRequest: Hashable, Codable, Sendable {
    public let target: TorrentSearchTarget

    public init(target: TorrentSearchTarget) {
        self.target = target
    }

    public static func movie(_ query: String) -> TorrentSearchRequest {
        TorrentSearchRequest(target: .movie(query: query))
    }

    public static func tvEpisode(
        seriesTitle: String,
        year: Int? = nil,
        imdbID: String? = nil,
        aliases: [String] = [],
        season: Int,
        episode: Int
    ) -> TorrentSearchRequest {
        TorrentSearchRequest(
            target: .tvEpisode(
                series: TVSeriesIdentity(
                    title: seriesTitle,
                    year: year,
                    imdbID: imdbID,
                    aliases: aliases
                ),
                episode: TVEpisodeIdentifier(season: season, episode: episode)
            )
        )
    }

    public static func tvSeasonPack(
        seriesTitle: String,
        year: Int? = nil,
        imdbID: String? = nil,
        aliases: [String] = [],
        season: Int
    ) -> TorrentSearchRequest {
        TorrentSearchRequest(
            target: .tvSeasonPack(
                series: TVSeriesIdentity(
                    title: seriesTitle,
                    year: year,
                    imdbID: imdbID,
                    aliases: aliases
                ),
                season: max(0, season)
            )
        )
    }

    public var rankingProfile: TorrentRankingProfile {
        target.rankingProfile
    }

    public func providerQuery(for providerID: String) -> String? {
        providerQueries(for: providerID)?.first
    }

    public func providerQueries(for providerID: String) -> [String]? {
        if providerID == "eztv" {
            guard let imdbID = target.tvSeries?.imdbNumericID else { return nil }
            return [imdbID]
        }

        switch target {
        case .movie:
            return [target.providerQuery]
        case .tvEpisode(let series, let episode):
            let fallback = "\(series.searchTitle) \(episode.releaseToken)"
            guard let year = series.year else { return [fallback] }
            return ["\(series.searchTitle) \(year) \(episode.releaseToken)", fallback]
        case .tvSeasonPack(let series, let season):
            let seasonToken = String(format: "S%02d", max(0, season))
            let fallback = "\(series.searchTitle) \(seasonToken)"
            guard let year = series.year else { return [fallback] }
            return ["\(series.searchTitle) \(year) \(seasonToken)", fallback]
        }
    }
}

public struct TorrentProviderSearchRequest: Hashable, Codable, Sendable {
    public let query: String
    public let queryVariants: [String]
    public let target: TorrentSearchTarget

    public init(
        query: String,
        queryVariants: [String]? = nil,
        target: TorrentSearchTarget
    ) {
        self.query = query
        var seen = Set<String>()
        let variants = queryVariants ?? [query]
        self.queryVariants = variants.filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
        self.target = target
    }
}

public enum TVReleaseParser {
    public static func parse(_ title: String) -> ParsedTVRelease? {
        // Matching is case-insensitive. Keeping the original string also keeps
        // UTF-16 offsets valid when the series title contains Unicode scalars
        // whose uppercased representation has a different length.
        let source = title
        var episodes = Set<TVEpisodeIdentifier>()
        var episodeMarkerLocations: [Int] = []

        collectCompactEpisodes(
            in: source,
            pattern: #"(?<![A-Z0-9])S(\d{1,2})E(\d{1,3})(?=$|[^0-9])"#,
            into: &episodes,
            markerLocations: &episodeMarkerLocations
        )
        collectCompactEpisodes(
            in: source,
            pattern: #"(?<![A-Z0-9])(\d{1,2})X(\d{1,3})(?=$|[^0-9])"#,
            into: &episodes,
            markerLocations: &episodeMarkerLocations
        )
        collectVerboseEpisodes(
            in: source,
            into: &episodes,
            markerLocations: &episodeMarkerLocations
        )
        collectChainedEpisodes(
            in: source,
            into: &episodes,
            markerLocations: &episodeMarkerLocations
        )
        collectEpisodeRanges(
            in: source,
            into: &episodes,
            markerLocations: &episodeMarkerLocations
        )

        if !episodes.isEmpty, let marker = episodeMarkerLocations.min() {
            return ParsedTVRelease(
                seriesTitle: seriesTitle(in: title, beforeUTF16Offset: marker),
                coverage: .episodes(episodes)
            )
        }

        var seasons = Set<Int>()
        var seasonMarkerLocations: [Int] = []
        collectSeasonRanges(
            in: source,
            into: &seasons,
            markerLocations: &seasonMarkerLocations
        )
        collectStandaloneSeasons(
            in: source,
            into: &seasons,
            markerLocations: &seasonMarkerLocations
        )

        if !seasons.isEmpty, let marker = seasonMarkerLocations.min() {
            return ParsedTVRelease(
                seriesTitle: seriesTitle(in: title, beforeUTF16Offset: marker),
                coverage: .seasons(seasons)
            )
        }

        if let completeSeriesMatch = firstMatch(
            pattern: #"(?i)(?:THE[\s._-]+)?COMPLETE[\s._-]+SERIES|ALL[\s._-]+SEASONS"#,
            in: title
        ) {
            return ParsedTVRelease(
                seriesTitle: seriesTitle(in: title, beforeUTF16Offset: completeSeriesMatch.range.location),
                coverage: .completeSeries
            )
        }

        return nil
    }

    public static func matches(_ title: String, target: TorrentSearchTarget) -> Bool {
        guard let parsed = parse(title) else { return false }

        switch target {
        case .movie:
            return false
        case .tvEpisode(let series, let episode):
            guard seriesMatches(parsed.seriesTitle, identity: series),
                  case .episodes(let episodes) = parsed.coverage else { return false }
            return episodes == [episode]
        case .tvSeasonPack(let series, let season):
            guard seriesMatches(parsed.seriesTitle, identity: series) else { return false }
            switch parsed.coverage {
            case .seasons(let seasons):
                return seasons == [season]
            case .completeSeries:
                return false
            case .episodes:
                return false
            }
        }
    }
}

private extension TVReleaseParser {
    static func collectCompactEpisodes(
        in text: String,
        pattern: String,
        into episodes: inout Set<TVEpisodeIdentifier>,
        markerLocations: inout [Int]
    ) {
        for match in matches(pattern: pattern, in: text) {
            guard let season = capturedInt(match, at: 1, in: text),
                  let episode = capturedInt(match, at: 2, in: text) else { continue }
            episodes.insert(TVEpisodeIdentifier(season: season, episode: episode))
            markerLocations.append(match.range.location)
        }
    }

    static func collectVerboseEpisodes(
        in text: String,
        into episodes: inout Set<TVEpisodeIdentifier>,
        markerLocations: inout [Int]
    ) {
        let pattern = #"(?<![A-Z0-9])SEASON[\s._-]*(\d{1,2})[\s._-]+EP(?:ISODE)?[\s._-]*(\d{1,3})(?=$|[^0-9])"#
        collectCompactEpisodes(
            in: text,
            pattern: pattern,
            into: &episodes,
            markerLocations: &markerLocations
        )
    }

    static func collectChainedEpisodes(
        in text: String,
        into episodes: inout Set<TVEpisodeIdentifier>,
        markerLocations: inout [Int]
    ) {
        let pattern = #"(?<![A-Z0-9])S(\d{1,2})E(\d{1,3})((?:E\d{1,3})+)"#
        for match in matches(pattern: pattern, in: text) {
            guard let season = capturedInt(match, at: 1, in: text),
                  let firstEpisode = capturedInt(match, at: 2, in: text),
                  let tail = capturedString(match, at: 3, in: text) else { continue }
            episodes.insert(TVEpisodeIdentifier(season: season, episode: firstEpisode))
            for tailMatch in matches(pattern: #"E(\d{1,3})"#, in: tail) {
                guard let episode = capturedInt(tailMatch, at: 1, in: tail) else { continue }
                episodes.insert(TVEpisodeIdentifier(season: season, episode: episode))
            }
            markerLocations.append(match.range.location)
        }
    }

    static func collectEpisodeRanges(
        in text: String,
        into episodes: inout Set<TVEpisodeIdentifier>,
        markerLocations: inout [Int]
    ) {
        let pattern = #"(?<![A-Z0-9])S(\d{1,2})E(\d{1,3})[\s._]*-[\s._]*(?:S(\d{1,2}))?E?(\d{1,3})(?=$|[^0-9])"#
        for match in matches(pattern: pattern, in: text) {
            guard let startSeason = capturedInt(match, at: 1, in: text),
                  let startEpisode = capturedInt(match, at: 2, in: text),
                  let endEpisode = capturedInt(match, at: 4, in: text) else { continue }
            let endSeason = capturedInt(match, at: 3, in: text) ?? startSeason
            guard startSeason == endSeason, startEpisode <= endEpisode, endEpisode - startEpisode <= 100 else {
                continue
            }
            for episode in startEpisode...endEpisode {
                episodes.insert(TVEpisodeIdentifier(season: startSeason, episode: episode))
            }
            markerLocations.append(match.range.location)
        }
    }

    static func collectSeasonRanges(
        in text: String,
        into seasons: inout Set<Int>,
        markerLocations: inout [Int]
    ) {
        let patterns = [
            #"(?<![A-Z0-9])S(\d{1,2})[\s._]*-[\s._]*S(\d{1,2})(?![\s._-]*E\d)"#,
            #"(?<![A-Z0-9])SEASONS?[\s._-]*(\d{1,2})[\s._]*(?:-|TO)[\s._]*(?:SEASONS?[\s._-]*)?(\d{1,2})(?![\s._-]*EP(?:ISODE)?[\s._-]*\d)"#
        ]
        for pattern in patterns {
            for match in matches(pattern: pattern, in: text) {
                guard let first = capturedInt(match, at: 1, in: text),
                      let last = capturedInt(match, at: 2, in: text),
                      first <= last,
                      last - first <= 100 else { continue }
                seasons.formUnion(first...last)
                markerLocations.append(match.range.location)
            }
        }
    }

    static func collectStandaloneSeasons(
        in text: String,
        into seasons: inout Set<Int>,
        markerLocations: inout [Int]
    ) {
        let patterns = [
            #"(?<![A-Z0-9])S(\d{1,2})(?![\s._-]*E\d)"#,
            #"(?<![A-Z0-9])SEASON[\s._-]*(\d{1,2})(?![\s._-]*EP(?:ISODE)?[\s._-]*\d)"#
        ]
        for pattern in patterns {
            for match in matches(pattern: pattern, in: text) {
                guard let season = capturedInt(match, at: 1, in: text) else { continue }
                seasons.insert(season)
                markerLocations.append(match.range.location)
            }
        }
    }

    static func seriesMatches(_ parsedTitle: String, identity: TVSeriesIdentity) -> Bool {
        let parsed = normalizedSeriesTitle(parsedTitle)
        guard !parsed.isEmpty else { return false }

        return identity.matchingTitles.contains { candidate in
            let normalizedCandidate = normalizedSeriesTitle(candidate)
            if parsed == normalizedCandidate {
                return true
            }
            if let year = identity.year, parsed == "\(normalizedCandidate) \(year)" {
                return true
            }

            let parsedTokens = parsed.split(separator: " ").map(String.init)
            let candidateTokens = normalizedCandidate.split(separator: " ").map(String.init)
            guard parsedTokens.starts(with: candidateTokens),
                  parsedTokens.count > candidateTokens.count else {
                return false
            }
            var allowedSuffixes: Set<String> = [
                "us", "uk", "au", "ca", "nz",
                "australia", "canada",
            ]
            if let year = identity.year {
                allowedSuffixes.insert(String(year))
            }
            return parsedTokens.dropFirst(candidateTokens.count).allSatisfy {
                allowedSuffixes.contains($0)
            }
        }
    }

    static func normalizedSeriesTitle(_ title: String) -> String {
        title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func seriesTitle(in title: String, beforeUTF16Offset offset: Int) -> String {
        let utf16 = title.utf16
        let boundedOffset = min(max(0, offset), utf16.count)
        guard let end = utf16.index(utf16.startIndex, offsetBy: boundedOffset, limitedBy: utf16.endIndex),
              let scalarEnd = String.Index(end, within: title) else {
            return title
        }
        return String(title[..<scalarEnd])
            .replacingOccurrences(of: #"[\s._-]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^[\s._-]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        return regex.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )
    }

    static func firstMatch(pattern: String, in text: String) -> NSTextCheckingResult? {
        matches(pattern: pattern, in: text).first
    }

    static func capturedString(
        _ match: NSTextCheckingResult,
        at index: Int,
        in text: String
    ) -> String? {
        guard match.numberOfRanges > index,
              match.range(at: index).location != NSNotFound,
              let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }

    static func capturedInt(
        _ match: NSTextCheckingResult,
        at index: Int,
        in text: String
    ) -> Int? {
        capturedString(match, at: index, in: text).flatMap(Int.init)
    }
}
