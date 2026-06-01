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

    // MARK: - Search / Results State
    @AppStorage("transmission.rpcURL") private var transmissionRPCURL: String = ""
    @AppStorage("transmission.username") private var transmissionUsername: String = ""
    @AppStorage("transmission.password") private var transmissionPassword: String = ""
    @State private var query: String = ""
    @State private var isSearching: Bool = false
    @State private var foundSoFar: Int = 0
    @State private var results: [SearchResult] = []
    @State private var errorMessage: String? = nil
    @State private var selected: SearchResult? = nil
    @State private var alertTitle: String = ""
    @State private var alertMessage: String? = nil
    @State private var transmissionSendPhase: TransmissionSendPhase = .idle
    @State private var isPresentingTransmissionSettings: Bool = false
    @State private var magnetPrefetchQueue: [MagnetPrefetchCandidate] = []
    @State private var activeMagnetPrefetchTasks: [String: Task<Void, Never>] = [:]
    @State private var attemptedMagnetPrefetchKeys: Set<String> = []
    @State private var selectedMagnetPrefetchTask: Task<Void, Never>? = nil

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
                SearchBar(query: $query, onSubmit: performSearch)
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
                                ResultsListView(results: sortedResults, selected: $selected)
                            }
                        }
                    } else if sortedResults.isEmpty {
                        EmptyResultsView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ResultsListView(results: sortedResults, selected: $selected)
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
                    username: $transmissionUsername,
                    password: $transmissionPassword
                )
            }
            .onChange(of: selected) { newValue in
                prefetchSelectedMagnet(for: newValue)
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
#if os(iOS)
        UIApplication.shared.endEditing()
#endif
        errorMessage = nil
        isSearching = true
        foundSoFar = 0
        results = []
        selected = nil
        cancelMagnetPrefetchPipeline()
        selectedMagnetPrefetchTask?.cancel()

        Task { @MainActor in
            let report = await searchService.searchAndRankReport(trimmed) { update in
                Task { @MainActor in
                    foundSoFar = update.foundSoFar
                    results = dedupedResults(update.results.map(SearchResult.init))
                    reconcileSelectedResult()
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
            prefetchMagnetsIfNeeded(from: results)
        }
    }

    private func sendSelectedToTransmission() {
        guard let selected else { return }
        let config: TransmissionConfig
        do {
            config = try makeTransmissionConfig()
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
                try await TransmissionClient(config: config).add(magnet: magnet)
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

    private func prefetchSelectedMagnet(for searchResult: SearchResult?) {
        selectedMagnetPrefetchTask?.cancel()
        guard let searchResult, shouldPrefetchMagnet(for: searchResult) else { return }

        selectedMagnetPrefetchTask = Task { @MainActor in
            await warmMagnet(for: searchResult)
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

    private func applyResolvedMagnet(_ magnet: String, to resultID: UUID) {
        guard let index = results.firstIndex(where: { $0.id == resultID }),
              results[index].magnet?.isEmpty != false else { return }
        let updated = results[index].withMagnet(magnet)
        results[index] = updated
        results = dedupedResults(results)
        if selected?.id == resultID {
            selected = results.first(where: { $0.id == updated.id })
        }
    }

    private func cancelMagnetPrefetchPipeline() {
        activeMagnetPrefetchTasks.values.forEach { $0.cancel() }
        activeMagnetPrefetchTasks.removeAll()
        magnetPrefetchQueue.removeAll()
        attemptedMagnetPrefetchKeys.removeAll()
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

    private func reconcileSelectedResult() {
        guard let selected else { return }
        if let refreshed = results.first(where: { $0.id == selected.id }) {
            self.selected = refreshed
            return
        }
        if let magnetHash = selected.magnet?.infoHashFromMagnet,
           let refreshed = results.first(where: { $0.magnet?.infoHashFromMagnet == magnetHash }) {
            self.selected = refreshed
        }
    }

    private func makeTransmissionConfig() throws -> TransmissionConfig {
        let rpcURLText = transmissionRPCURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rpcURLText.isEmpty else {
            throw TransmissionConfigurationError.missingRPCURL
        }

        let username = transmissionUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = transmissionPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        if (username.isEmpty && !password.isEmpty) || (!username.isEmpty && password.isEmpty) {
            throw TransmissionConfigurationError.incompleteCredentials
        }

        guard let rpcURL = normalizedTransmissionRPCURL(from: rpcURLText) else {
            throw TransmissionConfigurationError.invalidRPCURL
        }

        return TransmissionConfig(
            rpcURL: rpcURL,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password
        )
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

private enum TransmissionConfigurationError: LocalizedError {
    case missingRPCURL
    case invalidRPCURL
    case incompleteCredentials
    case missingMagnet

    var errorDescription: String? {
        switch self {
        case .missingRPCURL:
            return "Enter your Transmission RPC URL, for example http://YOUR-IP:9091/transmission/rpc."
        case .invalidRPCURL:
            return "The Transmission RPC URL is invalid."
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
    }

    func withMagnet(_ magnet: String) -> SearchResult {
        SearchResult(
            id: id,
            raw: TorrentSearchResult(
                id: raw.id,
                title: raw.title,
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
            score: score
        )
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
        score: Int
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
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .trailing) {
                TextField("Search movies or shows", text: $query)
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

// Removed ResultDetailView struct as requested

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

    var body: some View {
        List(results) { result in
            ResultRow(result: result) {
                selected = result
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
    @Binding var username: String
    @Binding var password: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("RPC URL", text: $rpcURL)
#if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#endif
                    TextField("Username (Optional)", text: $username)
#if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#endif
                    SecureField("Password (Optional)", text: $password)
                }

                Section("Tip") {
                    Text("If you enter only a host like 100.64.0.10:9091, the app will use http and append /transmission/rpc automatically.")
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
