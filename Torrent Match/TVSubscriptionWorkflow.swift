import Foundation
import SwiftData
import TorrentMatcherCore

enum TVSubscriptionWorkflowError: Error, LocalizedError {
    case duplicateSubscription
    case missingResolvedStart

    var errorDescription: String? {
        switch self {
        case .duplicateSubscription:
            return "This show is already in your subscriptions."
        case .missingResolvedStart:
            return "The selected starting point could not be resolved."
        }
    }
}

enum TVSubscriptionWorkflow {
    @MainActor
    static func createSubscription(
        show: TVShowIdentity,
        startMode: TVSubscriptionStartMode,
        requestedStart: TVEpisodeCoordinate?,
        backlog: TVSubscriptionBacklogPlan,
        existingSubscriptions: [TVSubscription],
        in context: ModelContext,
        now: Date = Date()
    ) throws -> TVSubscription {
        let seriesID = String(show.id)
        guard !existingSubscriptions.contains(where: { $0.seriesID == seriesID }) else {
            throw TVSubscriptionWorkflowError.duplicateSubscription
        }

        let resolvedStart: TVEpisodeCoordinate?
        let subscriptionStatus: TVSubscriptionStatus
        switch backlog.startResolution {
        case .episode(let episode):
            resolvedStart = episode.coordinate
            subscriptionStatus = .active
        case .waiting:
            resolvedStart = nil
            subscriptionStatus = .waitingForAirdate
        }

        let plannedCoordinates = backlog.individualEpisodes.map(\.coordinate) +
            backlog.fullSeasonCandidates.flatMap { $0.episodes.map(\.coordinate) }
        let nextCoordinate = plannedCoordinates.min() ?? resolvedStart

        let subscription = TVSubscription(
            seriesID: seriesID,
            seriesTitle: show.name,
            seriesYear: show.premieredYear,
            imdbID: show.imdbID,
            runtimeMinutes: show.runtimeMinutes,
            scheduleSource: "TVmaze",
            showStatus: show.status,
            startMode: startMode,
            requestedStart: requestedStart,
            resolvedStart: resolvedStart,
            nextEpisode: nextCoordinate,
            status: subscriptionStatus,
            createdAt: now,
            updatedAt: now
        )
        context.insert(subscription)

        let allCoverage = makeInitialCoverage(from: backlog)
        if let coverage = allCoverage.coverageEnvelope {
            let plan = TVAcquisitionPlan(
                subscriptionID: subscription.id,
                seriesID: seriesID,
                coverage: coverage,
                plannedJobCount: allCoverage.count,
                status: .confirmed,
                createdAt: now
            )
            context.insert(plan)
            context.insert(
                TVAcquisitionHistoryEntry(
                    subscriptionID: subscription.id,
                    planID: plan.id,
                    seriesID: seriesID,
                    event: .planConfirmed,
                    coverage: coverage,
                    occurredAt: now,
                    message: "Initial backlog confirmed"
                )
            )

            for season in backlog.fullSeasonCandidates {
                guard let first = season.episodes.min()?.coordinate,
                      let last = season.episodes.max()?.coordinate else {
                    continue
                }
                insertJob(
                    kind: .seasonPack,
                    coverage: TVEpisodeCoverage(start: first, end: last),
                    query: "\(show.name) \(String(format: "S%02d", season.season))",
                    subscription: subscription,
                    plan: plan,
                    context: context,
                    now: now
                )
            }

            for episode in backlog.individualEpisodes.sorted() {
                let coordinate = episode.coordinate
                insertJob(
                    kind: .episode,
                    coverage: TVEpisodeCoverage(
                        season: coordinate.season,
                        episode: coordinate.episode
                    ),
                    query: "\(show.name) \(episode.code)",
                    subscription: subscription,
                    plan: plan,
                    context: context,
                    now: now
                )
            }
        }

        try context.save()
        return subscription
    }

    @MainActor
    static func enqueueEpisodes(
        _ episodes: [TVEpisodeCoordinate],
        for subscription: TVSubscription,
        jobs: [TVAcquisitionJob],
        history: [TVAcquisitionHistoryEntry],
        plans: [TVAcquisitionPlan] = [],
        in context: ModelContext,
        now: Date = Date()
    ) throws {
        try enqueueBacklog(
            fullSeasonCandidates: [],
            individualEpisodes: episodes,
            for: subscription,
            jobs: jobs,
            history: history,
            plans: plans,
            in: context,
            now: now
        )
    }

    @MainActor
    static func enqueueBacklog(
        fullSeasonCandidates: [TVSeasonPackCandidate],
        individualEpisodes: [TVEpisodeCoordinate],
        for subscription: TVSubscription,
        jobs: [TVAcquisitionJob],
        history: [TVAcquisitionHistoryEntry],
        plans: [TVAcquisitionPlan] = [],
        in context: ModelContext,
        now: Date = Date()
    ) throws {
        var packJobs: [(season: Int, coverage: TVEpisodeCoverage)] = []
        var episodeCoordinates = Set(individualEpisodes)

        for candidate in fullSeasonCandidates {
            let coordinates = candidate.episodes.map {
                TVEpisodeCoordinate(season: $0.season, episode: $0.episode)
            }.sorted()
            guard let first = coordinates.first, let last = coordinates.last else {
                continue
            }
            let uncovered = coordinates.filter { coordinate in
                !TVAcquisitionIdempotency.isCovered(
                    seriesID: subscription.seriesID,
                    coverage: TVEpisodeCoverage(
                        season: coordinate.season,
                        episode: coordinate.episode
                    ),
                    jobs: jobs,
                    history: history,
                    plans: plans
                )
            }
            if uncovered.count == coordinates.count {
                packJobs.append(
                    (
                        season: candidate.season,
                        coverage: TVEpisodeCoverage(start: first, end: last)
                    )
                )
            } else {
                episodeCoordinates.formUnion(uncovered)
            }
        }

        let uncoveredEpisodes = TVAcquisitionIdempotency.uncovered(
            episodeCoordinates.map {
                TVEpisodeCoverage(season: $0.season, episode: $0.episode)
            },
            seriesID: subscription.seriesID,
            jobs: jobs,
            history: history,
            plans: plans
        ).sorted { $0.start < $1.start }
        let plannedCoverage = packJobs.map(\.coverage) + uncoveredEpisodes
        guard let coverage = plannedCoverage.coverageEnvelope else { return }

        let plan = TVAcquisitionPlan(
            subscriptionID: subscription.id,
            seriesID: subscription.seriesID,
            coverage: coverage,
            plannedJobCount: plannedCoverage.count,
            status: .confirmed,
            createdAt: now
        )
        context.insert(plan)
        context.insert(
            TVAcquisitionHistoryEntry(
                subscriptionID: subscription.id,
                planID: plan.id,
                seriesID: subscription.seriesID,
                event: .planConfirmed,
                coverage: coverage,
                occurredAt: now,
                message: "Newly aired episodes queued"
            )
        )

        for pack in packJobs.sorted(by: { $0.season < $1.season }) {
            insertJob(
                kind: .seasonPack,
                coverage: pack.coverage,
                query: "\(subscription.seriesTitle) \(String(format: "S%02d", pack.season))",
                subscription: subscription,
                plan: plan,
                context: context,
                now: now
            )
        }

        for coverage in uncoveredEpisodes {
            insertJob(
                kind: .episode,
                coverage: coverage,
                query: "\(subscription.seriesTitle) \(coverage.start.displayLabel)",
                subscription: subscription,
                plan: plan,
                context: context,
                now: now
            )
        }
    }

    @MainActor
    static func replaceSeasonPackWithEpisodes(
        _ job: TVAcquisitionJob,
        subscription: TVSubscription,
        episodeNumbers: [TVEpisodeCoordinate],
        in context: ModelContext,
        now: Date = Date()
    ) {
        job.status = .skipped
        job.lastErrorMessage = "No compatible season pack was available; using individual episodes."

        for episode in episodeNumbers.sorted() {
            let coverage = TVEpisodeCoverage(
                season: episode.season,
                episode: episode.episode
            )
            insertJob(
                kind: .episode,
                coverage: coverage,
                query: "\(subscription.seriesTitle) \(episode.displayLabel)",
                subscription: subscription,
                planID: job.planID,
                context: context,
                now: now
            )
        }
    }

    @MainActor
    private static func insertJob(
        kind: TVAcquisitionKind,
        coverage: TVEpisodeCoverage,
        query: String,
        subscription: TVSubscription,
        plan: TVAcquisitionPlan,
        context: ModelContext,
        now: Date
    ) {
        insertJob(
            kind: kind,
            coverage: coverage,
            query: query,
            subscription: subscription,
            planID: plan.id,
            context: context,
            now: now
        )
    }

    @MainActor
    private static func insertJob(
        kind: TVAcquisitionKind,
        coverage: TVEpisodeCoverage,
        query: String,
        subscription: TVSubscription,
        planID: UUID,
        context: ModelContext,
        now: Date
    ) {
        let job = TVAcquisitionJob(
            planID: planID,
            subscriptionID: subscription.id,
            seriesID: subscription.seriesID,
            kind: kind,
            coverage: coverage,
            searchQuery: query,
            createdAt: now
        )
        context.insert(job)
        context.insert(
            TVAcquisitionHistoryEntry(
                subscriptionID: subscription.id,
                planID: planID,
                jobID: job.id,
                seriesID: subscription.seriesID,
                event: .jobQueued,
                coverage: coverage,
                occurredAt: now,
                message: kind == .seasonPack ? "Season pack queued" : "Episode queued"
            )
        )
    }

    private static func makeInitialCoverage(
        from backlog: TVSubscriptionBacklogPlan
    ) -> [TVEpisodeCoverage] {
        let individual = backlog.individualEpisodes.map {
            TVEpisodeCoverage(season: $0.season, episode: $0.episode)
        }
        let seasons = backlog.fullSeasonCandidates.compactMap { season -> TVEpisodeCoverage? in
            guard let first = season.episodes.min()?.coordinate,
                  let last = season.episodes.max()?.coordinate else {
                return nil
            }
            return TVEpisodeCoverage(start: first, end: last)
        }
        return individual + seasons
    }

}

private extension TVEpisodeNumber {
    var coordinate: TVEpisodeCoordinate {
        TVEpisodeCoordinate(season: season, episode: episode)
    }
}

private extension Array where Element == TVEpisodeCoverage {
    var coverageEnvelope: TVEpisodeCoverage? {
        guard let first = map(\.start).min(),
              let last = map(\.end).max() else {
            return nil
        }
        return TVEpisodeCoverage(start: first, end: last)
    }
}
