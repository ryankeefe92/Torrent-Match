import Combine
import Foundation
import TorrentMatcherCore

struct TransmissionStoreSettings: Equatable, Sendable {
    var homeRPCURL: String
    var tailscaleRPCURL: String
    var preferTailscale: Bool
    var username: String
    var password: String

    init(
        homeRPCURL: String = "",
        tailscaleRPCURL: String = "",
        preferTailscale: Bool = false,
        username: String = "",
        password: String = ""
    ) {
        self.homeRPCURL = homeRPCURL
        self.tailscaleRPCURL = tailscaleRPCURL
        self.preferTailscale = preferTailscale
        self.username = username
        self.password = password
    }
}

struct TransmissionEndpointAttemptFailure: Hashable, Sendable {
    let endpointName: String
    let message: String
}

enum TransmissionStoreError: Error, LocalizedError {
    case missingRPCURL
    case invalidHomeRPCURL
    case invalidTailscaleRPCURL
    case incompleteCredentials
    case allEndpointsFailed([TransmissionEndpointAttemptFailure])

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
        case .allEndpointsFailed(let failures):
            let details = failures
                .map { "\($0.endpointName): \($0.message)" }
                .joined(separator: "\n")
            return "Tried all configured Transmission endpoints:\n\(details)"
        }
    }
}

@MainActor
final class TransmissionStore: ObservableObject {
    enum DefaultsKey {
        static let homeRPCURL = "transmission.rpcURL"
        static let tailscaleRPCURL = "transmission.tailscaleRPCURL"
        static let preferTailscale = "transmission.preferTailscale"
        static let username = "transmission.username"
        static let password = "transmission.password"
    }

    @Published private(set) var downloads: [TransmissionTorrent] = []
    @Published private(set) var allTorrents: [TransmissionTorrent] = []
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var isMonitoring: Bool = false
    @Published private(set) var activeEndpointName: String?
    @Published private(set) var lastErrorMessage: String?

    private let defaults: UserDefaults
    private let session: URLSession
    private var monitoringTask: Task<Void, Never>?
    private var monitoringID: UUID?

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
    }

    var settings: TransmissionStoreSettings {
        TransmissionStoreSettings(
            homeRPCURL: defaults.string(forKey: DefaultsKey.homeRPCURL) ?? "",
            tailscaleRPCURL: defaults.string(forKey: DefaultsKey.tailscaleRPCURL) ?? "",
            preferTailscale: defaults.bool(forKey: DefaultsKey.preferTailscale),
            username: defaults.string(forKey: DefaultsKey.username) ?? "",
            password: defaults.string(forKey: DefaultsKey.password) ?? ""
        )
    }

    var isConfigured: Bool {
        (try? makeEndpoints())?.isEmpty == false
    }

    func save(settings: TransmissionStoreSettings) {
        defaults.set(settings.homeRPCURL, forKey: DefaultsKey.homeRPCURL)
        defaults.set(settings.tailscaleRPCURL, forKey: DefaultsKey.tailscaleRPCURL)
        defaults.set(settings.preferTailscale, forKey: DefaultsKey.preferTailscale)
        defaults.set(settings.username, forKey: DefaultsKey.username)
        defaults.set(settings.password, forKey: DefaultsKey.password)
        objectWillChange.send()
    }

    func startMonitoring() {
        guard monitoringTask == nil else { return }

        let monitorID = UUID()
        monitoringID = monitorID
        isMonitoring = true
        monitoringTask = Task { [weak self] in
            await self?.monitorDownloads(id: monitorID)
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        monitoringID = nil
        isMonitoring = false
    }

    @discardableResult
    func refreshDownloads() async -> [TransmissionTorrent] {
        guard !isRefreshing else { return downloads }

        let endpoints: [TransmissionEndpoint]
        do {
            endpoints = try makeEndpoints()
        } catch {
            downloads = []
            allTorrents = []
            activeEndpointName = nil
            lastErrorMessage = Self.errorMessage(for: error)
            return downloads
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let fetchedTorrents = try await performRequest(using: endpoints) { client in
                try await client.torrents()
            }
            let wasIdle = downloads.isEmpty
            allTorrents = fetchedTorrents
            downloads = fetchedTorrents.filter(\.isIncompleteDownload)
            lastErrorMessage = nil
            if wasIdle, !downloads.isEmpty {
                accelerateActiveMonitoringIfNeeded()
            }
        } catch {
            downloads = []
            allTorrents = []
            activeEndpointName = nil
            lastErrorMessage = Self.errorMessage(for: error)
        }
        return downloads
    }

    @discardableResult
    func add(magnet: String) async throws -> TransmissionAddResult {
        let endpoints = try makeEndpoints()
        let result = try await performRequest(using: endpoints) { client in
            try await client.addReturningResult(magnet: magnet)
        }
        _ = await refreshDownloads()
        return result
    }

    func togglePause(for torrent: TransmissionTorrent) async throws {
        if torrent.isStopped {
            try await resume(torrentIDs: [torrent.id])
        } else {
            try await pause(torrentIDs: [torrent.id])
        }
    }

    func pause(torrentIDs: [Int]) async throws {
        try await performControl { client in
            try await client.stop(ids: torrentIDs)
        }
    }

    func resume(torrentIDs: [Int]) async throws {
        try await performControl { client in
            try await client.start(ids: torrentIDs)
        }
    }

    func remove(torrentIDs: [Int], deleteLocalData: Bool = true) async throws {
        try await performControl { client in
            try await client.remove(ids: torrentIDs, deleteLocalData: deleteLocalData)
        }
    }

    func setPriority(_ priority: TransmissionTorrentPriority, torrentIDs: [Int]) async throws {
        try await performControl { client in
            try await client.setPriority(priority, ids: torrentIDs)
        }
    }

    private func monitorDownloads(id: UUID) async {
        defer {
            if monitoringID == id {
                monitoringTask = nil
                monitoringID = nil
                isMonitoring = false
            }
        }

        _ = await refreshDownloads()
        while !Task.isCancelled {
            let interval: Duration = downloads.isEmpty ? .seconds(30) : .seconds(2)
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            _ = await refreshDownloads()
        }
    }

    private func accelerateActiveMonitoringIfNeeded() {
        guard isMonitoring else { return }
        stopMonitoring()
        startMonitoring()
    }

    private func performControl(
        operation: @escaping (TransmissionClient) async throws -> Void
    ) async throws {
        let endpoints = try makeEndpoints()
        try await performRequest(using: endpoints, operation: operation)
        _ = await refreshDownloads()
    }

    private func performRequest<Value>(
        using endpoints: [TransmissionEndpoint],
        operation: (TransmissionClient) async throws -> Value
    ) async throws -> Value {
        var failures: [TransmissionEndpointAttemptFailure] = []

        for endpoint in endpoints {
            do {
                let value = try await operation(
                    TransmissionClient(config: endpoint.config, session: session)
                )
                activeEndpointName = endpoint.name
                return value
            } catch {
                failures.append(
                    TransmissionEndpointAttemptFailure(
                        endpointName: endpoint.name,
                        message: Self.errorMessage(for: error)
                    )
                )
            }
        }

        throw TransmissionStoreError.allEndpointsFailed(failures)
    }

    private func makeEndpoints() throws -> [TransmissionEndpoint] {
        let currentSettings = settings
        let username = currentSettings.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = currentSettings.password.trimmingCharacters(in: .whitespacesAndNewlines)
        if (username.isEmpty && !password.isEmpty) || (!username.isEmpty && password.isEmpty) {
            throw TransmissionStoreError.incompleteCredentials
        }

        var endpoints: [TransmissionEndpoint] = []
        let homeText = currentSettings.homeRPCURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !homeText.isEmpty {
            guard let url = normalizedRPCURL(from: homeText) else {
                throw TransmissionStoreError.invalidHomeRPCURL
            }
            endpoints.append(
                TransmissionEndpoint(
                    name: "Home RPC",
                    config: makeConfig(url: url, username: username, password: password),
                    preferred: !currentSettings.preferTailscale
                )
            )
        }

        let tailscaleText = currentSettings.tailscaleRPCURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tailscaleText.isEmpty {
            guard let url = normalizedRPCURL(from: tailscaleText) else {
                throw TransmissionStoreError.invalidTailscaleRPCURL
            }
            endpoints.append(
                TransmissionEndpoint(
                    name: "Tailscale RPC",
                    config: makeConfig(url: url, username: username, password: password),
                    preferred: currentSettings.preferTailscale
                )
            )
        }

        guard !endpoints.isEmpty else {
            throw TransmissionStoreError.missingRPCURL
        }

        endpoints.sort { lhs, rhs in
            if lhs.preferred != rhs.preferred {
                return lhs.preferred
            }
            return lhs.name < rhs.name
        }

        var seenURLs: Set<URL> = []
        return endpoints.filter { seenURLs.insert($0.config.rpcURL).inserted }
    }

    private func makeConfig(url: URL, username: String, password: String) -> TransmissionConfig {
        TransmissionConfig(
            rpcURL: url,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password
        )
    }

    private func normalizedRPCURL(from rawValue: String) -> URL? {
        let valueWithScheme = rawValue.contains("://") ? rawValue : "http://\(rawValue)"
        guard var components = URLComponents(string: valueWithScheme),
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

    private static func errorMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let message = localizedError.errorDescription {
            return message
        }
        return error.localizedDescription
    }
}

private struct TransmissionEndpoint {
    let name: String
    let config: TransmissionConfig
    let preferred: Bool
}
