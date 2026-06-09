//
//  ContentView.swift
//  Torrent Match
//
//  Created by Ryan Keefe on 5/17/26.
//

import SwiftUI
import SwiftData
import TorrentMatcherCore

struct ContentView: View {
    private let searchService = TorrentSearchService(configs: BuiltInProviderConfigs.default)
    private let maxConcurrentMagnetPrefetches = 8
    private let maxConcurrentDetailPrefetches = 4

    // MARK: - Search / Results State
    @AppStorage("transmission.rpcURL") private var transmissionRPCURL: String = ""
    @AppStorage("transmission.tailscaleRPCURL") private var transmissionTailscaleRPCURL: String = ""
    @AppStorage("transmission.preferTailscale") private var transmissionPreferTailscale: Bool = false
    @AppStorage("transmission.username") private var transmissionUsername: String = ""
    @AppStorage("transmission.password") private var transmissionPassword: String = ""
    @StateObject private var movieAutocomplete = MovieAutocompleteViewModel()
    @State private var query: String = ""
    @State private var isSearching: Bool = false
    @State private var foundSoFar: Int = 0
    @State private var results: [SearchResult] = []
    @State private var errorMessage: String? = nil
    @State private var selected: SearchResult? = nil
    @State private var presentedResult: SearchResult? = nil
    @State private var alertTitle: String = ""
    @State private var alertMessage: String? = nil
    @State private var transmissionSendPhase: TransmissionSendPhase = .idle
    @State private var isPresentingTransmissionSettings: Bool = false
    @State private var magnetPrefetchQueue: [MagnetPrefetchCandidate] = []
    @State private var activeMagnetPrefetchTasks: [String: Task<Void, Never>] = [:]
    @State private var attemptedMagnetPrefetchKeys: Set<String> = []
    @State private var selectedMagnetPrefetchTask: Task<Void, Never>? = nil
    @State private var detailPrefetchQueue: [DetailPrefetchCandidate] = []
    @State private var activeDetailPrefetchTasks: [String: Task<Void, Never>] = [:]
    @State private var attemptedDetailPrefetchKeys: Set<String> = []
    @State private var detailMetadataStatuses: [UUID: DetailMetadataFetchStatus] = [:]

    var sortedResults: [SearchResult] {
        results.sorted { $0.score > $1.score }
    }

    private var transmissionButtonTitle: String {
        switch transmissionSendPhase {
        case .idle:
            return "Send to Transmission"
        case .fetchingMagnet:
            return "Fetching Magnet…"
        case .connecting:
            return "Connecting to Transmission…"
        }
    }

    private var isSendingToTransmission: Bool {
        transmissionSendPhase != .idle
    }

    var body: some View {
        NavigationViewWrapper {
            VStack(spacing: 0) {
                // Search Bar + Action
                SearchBar(
                    query: $query,
                    suggestions: movieAutocomplete.suggestions,
                    onSuggestionSelected: applyMovieSuggestion,
                    onSubmit: performSearch
                )
                    .padding([.horizontal, .top])
                    .padding(.bottom, 6)

                Divider()

                // Results / Loading / Error / Empty
                Group {
                    if let message = errorMessage {
                        ErrorStateView(message: message, retry: performSearch)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if isSearching {
                        if sortedResults.isEmpty {
                            SearchProgressView(foundCount: foundSoFar)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            VStack(spacing: 0) {
                                SearchProgressHeader(foundCount: foundSoFar)
                                    .padding(.horizontal)
                                    .padding(.vertical, 8)
                                Divider()
                                ResultsListView(results: sortedResults, selected: $selected, presentedResult: $presentedResult)
                            }
                        }
                    } else if sortedResults.isEmpty {
                        EmptyResultsView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ResultsListView(results: sortedResults, selected: $selected, presentedResult: $presentedResult)
                    }
                }
            }
            .navigationTitle("")
            .alert(alertTitle, isPresented: alertIsPresented) {
                Button("OK") {
                    alertMessage = nil
                }
            } message: {
                Text(alertMessage ?? "")
            }
            .sheet(isPresented: $isPresentingTransmissionSettings) {
                TransmissionSettingsView(
                    rpcURL: $transmissionRPCURL,
                    tailscaleRPCURL: $transmissionTailscaleRPCURL,
                    preferTailscale: $transmissionPreferTailscale,
                    username: $transmissionUsername,
                    password: $transmissionPassword
                )
            }
            .sheet(item: $presentedResult) { result in
                ResultDetailView(
                    result: result,
                    metadataStatus: detailMetadataStatuses[result.id] ?? .notStarted
                )
            }
            .onChange(of: selected) { _, newValue in
                prefetchSelectedMagnet(for: newValue)
            }
            .onChange(of: presentedResult) { _, newValue in
                fetchPresentedDetailMetadataIfNeeded(for: newValue)
            }
            .onChange(of: query) { _, newValue in
                movieAutocomplete.updateQuery(newValue)
            }
            .toolbar {
                #if os(iOS)
                if #available(iOS 17.0, *) {
                    ToolbarItem(placement: .topBarTrailing) {
                        transmissionSettingsButton
                    }
                } else {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        transmissionSettingsButton
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        Button {
                            sendSelectedToTransmission()
                        } label: {
                            Text(transmissionButtonTitle)
                        }
                        .labelStyle(.titleOnly)
                        .disabled(selected == nil || isSendingToTransmission)
                    }
                }
                #elseif os(macOS)
                ToolbarItem(placement: .automatic) {
                    transmissionSettingsButton
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        sendSelectedToTransmission()
                    } label: {
                        Text(transmissionButtonTitle)
                    }
                    .labelStyle(.titleOnly)
                    .disabled(selected == nil || isSendingToTransmission)
                }
                #else
                ToolbarItem(placement: .automatic) {
                    transmissionSettingsButton
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        sendSelectedToTransmission()
                    } label: {
                        Text(transmissionButtonTitle)
                    }
                    .labelStyle(.titleOnly)
                    .disabled(selected == nil || isSendingToTransmission)
                }
                #endif
            }
#if os(macOS)
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
#endif
        }
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    alertMessage = nil
                }
            }
        )
    }

    private var transmissionSettingsButton: some View {
        Button {
            isPresentingTransmissionSettings = true
        } label: {
            Label("Transmission Settings", systemImage: "gearshape")
        }
        .labelStyle(.iconOnly)
#if os(macOS)
        .help("Transmission Settings")
#endif
    }

    // MARK: - Actions
    private func performSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSearching else { return }
        let searchQuery = movieAutocomplete.resolvedSuggestion(for: trimmed)?.providerQuery ?? trimmed
#if os(iOS)
        UIApplication.shared.endEditing()
#endif
        movieAutocomplete.clearSuggestions()
        errorMessage = nil
        isSearching = true
        foundSoFar = 0
        results = []
        selected = nil
        presentedResult = nil
        cancelMagnetPrefetchPipeline()
        cancelDetailPrefetchPipeline()
        detailMetadataStatuses.removeAll()
        selectedMagnetPrefetchTask?.cancel()

        Task { @MainActor in
            let report = await searchService.searchAndRankReport(searchQuery) { update in
                Task { @MainActor in
                    foundSoFar = update.foundSoFar
                    results = dedupedResults(update.results.map(SearchResult.init))
                    reconcileSelectedResult()
                    prefetchDetailMetadataIfNeeded(from: results)
                    prefetchMagnetsIfNeeded(from: results)
                }
            }
            results = dedupedResults(report.results.map(SearchResult.init))
            foundSoFar = results.count
            if results.isEmpty, !report.failures.isEmpty {
                let details = report.failures
                    .map { "\($0.providerName): \($0.message)" }
                    .joined(separator: "\n")
                errorMessage = "No results. Providers reported errors:\n\(details)\n\nThis often means the site is blocked on your current network/DNS."
            }
            isSearching = false
            reconcileSelectedResult()
            prefetchDetailMetadataIfNeeded(from: results)
            prefetchMagnetsIfNeeded(from: results)
        }
    }

    private func applyMovieSuggestion(_ suggestion: MovieCatalogSuggestion) {
        query = suggestion.displayTitle
        movieAutocomplete.selectSuggestion(suggestion)
        performSearch()
    }

    private func sendSelectedToTransmission() {
        guard let selected else { return }
        let endpoints: [TransmissionEndpoint]
        do {
            endpoints = try makeTransmissionEndpoints()
        } catch {
            showAlert(
                title: "Transmission Not Configured",
                message: (error as? LocalizedError)?.errorDescription ?? "Enter your Transmission RPC settings first."
            )
            isPresentingTransmissionSettings = true
            return
        }

        Task { @MainActor in
            defer { transmissionSendPhase = .idle }

            do {
                transmissionSendPhase = .fetchingMagnet
                let magnet = try await resolvedMagnet(for: selected)
                transmissionSendPhase = .connecting
                try await addMagnetToTransmission(magnet, using: endpoints)
                showAlert(title: "Sent to Transmission", message: selected.title)
            } catch {
                let presentation = transmissionErrorPresentation(for: error, phase: transmissionSendPhase)
                showAlert(title: presentation.title, message: presentation.message)
            }
        }
    }

    private func releaseCountText(_ count: Int) -> String {
        count == 1 ? "1 release" : "\(count) releases"
    }

    private func resolvedMagnet(for selected: SearchResult) async throws -> String {
        if let magnet = selected.magnet, !magnet.isEmpty {
            return magnet
        }

        let magnet = try await searchService.resolveMagnet(for: selected.raw)
        guard let magnet, !magnet.isEmpty else {
            throw TransmissionConfigurationError.missingMagnet
        }

        if let index = results.firstIndex(where: { $0.id == selected.id }) {
            let updated = results[index].withMagnet(magnet)
            results[index] = updated
            results = dedupedResults(results)
            self.selected = results.first(where: { $0.id == updated.id }) ?? results.first(where: { $0.magnet?.infoHashFromMagnet == magnet.infoHashFromMagnet })
        }

        return magnet
    }

    private func prefetchMagnetsIfNeeded(from searchResults: [SearchResult]) {
        let candidates = magnetPrefetchCandidates(from: searchResults)
        guard !candidates.isEmpty else { return }

        for candidate in candidates {
            let key = magnetPrefetchDedupKey(for: candidate)
            guard activeMagnetPrefetchTasks[key] == nil else { continue }
            guard !attemptedMagnetPrefetchKeys.contains(key) else { continue }

            if let existingIndex = magnetPrefetchQueue.firstIndex(where: { $0.key == key }) {
                magnetPrefetchQueue[existingIndex] = MagnetPrefetchCandidate(key: key, result: candidate)
            } else {
                magnetPrefetchQueue.append(MagnetPrefetchCandidate(key: key, result: candidate))
            }
        }

        magnetPrefetchQueue.sort { lhs, rhs in
            if lhs.result.score != rhs.result.score {
                return lhs.result.score > rhs.result.score
            }
            return lhs.result.title < rhs.result.title
        }

        startQueuedMagnetPrefetchesIfNeeded()
    }

    private func prefetchDetailMetadataIfNeeded(from searchResults: [SearchResult]) {
        let candidates = detailPrefetchCandidates(from: searchResults)
        guard !candidates.isEmpty else { return }

        for candidate in candidates {
            let key = detailPrefetchDedupKey(for: candidate)
            guard activeDetailPrefetchTasks[key] == nil else { continue }
            guard !attemptedDetailPrefetchKeys.contains(key) else { continue }

            if let existingIndex = detailPrefetchQueue.firstIndex(where: { $0.key == key }) {
                detailPrefetchQueue[existingIndex] = DetailPrefetchCandidate(key: key, result: candidate)
            } else {
                detailPrefetchQueue.append(DetailPrefetchCandidate(key: key, result: candidate))
            }
        }

        detailPrefetchQueue.sort { lhs, rhs in
            if lhs.result.score != rhs.result.score {
                return lhs.result.score > rhs.result.score
            }
            return lhs.result.title < rhs.result.title
        }

        startQueuedDetailPrefetchesIfNeeded()
    }

    private func prefetchSelectedMagnet(for searchResult: SearchResult?) {
        selectedMagnetPrefetchTask?.cancel()
        guard let searchResult, shouldPrefetchMagnet(for: searchResult) else { return }

        selectedMagnetPrefetchTask = Task { @MainActor in
            await warmMagnet(for: searchResult)
        }
    }

    private func fetchPresentedDetailMetadataIfNeeded(for searchResult: SearchResult?) {
        guard let searchResult, shouldPrefetchDetailMetadata(for: searchResult) else { return }
        let key = detailPrefetchDedupKey(for: searchResult)
        guard activeDetailPrefetchTasks[key] == nil else { return }
        attemptedDetailPrefetchKeys.insert(key)

        activeDetailPrefetchTasks[key] = Task {
            defer {
                Task { @MainActor in
                    activeDetailPrefetchTasks[key] = nil
                    startQueuedDetailPrefetchesIfNeeded()
                }
            }
            await warmDetailMetadata(for: searchResult)
        }
    }

    private func magnetPrefetchCandidates(from searchResults: [SearchResult]) -> [SearchResult] {
        var seenResolutionKeys = Set<String>()
        return searchResults
            .sorted { $0.score > $1.score }
            .filter(shouldPrefetchMagnet)
            .filter { result in
                let key = magnetPrefetchDedupKey(for: result)
                return seenResolutionKeys.insert(key).inserted
            }
    }

    private func magnetPrefetchDedupKey(for result: SearchResult) -> String {
        let normalizedTitle = result.title.normalizedDedupeKey
        if !normalizedTitle.isEmpty {
            return normalizedTitle
        }
        if let detailURL = result.detailURL?.absoluteString, !detailURL.isEmpty {
            return detailURL
        }
        return result.id.uuidString
    }

    private func shouldPrefetchMagnet(for searchResult: SearchResult) -> Bool {
        searchResult.magnet?.isEmpty != false
    }

    private func detailPrefetchCandidates(from searchResults: [SearchResult]) -> [SearchResult] {
        var seenResolutionKeys = Set<String>()
        return searchResults
            .sorted { $0.score > $1.score }
            .filter(shouldPrefetchDetailMetadata)
            .filter { result in
                let key = detailPrefetchDedupKey(for: result)
                return seenResolutionKeys.insert(key).inserted
            }
    }

    private func detailPrefetchDedupKey(for result: SearchResult) -> String {
        if let detailURL = result.detailURL?.absoluteString, !detailURL.isEmpty {
            return "\(result.provider)|\(detailURL)"
        }
        return result.id.uuidString
    }

    private func shouldPrefetchDetailMetadata(for searchResult: SearchResult) -> Bool {
        guard searchResult.detailURL != nil,
              searchResult.raw.detailSpecs?.hasDisplayableFields != true else { return false }

        switch detailMetadataStatuses[searchResult.id] {
        case .fetching, .checkedNoMetadata, .failed(_):
            return false
        case .notStarted, .fetched, .none:
            return true
        }
    }

    private func warmMagnet(for searchResult: SearchResult) async {
        do {
            guard let magnet = try await searchService.resolveMagnet(for: searchResult.raw),
                  !magnet.isEmpty,
                  !Task.isCancelled else { return }
            await MainActor.run {
                applyResolvedMagnet(magnet, to: searchResult.id)
            }
        } catch {
            return
        }
    }

    private func warmDetailMetadata(for searchResult: SearchResult) async {
        await MainActor.run {
            detailMetadataStatuses[searchResult.id] = .fetching
        }
        do {
            guard let metadata = try await searchService.fetchDetailMetadata(for: searchResult.raw),
                  !Task.isCancelled else {
                await MainActor.run {
                    detailMetadataStatuses[searchResult.id] = .checkedNoMetadata
                }
                return
            }
            await MainActor.run {
                detailMetadataStatuses[searchResult.id] = metadata.specs?.hasDisplayableFields == true ? .fetched : .checkedNoMetadata
                applyResolvedDetailMetadata(metadata, to: searchResult.id)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            await MainActor.run {
                detailMetadataStatuses[searchResult.id] = .failed(message)
            }
            return
        }
    }

    private func applyResolvedMagnet(_ magnet: String, to resultID: UUID) {
        guard let index = results.firstIndex(where: { $0.id == resultID }),
              results[index].magnet?.isEmpty != false else { return }
        let updated = results[index].withMagnet(magnet)
        results[index] = updated
        results = dedupedResults(results)
        if selected?.id == resultID {
            selected = results.first(where: { $0.id == updated.id })
        }
        if presentedResult?.id == resultID {
            presentedResult = results.first(where: { $0.id == updated.id })
        }
    }

    private func applyResolvedDetailMetadata(_ metadata: TorrentDetailMetadata, to resultID: UUID) {
        guard let index = results.firstIndex(where: { $0.id == resultID }) else { return }
        let updated = results[index].withDetailMetadata(metadata)
        results[index] = updated
        results = dedupedResults(results)
        if selected?.id == resultID {
            selected = results.first(where: { $0.id == updated.id })
        }
        if presentedResult?.id == resultID {
            presentedResult = results.first(where: { $0.id == updated.id })
        }
        prefetchMagnetsIfNeeded(from: results)
        prefetchDetailMetadataIfNeeded(from: results)
    }

    private func cancelMagnetPrefetchPipeline() {
        activeMagnetPrefetchTasks.values.forEach { $0.cancel() }
        activeMagnetPrefetchTasks.removeAll()
        magnetPrefetchQueue.removeAll()
        attemptedMagnetPrefetchKeys.removeAll()
    }

    private func cancelDetailPrefetchPipeline() {
        activeDetailPrefetchTasks.values.forEach { $0.cancel() }
        activeDetailPrefetchTasks.removeAll()
        detailPrefetchQueue.removeAll()
        attemptedDetailPrefetchKeys.removeAll()
    }

    private func startQueuedMagnetPrefetchesIfNeeded() {
        while activeMagnetPrefetchTasks.count < maxConcurrentMagnetPrefetches {
            guard let nextCandidate = nextMagnetPrefetchCandidate() else { return }

            let key = nextCandidate.key
            attemptedMagnetPrefetchKeys.insert(key)
            activeMagnetPrefetchTasks[key] = Task {
                defer {
                    Task { @MainActor in
                        activeMagnetPrefetchTasks[key] = nil
                        startQueuedMagnetPrefetchesIfNeeded()
                    }
                }
                guard !Task.isCancelled else { return }
                await warmMagnet(for: nextCandidate.result)
            }
        }
    }

    private func nextMagnetPrefetchCandidate() -> MagnetPrefetchCandidate? {
        while !magnetPrefetchQueue.isEmpty {
            let candidate = magnetPrefetchQueue.removeFirst()
            let latestCandidate = latestMagnetPrefetchCandidate(forKey: candidate.key)
            if let latestCandidate {
                return MagnetPrefetchCandidate(key: candidate.key, result: latestCandidate)
            }
        }
        return nil
    }

    private func latestMagnetPrefetchCandidate(forKey key: String) -> SearchResult? {
        magnetPrefetchCandidates(from: results).first { magnetPrefetchDedupKey(for: $0) == key }
    }

    private func startQueuedDetailPrefetchesIfNeeded() {
        while activeDetailPrefetchTasks.count < maxConcurrentDetailPrefetches {
            guard let nextCandidate = nextDetailPrefetchCandidate() else { return }

            let key = nextCandidate.key
            attemptedDetailPrefetchKeys.insert(key)
            activeDetailPrefetchTasks[key] = Task {
                defer {
                    Task { @MainActor in
                        activeDetailPrefetchTasks[key] = nil
                        startQueuedDetailPrefetchesIfNeeded()
                    }
                }
                guard !Task.isCancelled else { return }
                await warmDetailMetadata(for: nextCandidate.result)
            }
        }
    }

    private func nextDetailPrefetchCandidate() -> DetailPrefetchCandidate? {
        while !detailPrefetchQueue.isEmpty {
            let candidate = detailPrefetchQueue.removeFirst()
            let latestCandidate = latestDetailPrefetchCandidate(forKey: candidate.key)
            if let latestCandidate {
                return DetailPrefetchCandidate(key: candidate.key, result: latestCandidate)
            }
        }
        return nil
    }

    private func latestDetailPrefetchCandidate(forKey key: String) -> SearchResult? {
        detailPrefetchCandidates(from: results).first { detailPrefetchDedupKey(for: $0) == key }
    }

    private func reconcileSelectedResult() {
        guard let selected else { return }
        if let refreshed = results.first(where: { $0.id == selected.id }) {
            self.selected = refreshed
        } else if let magnetHash = selected.magnet?.infoHashFromMagnet,
                  let refreshed = results.first(where: { $0.magnet?.infoHashFromMagnet == magnetHash }) {
            self.selected = refreshed
        }

        if let presentedResult,
           let refreshed = results.first(where: { $0.id == presentedResult.id }) {
            self.presentedResult = refreshed
        }
    }

    private func makeTransmissionEndpoints() throws -> [TransmissionEndpoint] {
        let username = transmissionUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = transmissionPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        if (username.isEmpty && !password.isEmpty) || (!username.isEmpty && password.isEmpty) {
            throw TransmissionConfigurationError.incompleteCredentials
        }

        var endpoints: [TransmissionEndpoint] = []

        let homeRPCURLText = transmissionRPCURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !homeRPCURLText.isEmpty {
            guard let rpcURL = normalizedTransmissionRPCURL(from: homeRPCURLText) else {
                throw TransmissionConfigurationError.invalidHomeRPCURL
            }

            endpoints.append(
                TransmissionEndpoint(
                    name: "Home RPC",
                    config: transmissionConfig(for: rpcURL, username: username, password: password)
                )
            )
        }

        let tailscaleRPCURLText = transmissionTailscaleRPCURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tailscaleRPCURLText.isEmpty {
            guard let rpcURL = normalizedTransmissionRPCURL(from: tailscaleRPCURLText) else {
                throw TransmissionConfigurationError.invalidTailscaleRPCURL
            }

            endpoints.append(
                TransmissionEndpoint(
                    name: "Tailscale RPC",
                    config: transmissionConfig(for: rpcURL, username: username, password: password)
                )
            )
        }

        guard !endpoints.isEmpty else {
            throw TransmissionConfigurationError.missingRPCURL
        }

        let orderedEndpoints = endpoints.sorted { lhs, rhs in
            lhs.priority(preferTailscale: transmissionPreferTailscale) < rhs.priority(preferTailscale: transmissionPreferTailscale)
        }

        var seenURLs: Set<URL> = []
        return orderedEndpoints.filter { endpoint in
            seenURLs.insert(endpoint.config.rpcURL).inserted
        }
    }

    private func transmissionConfig(for rpcURL: URL, username: String, password: String) -> TransmissionConfig {
        TransmissionConfig(
            rpcURL: rpcURL,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password
        )
    }

    private func addMagnetToTransmission(_ magnet: String, using endpoints: [TransmissionEndpoint]) async throws {
        var failures: [TransmissionEndpointFailure] = []

        for endpoint in endpoints {
            do {
                try await TransmissionClient(config: endpoint.config).add(magnet: magnet)
                return
            } catch {
                failures.append(TransmissionEndpointFailure(endpointName: endpoint.name, error: error))
            }
        }

        throw TransmissionSendError.allEndpointsFailed(failures)
    }

    private func normalizedTransmissionRPCURL(from rawValue: String) -> URL? {
        let withScheme: String
        if rawValue.contains("://") {
            withScheme = rawValue
        } else {
            withScheme = "http://" + rawValue
        }

        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            return nil
        }

        let path = components.path.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty || path == "/" {
            components.path = "/transmission/rpc"
        }

        return components.url
    }

    private func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
    }

    private func transmissionErrorPresentation(
        for error: Error,
        phase: TransmissionSendPhase
    ) -> (title: String, message: String) {
        switch phase {
        case .fetchingMagnet:
            return ("Magnet Error", magnetFetchErrorMessage(for: error))
        case .connecting:
            return ("Transmission Error", transmissionConnectionErrorMessage(for: error))
        case .idle:
            if error is TransmissionError || error is URLError {
                return ("Transmission Error", transmissionConnectionErrorMessage(for: error))
            }
            return ("Magnet Error", magnetFetchErrorMessage(for: error))
        }
    }

    private func magnetFetchErrorMessage(for error: Error) -> String {
        if let providerError = error as? ProviderError {
            switch providerError {
            case .timedOut(let provider, let seconds):
                return "Can't fetch magnet from \(provider): the request timed out after \(seconds)s."
            case .badStatus(let provider, let status):
                return "Can't fetch magnet from \(provider): the detail page returned HTTP \(status)."
            case .accessBlocked(let provider, let reason):
                return "Can't fetch magnet from \(provider): \(reason)."
            case .missingURLTemplate(let provider):
                return "Can't fetch magnet from \(provider): the provider is missing a search URL."
            case .invalidURL(let url):
                return "Can't fetch magnet: invalid URL \(url)."
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "Can't fetch magnet: the request timed out."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet, .networkConnectionLost:
                return "Can't fetch magnet: network connection failed."
            default:
                return "Can't fetch magnet: \(urlError.localizedDescription)"
            }
        }

        if let localizedError = error as? LocalizedError, let message = localizedError.errorDescription {
            return "Can't fetch magnet: \(message)"
        }

        return "Can't fetch magnet for the selected result."
    }

    private func transmissionConnectionErrorMessage(for error: Error) -> String {
        if let sendError = error as? TransmissionSendError {
            switch sendError {
            case .allEndpointsFailed(let failures):
                let details = failures
                    .map { "\($0.endpointName): \(transmissionConnectionFailureSummary(for: $0.error))." }
                    .joined(separator: "\n")
                let suggestion = failures.contains { $0.endpointName == "Tailscale RPC" }
                    ? "\n\nCheck that Tailscale is connected on both devices, your Mac is awake, and Transmission remote access is enabled."
                    : ""
                return "Tried all configured Transmission endpoints:\n\(details)\(suggestion)"
            }
        }

        if let transmissionError = error as? TransmissionError {
            switch transmissionError {
            case .missingSessionID:
                return "Can't connect to Transmission: no session ID was returned."
            case .badStatus(let status):
                if status == 401 || status == 403 {
                    return "Can't connect to Transmission: authentication failed."
                }
                return "Can't connect to Transmission: the RPC endpoint returned HTTP \(status)."
            case .rpcFailure(let message):
                return "Transmission rejected the torrent: \(message)."
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .userAuthenticationRequired:
                return "Can't connect to Transmission: authentication is required."
            case .timedOut:
                return "Can't connect to Transmission: the connection timed out."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet, .networkConnectionLost:
                return "Can't connect to Transmission: the server could not be reached."
            default:
                return "Can't connect to Transmission: \(urlError.localizedDescription)"
            }
        }

        if let localizedError = error as? LocalizedError, let message = localizedError.errorDescription {
            return "Can't connect to Transmission: \(message)"
        }

        return "Can't connect to Transmission."
    }

    private func transmissionConnectionFailureSummary(for error: Error) -> String {
        if let transmissionError = error as? TransmissionError {
            switch transmissionError {
            case .missingSessionID:
                return "no session ID was returned"
            case .badStatus(let status):
                if status == 401 || status == 403 {
                    return "authentication failed"
                }
                return "the RPC endpoint returned HTTP \(status)"
            case .rpcFailure(let message):
                return "Transmission rejected the torrent: \(message)"
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .userAuthenticationRequired:
                return "authentication is required"
            case .timedOut:
                return "the connection timed out"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet, .networkConnectionLost:
                return "the server could not be reached"
            default:
                return urlError.localizedDescription
            }
        }

        if let localizedError = error as? LocalizedError, let message = localizedError.errorDescription {
            return message
        }

        return "unknown connection error"
    }

    private func dedupedResults(_ results: [SearchResult]) -> [SearchResult] {
        let byHash = dedupeByInfoHash(results)
        return dedupeByNormalizedTitle(byHash)
    }

    private func dedupeByInfoHash(_ results: [SearchResult]) -> [SearchResult] {
        var output: [SearchResult] = []
        output.reserveCapacity(results.count)

        var indexByHash: [String: Int] = [:]
        indexByHash.reserveCapacity(results.count)

        for result in results {
            guard let hash = result.magnet?.infoHashFromMagnet?.lowercased(), !hash.isEmpty else {
                output.append(result)
                continue
            }

            if let existingIndex = indexByHash[hash] {
                output[existingIndex] = preferredDuplicate(between: output[existingIndex], and: result)
            } else {
                indexByHash[hash] = output.count
                output.append(result)
            }
        }

        return output
    }

    private func dedupeByNormalizedTitle(_ results: [SearchResult]) -> [SearchResult] {
        var output: [SearchResult] = []
        output.reserveCapacity(results.count)

        var indexByTitle: [String: Int] = [:]
        indexByTitle.reserveCapacity(results.count)

        for result in results {
            let key = result.title.normalizedDedupeKey
            guard !key.isEmpty else {
                output.append(result)
                continue
            }

            if let existingIndex = indexByTitle[key] {
                output[existingIndex] = preferredDuplicate(between: output[existingIndex], and: result)
            } else {
                indexByTitle[key] = output.count
                output.append(result)
            }
        }

        return output
    }

    private func preferredDuplicate(between lhs: SearchResult, and rhs: SearchResult) -> SearchResult {
        let lhsHasMagnet = lhs.magnet?.isEmpty == false
        let rhsHasMagnet = rhs.magnet?.isEmpty == false

        if lhsHasMagnet != rhsHasMagnet {
            return lhsHasMagnet ? lhs : rhs
        }

        if lhs.score != rhs.score {
            return lhs.score >= rhs.score ? lhs : rhs
        }

        let lhsSeeders = lhs.seeders ?? 0
        let rhsSeeders = rhs.seeders ?? 0
        if lhsSeeders != rhsSeeders {
            return lhsSeeders >= rhsSeeders ? lhs : rhs
        }

        return lhs
    }
}

private struct MagnetPrefetchCandidate {
    let key: String
    let result: SearchResult
}

private struct DetailPrefetchCandidate {
    let key: String
    let result: SearchResult
}

private enum DetailMetadataFetchStatus: Hashable {
    case notStarted
    case fetching
    case fetched
    case checkedNoMetadata
    case failed(String)
}

private enum TransmissionConfigurationError: LocalizedError {
    case missingRPCURL
    case invalidHomeRPCURL
    case invalidTailscaleRPCURL
    case incompleteCredentials
    case missingMagnet

    var errorDescription: String? {
        switch self {
        case .missingRPCURL:
            return "Enter a home RPC URL, a Tailscale RPC URL, or both."
        case .invalidHomeRPCURL:
            return "The home Transmission RPC URL is invalid."
        case .invalidTailscaleRPCURL:
            return "The Tailscale Transmission RPC URL is invalid."
        case .incompleteCredentials:
            return "Enter both a username and password, or leave both blank."
        case .missingMagnet:
            return "No magnet is available for the selected result."
        }
    }
}

private enum TransmissionSendPhase {
    case idle
    case fetchingMagnet
    case connecting
}

private struct TransmissionEndpoint {
    let name: String
    let config: TransmissionConfig

    func priority(preferTailscale: Bool) -> Int {
        if preferTailscale {
            return name == "Tailscale RPC" ? 0 : 1
        }
        return name == "Home RPC" ? 0 : 1
    }
}

private struct TransmissionEndpointFailure {
    let endpointName: String
    let error: Error
}

private enum TransmissionSendError: LocalizedError {
    case allEndpointsFailed([TransmissionEndpointFailure])
}

private struct SearchProgressView: View {
    let foundCount: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let dots = animatedDots(for: context.date)
            VStack(spacing: 8) {
                ProgressView("Searching providers\(dots)")
                Text(releaseCountText(foundCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func animatedDots(for date: Date) -> String {
        let phase = Int(date.timeIntervalSinceReferenceDate * 2).quotientAndRemainder(dividingBy: 3).remainder + 1
        return String(repeating: ".", count: phase)
    }

    private func releaseCountText(_ count: Int) -> String {
        count == 1 ? "1 result found" : "\(count) results found"
    }
}

private struct SearchProgressHeader: View {
    let foundCount: Int

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    Text("Searching providers\(animatedDots(for: context.date))")
                }
                .font(.callout.weight(.medium))
                Text(releaseCountText(foundCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func animatedDots(for date: Date) -> String {
        let phase = Int(date.timeIntervalSinceReferenceDate * 2).quotientAndRemainder(dividingBy: 3).remainder + 1
        return String(repeating: ".", count: phase)
    }

    private func releaseCountText(_ count: Int) -> String {
        count == 1 ? "1 result found" : "\(count) results found"
    }
}

// MARK: - Models
struct SearchResult: Identifiable, Hashable {
    let id: UUID
    let raw: TorrentSearchResult
    let title: String
    let provider: String
    let source: String
    let resolution: String
    let dynamicRange: String
    let codec: String
    let audio: String
    let imax: Bool
    let size: String?
    let seeders: Int?
    let leechers: Int?
    let magnet: String?
    let detailURL: URL?
    let score: Int
    let scoreNotes: [String]
    let detailMetadata: String?
    let detailSpecs: TorrentDetailSpecs?

    init(ranked: RankedTorrentResult) {
        id = ranked.id
        raw = ranked.raw
        title = ranked.raw.title
        provider = ranked.raw.provider
        source = ParserRankerAdapter.displayName(for: ranked.parsed.sourceType)
        resolution = ParserRankerAdapter.displayName(for: ranked.parsed.resolution)
        dynamicRange = ParserRankerAdapter.displayName(for: ranked.parsed.dynamicRange)
        codec = ParserRankerAdapter.displayName(for: ranked.parsed.videoCodec)
        audio = ParserRankerAdapter.audioSummary(codec: ranked.parsed.audioCodec, channels: ranked.parsed.channels, atmos: ranked.parsed.atmos)
        imax = ranked.parsed.imax
        size = ranked.raw.size
        seeders = ranked.raw.seeders
        leechers = ranked.raw.leechers
        magnet = ranked.raw.magnet
        detailURL = ranked.raw.detailURL
        score = ranked.score
        scoreNotes = ranked.notes
        detailMetadata = ranked.raw.detailMetadata
        detailSpecs = ranked.raw.detailSpecs
    }

    func withMagnet(_ magnet: String) -> SearchResult {
        SearchResult(
            id: id,
            raw: TorrentSearchResult(
                id: raw.id,
                title: raw.title,
                detailMetadata: raw.detailMetadata,
                detailSpecs: raw.detailSpecs,
                magnet: magnet,
                detailURL: raw.detailURL,
                seeders: raw.seeders,
                leechers: raw.leechers,
                provider: raw.provider,
                size: raw.size
            ),
            title: title,
            provider: provider,
            source: source,
            resolution: resolution,
            dynamicRange: dynamicRange,
            codec: codec,
            audio: audio,
            imax: imax,
            size: size,
            seeders: seeders,
            leechers: leechers,
            magnet: magnet,
            detailURL: detailURL,
            score: score,
            scoreNotes: scoreNotes,
            detailMetadata: detailMetadata,
            detailSpecs: detailSpecs
        )
    }

    func withDetailMetadata(_ metadata: TorrentDetailMetadata) -> SearchResult {
        let updatedRaw = TorrentSearchResult(
            id: raw.id,
            title: raw.title,
            detailMetadata: metadata.text ?? raw.detailMetadata,
            detailSpecs: metadata.specs ?? raw.detailSpecs,
            magnet: metadata.magnet ?? raw.magnet,
            detailURL: raw.detailURL,
            seeders: raw.seeders,
            leechers: raw.leechers,
            provider: raw.provider,
            size: raw.size
        )
        return SearchResult(ranked: TorrentRanker.score(updatedRaw))
    }

    private init(
        id: UUID,
        raw: TorrentSearchResult,
        title: String,
        provider: String,
        source: String,
        resolution: String,
        dynamicRange: String,
        codec: String,
        audio: String,
        imax: Bool,
        size: String?,
        seeders: Int?,
        leechers: Int?,
        magnet: String?,
        detailURL: URL?,
        score: Int,
        scoreNotes: [String],
        detailMetadata: String?,
        detailSpecs: TorrentDetailSpecs?
    ) {
        self.id = id
        self.raw = raw
        self.title = title
        self.provider = provider
        self.source = source
        self.resolution = resolution
        self.dynamicRange = dynamicRange
        self.codec = codec
        self.audio = audio
        self.imax = imax
        self.size = size
        self.seeders = seeders
        self.leechers = leechers
        self.magnet = magnet
        self.detailURL = detailURL
        self.score = score
        self.scoreNotes = scoreNotes
        self.detailMetadata = detailMetadata
        self.detailSpecs = detailSpecs
    }
}

// MARK: - Parser + Ranker adapter (uses core)
enum ParserRankerAdapter {
    struct ParsedMeta {
        var source: String
        var resolution: String
        var dynamicRange: String
        var audio: String
        var channels: String?
        var atmos: Bool
    }

    static func parseAndScore(releaseName: String) -> (ParsedMeta, Int) {
        // Use the real core
        let parsed = ReleaseParser.parse(releaseName)
        let mockRaw = TorrentSearchResult(
            title: releaseName,
            magnet: nil,
            detailURL: nil,
            seeders: 10, // tie-break only, not used in score
            leechers: 5,
            provider: "Sample"
        )
        let ranked = TorrentRanker.score(mockRaw)

        let meta = ParsedMeta(
            source: displayName(for: parsed.sourceType),
            resolution: displayName(for: parsed.resolution),
            dynamicRange: displayName(for: parsed.dynamicRange),
            audio: displayName(for: parsed.audioCodec, atmos: parsed.atmos),
            channels: channelsString(parsed.channels),
            atmos: parsed.atmos
        )
        return (meta, ranked.score)
    }

    static func channelsString(_ c: ChannelLayout) -> String? {
        switch c {
        case .sevenOne: return "7.1"
        case .fiveOne: return "5.1"
        case .twoZero: return "2.0"
        case .mono: return "Mono"
        case .unknown: return nil
        }
    }

    static func displayName(for source: SourceType) -> String {
        switch source {
        case .remux: return "Remux"
        case .bluray: return "BluRay"
        case .webdl: return "WEB-DL"
        case .webrip: return "WEBRip"
        case .dvd: return "DVD"
        case .hdtv: return "HDTV"
        case .cam: return "CAM"
        case .unknown: return "Unknown"
        }
    }

    static func displayName(for resolution: Resolution) -> String {
        switch resolution {
        case .p2160: return "4K"
        case .p1080: return "1080p"
        case .likely1080: return "Likely 1080p"
        case .p720: return "720p"
        case .sd: return "SD"
        case .unknown: return "Unknown"
        }
    }

    static func displayName(for dr: DynamicRange) -> String {
        switch dr {
        case .dolbyVision: return "Dolby Vision"
        case .hdr10plus: return "HDR10+"
        case .hdr10: return "HDR10"
        case .hdr: return "HDR"
        case .likelyHDR: return "Likely HDR"
        case .sdr: return "SDR"
        case .unknown: return "Unknown"
        }
    }

    static func displayName(for videoCodec: VideoCodec) -> String {
        switch videoCodec {
        case .hevc: return "HEVC"
        case .avc: return "h264"
        case .av1: return "AV1"
        case .unknown: return "Unknown"
        }
    }

    static func displayName(for ac: AudioCodec, atmos: Bool) -> String {
        let base: String
        switch ac {
        case .truehd: base = "TrueHD"
        case .dtsHDMA: base = "DTS MA"
        case .pcm: base = "PCM"
        case .ddp: base = "DDP"
        case .dts: base = "DTS"
        case .dd: base = "DD"
        case .aac: base = "AAC"
        case .unknown: base = "Unknown"
        }
        return base
    }

    static func audioSummary(codec: AudioCodec, channels: ChannelLayout, atmos: Bool) -> String {
        var parts: [String] = [displayName(for: codec, atmos: false)]
        if let channelText = channelsString(channels) {
            parts.append(channelText)
        }
        if atmos {
            parts.append("Atmos")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Views
private struct SearchBar: View {
    @Binding var query: String
    let suggestions: [MovieCatalogSuggestion]
    var onSuggestionSelected: (MovieCatalogSuggestion) -> Void
    var onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ZStack(alignment: .trailing) {
                    TextField("Search movies", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .padding(.trailing, query.isEmpty ? 0 : 28)
                        .submitLabel(.search)
                        .onSubmit(onSubmit)

                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 10)
                    }
                }
                Button(action: onSubmit) {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(suggestions) { suggestion in
                        Button {
                            onSuggestionSelected(suggestion)
                        } label: {
                            HStack {
                                Text(suggestion.displayTitle)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if suggestion.id != suggestions.last?.id {
                            Divider()
                        }
                    }
                }
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )
            }
        }
    }
}

private struct MetaChip: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .lineLimit(1)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    init(spacing: CGFloat = 8, lineSpacing: CGFloat = 4) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        y += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct ScoreBadge: View {
    let score: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(scoreColor)
                .frame(width: 44, height: 44)
            Text("\(score)")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .accessibilityLabel("Score \(score)")
    }

    private var scoreColor: Color {
        switch score {
        case 80...: return .green
        case 60..<80: return .orange
        default: return .red
        }
    }
}

// Removed ChipsFlow and HeightPreferenceKey structs as requested

private struct ResultDetailView: View {
    let result: SearchResult
    let metadataStatus: DetailMetadataFetchStatus

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(prettifiedTitle(result.title))
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        ScoreBadge(score: result.score)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.provider)
                                .font(.headline)
                            if let detailURL = result.detailURL {
                                Link(detailURL.host ?? detailURL.absoluteString, destination: detailURL)
                                    .font(.callout)
                            }
                        }
                    }
                }

                FlowLayout(spacing: 8, lineSpacing: 6) {
                    Tag("Source", value: result.source)
                    Tag("Resolution", value: result.resolution)
                    Tag("Range", value: result.dynamicRange)
                    Tag("Video", value: result.codec)
                    Tag("Audio", value: result.audio)
                    if result.imax {
                        Tag("Format", value: "IMAX")
                    }
                    if let size = result.size, !size.isEmpty {
                        Tag("Size", value: size)
                    }
                    if let seeders = result.seeders {
                        Tag("Seeders", value: "\(seeders)")
                    }
                    if let leechers = result.leechers {
                        Tag("Leechers", value: "\(leechers)")
                    }
                }

                if !result.scoreNotes.isEmpty {
                    DetailSection(title: "Score") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(result.scoreNotes, id: \.self) { note in
                                Text(note)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                DetailSection(title: "Detail Page Specs") {
                    if let specs = result.detailSpecs, specs.hasDisplayableFields {
                        DetailSpecList(specs: specs)
                    } else if result.detailURL != nil {
                        metadataStatusView
                    } else {
                        Text("This result does not include a detail page URL.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420, minHeight: 420)
    }

    private func prettifiedTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    @ViewBuilder
    private var metadataStatusView: some View {
        switch metadataStatus {
        case .notStarted:
            Text("Metadata fetch is queued for this result.")
                .foregroundStyle(.secondary)
        case .fetching:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Fetching and parsing the detail page...")
                    .foregroundStyle(.secondary)
            }
        case .fetched:
            Text("Checked the detail page, but no requested specs were found.")
                .foregroundStyle(.secondary)
        case .checkedNoMetadata:
            Text("Checked the detail page, but no requested specs were found.")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text("Detail page fetch failed: \(message)")
                .foregroundStyle(.secondary)
        }
    }
}

private struct DetailSpecList: View {
    let specs: TorrentDetailSpecs

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.label) { row in
                DetailSpecRow(label: row.label, value: row.value, isCalculated: row.isCalculated)
            }
        }
        .textSelection(.enabled)
    }

    private var rows: [(label: String, value: String, isCalculated: Bool)] {
        var rows: [(String, String, Bool)] = []
        append("Full torrent name", specs.fullTorrentName, field: "fullTorrentName", to: &rows)
        append("Video bitrate", specs.videoBitrate, field: "videoBitrate", to: &rows)
        append("Resolution width", specs.resolutionWidth, field: "resolutionWidth", to: &rows)
        append("Resolution height", specs.resolutionHeight, field: "resolutionHeight", to: &rows)
        append("Frame rate", specs.frameRate, field: "frameRate", to: &rows)
        append("Bit depth", specs.bitDepth, field: "bitDepth", to: &rows)
        append("CRF", specs.crf, field: "crf", to: &rows)
        append("Preset", specs.preset, field: "preset", to: &rows)
        append("Encoding passes", specs.encodingPasses, field: "encodingPasses", to: &rows)
        append("Color gamut", specs.colorGamut, field: "colorGamut", to: &rows)
        append("Dolby Vision profile", specs.dolbyVisionProfile, field: "dolbyVisionProfile", to: &rows)
        append("Aspect ratio", specs.aspectRatio, field: "aspectRatio", to: &rows)
        append("Best English audio bitrate", specs.bestEnglishAudioBitrate, field: "bestEnglishAudioBitrate", to: &rows)
        append("Best English audio sample rate", specs.bestEnglishAudioSampleRate, field: "bestEnglishAudioSampleRate", to: &rows)
        if !specs.allAudioTrackBitrates.isEmpty {
            rows.append(("All audio track bitrates", specs.allAudioTrackBitrates.joined(separator: "\n"), specs.isCalculated("allAudioTrackBitrates")))
        }
        append("Total audio bitrate", specs.totalAudioTrackBitrate, field: "totalAudioTrackBitrate", to: &rows)
        append("Overall bitrate", specs.overallBitrate, field: "overallBitrate", to: &rows)
        append("Calculated video bitrate", specs.calculatedVideoBitrate, field: "calculatedVideoBitrate", to: &rows)
        append("Runtime", specs.runtime, field: "runtime", to: &rows)
        return rows
    }

    private func append(_ label: String, _ value: String?, field: String, to rows: inout [(String, String, Bool)]) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return }
        rows.append((label, value, specs.isCalculated(field)))
    }
}

private struct DetailSpecRow: View {
    let label: String
    let value: String
    let isCalculated: Bool

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(isCalculated ? .orange : .secondary)
                    .frame(width: 190, alignment: .leading)
                Text(value)
                    .font(.callout)
                    .foregroundStyle(isCalculated ? .orange : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct Tag: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label + ":")
                .foregroundStyle(.secondary)
            Text(value)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
    }
}

private struct ErrorStateView: View {
    let message: String
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
            Button("Try Again", action: retry)
        }
        .padding()
    }
}

private struct EmptyResultsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("Search for a movie or show to see ranked results")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

private struct ResultsListView: View {
    let results: [SearchResult]
    @Binding var selected: SearchResult?
    @Binding var presentedResult: SearchResult?

    var body: some View {
        List(results) { result in
            ResultRow(result: result) {
                selected = result
                presentedResult = result
            }
            .listRowBackground(selected?.id == result.id ? Color.accentColor.opacity(0.1) : Color.clear)
        }
        .listStyle(.plain)
        .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
        .modifier(ContentMarginsZero())
    }
}

private struct ContentMarginsZero: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            content.contentMargins(.all, 0)
        } else {
            content
        }
    }
}

private struct ResultRow: View {
    let result: SearchResult
    var onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                ScoreBadge(score: result.score)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(prettifiedTitle(result.title))
                        .font(.headline)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .allowsTightening(false)
                    FlowLayout(spacing: 8, lineSpacing: 4) {
                        MetaChip(text: result.source, systemImage: "film")
                        MetaChip(text: result.resolution, systemImage: "rectangle.3.group")
                        MetaChip(text: result.dynamicRange, systemImage: "circle.lefthalf.filled")
                        MetaChip(text: result.codec, systemImage: "play.rectangle")
                        MetaChip(text: result.audio, systemImage: "speaker.wave.2")
                        if result.imax {
                            MetaChip(text: "IMAX", systemImage: "rectangle.expand.vertical")
                        }
                    }
                    if result.seeders != nil || result.leechers != nil || (result.size?.isEmpty == false) {
                        HStack(spacing: 12) {
                            MetaChip(text: result.provider, systemImage: "network")
                            if let size = result.size, !size.isEmpty {
                                MetaChip(text: size, systemImage: "externaldrive")
                            }
                            if let seeders = result.seeders {
                                MetaChip(text: "\(seeders)", systemImage: "arrow.up.circle")
                            }
                            if let leechers = result.leechers {
                                MetaChip(text: "\(leechers)", systemImage: "arrow.down.circle")
                            }
                        }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .padding(.vertical, 4)
    }
    
    private func prettifiedTitle(_ title: String) -> String {
        var s = title.replacingOccurrences(of: ".", with: " ")
        s = s.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: "-", with: "-") // keep hyphen as a token but avoid mid-word joiners
        // Collapse multiple spaces
        let parts = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }
}

fileprivate struct NavigationViewWrapper<Content: View>: View {
    let content: () -> Content

    var body: some View {
        NavigationStack {
            content()
        }
    }
}

private struct TransmissionSettingsView: View {
    @Binding var rpcURL: String
    @Binding var tailscaleRPCURL: String
    @Binding var preferTailscale: Bool
    @Binding var username: String
    @Binding var password: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Endpoints") {
                    TextField("Home RPC URL (Optional)", text: $rpcURL)
#if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#endif
                    TextField("Tailscale RPC URL (Optional)", text: $tailscaleRPCURL)
#if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#endif
                    Toggle("Prefer Tailscale First", isOn: $preferTailscale)
                }

                Section("Authentication") {
                    TextField("Username (Optional)", text: $username)
#if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#endif
                    SecureField("Password (Optional)", text: $password)
                }

                Section("Tip") {
                    Text("Use your LAN address in Home RPC URL and your Tailscale IP or MagicDNS name in Tailscale RPC URL. If you enter only a host like 100.64.0.10:9091, the app will use http and append /transmission/rpc automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Transmission")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 240)
    }
}

#if os(iOS)
private extension UIApplication {
    func endEditing() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
#endif

#Preview("macOS Wide Preview") {
#if os(macOS)
    // Seeded preview with a wider frame so rows don't truncate vertically
    ContentView_PreviewWrapper()
        .frame(width: 900, height: 600)
#else
    ContentView()
#endif
}
// Helper to preview ContentView with seeded results on macOS
private struct ContentView_PreviewWrapper: View {
    var body: some View {
        ContentView()
            .onAppear { /* no-op; ContentView drives its own state */ }
    }
}

#Preview("iOS Preview") {
#if os(iOS)
    ContentView()
#endif
}
