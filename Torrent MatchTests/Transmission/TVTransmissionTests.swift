import Foundation
import SwiftData
import Testing
@testable import Torrent_Match

@Suite(.serialized)
struct TVTransmissionTests {
    @Test
    func torrentAddReturnsAddedTorrentIdentity() async throws {
        let client = TransmissionClient(
            config: TransmissionConfig(
                rpcURL: URL(string: "https://transmission-added.test/transmission/rpc")!
            ),
            session: makeTransmissionSession()
        )

        let result = try await client.addReturningResult(
            magnet: "magnet:?xt=urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        )

        #expect(result.disposition == .added)
        #expect(result.torrentID == 41)
        #expect(result.torrentName == "Example Show S01E01 2160p WEB-DL")
        #expect(result.infoHash == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        #expect(result.wasAdded)
        #expect(!result.wasDuplicate)
    }

    @Test
    func torrentAddReturnsDuplicateTorrentIdentity() async throws {
        let client = TransmissionClient(
            config: TransmissionConfig(
                rpcURL: URL(string: "https://transmission-duplicate.test/transmission/rpc")!
            ),
            session: makeTransmissionSession()
        )

        let result = try await client.addReturningResult(
            magnet: "magnet:?xt=urn:btih:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
        )

        #expect(result.disposition == .duplicate)
        #expect(result.torrentID == 73)
        #expect(result.torrentName == "Example Show S01E02 2160p WEB-DL")
        #expect(result.infoHash == "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")
        #expect(!result.wasAdded)
        #expect(result.wasDuplicate)
    }

    @MainActor
    @Test
    func transmissionStoreUsesPreferredEndpointThenFallsBack() async throws {
        let suiteName = "TVTransmissionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = TransmissionStore(defaults: defaults, session: makeTransmissionSession())
        store.save(
            settings: TransmissionStoreSettings(
                homeRPCURL: "https://transmission-added.test",
                tailscaleRPCURL: "https://transmission-failure.test",
                preferTailscale: true
            )
        )

        let result = try await store.add(
            magnet: "magnet:?xt=urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        )

        #expect(result.disposition == .added)
        #expect(result.torrentID == 41)
        #expect(store.activeEndpointName == "Home RPC")
        #expect(store.downloads.isEmpty)
        #expect(store.lastErrorMessage == nil)
    }

    @MainActor
    @Test
    func subscriptionModelsPersistWithoutRelationshipsOrUniqueConstraints() throws {
        let schema = Schema([
            TVSubscription.self,
            TVAcquisitionPlan.self,
            TVAcquisitionJob.self,
            TVAcquisitionHistoryEntry.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let start = TVEpisodeCoordinate(season: 1, episode: 1)
        let through = TVEpisodeCoordinate(season: 1, episode: 10)
        let coverage = TVEpisodeCoverage(start: start, end: through)
        let subscription = TVSubscription(
            seriesID: "tvmaze:123",
            seriesTitle: "Example Show",
            seriesYear: 2026,
            imdbID: "tt1234567",
            runtimeMinutes: 52,
            scheduleSource: "TVmaze",
            showStatus: .running,
            startMode: .first,
            resolvedStart: start,
            nextEpisode: TVEpisodeCoordinate(season: 2, episode: 1)
        )
        subscription.nextAirdate = Date(timeIntervalSince1970: 2_000_000_000)
        subscription.checkRequestedAt = Date(timeIntervalSince1970: 1_900_000_000)

        let plan = TVAcquisitionPlan(
            subscriptionID: subscription.id,
            seriesID: subscription.seriesID,
            coverage: coverage,
            plannedJobCount: 1
        )
        plan.confirm(at: Date(timeIntervalSince1970: 1_800_000_000))

        let job = TVAcquisitionJob(
            planID: plan.id,
            subscriptionID: subscription.id,
            seriesID: subscription.seriesID,
            kind: .seasonPack,
            coverage: coverage,
            searchQuery: "Example Show S01",
            status: .downloading
        )
        let history = TVAcquisitionHistoryEntry(
            subscriptionID: subscription.id,
            planID: plan.id,
            jobID: job.id,
            seriesID: subscription.seriesID,
            event: .torrentAdded,
            coverage: coverage,
            torrentID: 41,
            torrentName: "Example Show S01 2160p BluRay",
            torrentInfoHash: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        )

        context.insert(subscription)
        context.insert(plan)
        context.insert(job)
        context.insert(history)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<TVSubscription>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<TVAcquisitionPlan>()).first?.status == .confirmed)
        #expect(try context.fetch(FetchDescriptor<TVAcquisitionJob>()).first?.kind == .seasonPack)
        #expect(try context.fetch(FetchDescriptor<TVAcquisitionHistoryEntry>()).first?.event == .torrentAdded)
    }

    @MainActor
    @Test
    func seasonPackCoveragePreventsDuplicateEpisodeJobs() {
        let subscriptionID = UUID()
        let planID = UUID()
        let seasonCoverage = TVEpisodeCoverage(
            start: TVEpisodeCoordinate(season: 1, episode: 1),
            end: TVEpisodeCoordinate(season: 1, episode: 10)
        )
        let requestedEpisode = TVEpisodeCoverage(season: 1, episode: 4)
        let job = TVAcquisitionJob(
            planID: planID,
            subscriptionID: subscriptionID,
            seriesID: "TVMAZE:123",
            kind: .seasonPack,
            coverage: seasonCoverage,
            searchQuery: "Example Show S01",
            status: .downloading
        )

        #expect(
            TVAcquisitionIdempotency.isCovered(
                seriesID: " tvmaze:123 ",
                coverage: requestedEpisode,
                jobs: [job],
                history: []
            )
        )

        job.status = .failed
        #expect(
            !TVAcquisitionIdempotency.isCovered(
                seriesID: "tvmaze:123",
                coverage: requestedEpisode,
                jobs: [job],
                history: []
            )
        )

        let duplicateHistory = TVAcquisitionHistoryEntry(
            subscriptionID: subscriptionID,
            planID: planID,
            jobID: job.id,
            seriesID: "tvmaze:123",
            event: .torrentDuplicate,
            coverage: seasonCoverage
        )
        #expect(
            TVAcquisitionIdempotency.isCovered(
                seriesID: "tvmaze:123",
                coverage: requestedEpisode,
                jobs: [job],
                history: [duplicateHistory]
            )
        )

        let completedEpisodes = (1...10).map { episode in
            TVAcquisitionHistoryEntry(
                subscriptionID: subscriptionID,
                seriesID: "tvmaze:123",
                event: .downloadCompleted,
                coverage: TVEpisodeCoverage(season: 1, episode: episode)
            )
        }
        #expect(
            TVAcquisitionIdempotency.isCovered(
                seriesID: "tvmaze:123",
                coverage: seasonCoverage,
                jobs: [],
                history: completedEpisodes
            )
        )

        let confirmedPlan = TVAcquisitionPlan(
            subscriptionID: subscriptionID,
            seriesID: "tvmaze:123",
            coverage: seasonCoverage,
            plannedJobCount: 1,
            status: .confirmed
        )
        #expect(
            TVAcquisitionIdempotency.isCovered(
                seriesID: "tvmaze:123",
                coverage: requestedEpisode,
                jobs: [],
                history: [],
                plans: [confirmedPlan]
            )
        )
    }
}

private func makeTransmissionSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TVTransmissionMockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class TVTransmissionMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        if request.value(forHTTPHeaderField: "X-Transmission-Session-Id") == nil {
            send(
                status: 409,
                headers: ["X-Transmission-Session-Id": "test-session-id"],
                body: #"{"result":"session required"}"#
            )
            return
        }

        if url.host == "transmission-failure.test" {
            send(status: 503, body: #"{"result":"unavailable"}"#)
            return
        }

        let method = requestMethod()
        if method == "torrent-get" {
            send(
                status: 200,
                body: #"{"arguments":{"torrents":[]},"result":"success"}"#
            )
            return
        }

        switch url.host {
        case "transmission-added.test":
            send(
                status: 200,
                body: #"{"arguments":{"torrent-added":{"hashString":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","id":41,"name":"Example Show S01E01 2160p WEB-DL"}},"result":"success"}"#
            )
        case "transmission-duplicate.test":
            send(
                status: 200,
                body: #"{"arguments":{"torrent-duplicate":{"hashString":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","id":73,"name":"Example Show S01E02 2160p WEB-DL"}},"result":"success"}"#
            )
        default:
            send(status: 404, body: #"{"result":"not found"}"#)
        }
    }

    override func stopLoading() {}

    private func requestMethod() -> String? {
        guard let body = request.httpBody ?? request.httpBodyStream?.readAllData(),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return object["method"] as? String
    }

    private func send(
        status: Int,
        headers: [String: String] = [:],
        body: String
    ) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private extension InputStream {
    func readAllData() -> Data {
        open()
        defer { close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while hasBytesAvailable {
            let count = read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
