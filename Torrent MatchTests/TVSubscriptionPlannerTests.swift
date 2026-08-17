import Foundation
import Testing
import TorrentMatcherCore

@Suite(.serialized)
struct TVSubscriptionPlannerTests {
    @Test func resolvesFirstCurrentNextAndManualAtExactAirtime() throws {
        let exactBoundary = instant("2026-07-30T00:30:00Z")
        let episodes = [
            scheduled(0, 1, "2026-07-30T00:20:00Z"),
            scheduled(1, 1, "2026-07-29T20:00:00-04:00"),
            scheduled(1, 2, "2026-07-30T09:30:00+09:00"),
            scheduled(1, 3, "2026-07-29T21:00:00-04:00")
        ]

        #expect(
            try TVSubscriptionPlanner.resolve(
                start: .first,
                episodes: episodes,
                asOf: exactBoundary
            ) == .episode(TVEpisodeNumber(season: 1, episode: 1))
        )
        #expect(
            try TVSubscriptionPlanner.resolve(
                start: .manual(TVEpisodeNumber(season: 4, episode: 7)),
                episodes: episodes,
                asOf: exactBoundary
            ) == .episode(TVEpisodeNumber(season: 4, episode: 7))
        )
        #expect(
            try TVSubscriptionPlanner.resolve(
                start: .current,
                episodes: episodes,
                asOf: exactBoundary
            ) == .episode(TVEpisodeNumber(season: 1, episode: 2))
        )
        #expect(
            try TVSubscriptionPlanner.resolve(
                start: .next,
                episodes: episodes,
                asOf: exactBoundary
            ) == .episode(TVEpisodeNumber(season: 1, episode: 3))
        )
    }

    @Test func currentExcludesSpecialsAndNextWaitsWhenUnannounced() throws {
        let now = instant("2026-07-30T00:50:00Z")
        let episodes = [
            scheduled(1, 1, "2026-07-30T00:00:00Z"),
            scheduled(1, 2, "2026-07-30T00:30:00Z"),
            scheduled(0, 12, "2026-07-30T00:45:00Z")
        ]

        #expect(
            try TVSubscriptionPlanner.resolve(
                start: .current,
                episodes: episodes,
                asOf: now
            ) == .episode(TVEpisodeNumber(season: 1, episode: 2))
        )
        #expect(
            try TVSubscriptionPlanner.resolve(
                start: .next,
                episodes: episodes,
                asOf: now
            ) == .waiting(.nextEpisodeUnannounced)
        )
        #expect(
            try TVSubscriptionPlanner.resolve(
                start: .current,
                episodes: episodes,
                asOf: instant("2026-07-29T23:59:59Z")
            ) == .waiting(.noAiredEpisode)
        )
    }

    @Test func backlogUsesIndividualsAroundAnExactCompletedSeason() throws {
        let now = instant("2026-07-30T12:00:00Z")
        let schedule = makeSchedule(
            status: .running,
            episodes: [
                scheduled(1, 1, "2026-05-01T00:00:00Z"),
                scheduled(1, 2, "2026-05-08T00:00:00Z"),
                scheduled(1, 3, "2026-05-15T00:00:00Z"),
                scheduled(1, 4, "2026-05-22T00:00:00Z"),
                scheduled(2, 1, "2026-06-01T00:00:00Z"),
                scheduled(2, 2, "2026-06-08T00:00:00Z"),
                scheduled(2, 3, "2026-06-15T00:00:00Z"),
                scheduled(3, 1, "2026-07-15T00:00:00Z"),
                scheduled(3, 2, "2026-07-22T00:00:00Z"),
                scheduled(3, 3, "2026-08-05T00:00:00Z")
            ]
        )

        let plan = try TVSubscriptionPlanner.plan(
            schedule: schedule,
            start: .manual(TVEpisodeNumber(season: 1, episode: 3)),
            asOf: now
        )

        #expect(plan.startResolution == .episode(TVEpisodeNumber(season: 1, episode: 3)))
        #expect(
            plan.individualEpisodes == [
                TVEpisodeNumber(season: 1, episode: 3),
                TVEpisodeNumber(season: 1, episode: 4),
                TVEpisodeNumber(season: 3, episode: 1),
                TVEpisodeNumber(season: 3, episode: 2)
            ]
        )
        #expect(
            plan.fullSeasonCandidates == [
                TVSeasonPackCandidate(
                    season: 2,
                    episodes: [
                        TVEpisodeNumber(season: 2, episode: 1),
                        TVEpisodeNumber(season: 2, episode: 2),
                        TVEpisodeNumber(season: 2, episode: 3)
                    ]
                )
            ]
        )
    }

    @Test func endedFinalSeasonCanBeAPackButNumberingGapsCannot() throws {
        let now = instant("2026-07-30T12:00:00Z")
        let complete = try TVSubscriptionPlanner.plan(
            schedule: makeSchedule(
                status: .ended,
                episodes: [
                    scheduled(1, 1, "2026-05-01T00:00:00Z"),
                    scheduled(1, 2, "2026-05-08T00:00:00Z")
                ]
            ),
            start: .first,
            asOf: now
        )
        let gap = try TVSubscriptionPlanner.plan(
            schedule: makeSchedule(
                status: .ended,
                episodes: [
                    scheduled(1, 1, "2026-05-01T00:00:00Z"),
                    scheduled(1, 3, "2026-05-15T00:00:00Z")
                ]
            ),
            start: .first,
            asOf: now
        )

        #expect(
            complete.fullSeasonCandidates == [
                TVSeasonPackCandidate(
                    season: 1,
                    episodes: [
                        TVEpisodeNumber(season: 1, episode: 1),
                        TVEpisodeNumber(season: 1, episode: 2)
                    ]
                )
            ]
        )
        #expect(complete.individualEpisodes.isEmpty)
        #expect(gap.fullSeasonCandidates.isEmpty)
        #expect(
            gap.individualEpisodes == [
                TVEpisodeNumber(season: 1, episode: 1),
                TVEpisodeNumber(season: 1, episode: 3)
            ]
        )
    }

    @Test func tvMazeClientUsesInjectedURLSessionBaseURLAndDate() async throws {
        let now = instant("2026-07-30T00:30:00Z")
        let showJSON = """
        {
          "id": 42,
          "name": "Boundary Show",
          "status": "Running",
          "premiered": "2024-09-12",
          "runtime": 60,
          "averageRuntime": 55,
          "externals": {"imdb": "tt1234567"}
        }
        """
        let session = URLSession(
            configuration: TVMazeMockURLProtocol.configuration { request in
                switch request.url?.path {
                case "/v1/search/shows":
                    return .json("[{\"score\":1.0,\"show\":\(showJSON)}]")
                case "/v1/shows/42":
                    return .json(showJSON)
                case "/v1/shows/42/episodes":
                    return .json(
                        """
                        [
                          {"season":0,"number":1,"type":"significant_special","airstamp":"2026-07-30T00:20:00Z"},
                          {"season":1,"number":1,"type":"regular","airstamp":"2026-07-29T20:00:00-04:00"},
                          {"season":1,"number":2,"type":"regular","airstamp":"2026-07-30T09:30:00+09:00"},
                          {"season":1,"number":3,"type":"regular","airstamp":"2026-07-30T01:30:00Z"}
                        ]
                        """
                    )
                default:
                    return .json("{}", status: 404)
                }
            }
        )
        let client = TVMazeClient(
            session: session,
            baseURL: URL(string: "https://tvmaze.test/v1")!,
            now: { now }
        )

        let matches = try await client.searchShows(" Boundary Show ")
        let plan = try await client.subscriptionPlan(showID: 42, start: .current)

        #expect(
            matches == [
                TVShowIdentity(
                    id: 42,
                    name: "Boundary Show",
                    imdbID: "tt1234567",
                    premieredYear: 2024,
                    status: .running,
                    runtimeMinutes: 55
                )
            ]
        )
        #expect(plan.startResolution == .episode(TVEpisodeNumber(season: 1, episode: 2)))
        #expect(plan.individualEpisodes == [TVEpisodeNumber(season: 1, episode: 2)])
        #expect(plan.fullSeasonCandidates.isEmpty)
    }
}

private func makeSchedule(
    status: TVShowStatus,
    episodes: [TVEpisodeSchedule]
) -> TVShowSchedule {
    TVShowSchedule(
        show: TVShowIdentity(
            id: 1,
            name: "Test Show",
            imdbID: "tt0000001",
            premieredYear: 2020,
            status: status,
            runtimeMinutes: 50
        ),
        episodes: episodes
    )
}

private func scheduled(
    _ season: Int,
    _ episode: Int,
    _ airstamp: String
) -> TVEpisodeSchedule {
    TVEpisodeSchedule(
        number: TVEpisodeNumber(season: season, episode: episode),
        airstamp: instant(airstamp)
    )
}

private func instant(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: value) else {
        fatalError("Invalid test date: \(value)")
    }
    return date
}

private final class TVMazeMockURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> TVMazeMockResponse
    private static var handler: Handler?

    static func configuration(handler: @escaping Handler) -> URLSessionConfiguration {
        self.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TVMazeMockURLProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let response = handler(request)
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct TVMazeMockResponse: Sendable {
    let status: Int
    let body: String

    static func json(_ body: String, status: Int = 200) -> TVMazeMockResponse {
        TVMazeMockResponse(status: status, body: body)
    }
}
