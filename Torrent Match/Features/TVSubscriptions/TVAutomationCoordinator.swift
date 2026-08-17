import Combine
import Foundation
import SwiftData

@MainActor
final class TVAutomationCoordinator: ObservableObject {
    @Published private(set) var isChecking = false
    @Published private(set) var statusMessage = "Mac monitoring is ready"

    private let tvMaze: TVMazeClient
    private let searchService: TorrentSearchService
    private var monitoringTask: Task<Void, Never>?
    private let schedulerPollInterval: Duration
    private let regularCheckInterval: TimeInterval
    private let retryInterval: TimeInterval

    init(
        tvMaze: TVMazeClient = TVMazeClient(),
        searchService: TorrentSearchService = TorrentSearchService(
            configs: BuiltInProviderConfigs.television
        ),
        schedulerPollInterval: Duration = .seconds(300),
        regularCheckInterval: TimeInterval = 15 * 60,
        retryInterval: TimeInterval = 15 * 60
    ) {
        self.tvMaze = tvMaze
        self.searchService = searchService
        self.schedulerPollInterval = schedulerPollInterval
        self.regularCheckInterval = regularCheckInterval
        self.retryInterval = retryInterval
    }

    func start(
        in context: ModelContext,
        transmissionStore: TransmissionStore
    ) {
#if os(macOS)
        guard monitoringTask == nil else { return }
        monitoringTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runCycle(
                in: context,
                transmissionStore: transmissionStore,
                forceScheduleRefresh: true
            )

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: self.schedulerPollInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.runCycle(
                    in: context,
                    transmissionStore: transmissionStore,
                    forceScheduleRefresh: false
                )
            }
        }
#endif
    }

    func stop() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    func checkNow(
        in context: ModelContext,
        transmissionStore: TransmissionStore
    ) async {
#if os(macOS)
        await runCycle(
            in: context,
            transmissionStore: transmissionStore,
            forceScheduleRefresh: true
        )
#else
        let now = Date()
        let subscriptions = (try? context.fetch(FetchDescriptor<TVSubscription>())) ?? []
        subscriptions.filter(\.isEnabled).forEach {
            $0.checkRequestedAt = now
            $0.updatedAt = now
        }
        try? context.save()
#endif
    }

    private func runCycle(
        in context: ModelContext,
        transmissionStore: TransmissionStore,
        forceScheduleRefresh: Bool
    ) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            let subscriptions = try context.fetch(
                FetchDescriptor<TVSubscription>(
                    sortBy: [SortDescriptor(\.seriesTitle)]
                )
            )
            let enabled = subscriptions.filter(\.isEnabled)
            statusMessage = enabled.isEmpty
                ? "No active subscriptions"
                : "Checking \(enabled.count) \(enabled.count == 1 ? "subscription" : "subscriptions")"

            let now = Date()
            for subscription in enabled {
                guard shouldRefreshSchedule(
                    subscription,
                    now: now,
                    forced: forceScheduleRefresh
                ) else {
                    continue
                }
                await refresh(
                    subscription,
                    in: context,
                    now: now
                )
            }

            try recoverInterruptedJobs(in: context, now: now)
            await reconcileCompletedDownloads(
                in: context,
                transmissionStore: transmissionStore
            )
            await processQueuedJobs(
                in: context,
                transmissionStore: transmissionStore,
                now: Date()
            )
            try context.save()

            let queuedJobs = try context.fetch(
                FetchDescriptor<TVAcquisitionJob>()
            ).contains {
                $0.status == .queued || $0.status == .failed
            }
            if queuedJobs && !transmissionStore.isConfigured {
                statusMessage = "Configure Transmission to start queued TV downloads"
            } else {
                let formatter = DateFormatter()
                formatter.timeStyle = .short
                formatter.dateStyle = .none
                statusMessage = enabled.isEmpty
                    ? "No active subscriptions"
                    : "Last checked \(formatter.string(from: Date()))"
            }
        } catch {
            statusMessage = Self.message(for: error)
        }
    }

    private func shouldRefreshSchedule(
        _ subscription: TVSubscription,
        now: Date,
        forced: Bool
    ) -> Bool {
        if forced { return true }
        if let requestedAt = subscription.checkRequestedAt,
           requestedAt > (subscription.lastCheckedAt ?? .distantPast) {
            return true
        }
        guard let lastCheckedAt = subscription.lastCheckedAt else { return true }
        return now.timeIntervalSince(lastCheckedAt) >= regularCheckInterval
    }

    private func refresh(
        _ subscription: TVSubscription,
        in context: ModelContext,
        now: Date
    ) async {
        guard let showID = Int(subscription.seriesID) else {
            subscription.status = .error
            subscription.lastErrorMessage = "The TVmaze show identifier is invalid."
            subscription.lastCheckedAt = now
            return
        }

        subscription.status = .checking
        subscription.lastCheckedAt = now
        do {
            let schedule = try await tvMaze.schedule(for: showID)
            subscription.seriesTitle = schedule.show.name
            subscription.seriesYear = schedule.show.premieredYear
            subscription.imdbID = schedule.show.imdbID
            subscription.runtimeMinutes = schedule.show.runtimeMinutes
            subscription.showStatus = schedule.show.status

            if subscription.resolvedStart == nil {
                subscription.resolvedStart = try resolveDeferredStart(
                    for: subscription,
                    schedule: schedule,
                    now: now
                )
            }

            let jobs = try jobs(for: subscription, in: context)
            let history = try history(for: subscription, in: context)
            let plans = try plans(for: subscription, in: context)
            if let start = subscription.resolvedStart {
                let backlog = try TVSubscriptionPlanner.plan(
                    schedule: schedule,
                    start: .manual(start.episodeNumber),
                    asOf: now
                )
                try TVSubscriptionWorkflow.enqueueBacklog(
                    fullSeasonCandidates: backlog.fullSeasonCandidates,
                    individualEpisodes: backlog.individualEpisodes.map {
                        TVEpisodeCoordinate($0)
                    },
                    for: subscription,
                    jobs: jobs,
                    history: history,
                    plans: plans,
                    in: context,
                    now: now
                )
            }

            let nextScheduled = schedule.episodes
                .filter { episode in
                    guard let airstamp = episode.airstamp, airstamp > now else {
                        return false
                    }
                    if let start = subscription.resolvedStart {
                        return TVEpisodeCoordinate(episode.number) >= start
                    }
                    return true
                }
                .sorted(by: Self.airdateOrder)
                .first
            subscription.nextEpisodeToAcquire = nextScheduled.map {
                TVEpisodeCoordinate($0.number)
            }
            subscription.nextAirdate = nextScheduled?.airstamp
            subscription.lastSuccessfulCheckAt = now
            subscription.checkRequestedAt = nil
            subscription.lastErrorMessage = nil
            subscription.status = subscription.resolvedStart == nil
                ? .waitingForAirdate
                : .active
            subscription.updatedAt = now
            try context.save()
        } catch {
            subscription.status = .error
            subscription.lastErrorMessage = Self.message(for: error)
            subscription.updatedAt = now
            try? context.save()
        }
    }

    private func resolveDeferredStart(
        for subscription: TVSubscription,
        schedule: TVShowSchedule,
        now: Date
    ) throws -> TVEpisodeCoordinate? {
        switch subscription.startMode {
        case .first:
            return TVEpisodeCoordinate(season: 1, episode: 1)
        case .manual:
            return subscription.requestedStart
        case .current:
            let resolution = try TVSubscriptionPlanner.resolve(
                start: .current,
                episodes: schedule.episodes,
                asOf: now
            )
            guard case .episode(let number) = resolution else { return nil }
            return TVEpisodeCoordinate(number)
        case .next:
            // "Next" is anchored to subscription creation. If an announced
            // episode airs between Mac checks, it remains the requested start.
            let episode = schedule.episodes
                .filter { ($0.airstamp ?? .distantPast) > subscription.createdAt }
                .sorted(by: Self.airdateOrder)
                .first
            return episode.map { TVEpisodeCoordinate($0.number) }
        }
    }

    private func processQueuedJobs(
        in context: ModelContext,
        transmissionStore: TransmissionStore,
        now: Date
    ) async {
        guard transmissionStore.isConfigured else {
            statusMessage = "Configure Transmission to start queued TV downloads"
            return
        }

        let allJobs: [TVAcquisitionJob]
        let subscriptions: [TVSubscription]
        do {
            allJobs = try context.fetch(
                FetchDescriptor<TVAcquisitionJob>(
                    sortBy: [SortDescriptor(\.createdAt)]
                )
            )
            subscriptions = try context.fetch(FetchDescriptor<TVSubscription>())
        } catch {
            statusMessage = Self.message(for: error)
            return
        }

        let eligible = allJobs.filter {
            ($0.status == .queued || $0.status == .failed) &&
                ($0.nextAttemptAt == nil || $0.nextAttemptAt! <= now)
        }

        for job in eligible {
            guard !Task.isCancelled,
                  let subscription = subscriptions.first(where: {
                      $0.id == job.subscriptionID && $0.isEnabled
                  }) else {
                continue
            }
            await process(
                job,
                subscription: subscription,
                in: context,
                transmissionStore: transmissionStore,
                now: Date()
            )
        }
    }

    private func recoverInterruptedJobs(
        in context: ModelContext,
        now: Date
    ) throws {
        let jobs = try context.fetch(FetchDescriptor<TVAcquisitionJob>())
        for job in jobs {
            switch job.status {
            case .searching, .selected, .submitting:
                job.status = .queued
                job.nextAttemptAt = nil
                job.lastErrorMessage = "Recovered after Torrent Match stopped during the previous attempt."
                job.updatedAt = now
            case .queued, .downloading, .completed, .skipped, .failed, .cancelled:
                break
            }
        }
    }

    private func process(
        _ job: TVAcquisitionJob,
        subscription: TVSubscription,
        in context: ModelContext,
        transmissionStore: TransmissionStore,
        now: Date
    ) async {
        job.status = .searching
        job.attemptCount += 1
        job.updatedAt = now
        job.lastErrorMessage = nil
        try? context.save()

        let request: TorrentSearchRequest
        switch job.kind {
        case .episode:
            request = .tvEpisode(
                seriesTitle: subscription.seriesTitle,
                year: subscription.seriesYear,
                imdbID: subscription.imdbID,
                season: job.coverage.start.season,
                episode: job.coverage.start.episode
            )
        case .seasonPack:
            request = .tvSeasonPack(
                seriesTitle: subscription.seriesTitle,
                year: subscription.seriesYear,
                imdbID: subscription.imdbID,
                season: job.coverage.start.season
            )
        }

        let report = await searchService.searchAndRankReport(request)
        let ranked = await enrichedRanking(
            for: report.results,
            runtimeMinutes: job.kind == .episode ? subscription.runtimeMinutes : nil
        )
        guard let selected = ranked.first else {
            if job.kind == .seasonPack {
                if !report.failures.isEmpty, job.attemptCount < 3 {
                    scheduleRetry(
                        job,
                        message: "Season-pack providers were temporarily unavailable. Torrent Match will retry before falling back to episodes.\n" +
                            report.failures.map {
                                "\($0.providerName): \($0.message)"
                            }.joined(separator: "\n"),
                        now: now
                    )
                    try? context.save()
                    return
                }
                TVSubscriptionWorkflow.replaceSeasonPackWithEpisodes(
                    job,
                    subscription: subscription,
                    episodeNumbers: coordinates(in: job.coverage),
                    in: context,
                    now: now
                )
                context.insert(
                    TVAcquisitionHistoryEntry(
                        subscriptionID: subscription.id,
                        planID: job.planID,
                        jobID: job.id,
                        seriesID: subscription.seriesID,
                        event: .failed,
                        coverage: job.coverage,
                        occurredAt: now,
                        message: "No compatible season pack found; individual episodes queued."
                    )
                )
                try? context.save()
                return
            }

            scheduleRetry(
                job,
                message: report.failures.isEmpty
                    ? "No compatible release is available yet."
                    : report.failures.map { "\($0.providerName): \($0.message)" }.joined(separator: "\n"),
                now: now
            )
            try? context.save()
            return
        }

        job.status = .selected
        job.selectedTorrentTitle = selected.raw.preferredTitle
        job.selectedProvider = selected.raw.provider
        job.selectedScore = selected.score
        job.updatedAt = Date()
        try? context.save()

        do {
            guard validateInFlightAcquisition(
                jobID: job.id,
                subscriptionID: subscription.id,
                in: context
            ) else {
                return
            }
            guard let magnet = try await searchService.resolveMagnet(for: selected.raw),
                  !magnet.isEmpty else {
                scheduleRetry(
                    job,
                    message: "The selected release did not provide a magnet link.",
                    now: Date()
                )
                try? context.save()
                return
            }

            guard validateInFlightAcquisition(
                jobID: job.id,
                subscriptionID: subscription.id,
                in: context
            ) else {
                return
            }
            job.status = .submitting
            job.magnetURI = magnet
            job.magnetInfoHash = Self.infoHash(from: magnet)
            job.updatedAt = Date()
            try? context.save()

            guard validateInFlightAcquisition(
                jobID: job.id,
                subscriptionID: subscription.id,
                in: context
            ) else {
                return
            }
            let result = try await transmissionStore.add(magnet: magnet)
            let submittedAt = Date()
            job.status = .downloading
            job.transmissionTorrentID = result.torrentID
            job.transmissionTorrentName = result.torrentName
            job.transmissionInfoHash = result.infoHash
            job.submittedAt = submittedAt
            job.nextAttemptAt = nil
            job.lastErrorMessage = nil
            job.updatedAt = submittedAt
            context.insert(
                TVAcquisitionHistoryEntry(
                    subscriptionID: subscription.id,
                    planID: job.planID,
                    jobID: job.id,
                    seriesID: subscription.seriesID,
                    event: result.wasDuplicate ? .torrentDuplicate : .torrentAdded,
                    coverage: job.coverage,
                    occurredAt: submittedAt,
                    torrentID: result.torrentID,
                    torrentName: result.torrentName,
                    torrentInfoHash: result.infoHash,
                    message: result.wasDuplicate
                        ? "Transmission already had the selected release."
                        : "Sent the selected release to Transmission."
                )
            )
            try context.save()
        } catch {
            scheduleRetry(job, message: Self.message(for: error), now: Date())
            try? context.save()
        }
    }

    private func enrichedRanking(
        for initial: [RankedTorrentResult],
        runtimeMinutes: Int?
    ) async -> [RankedTorrentResult] {
        let candidates = initial
        guard !candidates.isEmpty else { return [] }

        let service = searchService
        let enrich: @Sendable (Int) async -> (Int, TorrentSearchResult) = { index in
            let raw = candidates[index].raw
            guard raw.detailURL != nil,
                  let metadata = try? await service.fetchDetailMetadata(for: raw) else {
                return (index, raw)
            }
            let specs = metadata.specs?.mergedMissingFields(
                from: raw.detailSpecs
            ) ?? raw.detailSpecs
            return (
                index,
                TorrentSearchResult(
                    id: raw.id,
                    title: raw.title,
                    detailMetadata: metadata.text ?? raw.detailMetadata,
                    detailSpecs: specs,
                    magnet: metadata.magnet ?? raw.magnet,
                    detailURL: raw.detailURL,
                    seeders: raw.seeders,
                    leechers: raw.leechers,
                    provider: raw.provider,
                    size: raw.size
                )
            )
        }
        let enriched = await withTaskGroup(
            of: (Int, TorrentSearchResult).self,
            returning: [TorrentSearchResult].self
        ) { group in
            let concurrency = min(16, candidates.count)
            for index in 0..<concurrency {
                group.addTask {
                    await enrich(index)
                }
            }

            var indexed: [(Int, TorrentSearchResult)] = []
            var nextIndex = concurrency
            while let result = await group.next() {
                indexed.append(result)
                if nextIndex < candidates.count {
                    let index = nextIndex
                    nextIndex += 1
                    group.addTask {
                        await enrich(index)
                    }
                }
            }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
        let runtimeEnriched = enriched.map { result in
            guard let runtimeMinutes,
                  runtimeMinutes > 0,
                  result.detailSpecs?.runtime?.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty != false,
                  case .episodes(let episodes) = TVReleaseParser.parse(
                      result.preferredTitle
                  )?.coverage,
                  episodes.count == 1 else {
                return result
            }

            let specs = (result.detailSpecs ?? TorrentDetailSpecs())
                .withFallbackRuntime("\(runtimeMinutes) min")
            return TorrentSearchResult(
                id: result.id,
                title: result.title,
                detailMetadata: result.detailMetadata,
                detailSpecs: specs,
                magnet: result.magnet,
                detailURL: result.detailURL,
                seeders: result.seeders,
                leechers: result.leechers,
                provider: result.provider,
                size: result.size
            )
        }
        return TorrentRanker.rank(
            runtimeEnriched,
            hideExcluded: true,
            profile: .television
        )
    }

    /// Re-reads shared state immediately before each irreversible handoff.
    /// This prevents a pause, removal, or explicit cancellation that occurs
    /// during provider/detail awaits from submitting a stale acquisition.
    private func validateInFlightAcquisition(
        jobID: UUID,
        subscriptionID: UUID,
        in context: ModelContext
    ) -> Bool {
        let subscriptions = (try? context.fetch(
            FetchDescriptor<TVSubscription>()
        )) ?? []
        guard subscriptions.contains(where: {
            $0.id == subscriptionID && $0.isEnabled
        }) else {
            return false
        }

        let jobs = (try? context.fetch(
            FetchDescriptor<TVAcquisitionJob>()
        )) ?? []
        guard let current = jobs.first(where: { $0.id == jobID }) else {
            return false
        }
        switch current.status {
        case .searching, .selected, .submitting:
            return true
        case .queued, .downloading, .completed, .skipped, .failed, .cancelled:
            return false
        }
    }

    private func reconcileCompletedDownloads(
        in context: ModelContext,
        transmissionStore: TransmissionStore
    ) async {
        guard transmissionStore.isConfigured else { return }
        _ = await transmissionStore.refreshDownloads()

        let jobs = (try? context.fetch(FetchDescriptor<TVAcquisitionJob>())) ?? []
        let completedTorrents = transmissionStore.allTorrents.filter {
            !$0.isIncompleteDownload
        }
        let now = Date()

        for job in jobs where job.status == .downloading {
            let match = completedTorrents.first { torrent in
                if let id = job.transmissionTorrentID, torrent.id == id {
                    return true
                }
                return job.transmissionTorrentName == torrent.name
            }
            guard let match else { continue }

            job.status = .completed
            job.completedAt = now
            job.updatedAt = now
            context.insert(
                TVAcquisitionHistoryEntry(
                    subscriptionID: job.subscriptionID,
                    planID: job.planID,
                    jobID: job.id,
                    seriesID: job.seriesID,
                    event: .downloadCompleted,
                    coverage: job.coverage,
                    occurredAt: now,
                    torrentID: match.id,
                    torrentName: match.name,
                    torrentInfoHash: job.transmissionInfoHash,
                    message: "Transmission reports the download complete."
                )
            )
        }
        try? context.save()
    }

    private func scheduleRetry(
        _ job: TVAcquisitionJob,
        message: String,
        now: Date
    ) {
        job.status = .queued
        job.nextAttemptAt = now.addingTimeInterval(retryInterval)
        job.lastErrorMessage = message
        job.updatedAt = now
    }

    private func jobs(
        for subscription: TVSubscription,
        in context: ModelContext
    ) throws -> [TVAcquisitionJob] {
        try context.fetch(FetchDescriptor<TVAcquisitionJob>()).filter {
            $0.subscriptionID == subscription.id
        }
    }

    private func history(
        for subscription: TVSubscription,
        in context: ModelContext
    ) throws -> [TVAcquisitionHistoryEntry] {
        try context.fetch(FetchDescriptor<TVAcquisitionHistoryEntry>()).filter {
            $0.subscriptionID == subscription.id
        }
    }

    private func plans(
        for subscription: TVSubscription,
        in context: ModelContext
    ) throws -> [TVAcquisitionPlan] {
        try context.fetch(FetchDescriptor<TVAcquisitionPlan>()).filter {
            $0.subscriptionID == subscription.id
        }
    }

    private func coordinates(in coverage: TVEpisodeCoverage) -> [TVEpisodeCoordinate] {
        guard coverage.start.season == coverage.end.season else {
            return [coverage.start, coverage.end]
        }
        return (coverage.start.episode...coverage.end.episode).map {
            TVEpisodeCoordinate(season: coverage.start.season, episode: $0)
        }
    }

    private static func airdateOrder(
        _ lhs: TVEpisodeSchedule,
        _ rhs: TVEpisodeSchedule
    ) -> Bool {
        let lhsDate = lhs.airstamp ?? .distantFuture
        let rhsDate = rhs.airstamp ?? .distantFuture
        if lhsDate != rhsDate {
            return lhsDate < rhsDate
        }
        return lhs.number < rhs.number
    }

    private static func infoHash(from magnet: String) -> String? {
        guard let components = URLComponents(string: magnet),
              let value = components.queryItems?
                .first(where: { $0.name.lowercased() == "xt" })?
                .value,
              value.lowercased().hasPrefix("urn:btih:") else {
            return nil
        }
        return String(value.dropFirst("urn:btih:".count))
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
