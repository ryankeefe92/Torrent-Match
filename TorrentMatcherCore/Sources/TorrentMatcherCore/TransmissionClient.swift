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
        let sessionID = try await fetchSessionID()
        var request = URLRequest(url: config.rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sessionID, forHTTPHeaderField: "X-Transmission-Session-Id")
        applyAuth(to: &request)

        let payload: [String: Any] = [
            "method": "torrent-add",
            "arguments": ["filename": magnet]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TransmissionError.badStatus(http.statusCode)
        }
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

    public var errorDescription: String? {
        switch self {
        case .missingSessionID: return "Transmission session ID was not returned."
        case .badStatus(let status): return "Transmission returned HTTP status \(status)."
        }
    }
}
