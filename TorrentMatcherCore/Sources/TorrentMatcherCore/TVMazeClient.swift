import Foundation

public enum TVMazeClientError: Error, LocalizedError, Sendable {
    case invalidBaseURL
    case invalidShowID(Int)
    case badStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Unable to construct a TVmaze request URL."
        case .invalidShowID(let id):
            return "TVmaze show IDs must be positive, not \(id)."
        case .badStatus(let status):
            return "TVmaze returned HTTP status \(status)."
        }
    }
}

public final class TVMazeClient: @unchecked Sendable {
    private let session: URLSession
    private let baseURL: URL
    private let now: @Sendable () -> Date

    public init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.tvmaze.com")!,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.baseURL = baseURL
        self.now = now
    }

    public func searchShows(_ query: String) async throws -> [TVShowIdentity] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let url = try endpoint(
            path: ["search", "shows"],
            queryItems: [URLQueryItem(name: "q", value: trimmed)]
        )
        let payload: [TVMazeSearchPayload] = try await fetch(url)
        return payload
            .map(\.show)
            .map(Self.identity)
            .uniquedByShowID()
    }

    public func show(id: Int) async throws -> TVShowIdentity {
        guard id > 0 else {
            throw TVMazeClientError.invalidShowID(id)
        }
        let url = try endpoint(path: ["shows", String(id)])
        let payload: TVMazeShowPayload = try await fetch(url)
        return Self.identity(payload)
    }

    public func episodes(for showID: Int) async throws -> [TVEpisodeSchedule] {
        guard showID > 0 else {
            throw TVMazeClientError.invalidShowID(showID)
        }
        let url = try endpoint(path: ["shows", String(showID), "episodes"])
        let payload: [TVMazeEpisodePayload] = try await fetch(url)
        return Self.episodeSchedules(payload)
    }

    public func schedule(for showID: Int) async throws -> TVShowSchedule {
        guard showID > 0 else {
            throw TVMazeClientError.invalidShowID(showID)
        }
        let url = try endpoint(
            path: ["shows", String(showID)],
            queryItems: [URLQueryItem(name: "embed", value: "episodes")]
        )
        let payload: TVMazeShowPayload = try await fetch(url)
        let episodes: [TVEpisodeSchedule]
        if let embedded = payload.embedded?.episodes {
            episodes = Self.episodeSchedules(embedded)
        } else {
            episodes = try await self.episodes(for: showID)
        }
        return TVShowSchedule(show: Self.identity(payload), episodes: episodes)
    }

    public func subscriptionPlan(
        showID: Int,
        start: TVSubscriptionStartOption
    ) async throws -> TVSubscriptionBacklogPlan {
        let showSchedule = try await schedule(for: showID)
        return try TVSubscriptionPlanner.plan(
            schedule: showSchedule,
            start: start,
            asOf: now()
        )
    }

    private func endpoint(
        path: [String],
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        let pathURL = path.reduce(baseURL) { partial, component in
            partial.appendingPathComponent(component)
        }
        guard var components = URLComponents(
            url: pathURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw TVMazeClientError.invalidBaseURL
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw TVMazeClientError.invalidBaseURL
        }
        return url
    }

    private func fetch<Value: Decodable>(_ url: URL) async throws -> Value {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Torrent Match/1.0 (TV schedule lookup)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw TVMazeClientError.badStatus(http.statusCode)
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private static func identity(_ payload: TVMazeShowPayload) -> TVShowIdentity {
        TVShowIdentity(
            id: payload.id,
            name: payload.name,
            imdbID: payload.externals?.imdb?.nilIfBlank,
            premieredYear: Self.year(from: payload.premiered),
            status: TVShowStatus(tvMazeValue: payload.status),
            runtimeMinutes: payload.averageRuntime ?? payload.runtime
        )
    }

    private static func episodeSchedules(
        _ payload: [TVMazeEpisodePayload]
    ) -> [TVEpisodeSchedule] {
        payload.compactMap { episode in
            guard (episode.type?.lowercased() ?? "regular") == "regular",
                  episode.season > 0,
                  let episodeNumber = episode.number,
                  episodeNumber > 0 else {
                return nil
            }

            return TVEpisodeSchedule(
                number: TVEpisodeNumber(
                    season: episode.season,
                    episode: episodeNumber
                ),
                airstamp: Self.date(from: episode.airstamp)
            )
        }
    }

    private static func year(from premiered: String?) -> Int? {
        guard let premiered,
              let yearText = premiered.split(separator: "-", maxSplits: 1).first,
              yearText.count == 4 else {
            return nil
        }
        return Int(yearText)
    }

    private static func date(from rawValue: String?) -> Date? {
        guard let rawValue, !rawValue.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        if let date = fractional.date(from: rawValue) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: rawValue)
    }
}

private struct TVMazeSearchPayload: Decodable {
    let show: TVMazeShowPayload
}

private struct TVMazeShowPayload: Decodable {
    let id: Int
    let name: String
    let status: String?
    let premiered: String?
    let runtime: Int?
    let averageRuntime: Int?
    let externals: TVMazeExternalIDsPayload?
    let embedded: TVMazeEmbeddedPayload?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case premiered
        case runtime
        case averageRuntime
        case externals
        case embedded = "_embedded"
    }
}

private struct TVMazeEmbeddedPayload: Decodable {
    let episodes: [TVMazeEpisodePayload]
}

private struct TVMazeExternalIDsPayload: Decodable {
    let imdb: String?
}

private struct TVMazeEpisodePayload: Decodable {
    let season: Int
    let number: Int?
    let type: String?
    let airstamp: String?
}

private extension Array where Element == TVShowIdentity {
    func uniquedByShowID() -> [TVShowIdentity] {
        var seen: Set<Int> = []
        return filter { seen.insert($0.id).inserted }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
