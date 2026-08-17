import SwiftData
import SwiftUI
import TorrentMatcherCore

struct TVSubscriptionsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var transmissionStore: TransmissionStore
    @EnvironmentObject private var automation: TVAutomationCoordinator
    @Query(sort: \TVSubscription.seriesTitle) private var subscriptions: [TVSubscription]
    @Query(sort: \TVAcquisitionJob.createdAt, order: .reverse) private var jobs: [TVAcquisitionJob]
    @Query(sort: \TVAcquisitionHistoryEntry.occurredAt, order: .reverse)
    private var history: [TVAcquisitionHistoryEntry]

    @AppStorage(TransmissionStore.DefaultsKey.homeRPCURL) private var transmissionRPCURL = ""
    @AppStorage(TransmissionStore.DefaultsKey.tailscaleRPCURL) private var transmissionTailscaleRPCURL = ""
    @AppStorage(TransmissionStore.DefaultsKey.preferTailscale) private var transmissionPreferTailscale = false
    @AppStorage(TransmissionStore.DefaultsKey.username) private var transmissionUsername = ""
    @AppStorage(TransmissionStore.DefaultsKey.password) private var transmissionPassword = ""
#if os(macOS)
    @AppStorage("tv.launchAtLogin") private var launchAtLogin = true
#endif

    @State private var isAddingSubscription = false
    @State private var isShowingTransmissionSettings = false
    @State private var subscriptionPendingRemoval: TVSubscription?
    @State private var alertMessage: String?

    private var visibleJobs: [TVAcquisitionJob] {
        Array(jobs.prefix(50))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DownloadsPanel(
                    downloads: transmissionStore.downloads,
                    isRefreshing: transmissionStore.isRefreshing,
                    onRefresh: refreshDownloads,
                    onTogglePause: toggleDownload,
                    onDelete: deleteDownload,
                    onPriorityChange: updateDownloadPriority
                )

                List {
                    Section {
                        if subscriptions.isEmpty {
                            ContentUnavailableView {
                                Label("No Show Subscriptions", systemImage: "tv.badge.plus")
                            } description: {
                                Text("Add a favorite show and choose where Torrent Match should begin.")
                            } actions: {
                                Button("Add Show") {
                                    isAddingSubscription = true
                                }
                            }
                        } else {
                            ForEach(subscriptions) { subscription in
                                TVSubscriptionRow(
                                    subscription: subscription,
                                    jobs: jobs.filter { $0.subscriptionID == subscription.id },
                                    onToggleEnabled: { toggle(subscription) },
                                    onRemove: { subscriptionPendingRemoval = subscription }
                                )
                            }
                        }
                    } header: {
                        Text("Subscriptions")
                    } footer: {
#if os(macOS)
                        Text("This Mac monitors air times and performs downloads while Torrent Match is running.")
#else
                        Text("Subscriptions are currently stored on this device. Transmission activity can still be controlled remotely.")
#endif
                    }

                    if !visibleJobs.isEmpty {
                        Section("Queue and Activity") {
                            ForEach(visibleJobs) { job in
                                TVAcquisitionJobRow(
                                    job: job,
                                    seriesTitle: subscriptions.first(where: {
                                        $0.id == job.subscriptionID
                                    })?.seriesTitle ?? job.searchQuery
                                )
                            }
                        }
                    }

                    if let lastEvent = history.first {
                        Section("Latest Event") {
                            LabeledContent(lastEvent.event.displayTitle) {
                                Text(lastEvent.occurredAt, style: .relative)
                            }
                            if let message = lastEvent.message, !message.isEmpty {
                                Text(message)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Shows")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        requestCheck()
                    } label: {
                        if automation.isChecking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Check Now", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(automation.isChecking || subscriptions.isEmpty)

                    Button {
                        isShowingTransmissionSettings = true
                    } label: {
                        Label("Transmission", systemImage: "externaldrive.connected.to.line.below")
                    }

                    Button {
                        isAddingSubscription = true
                    } label: {
                        Label("Add Show", systemImage: "plus")
                    }
                }
            }
#if os(macOS)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Toggle("Launch Torrent Match at login", isOn: $launchAtLogin)
                        .toggleStyle(.checkbox)
                        .onChange(of: launchAtLogin) { _, isEnabled in
                            do {
                                try MacLoginItemController.setEnabled(isEnabled)
                            } catch {
                                alertMessage = Self.message(for: error)
                            }
                        }
                    Spacer()
                    Text(automation.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
#endif
        }
        .sheet(isPresented: $isAddingSubscription) {
            AddTVSubscriptionView()
        }
        .sheet(isPresented: $isShowingTransmissionSettings, onDismiss: saveTransmissionSettings) {
            TransmissionSettingsView(
                rpcURL: $transmissionRPCURL,
                tailscaleRPCURL: $transmissionTailscaleRPCURL,
                preferTailscale: $transmissionPreferTailscale,
                username: $transmissionUsername,
                password: $transmissionPassword
            )
        }
        .confirmationDialog(
            "Remove this subscription?",
            isPresented: Binding(
                get: { subscriptionPendingRemoval != nil },
                set: { if !$0 { subscriptionPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Subscription", role: .destructive) {
                if let subscription = subscriptionPendingRemoval {
                    remove(subscription)
                }
                subscriptionPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                subscriptionPendingRemoval = nil
            }
        } message: {
            Text("Its queued TV jobs and activity history will also be removed. Existing Transmission downloads and files are left alone.")
        }
        .alert(
            "TV Subscriptions",
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func toggle(_ subscription: TVSubscription) {
        subscription.isEnabled.toggle()
        subscription.status = subscription.isEnabled ? .active : .paused
        subscription.checkRequestedAt = subscription.isEnabled ? Date() : nil
        do {
            try modelContext.save()
        } catch {
            alertMessage = Self.message(for: error)
        }
    }

    private func remove(_ subscription: TVSubscription) {
        plans(for: subscription).forEach(modelContext.delete)
        jobs.filter { $0.subscriptionID == subscription.id }.forEach(modelContext.delete)
        history.filter { $0.subscriptionID == subscription.id }.forEach(modelContext.delete)
        modelContext.delete(subscription)
        do {
            try modelContext.save()
        } catch {
            alertMessage = Self.message(for: error)
        }
    }

    private func plans(for subscription: TVSubscription) -> [TVAcquisitionPlan] {
        let descriptor = FetchDescriptor<TVAcquisitionPlan>()
        return (try? modelContext.fetch(descriptor))?.filter {
            $0.subscriptionID == subscription.id
        } ?? []
    }

    private func requestCheck() {
#if os(macOS)
        Task {
            await automation.checkNow(
                in: modelContext,
                transmissionStore: transmissionStore
            )
        }
#else
        let now = Date()
        subscriptions.filter(\.isEnabled).forEach {
            $0.checkRequestedAt = now
            $0.updatedAt = now
        }
        do {
            try modelContext.save()
            alertMessage = "The Mac will check these subscriptions on its next monitoring pass."
        } catch {
            alertMessage = Self.message(for: error)
        }
#endif
    }

    private func refreshDownloads() {
        Task {
            _ = await transmissionStore.refreshDownloads()
            if let error = transmissionStore.lastErrorMessage {
                alertMessage = error
            }
        }
    }

    private func toggleDownload(_ torrent: TransmissionTorrent) {
        Task {
            do {
                try await transmissionStore.togglePause(for: torrent)
            } catch {
                alertMessage = Self.message(for: error)
            }
        }
    }

    private func deleteDownload(_ torrent: TransmissionTorrent) {
        Task {
            do {
                try await transmissionStore.remove(torrentIDs: [torrent.id])
            } catch {
                alertMessage = Self.message(for: error)
            }
        }
    }

    private func updateDownloadPriority(
        _ priority: TransmissionTorrentPriority,
        _ torrent: TransmissionTorrent
    ) {
        Task {
            do {
                try await transmissionStore.setPriority(priority, torrentIDs: [torrent.id])
            } catch {
                alertMessage = Self.message(for: error)
            }
        }
    }

    private func saveTransmissionSettings() {
        transmissionStore.save(
            settings: TransmissionStoreSettings(
                homeRPCURL: transmissionRPCURL,
                tailscaleRPCURL: transmissionTailscaleRPCURL,
                preferTailscale: transmissionPreferTailscale,
                username: transmissionUsername,
                password: transmissionPassword
            )
        )
        refreshDownloads()
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

private struct TVSubscriptionRow: View {
    let subscription: TVSubscription
    let jobs: [TVAcquisitionJob]
    var onToggleEnabled: () -> Void
    var onRemove: () -> Void

    private var activeJobs: [TVAcquisitionJob] {
        jobs.filter {
            switch $0.status {
            case .queued, .searching, .selected, .submitting, .downloading:
                return true
            case .completed, .skipped, .failed, .cancelled:
                return false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(subscription.displayTitle)
                    .font(.headline)
                Spacer(minLength: 8)
                Text(subscription.displayStatus)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(subscription.statusColor)
            }

            HStack(spacing: 12) {
                Label(subscription.startDescription, systemImage: "flag.checkered")
                if let next = subscription.nextEpisodeToAcquire {
                    Label("Next \(next.displayLabel)", systemImage: "forward.end")
                } else if subscription.showStatus == .ended && activeJobs.isEmpty {
                    Label("Caught up", systemImage: "checkmark.circle")
                } else {
                    Label("Waiting for schedule", systemImage: "calendar.badge.clock")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let airdate = subscription.nextAirdate {
                Text("Airs \(airdate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !activeJobs.isEmpty {
                Text(activeJobs.count == 1 ? "1 active acquisition" : "\(activeJobs.count) active acquisitions")
                    .font(.caption.weight(.medium))
            }

            if let error = subscription.lastErrorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button(subscription.isEnabled ? "Pause Subscription" : "Resume Subscription") {
                onToggleEnabled()
            }
            Divider()
            Button("Remove Subscription", role: .destructive) {
                onRemove()
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Remove", role: .destructive) {
                onRemove()
            }
            Button(subscription.isEnabled ? "Pause" : "Resume") {
                onToggleEnabled()
            }
            .tint(subscription.isEnabled ? .orange : .green)
        }
    }
}

private struct TVAcquisitionJobRow: View {
    let job: TVAcquisitionJob
    let seriesTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(seriesTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(job.status.displayTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(job.status.color)
            }

            HStack(spacing: 10) {
                Label(job.coverageDescription, systemImage: job.kind == .seasonPack ? "square.stack" : "play.rectangle")
                if let provider = job.selectedProvider {
                    Text(provider)
                }
                if let score = job.selectedScore {
                    Text("Score \(score)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let release = job.selectedTorrentTitle {
                Text(release)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let error = job.lastErrorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AddTVSubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var existingSubscriptions: [TVSubscription]

    private let tvMaze = TVMazeClient()
    @State private var query = ""
    @State private var searchResults: [TVShowIdentity] = []
    @State private var selectedShow: TVShowIdentity?
    @State private var schedule: TVShowSchedule?
    @State private var startMode: TVSubscriptionStartMode = .first
    @State private var manualSeason = 1
    @State private var manualEpisode = 1
    @State private var backlog: TVSubscriptionBacklogPlan?
    @State private var isSearching = false
    @State private var isLoadingSchedule = false
    @State private var isReviewing = false
    @State private var errorMessage: String?
    @State private var scheduleRequestID: UUID?
    @State private var scheduleLoadTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                if selectedShow == nil {
                    searchSection
                    resultsSection
                } else if !isReviewing {
                    selectedShowSection
                    startSection
                    planSummarySection
                } else {
                    confirmationSection
                }

                Section {
                    Link("TV scheduling data by TVmaze", destination: URL(string: "https://www.tvmaze.com")!)
                        .font(.footnote)
                }
            }
            .navigationTitle(isReviewing ? "Confirm Subscription" : "Add Show")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isReviewing ? "Back" : "Cancel") {
                        if isReviewing {
                            isReviewing = false
                        } else {
                            dismiss()
                        }
                    }
                }

                if selectedShow != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isReviewing ? "Add" : "Review") {
                            if isReviewing {
                                addSubscription()
                            } else {
                                isReviewing = true
                            }
                        }
                        .disabled(backlog == nil || isLoadingSchedule)
                    }
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
#endif
        .alert(
            "Couldn’t Add Show",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: startMode) { _, _ in
            updatePlan()
        }
        .onChange(of: manualSeason) { _, _ in
            updatePlan()
        }
        .onChange(of: manualEpisode) { _, _ in
            updatePlan()
        }
        .onDisappear {
            scheduleLoadTask?.cancel()
        }
    }

    private var searchSection: some View {
        Section("Find a Show") {
            TextField("Show title", text: $query)
                .onSubmit(search)
#if os(iOS)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
#endif
            Button {
                search()
            } label: {
                if isSearching {
                    ProgressView()
                } else {
                    Label("Search", systemImage: "magnifyingglass")
                }
            }
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        if !searchResults.isEmpty {
            Section("Results") {
                ForEach(searchResults) { show in
                    Button {
                        select(show)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(show.name)
                                    .foregroundStyle(.primary)
                                Text(show.searchSubtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var selectedShowSection: some View {
        Section("Show") {
            if let selectedShow {
                LabeledContent("Title", value: selectedShow.name)
                if let year = selectedShow.premieredYear {
                    LabeledContent("Premiered", value: String(year))
                }
                LabeledContent("Status", value: selectedShow.status.displayTitle)
                Button("Choose a Different Show") {
                    clearSelectedShow()
                }
            }
        }
    }

    private var startSection: some View {
        Section("Start With") {
            Picker("Starting point", selection: $startMode) {
                Text("First").tag(TVSubscriptionStartMode.first)
                Text("Current").tag(TVSubscriptionStartMode.current)
                Text("Next").tag(TVSubscriptionStartMode.next)
                Text("Manual").tag(TVSubscriptionStartMode.manual)
            }
            .pickerStyle(.segmented)

            Text(startMode.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if startMode == .manual {
                Stepper("Season \(manualSeason)", value: $manualSeason, in: 1...999)
                Stepper("Episode \(manualEpisode)", value: $manualEpisode, in: 1...999)
            }
        }
    }

    @ViewBuilder
    private var planSummarySection: some View {
        Section("Download Plan") {
            if isLoadingSchedule {
                HStack {
                    ProgressView()
                    Text("Loading the episode schedule…")
                }
            } else if let backlog {
                planRows(backlog)
            } else {
                Text("Choose a starting point to preview the backlog.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var confirmationSection: some View {
        if let selectedShow, let backlog {
            Section("Subscription") {
                LabeledContent("Show", value: selectedShow.name)
                LabeledContent("Starting point", value: startMode.reviewLabel(manual: requestedStart))
                resolutionRow(backlog.startResolution)
            }

            Section {
                planRows(backlog)
            } header: {
                Text("Initial Acquisition")
            } footer: {
                Text("Complete, entirely needed seasons use season packs when available. If a compatible pack cannot be found, Torrent Match falls back to those episodes individually.")
            }

            Section("Automation") {
                Label("The always-running Mac checks for newly aired episodes.", systemImage: "desktopcomputer")
                Label("The highest-ranked Apple TV-compatible release available at download time is sent to Transmission.", systemImage: "appletv")
                Label("Quality upgrades are not performed.", systemImage: "arrow.down.circle")
            }
        }
    }

    @ViewBuilder
    private func planRows(_ backlog: TVSubscriptionBacklogPlan) -> some View {
        resolutionRow(backlog.startResolution)

        ForEach(backlog.fullSeasonCandidates, id: \.season) { season in
            LabeledContent("Season \(season.season) pack") {
                Text("\(season.episodes.count) episodes")
            }
        }

        if !backlog.individualEpisodes.isEmpty {
            LabeledContent("Individual episodes") {
                Text("\(backlog.individualEpisodes.count)")
            }
            Text(backlog.individualEpisodes.map(\.code).joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if backlog.fullSeasonCandidates.isEmpty && backlog.individualEpisodes.isEmpty {
            Text(backlog.emptyPlanMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func resolutionRow(_ resolution: TVSubscriptionStartResolution) -> some View {
        switch resolution {
        case .episode(let number):
            LabeledContent("Resolved start", value: number.code)
        case .waiting(let reason):
            Label(reason.displayMessage, systemImage: "calendar.badge.clock")
                .foregroundStyle(.secondary)
        }
    }

    private var requestedStart: TVEpisodeCoordinate? {
        guard startMode == .manual else { return nil }
        return TVEpisodeCoordinate(season: manualSeason, episode: manualEpisode)
    }

    private func search() {
        let title = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !isSearching else { return }
        isSearching = true
        errorMessage = nil
        Task {
            do {
                let shows = try await tvMaze.searchShows(title)
                searchResults = shows
                if shows.isEmpty {
                    errorMessage = "No matching shows were found."
                }
            } catch {
                errorMessage = Self.message(for: error)
            }
            isSearching = false
        }
    }

    private func select(_ show: TVShowIdentity) {
        scheduleLoadTask?.cancel()
        let requestID = UUID()
        scheduleRequestID = requestID
        selectedShow = show
        schedule = nil
        backlog = nil
        isLoadingSchedule = true
        errorMessage = nil
        scheduleLoadTask = Task {
            do {
                let loadedSchedule = try await tvMaze.schedule(for: show.id)
                guard !Task.isCancelled,
                      scheduleRequestID == requestID,
                      selectedShow?.id == show.id else {
                    return
                }
                schedule = loadedSchedule
                updatePlan()
            } catch {
                guard !Task.isCancelled,
                      scheduleRequestID == requestID else {
                    return
                }
                errorMessage = Self.message(for: error)
            }
            guard scheduleRequestID == requestID else { return }
            isLoadingSchedule = false
            scheduleLoadTask = nil
        }
    }

    private func clearSelectedShow() {
        scheduleLoadTask?.cancel()
        scheduleLoadTask = nil
        scheduleRequestID = nil
        selectedShow = nil
        schedule = nil
        backlog = nil
        isLoadingSchedule = false
        isReviewing = false
    }

    private func updatePlan() {
        guard let schedule else { return }
        do {
            backlog = try TVSubscriptionPlanner.plan(
                schedule: schedule,
                start: plannerStart,
                asOf: Date()
            )
            errorMessage = nil
        } catch {
            backlog = nil
            errorMessage = Self.message(for: error)
        }
    }

    private var plannerStart: TVSubscriptionStartOption {
        switch startMode {
        case .first:
            return .first
        case .current:
            return .current
        case .next:
            return .next
        case .manual:
            return .manual(
                TVEpisodeNumber(season: manualSeason, episode: manualEpisode)
            )
        }
    }

    private func addSubscription() {
        guard let selectedShow, let backlog else { return }
        do {
            _ = try TVSubscriptionWorkflow.createSubscription(
                show: selectedShow,
                startMode: startMode,
                requestedStart: requestedStart,
                backlog: backlog,
                existingSubscriptions: existingSubscriptions,
                in: modelContext
            )
            dismiss()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

private extension TVSubscription {
    var displayTitle: String {
        guard let seriesYear else { return seriesTitle }
        return "\(seriesTitle) (\(seriesYear))"
    }

    var startDescription: String {
        switch startMode {
        case .first:
            return "From S01E01"
        case .current:
            return resolvedStart.map { "From current \($0.displayLabel)" } ?? "From current"
        case .next:
            return resolvedStart.map { "From next \($0.displayLabel)" } ?? "From next"
        case .manual:
            return requestedStart.map { "From \($0.displayLabel)" } ?? "Manual start"
        }
    }

    var displayStatus: String {
        if !isEnabled { return "Paused" }
        switch status {
        case .active:
            return "Active"
        case .paused:
            return "Paused"
        case .checking:
            return "Checking"
        case .waitingForAirdate:
            return "Waiting"
        case .error:
            return "Needs Attention"
        }
    }

    var statusColor: Color {
        if !isEnabled { return .secondary }
        switch status {
        case .active:
            return .green
        case .checking:
            return .blue
        case .waitingForAirdate:
            return .orange
        case .error:
            return .red
        case .paused:
            return .secondary
        }
    }
}

private extension TVAcquisitionJob {
    var coverageDescription: String {
        if kind == .seasonPack {
            return "Season \(coverage.start.season) pack"
        }
        if coverage.start.season == coverage.end.season,
           coverage.start.episode == coverage.end.episode {
            return coverage.start.displayLabel
        }
        return "\(coverage.start.displayLabel)–\(coverage.end.displayLabel)"
    }
}

private extension TVAcquisitionJobStatus {
    var displayTitle: String {
        switch self {
        case .queued: return "Queued"
        case .searching: return "Searching"
        case .selected: return "Selected"
        case .submitting: return "Sending"
        case .downloading: return "Downloading"
        case .completed: return "Complete"
        case .skipped: return "Replaced"
        case .failed: return "Retrying"
        case .cancelled: return "Cancelled"
        }
    }

    var color: Color {
        switch self {
        case .queued, .selected:
            return .secondary
        case .searching, .submitting:
            return .blue
        case .downloading:
            return .green
        case .completed:
            return .mint
        case .skipped, .cancelled:
            return .secondary
        case .failed:
            return .red
        }
    }
}

private extension TVAcquisitionHistoryEvent {
    var displayTitle: String {
        switch self {
        case .planConfirmed: return "Plan confirmed"
        case .jobQueued: return "Acquisition queued"
        case .torrentAdded: return "Torrent added"
        case .torrentDuplicate: return "Existing torrent matched"
        case .downloadCompleted: return "Download completed"
        case .failed: return "Acquisition failed"
        case .cancelled: return "Acquisition cancelled"
        }
    }
}

private extension TVSubscriptionStartMode {
    var explanation: String {
        switch self {
        case .first:
            return "Begin with S01E01 and acquire the aired backlog."
        case .current:
            return "Begin with the most recently aired regular episode."
        case .next:
            return "Wait for the next regular episode to air, even if it has not been announced yet."
        case .manual:
            return "Begin with the season and episode you enter."
        }
    }

    func reviewLabel(manual: TVEpisodeCoordinate?) -> String {
        switch self {
        case .first: return "First (S01E01)"
        case .current: return "Current"
        case .next: return "Next"
        case .manual: return manual?.displayLabel ?? "Manual"
        }
    }
}

private extension TVShowIdentity {
    var searchSubtitle: String {
        [premieredYear.map(String.init), status.displayTitle]
            .compactMap { $0 }
            .joined(separator: " • ")
    }
}

private extension TorrentMatcherCore.TVShowStatus {
    var displayTitle: String {
        switch self {
        case .running: return "Running"
        case .ended: return "Ended"
        case .toBeDetermined: return "To Be Determined"
        case .inDevelopment: return "In Development"
        case .unknown: return "Unknown"
        }
    }
}

private extension TVSubscriptionWaitingReason {
    var displayMessage: String {
        switch self {
        case .noAiredEpisode:
            return "No regular episode has aired yet. The subscription will wait."
        case .nextEpisodeUnannounced:
            return "The next regular episode has not been announced. The subscription will wait."
        }
    }
}

private extension TVSubscriptionBacklogPlan {
    var emptyPlanMessage: String {
        switch startResolution {
        case .waiting:
            return "Nothing will download until the requested episode exists and has aired."
        case .episode:
            return "There is no aired backlog from this starting point yet."
        }
    }
}
