import Foundation

public struct TransmissionConfig: Hashable, Sendable {
    public let rpcURL: URL
    public let username: String?
    public let password: String?

    public init(rpcURL: URL, username: String? = nil, password: String? = nil) {
        self.rpcURL = rpcURL
        self.username = username
        self.password = password
    }
}

public final class TransmissionClient: @unchecked Sendable {
    private let config: TransmissionConfig
    private let session: URLSession

    public init(config: TransmissionConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func add(magnet: String) async throws {
        _ = try await addReturningResult(magnet: magnet)
    }

    public func addReturningResult(magnet: String) async throws -> TransmissionAddResult {
        let payload: [String: Any] = [
            "method": "torrent-add",
            "arguments": ["filename": magnet]
        ]
        let response = try await send(payload, decoding: TransmissionTorrentAddResponse.self)
        guard response.result == "success" else {
            throw TransmissionError.rpcFailure(response.result)
        }
        if let added = response.arguments?.torrentAdded {
            return TransmissionAddResult(
                disposition: .added,
                torrentID: added.id,
                torrentName: added.name,
                infoHash: added.hashString
            )
        }
        if let duplicate = response.arguments?.torrentDuplicate {
            return TransmissionAddResult(
                disposition: .duplicate,
                torrentID: duplicate.id,
                torrentName: duplicate.name,
                infoHash: duplicate.hashString
            )
        }
        throw TransmissionError.rpcFailure("torrent-add returned no added or duplicate torrent")
    }

    public func torrents() async throws -> [TransmissionTorrent] {
        let fields = [
            "id",
            "name",
            "percentDone",
            "status",
            "rateDownload",
            "peersSendingToUs",
            "peersGettingFromUs",
            "bandwidthPriority",
            "trackerStats"
        ]
        let payload: [String: Any] = [
            "method": "torrent-get",
            "arguments": ["fields": fields]
        ]
        let response = try await send(payload, decoding: TransmissionTorrentGetResponse.self)
        guard response.result == "success" else {
            throw TransmissionError.rpcFailure(response.result)
        }
        return response.arguments.torrents
    }

    public func start(ids: [Int]) async throws {
        try await perform(method: "torrent-start", ids: ids)
    }

    public func stop(ids: [Int]) async throws {
        try await perform(method: "torrent-stop", ids: ids)
    }

    public func remove(ids: [Int], deleteLocalData: Bool = true) async throws {
        let payload: [String: Any] = [
            "method": "torrent-remove",
            "arguments": [
                "ids": ids,
                "delete-local-data": deleteLocalData
            ]
        ]
        let response = try await send(payload, decoding: TransmissionRPCResponse.self)
        guard response.result == "success" else {
            throw TransmissionError.rpcFailure(response.result)
        }
    }

    public func setPriority(_ priority: TransmissionTorrentPriority, ids: [Int]) async throws {
        let payload: [String: Any] = [
            "method": "torrent-set",
            "arguments": [
                "ids": ids,
                "bandwidthPriority": priority.rawValue
            ]
        ]
        let response = try await send(payload, decoding: TransmissionRPCResponse.self)
        guard response.result == "success" else {
            throw TransmissionError.rpcFailure(response.result)
        }
    }

    private func perform(method: String, ids: [Int]) async throws {
        let payload: [String: Any] = [
            "method": method,
            "arguments": ["ids": ids]
        ]
        let response = try await send(payload, decoding: TransmissionRPCResponse.self)
        guard response.result == "success" else {
            throw TransmissionError.rpcFailure(response.result)
        }
    }

    private func send<Response: Decodable>(
        _ payload: [String: Any],
        decoding responseType: Response.Type
    ) async throws -> Response {
        let sessionID = try await fetchSessionID()
        var request = URLRequest(url: config.rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sessionID, forHTTPHeaderField: "X-Transmission-Session-Id")
        applyAuth(to: &request)

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TransmissionError.badStatus(http.statusCode)
        }
        return try JSONDecoder().decode(responseType, from: data)
    }

    private func fetchSessionID() async throws -> String {
        var request = URLRequest(url: config.rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        applyAuth(to: &request)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TransmissionError.missingSessionID }
        if let id = http.value(forHTTPHeaderField: "X-Transmission-Session-Id") { return id }
        if !(200..<300).contains(http.statusCode) {
            throw TransmissionError.badStatus(http.statusCode)
        }
        throw TransmissionError.missingSessionID
    }

    private func applyAuth(to request: inout URLRequest) {
        guard let username = config.username, let password = config.password else { return }
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    }
}

public enum TransmissionError: Error, LocalizedError, Sendable {
    case missingSessionID
    case badStatus(Int)
    case rpcFailure(String)

    public var errorDescription: String? {
        switch self {
        case .missingSessionID: return "Transmission session ID was not returned."
        case .badStatus(let status): return "Transmission returned HTTP status \(status)."
        case .rpcFailure(let message): return "Transmission RPC failed: \(message)."
        }
    }
}

private struct TransmissionRPCResponse: Decodable {
    let result: String
}

public enum TransmissionTorrentPriority: Int, CaseIterable, Sendable {
    case low = -1
    case normal = 0
    case high = 1
}

public struct TransmissionAddResult: Hashable, Sendable {
    public enum Disposition: String, Hashable, Sendable {
        case added
        case duplicate
    }

    public let disposition: Disposition
    public let torrentID: Int
    public let torrentName: String
    public let infoHash: String

    public init(
        disposition: Disposition,
        torrentID: Int,
        torrentName: String,
        infoHash: String
    ) {
        self.disposition = disposition
        self.torrentID = torrentID
        self.torrentName = torrentName
        self.infoHash = infoHash
    }

    public var wasAdded: Bool {
        disposition == .added
    }

    public var wasDuplicate: Bool {
        disposition == .duplicate
    }
}

public struct TransmissionTorrent: Identifiable, Hashable, Sendable, Decodable {
    public let id: Int
    public let name: String
    public let percentDone: Double
    public let status: Int
    public let rateDownload: Int
    public let peersSendingToUs: Int
    public let peersGettingFromUs: Int
    public let bandwidthPriority: Int
    public let trackerStats: [TransmissionTrackerStats]

    public var seeders: Int {
        trackerStats.reduce(0) { partial, stats in
            partial + max(stats.seederCount ?? 0, 0)
        }
    }

    public var leechers: Int {
        trackerStats.reduce(0) { partial, stats in
            partial + max(stats.leecherCount ?? 0, 0)
        }
    }

    public var priority: TransmissionTorrentPriority {
        TransmissionTorrentPriority(rawValue: bandwidthPriority) ?? .normal
    }

    public var isStopped: Bool {
        status == 0
    }

    public var isIncompleteDownload: Bool {
        percentDone < 1
    }
}

public struct TransmissionTrackerStats: Hashable, Sendable, Decodable {
    public let seederCount: Int?
    public let leecherCount: Int?
}

private struct TransmissionTorrentGetResponse: Decodable {
    let result: String
    let arguments: TransmissionTorrentGetArguments
}

private struct TransmissionTorrentGetArguments: Decodable {
    let torrents: [TransmissionTorrent]
}

private struct TransmissionTorrentAddResponse: Decodable {
    let result: String
    let arguments: TransmissionTorrentAddArguments?
}

private struct TransmissionTorrentAddArguments: Decodable {
    let torrentAdded: TransmissionTorrentAddSummary?
    let torrentDuplicate: TransmissionTorrentAddSummary?

    private enum CodingKeys: String, CodingKey {
        case torrentAdded = "torrent-added"
        case torrentDuplicate = "torrent-duplicate"
    }
}

private struct TransmissionTorrentAddSummary: Decodable {
    let id: Int
    let name: String
    let hashString: String
}
