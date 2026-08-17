import Foundation
import SwiftData
import Testing
@testable import Torrent_Match

@Suite(.serialized)
@MainActor
struct TVSubscriptionWorkflowTests {
    @Test
    func initialBacklogCreatesConfirmedPlanPackEpisodesAndHistory() throws {
        let (_, context) = try makeContext()
        let show = TVShowIdentity(
            id: 42,
            name: "Example Show",
            imdbID: "tt1234567",
            premieredYear: 2024,
            status: .running,
            runtimeMinutes: 52
        )
        let backlog = TVSubscriptionBacklogPlan(
            startResolution: .episode(
                TVEpisodeNumber(season: 1, episode: 3)
            ),
            individualEpisodes: [
                TVEpisodeNumber(season: 1, episode: 3),
                TVEpisodeNumber(season: 1, episode: 4),
            ],
            fullSeasonCandidates: [
                TVSeasonPackCandidate(
                    season: 2,
                    episodes: [
                        TVEpisodeNumber(season: 2, episode: 1),
                        TVEpisodeNumber(season: 2, episode: 2),
                        TVEpisodeNumber(season: 2, episode: 3),
                    ]
                ),
            ]
        )

        let subscription = try TVSubscriptionWorkflow.createSubscription(
            show: show,
            startMode: .manual,
            requestedStart: TVEpisodeCoordinate(season: 1, episode: 3),
            backlog: backlog,
            existingSubscriptions: [],
            in: context,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let plans = try context.fetch(FetchDescriptor<TVAcquisitionPlan>())
        let jobs = try context.fetch(FetchDescriptor<TVAcquisitionJob>())
        let history = try context.fetch(FetchDescriptor<TVAcquisitionHistoryEntry>())

        #expect(subscription.seriesID == "42")
        #expect(subscription.resolvedStart == TVEpisodeCoordinate(season: 1, episode: 3))
        #expect(plans.count == 1)
        #expect(plans.first?.status == .confirmed)
        #expect(plans.first?.plannedJobCount == 3)
        #expect(jobs.filter { $0.kind == .seasonPack }.count == 1)
        #expect(jobs.filter { $0.kind == .episode }.count == 2)
        #expect(
            jobs.first(where: { $0.kind == .seasonPack })?.coverage ==
                TVEpisodeCoverage(
                    start: TVEpisodeCoordinate(season: 2, episode: 1),
                    end: TVEpisodeCoordinate(season: 2, episode: 3)
                )
        )
        #expect(history.filter { $0.event == .planConfirmed }.count == 1)
        #expect(history.filter { $0.event == .jobQueued }.count == 3)
    }

    @Test
    func duplicateSeriesCannotBeSubscribedTwice() throws {
        let (_, context) = try makeContext()
        let show = TVShowIdentity(
            id: 42,
            name: "Example Show",
            imdbID: nil,
            premieredYear: 2024,
            status: .running,
            runtimeMinutes: 45
        )
        let existing = TVSubscription(
            seriesID: "42",
            seriesTitle: "Example Show",
            startMode: .first
        )
        context.insert(existing)

        #expect(throws: TVSubscriptionWorkflowError.self) {
            try TVSubscriptionWorkflow.createSubscription(
                show: show,
                startMode: .first,
                requestedStart: nil,
                backlog: TVSubscriptionBacklogPlan(
                    startResolution: .episode(
                        TVEpisodeNumber(season: 1, episode: 1)
                    ),
                    individualEpisodes: [],
                    fullSeasonCandidates: []
                ),
                existingSubscriptions: [existing],
                in: context
            )
        }
    }

    @Test
    func unavailableSeasonPackFallsBackToExactIndividualRange() throws {
        let (_, context) = try makeContext()
        let subscription = TVSubscription(
            seriesID: "42",
            seriesTitle: "Example Show",
            startMode: .first
        )
        let coverage = TVEpisodeCoverage(
            start: TVEpisodeCoordinate(season: 2, episode: 1),
            end: TVEpisodeCoordinate(season: 2, episode: 4)
        )
        let plan = TVAcquisitionPlan(
            subscriptionID: subscription.id,
            seriesID: subscription.seriesID,
            coverage: coverage,
            plannedJobCount: 1,
            status: .confirmed
        )
        let pack = TVAcquisitionJob(
            planID: plan.id,
            subscriptionID: subscription.id,
            seriesID: subscription.seriesID,
            kind: .seasonPack,
            coverage: coverage,
            searchQuery: "Example Show S02"
        )
        context.insert(subscription)
        context.insert(plan)
        context.insert(pack)

        TVSubscriptionWorkflow.replaceSeasonPackWithEpisodes(
            pack,
            subscription: subscription,
            episodeNumbers: (1...4).map {
                TVEpisodeCoordinate(season: 2, episode: $0)
            },
            in: context
        )
        try context.save()

        let jobs = try context.fetch(FetchDescriptor<TVAcquisitionJob>())
        let episodes = jobs
            .filter { $0.kind == .episode }
            .map(\.coverage.start)
            .sorted()

        #expect(pack.status == .skipped)
        #expect(episodes == (1...4).map {
            TVEpisodeCoordinate(season: 2, episode: $0)
        })
        #expect(jobs.filter { $0.kind == .seasonPack }.count == 1)
    }

    @Test
    func catchUpUsesPackOnlyWhenTheEntireSeasonIsStillNeeded() throws {
        let (_, context) = try makeContext()
        let subscription = TVSubscription(
            seriesID: "42",
            seriesTitle: "Example Show",
            startMode: .first
        )
        let alreadyDownloaded = TVAcquisitionHistoryEntry(
            subscriptionID: subscription.id,
            seriesID: subscription.seriesID,
            event: .downloadCompleted,
            coverage: TVEpisodeCoverage(season: 2, episode: 1)
        )
        context.insert(subscription)
        context.insert(alreadyDownloaded)

        try TVSubscriptionWorkflow.enqueueBacklog(
            fullSeasonCandidates: [
                TVSeasonPackCandidate(
                    season: 2,
                    episodes: (1...3).map {
                        TVEpisodeNumber(season: 2, episode: $0)
                    }
                ),
            ],
            individualEpisodes: [],
            for: subscription,
            jobs: [],
            history: [alreadyDownloaded],
            in: context
        )
        try context.save()

        let jobs = try context.fetch(FetchDescriptor<TVAcquisitionJob>())
        #expect(jobs.allSatisfy { $0.kind == .episode })
        #expect(jobs.map(\.coverage.start).sorted() == [
            TVEpisodeCoordinate(season: 2, episode: 2),
            TVEpisodeCoordinate(season: 2, episode: 3),
        ])
    }

    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let schema = Schema([
            TVSubscription.self,
            TVAcquisitionPlan.self,
            TVAcquisitionJob.self,
            TVAcquisitionHistoryEntry.self,
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        return (container, ModelContext(container))
    }
}
