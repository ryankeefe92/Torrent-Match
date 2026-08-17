import Foundation

public enum TVShowStatus: String, Codable, Hashable, Sendable {
    case running
    case ended
    case toBeDetermined
    case inDevelopment
    case unknown

    public init(tvMazeValue: String?) {
        switch tvMazeValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "running":
            self = .running
        case "ended":
            self = .ended
        case "to be determined":
            self = .toBeDetermined
        case "in development":
            self = .inDevelopment
        default:
            self = .unknown
        }
    }

    public var isEnded: Bool {
        self == .ended
    }
}

public struct TVShowIdentity: Identifiable, Codable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let imdbID: String?
    public let premieredYear: Int?
    public let status: TVShowStatus
    public let runtimeMinutes: Int?

    public init(
        id: Int,
        name: String,
        imdbID: String?,
        premieredYear: Int?,
        status: TVShowStatus,
        runtimeMinutes: Int?
    ) {
        self.id = id
        self.name = name
        self.imdbID = imdbID
        self.premieredYear = premieredYear
        self.status = status
        self.runtimeMinutes = runtimeMinutes
    }
}

public struct TVEpisodeNumber: Codable, Hashable, Sendable, Comparable {
    public let season: Int
    public let episode: Int

    public init(season: Int, episode: Int) {
        self.season = season
        self.episode = episode
    }

    public static func < (lhs: TVEpisodeNumber, rhs: TVEpisodeNumber) -> Bool {
        if lhs.season != rhs.season {
            return lhs.season < rhs.season
        }
        return lhs.episode < rhs.episode
    }

    public var code: String {
        String(format: "S%02dE%02d", season, episode)
    }
}

public struct TVEpisodeSchedule: Codable, Hashable, Sendable {
    public let number: TVEpisodeNumber
    public let airstamp: Date?

    public init(number: TVEpisodeNumber, airstamp: Date?) {
        self.number = number
        self.airstamp = airstamp
    }
}

public struct TVShowSchedule: Codable, Hashable, Sendable {
    public let show: TVShowIdentity
    public let episodes: [TVEpisodeSchedule]

    public init(show: TVShowIdentity, episodes: [TVEpisodeSchedule]) {
        self.show = show
        self.episodes = episodes
    }
}

public enum TVSubscriptionStartOption: Codable, Hashable, Sendable {
    case first
    case current
    case next
    case manual(TVEpisodeNumber)
}

public enum TVSubscriptionWaitingReason: String, Codable, Hashable, Sendable {
    case noAiredEpisode
    case nextEpisodeUnannounced
}

public enum TVSubscriptionStartResolution: Codable, Hashable, Sendable {
    case episode(TVEpisodeNumber)
    case waiting(TVSubscriptionWaitingReason)
}

public struct TVSeasonPackCandidate: Codable, Hashable, Sendable {
    public let season: Int
    public let episodes: [TVEpisodeNumber]

    public init(season: Int, episodes: [TVEpisodeNumber]) {
        self.season = season
        self.episodes = episodes
    }
}

public struct TVSubscriptionBacklogPlan: Codable, Hashable, Sendable {
    public let startResolution: TVSubscriptionStartResolution
    public let individualEpisodes: [TVEpisodeNumber]
    public let fullSeasonCandidates: [TVSeasonPackCandidate]

    public init(
        startResolution: TVSubscriptionStartResolution,
        individualEpisodes: [TVEpisodeNumber],
        fullSeasonCandidates: [TVSeasonPackCandidate]
    ) {
        self.startResolution = startResolution
        self.individualEpisodes = individualEpisodes
        self.fullSeasonCandidates = fullSeasonCandidates
    }
}

public enum TVSubscriptionPlannerError: Error, LocalizedError, Sendable {
    case invalidManualEpisode(TVEpisodeNumber)

    public var errorDescription: String? {
        switch self {
        case .invalidManualEpisode(let number):
            return "Manual TV episode must use positive season and episode numbers, not \(number.code)."
        }
    }
}

public enum TVSubscriptionPlanner {
    public static func resolve(
        start: TVSubscriptionStartOption,
        episodes: [TVEpisodeSchedule],
        asOf date: Date
    ) throws -> TVSubscriptionStartResolution {
        let regularEpisodes = normalizedRegularEpisodes(episodes)

        switch start {
        case .first:
            return .episode(TVEpisodeNumber(season: 1, episode: 1))
        case .manual(let number):
            guard number.season > 0, number.episode > 0 else {
                throw TVSubscriptionPlannerError.invalidManualEpisode(number)
            }
            return .episode(number)
        case .current:
            guard let current = regularEpisodes
                .filter({ ($0.airstamp ?? .distantFuture) <= date })
                .max(by: airsBefore) else {
                return .waiting(.noAiredEpisode)
            }
            return .episode(current.number)
        case .next:
            guard let next = regularEpisodes
                .filter({ ($0.airstamp ?? .distantPast) > date })
                .min(by: airsBefore) else {
                return .waiting(.nextEpisodeUnannounced)
            }
            return .episode(next.number)
        }
    }

    public static func plan(
        schedule: TVShowSchedule,
        start: TVSubscriptionStartOption,
        asOf date: Date
    ) throws -> TVSubscriptionBacklogPlan {
        let episodes = normalizedRegularEpisodes(schedule.episodes)
        let resolution = try resolve(start: start, episodes: episodes, asOf: date)

        guard case .episode(let firstNeeded) = resolution else {
            return TVSubscriptionBacklogPlan(
                startResolution: resolution,
                individualEpisodes: [],
                fullSeasonCandidates: []
            )
        }

        let airedNeeded = episodes.filter { episode in
            guard let airstamp = episode.airstamp else { return false }
            return airstamp <= date && episode.number >= firstNeeded
        }
        let neededBySeason = Dictionary(grouping: airedNeeded, by: \.number.season)
        let allBySeason = Dictionary(grouping: episodes, by: \.number.season)

        var individualEpisodes: [TVEpisodeNumber] = []
        var fullSeasonCandidates: [TVSeasonPackCandidate] = []

        for season in neededBySeason.keys.sorted() {
            let needed = (neededBySeason[season] ?? []).map(\.number).sorted()
            let all = (allBySeason[season] ?? []).map(\.number).sorted()

            if isExactCompletedSeason(
                season: season,
                allEpisodes: all,
                scheduledEpisodes: allBySeason[season] ?? [],
                allSeasons: allBySeason.keys,
                showStatus: schedule.show.status,
                asOf: date
            ), needed == all {
                fullSeasonCandidates.append(
                    TVSeasonPackCandidate(season: season, episodes: all)
                )
            } else {
                individualEpisodes.append(contentsOf: needed)
            }
        }

        return TVSubscriptionBacklogPlan(
            startResolution: resolution,
            individualEpisodes: individualEpisodes.sorted(),
            fullSeasonCandidates: fullSeasonCandidates.sorted { $0.season < $1.season }
        )
    }

    private static func normalizedRegularEpisodes(
        _ episodes: [TVEpisodeSchedule]
    ) -> [TVEpisodeSchedule] {
        var byNumber: [TVEpisodeNumber: TVEpisodeSchedule] = [:]

        for episode in episodes
        where episode.number.season > 0 && episode.number.episode > 0 {
            guard let existing = byNumber[episode.number] else {
                byNumber[episode.number] = episode
                continue
            }

            switch (existing.airstamp, episode.airstamp) {
            case (nil, .some):
                byNumber[episode.number] = episode
            case let (.some(existingDate), .some(newDate)) where newDate < existingDate:
                byNumber[episode.number] = episode
            default:
                break
            }
        }

        return byNumber.values.sorted { $0.number < $1.number }
    }

    private static func airsBefore(
        _ lhs: TVEpisodeSchedule,
        _ rhs: TVEpisodeSchedule
    ) -> Bool {
        switch (lhs.airstamp, rhs.airstamp) {
        case let (.some(lhsDate), .some(rhsDate)):
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case (nil, nil):
            break
        }
        return lhs.number < rhs.number
    }

    private static func isExactCompletedSeason(
        season: Int,
        allEpisodes: [TVEpisodeNumber],
        scheduledEpisodes: [TVEpisodeSchedule],
        allSeasons: Dictionary<Int, [TVEpisodeSchedule]>.Keys,
        showStatus: TVShowStatus,
        asOf date: Date
    ) -> Bool {
        guard isContiguousSeason(allEpisodes),
              scheduledEpisodes.allSatisfy({
                  guard let airstamp = $0.airstamp else { return false }
                  return airstamp <= date
              }) else {
            return false
        }

        if allSeasons.contains(where: { $0 > season }) {
            return true
        }
        return showStatus.isEnded
    }

    private static func isContiguousSeason(_ episodes: [TVEpisodeNumber]) -> Bool {
        guard let last = episodes.last, last.episode == episodes.count else {
            return false
        }
        return episodes.enumerated().allSatisfy { index, number in
            number.episode == index + 1
        }
    }
}
