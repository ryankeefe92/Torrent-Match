import Foundation
import SwiftData
import TorrentMatcherCore

enum TVSubscriptionStartMode: String, CaseIterable, Codable, Sendable {
    case first
    case current
    case next
    case manual
}

enum TVSubscriptionStatus: String, CaseIterable, Codable, Sendable {
    case active
    case paused
    case checking
    case waitingForAirdate
    case error
}

enum TVAcquisitionKind: String, CaseIterable, Codable, Sendable {
    case episode
    case seasonPack
}

enum TVAcquisitionPlanStatus: String, CaseIterable, Codable, Sendable {
    case proposed
    case confirmed
    case executing
    case completed
    case cancelled
    case failed

    var reservesCoverage: Bool {
        switch self {
        case .confirmed, .executing, .completed:
            return true
        case .proposed, .cancelled, .failed:
            return false
        }
    }
}

enum TVAcquisitionJobStatus: String, CaseIterable, Codable, Sendable {
    case queued
    case searching
    case selected
    case submitting
    case downloading
    case completed
    case skipped
    case failed
    case cancelled

    var reservesCoverage: Bool {
        switch self {
        case .queued, .searching, .selected, .submitting, .downloading, .completed:
            return true
        case .skipped, .failed, .cancelled:
            return false
        }
    }
}

enum TVAcquisitionHistoryEvent: String, CaseIterable, Codable, Sendable {
    case planConfirmed
    case jobQueued
    case torrentAdded
    case torrentDuplicate
    case downloadCompleted
    case failed
    case cancelled

    var confirmsCoverage: Bool {
        switch self {
        case .torrentAdded, .torrentDuplicate, .downloadCompleted:
            return true
        case .planConfirmed, .jobQueued, .failed, .cancelled:
            return false
        }
    }
}

struct TVEpisodeCoordinate: Hashable, Codable, Sendable, Comparable {
    let season: Int
    let episode: Int

    init(season: Int, episode: Int) {
        self.season = max(0, season)
        self.episode = max(1, episode)
    }

    init(_ number: TVEpisodeNumber) {
        self.init(season: number.season, episode: number.episode)
    }

    static func < (lhs: TVEpisodeCoordinate, rhs: TVEpisodeCoordinate) -> Bool {
        if lhs.season != rhs.season {
            return lhs.season < rhs.season
        }
        return lhs.episode < rhs.episode
    }

    var displayLabel: String {
        String(format: "S%02dE%02d", season, episode)
    }

    var episodeNumber: TVEpisodeNumber {
        TVEpisodeNumber(season: season, episode: episode)
    }

    fileprivate var keyComponent: String {
        String(format: "s%04de%04d", season, episode)
    }
}

struct TVEpisodeCoverage: Hashable, Codable, Sendable {
    let start: TVEpisodeCoordinate
    let end: TVEpisodeCoordinate

    init(start: TVEpisodeCoordinate, end: TVEpisodeCoordinate) {
        if start <= end {
            self.start = start
            self.end = end
        } else {
            self.start = end
            self.end = start
        }
    }

    init(season: Int, episode: Int) {
        let coordinate = TVEpisodeCoordinate(season: season, episode: episode)
        self.init(start: coordinate, end: coordinate)
    }

    func contains(_ other: TVEpisodeCoverage) -> Bool {
        start <= other.start && end >= other.end
    }

    func coverageKey(seriesID: String) -> String {
        "\(seriesID.tvCoverageIdentifier)|\(start.keyComponent)-\(end.keyComponent)"
    }
}

@Model
final class TVSubscription {
    var id: UUID = UUID()
    var seriesID: String = ""
    var seriesTitle: String = ""
    var seriesYear: Int?
    var imdbID: String?
    var runtimeMinutes: Int?
    var scheduleSource: String = ""
    var showStatusRawValue: String = TVShowStatus.unknown.rawValue
    var startModeRawValue: String = TVSubscriptionStartMode.first.rawValue
    var requestedSeason: Int?
    var requestedEpisode: Int?
    var resolvedStartSeason: Int?
    var resolvedStartEpisode: Int?
    var nextSeason: Int?
    var nextEpisode: Int?
    var statusRawValue: String = TVSubscriptionStatus.active.rawValue
    var isEnabled: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastCheckedAt: Date?
    var lastSuccessfulCheckAt: Date?
    var nextAirdate: Date?
    var checkRequestedAt: Date?
    var lastErrorMessage: String?

    init(
        id: UUID = UUID(),
        seriesID: String,
        seriesTitle: String,
        seriesYear: Int? = nil,
        imdbID: String? = nil,
        runtimeMinutes: Int? = nil,
        scheduleSource: String = "",
        showStatus: TVShowStatus = .unknown,
        startMode: TVSubscriptionStartMode,
        requestedStart: TVEpisodeCoordinate? = nil,
        resolvedStart: TVEpisodeCoordinate? = nil,
        nextEpisode: TVEpisodeCoordinate? = nil,
        status: TVSubscriptionStatus = .active,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.seriesID = seriesID
        self.seriesTitle = seriesTitle
        self.seriesYear = seriesYear
        self.imdbID = imdbID
        self.runtimeMinutes = runtimeMinutes
        self.scheduleSource = scheduleSource
        showStatusRawValue = showStatus.rawValue
        self.startModeRawValue = startMode.rawValue
        requestedSeason = requestedStart?.season
        requestedEpisode = requestedStart?.episode
        resolvedStartSeason = resolvedStart?.season
        resolvedStartEpisode = resolvedStart?.episode
        nextSeason = nextEpisode?.season
        self.nextEpisode = nextEpisode?.episode
        statusRawValue = status.rawValue
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var startMode: TVSubscriptionStartMode {
        get { TVSubscriptionStartMode(rawValue: startModeRawValue) ?? .first }
        set {
            startModeRawValue = newValue.rawValue
            updatedAt = Date()
        }
    }

    var showStatus: TVShowStatus {
        get { TVShowStatus(rawValue: showStatusRawValue) ?? .unknown }
        set {
            showStatusRawValue = newValue.rawValue
            updatedAt = Date()
        }
    }

    var status: TVSubscriptionStatus {
        get { TVSubscriptionStatus(rawValue: statusRawValue) ?? .active }
        set {
            statusRawValue = newValue.rawValue
            updatedAt = Date()
        }
    }

    var requestedStart: TVEpisodeCoordinate? {
        get {
            guard let requestedSeason, let requestedEpisode else { return nil }
            return TVEpisodeCoordinate(season: requestedSeason, episode: requestedEpisode)
        }
        set {
            requestedSeason = newValue?.season
            requestedEpisode = newValue?.episode
            updatedAt = Date()
        }
    }

    var resolvedStart: TVEpisodeCoordinate? {
        get {
            guard let resolvedStartSeason, let resolvedStartEpisode else { return nil }
            return TVEpisodeCoordinate(season: resolvedStartSeason, episode: resolvedStartEpisode)
        }
        set {
            resolvedStartSeason = newValue?.season
            resolvedStartEpisode = newValue?.episode
            updatedAt = Date()
        }
    }

    var nextEpisodeToAcquire: TVEpisodeCoordinate? {
        get {
            guard let nextSeason, let nextEpisode else { return nil }
            return TVEpisodeCoordinate(season: nextSeason, episode: nextEpisode)
        }
        set {
            nextSeason = newValue?.season
            nextEpisode = newValue?.episode
            updatedAt = Date()
        }
    }
}

@Model
final class TVAcquisitionPlan {
    var id: UUID = UUID()
    var subscriptionID: UUID = UUID()
    var seriesID: String = ""
    var statusRawValue: String = TVAcquisitionPlanStatus.proposed.rawValue
    var coverageStartSeason: Int = 0
    var coverageStartEpisode: Int = 1
    var coverageEndSeason: Int = 0
    var coverageEndEpisode: Int = 1
    var coverageKey: String = ""
    var plannedJobCount: Int = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var confirmedAt: Date?
    var completedAt: Date?
    var lastErrorMessage: String?

    init(
        id: UUID = UUID(),
        subscriptionID: UUID,
        seriesID: String,
        coverage: TVEpisodeCoverage,
        plannedJobCount: Int = 0,
        status: TVAcquisitionPlanStatus = .proposed,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.subscriptionID = subscriptionID
        self.seriesID = seriesID
        statusRawValue = status.rawValue
        coverageStartSeason = coverage.start.season
        coverageStartEpisode = coverage.start.episode
        coverageEndSeason = coverage.end.season
        coverageEndEpisode = coverage.end.episode
        coverageKey = coverage.coverageKey(seriesID: seriesID)
        self.plannedJobCount = plannedJobCount
        self.createdAt = createdAt
        updatedAt = createdAt
        confirmedAt = status == .confirmed ? createdAt : nil
    }

    var status: TVAcquisitionPlanStatus {
        get { TVAcquisitionPlanStatus(rawValue: statusRawValue) ?? .proposed }
        set {
            let now = Date()
            statusRawValue = newValue.rawValue
            if newValue == .confirmed, confirmedAt == nil {
                confirmedAt = now
            }
            if newValue == .completed, completedAt == nil {
                completedAt = now
            }
            updatedAt = now
        }
    }

    var coverage: TVEpisodeCoverage {
        TVEpisodeCoverage(
            start: TVEpisodeCoordinate(season: coverageStartSeason, episode: coverageStartEpisode),
            end: TVEpisodeCoordinate(season: coverageEndSeason, episode: coverageEndEpisode)
        )
    }

    func covers(seriesID: String, coverage requestedCoverage: TVEpisodeCoverage) -> Bool {
        self.seriesID.tvCoverageIdentifier == seriesID.tvCoverageIdentifier &&
            coverage.contains(requestedCoverage)
    }

    func confirm(at date: Date = Date()) {
        statusRawValue = TVAcquisitionPlanStatus.confirmed.rawValue
        confirmedAt = date
        updatedAt = date
    }
}

@Model
final class TVAcquisitionJob {
    var id: UUID = UUID()
    var planID: UUID = UUID()
    var subscriptionID: UUID = UUID()
    var seriesID: String = ""
    var kindRawValue: String = TVAcquisitionKind.episode.rawValue
    var statusRawValue: String = TVAcquisitionJobStatus.queued.rawValue
    var coverageStartSeason: Int = 0
    var coverageStartEpisode: Int = 1
    var coverageEndSeason: Int = 0
    var coverageEndEpisode: Int = 1
    var coverageKey: String = ""
    var searchQuery: String = ""
    var selectedTorrentTitle: String?
    var selectedProvider: String?
    var selectedScore: Int?
    var magnetURI: String?
    var magnetInfoHash: String?
    var transmissionTorrentID: Int?
    var transmissionTorrentName: String?
    var transmissionInfoHash: String?
    var attemptCount: Int = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var nextAttemptAt: Date?
    var submittedAt: Date?
    var completedAt: Date?
    var lastErrorMessage: String?

    init(
        id: UUID = UUID(),
        planID: UUID,
        subscriptionID: UUID,
        seriesID: String,
        kind: TVAcquisitionKind,
        coverage: TVEpisodeCoverage,
        searchQuery: String,
        status: TVAcquisitionJobStatus = .queued,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.planID = planID
        self.subscriptionID = subscriptionID
        self.seriesID = seriesID
        kindRawValue = kind.rawValue
        statusRawValue = status.rawValue
        coverageStartSeason = coverage.start.season
        coverageStartEpisode = coverage.start.episode
        coverageEndSeason = coverage.end.season
        coverageEndEpisode = coverage.end.episode
        coverageKey = coverage.coverageKey(seriesID: seriesID)
        self.searchQuery = searchQuery
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    var kind: TVAcquisitionKind {
        get { TVAcquisitionKind(rawValue: kindRawValue) ?? .episode }
        set {
            kindRawValue = newValue.rawValue
            updatedAt = Date()
        }
    }

    var status: TVAcquisitionJobStatus {
        get { TVAcquisitionJobStatus(rawValue: statusRawValue) ?? .queued }
        set {
            let now = Date()
            statusRawValue = newValue.rawValue
            if newValue == .submitting, submittedAt == nil {
                submittedAt = now
            }
            if newValue == .completed, completedAt == nil {
                completedAt = now
            }
            updatedAt = now
        }
    }

    var coverage: TVEpisodeCoverage {
        TVEpisodeCoverage(
            start: TVEpisodeCoordinate(season: coverageStartSeason, episode: coverageStartEpisode),
            end: TVEpisodeCoordinate(season: coverageEndSeason, episode: coverageEndEpisode)
        )
    }

    func covers(seriesID: String, coverage requestedCoverage: TVEpisodeCoverage) -> Bool {
        self.seriesID.tvCoverageIdentifier == seriesID.tvCoverageIdentifier &&
            coverage.contains(requestedCoverage)
    }
}

@Model
final class TVAcquisitionHistoryEntry {
    var id: UUID = UUID()
    var subscriptionID: UUID = UUID()
    var planID: UUID?
    var jobID: UUID?
    var seriesID: String = ""
    var eventRawValue: String = TVAcquisitionHistoryEvent.jobQueued.rawValue
    var coverageStartSeason: Int = 0
    var coverageStartEpisode: Int = 1
    var coverageEndSeason: Int = 0
    var coverageEndEpisode: Int = 1
    var coverageKey: String = ""
    var occurredAt: Date = Date()
    var torrentID: Int?
    var torrentName: String?
    var torrentInfoHash: String?
    var message: String?

    init(
        id: UUID = UUID(),
        subscriptionID: UUID,
        planID: UUID? = nil,
        jobID: UUID? = nil,
        seriesID: String,
        event: TVAcquisitionHistoryEvent,
        coverage: TVEpisodeCoverage,
        occurredAt: Date = Date(),
        torrentID: Int? = nil,
        torrentName: String? = nil,
        torrentInfoHash: String? = nil,
        message: String? = nil
    ) {
        self.id = id
        self.subscriptionID = subscriptionID
        self.planID = planID
        self.jobID = jobID
        self.seriesID = seriesID
        eventRawValue = event.rawValue
        coverageStartSeason = coverage.start.season
        coverageStartEpisode = coverage.start.episode
        coverageEndSeason = coverage.end.season
        coverageEndEpisode = coverage.end.episode
        coverageKey = coverage.coverageKey(seriesID: seriesID)
        self.occurredAt = occurredAt
        self.torrentID = torrentID
        self.torrentName = torrentName
        self.torrentInfoHash = torrentInfoHash
        self.message = message
    }

    var event: TVAcquisitionHistoryEvent {
        get { TVAcquisitionHistoryEvent(rawValue: eventRawValue) ?? .jobQueued }
        set { eventRawValue = newValue.rawValue }
    }

    var coverage: TVEpisodeCoverage {
        TVEpisodeCoverage(
            start: TVEpisodeCoordinate(season: coverageStartSeason, episode: coverageStartEpisode),
            end: TVEpisodeCoordinate(season: coverageEndSeason, episode: coverageEndEpisode)
        )
    }

    func covers(seriesID: String, coverage requestedCoverage: TVEpisodeCoverage) -> Bool {
        self.seriesID.tvCoverageIdentifier == seriesID.tvCoverageIdentifier &&
            coverage.contains(requestedCoverage)
    }
}

enum TVAcquisitionIdempotency {
    static func isCovered(
        seriesID: String,
        coverage: TVEpisodeCoverage,
        jobs: [TVAcquisitionJob],
        history: [TVAcquisitionHistoryEntry],
        plans: [TVAcquisitionPlan] = []
    ) -> Bool {
        if plans.contains(where: {
            $0.status.reservesCoverage && $0.covers(seriesID: seriesID, coverage: coverage)
        }) {
            return true
        }

        let reservedJobCoverage = jobs.compactMap { job -> TVEpisodeCoverage? in
            guard job.status.reservesCoverage,
                  job.seriesID.tvCoverageIdentifier == seriesID.tvCoverageIdentifier else {
                return nil
            }
            return job.coverage
        }
        let confirmedHistoryCoverage = history.compactMap { entry -> TVEpisodeCoverage? in
            guard entry.event.confirmsCoverage,
                  entry.seriesID.tvCoverageIdentifier == seriesID.tvCoverageIdentifier else {
                return nil
            }
            return entry.coverage
        }
        let existingCoverage = reservedJobCoverage + confirmedHistoryCoverage
        if existingCoverage.contains(where: { $0.contains(coverage) }) {
            return true
        }

        guard coverage.start.season == coverage.end.season else {
            return false
        }
        return (coverage.start.episode...coverage.end.episode).allSatisfy { episode in
            let coordinateCoverage = TVEpisodeCoverage(
                season: coverage.start.season,
                episode: episode
            )
            return existingCoverage.contains(where: { $0.contains(coordinateCoverage) })
        }
    }

    static func uncovered(
        _ requestedCoverage: [TVEpisodeCoverage],
        seriesID: String,
        jobs: [TVAcquisitionJob],
        history: [TVAcquisitionHistoryEntry],
        plans: [TVAcquisitionPlan] = []
    ) -> [TVEpisodeCoverage] {
        requestedCoverage.filter {
            !isCovered(
                seriesID: seriesID,
                coverage: $0,
                jobs: jobs,
                history: history,
                plans: plans
            )
        }
    }
}

private extension String {
    var tvCoverageIdentifier: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "|", with: "%7c")
    }
}
