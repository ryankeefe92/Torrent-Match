//
//  Torrent_MatchTests.swift
//  Torrent MatchTests
//
//  Created by Ryan Keefe on 5/17/26.
//

import Foundation
import Testing
import TorrentMatcherCore

struct Torrent_MatchTests {

    @Test func htmlProvidersKeepRowsWhenSeedLeechParsingFails() async throws {
        // Title matches, but seed/leech markup is intentionally missing to simulate provider HTML drift.
        let sampleHTML = """
        <table>
          <tr>
            <td class="name">
              <a href="/torrent/12345/test/">The Matrix 1999 2160p WEB-DL DDP5 1 Atmos H265-GROUP</a>
            </td>
            <td class="size">6.4 GB</td>
          </tr>
        </table>
        """

        let config = ProviderConfig(
            id: "test-html",
            name: "TestHTML",
            enabled: true,
            searchURLTemplate: "https://example.com/search/{{query}}",
            alternateSearchURLTemplates: [],
            resultBlockPattern: #"<tr[^>]*>([\s\S]*?)</tr>"#,
            titlePattern: #"<a[^>]+href=[\"'](?:https?://[^\"']+)?/torrent/[^\"']+[\"'][^>]*>([^<]+)</a>"#,
            detailURLPattern: #"<a[^>]+href=[\"']((?:https?://[^\"']+)?/torrent/[^\"']+)[\"'][^>]*>[^<]+</a>"#,
            magnetPattern: nil,
            fetchMagnetFromDetailDuringSearch: false,
            seedersPattern: #"<td[^>]*class=[\"'][^\"']*seeds[^\"']*[\"'][^>]*>\s*(\d+)\s*</td>"#,
            leechersPattern: #"<td[^>]*class=[\"'][^\"']*leeches[^\"']*[\"'][^>]*>\s*(\d+)\s*</td>"#,
            sizePattern: nil,
            detailBaseURL: "https://example.com",
            timeoutSeconds: 5,
            searchPageCount: 1
        )

        let session = URLSession(configuration: MockURLProtocol.ephemeralConfiguration { _ in
            .immediate(status: 200, body: sampleHTML)
        })
        let provider = RegexHTMLProvider(config: config, session: session)
        let results = try await provider.search("matrix", onProgress: nil)

        #expect(results.count == 1)
        #expect(results.first?.title.contains("The Matrix 1999") == true)
    }

    @Test func x1337SearchUsesLeadingArticleStrippedVariant() async throws {
        let sampleHTML = """
        <table>
          <tr>
            <td class="name">
              <a href="/torrent/12345/test/">The Matrix 1999 2160p WEB-DL DDP5 1 Atmos H265-GROUP</a>
            </td>
            <td class="coll-2 seeds">20</td>
            <td class="coll-3 leeches">12</td>
          </tr>
        </table>
        """
        let emptyHTML = "<table></table>"

        let config = ProviderConfig(
            id: "1337x",
            name: "1337x",
            enabled: true,
            searchURLTemplate: "https://example.com/category-search/{{query}}/Movies/{{page}}/",
            alternateSearchURLTemplates: [],
            resultBlockPattern: #"<tr[^>]*>([\s\S]*?)</tr>"#,
            titlePattern: #"<a[^>]+href=[\"'](?:https?://[^\"']+)?/torrent/[^\"']+[\"'][^>]*>([^<]+)</a>"#,
            detailURLPattern: #"<a[^>]+href=[\"']((?:https?://[^\"']+)?/torrent/[^\"']+)[\"'][^>]*>[^<]+</a>"#,
            magnetPattern: nil,
            fetchMagnetFromDetailDuringSearch: false,
            seedersPattern: #"<td[^>]*class=[\"'][^\"']*seeds[^\"']*[\"'][^>]*>\s*(\d+)\s*</td>"#,
            leechersPattern: #"<td[^>]*class=[\"'][^\"']*leeches[^\"']*[\"'][^>]*>\s*(\d+)\s*</td>"#,
            sizePattern: nil,
            detailBaseURL: "https://example.com",
            timeoutSeconds: 5,
            searchPageCount: 1
        )

        let session = URLSession(configuration: MockURLProtocol.ephemeralConfiguration { request in
            let url = request.url?.absoluteString.lowercased() ?? ""
            return url.contains("/category-search/matrix/movies/")
                ? .immediate(status: 200, body: sampleHTML)
                : .immediate(status: 200, body: emptyHTML)
        })
        let provider = RegexHTMLProvider(config: config, session: session)
        let results = try await provider.search("The Matrix", onProgress: nil)

        #expect(results.count == 1)
        #expect(results.first?.title.contains("The Matrix 1999") == true)
    }

    @Test func x1337SearchReturnsFromFirstUsableMirror() async throws {
        let sampleHTML = """
        <table>
          <tr>
            <td class="name">
              <a href="/torrent/12345/test/">The Matrix 1999 2160p WEB-DL DDP5 1 Atmos H265-GROUP</a>
            </td>
            <td class="coll-2 seeds">20</td>
            <td class="coll-3 leeches">12</td>
          </tr>
        </table>
        """

        let config = ProviderConfig(
            id: "1337x",
            name: "1337x",
            enabled: true,
            searchURLTemplate: "https://dead.example/category-search/{{query}}/Movies/{{page}}/",
            alternateSearchURLTemplates: [
                "https://live.example/category-search/{{query}}/Movies/{{page}}/"
            ],
            resultBlockPattern: #"<tr[^>]*>([\s\S]*?)</tr>"#,
            titlePattern: #"<a[^>]+href=[\"'](?:https?://[^\"']+)?/torrent/[^\"']+[\"'][^>]*>([^<]+)</a>"#,
            detailURLPattern: #"<a[^>]+href=[\"']((?:https?://[^\"']+)?/torrent/[^\"']+)[\"'][^>]*>[^<]+</a>"#,
            magnetPattern: nil,
            fetchMagnetFromDetailDuringSearch: false,
            seedersPattern: #"<td[^>]*class=[\"'][^\"']*seeds[^\"']*[\"'][^>]*>\s*(\d+)\s*</td>"#,
            leechersPattern: #"<td[^>]*class=[\"'][^\"']*leeches[^\"']*[\"'][^>]*>\s*(\d+)\s*</td>"#,
            sizePattern: nil,
            detailBaseURL: "https://live.example",
            timeoutSeconds: 5,
            searchPageCount: 1
        )

        let session = URLSession(configuration: MockURLProtocol.ephemeralConfiguration { request in
            let host = request.url?.host?.lowercased() ?? ""
            if host == "live.example" {
                return .immediate(status: 200, body: sampleHTML)
            }
            return .delayed(status: 200, body: "<table></table>", seconds: 2.0)
        })
        let provider = RegexHTMLProvider(config: config, session: session)

        let start = Date()
        let results = try await provider.search("The Matrix", onProgress: nil)
        let elapsed = Date().timeIntervalSince(start)

        #expect(results.count == 1)
        #expect(elapsed < 1.0)
    }

    @Test func partialResultsSurviveProviderTimeout() async {
        let partialResult = TorrentSearchResult(
            title: "The Matrix 1999 2160p WEB-DL DDP5 1 Atmos H265-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 25,
            leechers: 3,
            provider: "Slow Provider"
        )
        let provider = MockTorrentProvider(
            config: ProviderConfig(
                id: "slow-provider",
                name: "Slow Provider",
                enabled: true,
                searchURLTemplate: "https://example.com",
                resultBlockPattern: "",
                titlePattern: "",
                detailURLPattern: nil,
                magnetPattern: nil,
                fetchMagnetFromDetailDuringSearch: false,
                seedersPattern: "",
                leechersPattern: "",
                detailBaseURL: nil
            )
        ) { _, onProgress in
            if let onProgress {
                await onProgress([partialResult])
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return [partialResult]
        }

        let service = TorrentSearchService(providers: [provider], providerTimeoutSeconds: 1)
        let report = await service.searchAndRankReport("The Matrix 1999")

        #expect(report.results.count == 1)
        #expect(report.results.first?.raw.title == partialResult.title)
        #expect(report.failures.count == 1)
        #expect(report.failures.first?.providerName == "Slow Provider")
    }

    @Test func dedupeCollapsesIdenticalTitlesEvenWithDifferentInfoHashes() {
        let title = "Movie.2025.2160p.WEB-DL.DDP5.1.Atmos.HDR.H.265-GROUP"

        let a = TorrentSearchResult(
            title: title,
            magnet: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
            detailURL: nil,
            seeders: 10,
            leechers: 1,
            provider: "A"
        )
        let b = TorrentSearchResult(
            title: title,
            magnet: "magnet:?xt=urn:btih:89abcdef0123456789abcdef0123456789abcdef",
            detailURL: nil,
            seeders: 20,
            leechers: 2,
            provider: "B"
        )

        let deduped = TorrentResultDedupe.dedupe([a, b])
        #expect(deduped.count == 1)
        #expect(deduped.first?.title == title)
    }

    @Test func dedupeCollapsesSameInfoHashEvenWithDifferentTitles() {
        let hash = "0123456789abcdef0123456789abcdef01234567"
        let magnet = "magnet:?xt=urn:btih:\(hash)"

        let a = TorrentSearchResult(
            title: "Movie.2025.2160p.WEB-DL.DDP5.1.Atmos.HDR.H.265-GROUP",
            magnet: magnet,
            detailURL: nil,
            seeders: 10,
            leechers: 1,
            provider: "A"
        )
        let b = TorrentSearchResult(
            title: "Movie 2025 2160p WEB-DL DDP5.1 Atmos HDR H.265 GROUP",
            magnet: magnet,
            detailURL: nil,
            seeders: 20,
            leechers: 2,
            provider: "B"
        )

        let deduped = TorrentResultDedupe.dedupe([a, b])
        #expect(deduped.count == 1)
    }

    @Test func parserTreatsDDTokenAsDolbyDigital() {
        let parsed = ReleaseParser.parse("Movie.2025.1080p.WEB-DL.DD.H.264-GROUP")
        #expect(parsed.audioCodec == .dd)
    }

    @Test func parserTreatsDolbyDAsDolbyDigital() {
        let parsed = ReleaseParser.parse("Movie.2025.1080p.WEB-DL.DolbyD.H.264-GROUP")
        #expect(parsed.audioCodec == .dd)
    }

    @Test func parserTreatsAvcAsH264() {
        let parsed = ReleaseParser.parse("Movie.2025.1080p.WEB-DL.AVC.DDP5.1-GROUP")
        #expect(parsed.videoCodec == .avc)
    }

    @Test func parserInfersDtsMaChannelsWhenMissing() {
        let parsed = ReleaseParser.parse("Movie.2025.2160p.UHD.BluRay.DTS-HD.MA.HDR.GROUP")
        #expect(parsed.audioCodec == .dtsHDMA)
        #expect(parsed.channels == .fiveOne)
    }

    @Test func parserFindsChannelsWhenPackedAgainstCodecToken() {
        let parsed = ReleaseParser.parse("Movie.2025.2160p.WEB-DL.DDP5 1.Atmos.HDR.H.265-GROUP")
        #expect(parsed.audioCodec == .ddp)
        #expect(parsed.channels == .fiveOne)
        #expect(parsed.atmos == true)
    }

    @Test func parserDoesNotMarkDTSAsAtmos() {
        let parsed = ReleaseParser.parse("Movie.2025.2160p.BluRay.DTS-HD.MA.7.1.Atmos.HDR.H.265-GROUP")
        #expect(parsed.audioCodec == .dtsHDMA)
        #expect(parsed.channels == .sevenOne)
        #expect(parsed.atmos == false)
    }

    @Test func parserTreatsDTSXAsDTSHDMA() {
        let parsed = ReleaseParser.parse("Movie.2025.2160p.BluRay.DTS-X.7.1.HDR.H.265-GROUP")
        #expect(parsed.audioCodec == .dtsHDMA)
    }

    @Test func parserTreatsPackedDtsMaVariantsAsDtsHDMA() {
        let a = ReleaseParser.parse("Movie.2025.2160p.BluRay.DTS-MA5 1.HDR.H.265-GROUP")
        let b = ReleaseParser.parse("Movie.2025.2160p.BluRay.DTS-MA7 1.HDR.H.265-GROUP")
        let c = ReleaseParser.parse("Movie.2025.2160p.BluRay.DTS-HDMA5 1.HDR.H.265-GROUP")
        let d = ReleaseParser.parse("Movie.2025.2160p.BluRay.DTS-HDMA7 1.HDR.H.265-GROUP")

        #expect(a.audioCodec == .dtsHDMA)
        #expect(a.channels == .fiveOne)
        #expect(b.audioCodec == .dtsHDMA)
        #expect(b.channels == .sevenOne)
        #expect(c.audioCodec == .dtsHDMA)
        #expect(c.channels == .fiveOne)
        #expect(d.audioCodec == .dtsHDMA)
        #expect(d.channels == .sevenOne)
    }

    @Test func parserInfersUHDDefaults() {
        let parsed = ReleaseParser.parse("Movie.2025.UHD.BluRay.REMUX-GROUP")
        #expect(parsed.sourceType == .remux)
        #expect(parsed.resolution == .p2160)
        #expect(parsed.dynamicRange == .likelyHDR)
        #expect(parsed.videoCodec == .hevc)
    }

    @Test func parserTreatsUhdRemuxAsHevc() {
        let parsed = ReleaseParser.parse("Movie.2025.2160p.UHD.BluRay.REMUX.DDP5.1.HDR.GROUP")
        #expect(parsed.sourceType == .remux)
        #expect(parsed.resolution == .p2160)
        #expect(parsed.videoCodec == .hevc)
    }

    @Test func parserTreatsBdRemuxAsRemux() {
        let parsed = ReleaseParser.parse("Movie.2025.2160p.BDREMUX.TrueHD.7.1.HDR.GROUP")
        #expect(parsed.sourceType == .remux)
    }

    @Test func parserFallsBackToDdForUhdRemuxWithMissingAudioCodec() {
        let parsed = ReleaseParser.parse("Movie.2025.2160p.UHD.BluRay.REMUX.HDR.GROUP")
        #expect(parsed.sourceType == .remux)
        #expect(parsed.audioCodec == .dd)
    }

    @Test func parserFallsBackToDdForBlurayRemuxWithMissingAudioCodec() {
        let parsed = ReleaseParser.parse("Movie.2025.1080p.BluRay.REMUX.HDR.GROUP")
        #expect(parsed.sourceType == .remux)
        #expect(parsed.audioCodec == .dd)
    }

    @Test func parserInfersUHDFrom2160pBluray() {
        let parsed = ReleaseParser.parse("Movie.2025.2160p.BluRay-GROUP")
        #expect(parsed.resolution == .p2160)
        #expect(parsed.dynamicRange == .likelyHDR)
    }

    @Test func parserInfersStandardBlurayDefaults() {
        let parsed = ReleaseParser.parse("Movie.2025.BluRay-GROUP")
        #expect(parsed.sourceType == .bluray)
        #expect(parsed.resolution == .likely1080)
        #expect(parsed.dynamicRange == .sdr)
    }

    @Test func parserTreatsBRRipAsBluRay() {
        let parsed = ReleaseParser.parse("Movie.2025.BRRip-GROUP")
        #expect(parsed.sourceType == .bluray)
    }

    @Test func parserTreatsHDRipAsHDTVNotHDR() {
        let parsed = ReleaseParser.parse("Movie.2025.HDRip-GROUP")
        #expect(parsed.sourceType == .hdtv)
        #expect(parsed.resolution == .p720)
        #expect(parsed.dynamicRange == .unknown)
    }

    @Test func parserRecognizesPCMAndMono() {
        let parsed = ReleaseParser.parse("Movie.2025.1080p.BluRay.PCM.1.0-GROUP")
        #expect(parsed.audioCodec == .pcm)
        #expect(parsed.channels == .mono)
    }

    @Test func parserTreatsDDSevenOneAsDolbyDigitalPlus() {
        let parsed = ReleaseParser.parse("Movie.2025.1080p.BluRay.DD7 1.x264-GROUP")
        #expect(parsed.audioCodec == .ddp)
        #expect(parsed.channels == .sevenOne)
    }

    @Test func parserTreatsDdpaAsDdpatmos() {
        let parsed = ReleaseParser.parse("Movie.2025.2160p.WEB-DL.DDPA.HDR.H.265-GROUP")
        #expect(parsed.audioCodec == .ddp)
        #expect(parsed.atmos == true)
    }

    @Test func parserDoesNotTreatHDR10AsMono() {
        let parsed = ReleaseParser.parse("Movie.2025.2160p.WEB-DL.HDR10.H.265-GROUP")
        #expect(parsed.dynamicRange == .hdr10)
        #expect(parsed.channels == .unknown)
    }

    @Test func parserTreatsSplitHDR10TokensAsHDR10() {
        let splitHDR10 = ReleaseParser.parse("Movie.2025.2160p.WEB-DL.HDR 10 bit.H.265-GROUP")
        let reversedHDR10 = ReleaseParser.parse("Movie.2025.2160p.WEB-DL.10bit HDR.H.265-GROUP")
        #expect(splitHDR10.dynamicRange == .hdr10)
        #expect(reversedHDR10.dynamicRange == .hdr10)
    }

    @Test func parserInfersDDPFromAtmosChannelContextWithoutAtmosBonus() {
        let parsed = ReleaseParser.parse("Movie.2025.2160p.WEB-DL.Atmos.7 1.HDR.H.265-GROUP")
        #expect(parsed.audioCodec == .ddp)
        #expect(parsed.channels == .sevenOne)
        #expect(parsed.atmos == false)
    }

    @Test func parserTreatsBareAtmosAsDDP51() {
        let parsed = ReleaseParser.parse("Movie.2025.2160p.WEB-DL.Atmos.HDR.H.265-GROUP")
        #expect(parsed.audioCodec == .ddp)
        #expect(parsed.channels == .fiveOne)
        #expect(parsed.atmos == false)
    }

    @Test func torrentGalaxyConfigExtractsSizeFromBadgeMarkup() {
        let sampleHTML = """
        <div class="tgxtablerow txlight">
          <div class="tgxtablecell clickable-row click textshadow rounded txlight" id="click" data-href="/post-detail/8b3858/the-matrix-1999-1080p-max-web-dl-ddp5-1-atmos-h-264-turg/" style="word-break:break-all;">
            <div><a class="txlight" title="The Matrix 1999 1080p MAX WEB-DL DDP5 1 Atmos H 264-TURG" href="/post-detail/8b3858/the-matrix-1999-1080p-max-web-dl-ddp5-1-atmos-h-264-turg/"><span src="torrent"><b>The Matrix 1999 1080p MAX WEB-DL DDP5 1 Atmos H 264-TURG</b></span></a></div>
          </div>
          <div class="tgxtablecell collapsehide rounded txlight" style="text-align:right;"><span class="badge badge-secondary txlight" style="border-radius:4px;">6.4&nbsp;GB</span></div>
          <div class="tgxtablecell collapsehide rounded txlight"><span title="Seeders/Leechers">[<font color="green"><b>4</b></font>/<font color="#ff0000"><b>1</b></font>]</span></div>
        </div>
        """

        let testResult = ProviderConfigTester.test(config: BuiltInProviderConfigs.torrentGalaxy, sampleHTML: sampleHTML)
        #expect(testResult.sampleResults.count == 1)
        #expect(testResult.sampleResults.first?.size == "6.4 GB")
    }

    @Test func searchMatchesMovieTitlesWithBridgeWordsInsideName() async {
        let result = TorrentSearchResult(
            title: "Mission Impossible The Final Reckoning 2025 2160p WEB-DL DDP5 1 Atmos H265-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 15,
            leechers: 2,
            provider: "Provider"
        )
        let provider = MockTorrentProvider.singleResult(result, id: "provider", name: "Provider")
        let service = TorrentSearchService(providers: [provider])

        let report = await service.searchAndRankReport("Mission Impossible Final Reckoning")

        #expect(report.results.count == 1)
        #expect(report.results.first?.raw.title == result.title)
    }

    @Test func searchKeeps1337xMovieReleaseWithoutYearWhenCodecMarkersExist() async {
        let result = TorrentSearchResult(
            title: "The Matrix Resurrections WEB-DL DDP5 1 Atmos H265-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 11,
            leechers: 2,
            provider: "1337x"
        )
        let provider = MockTorrentProvider.singleResult(result, id: "1337x", name: "1337x")
        let service = TorrentSearchService(providers: [provider])

        let report = await service.searchAndRankReport("The Matrix Resurrections")

        #expect(report.results.count == 1)
        #expect(report.results.first?.raw.title == result.title)
    }

    @Test func rankerExcludesLegacyCodecVariants() {
        let result = TorrentSearchResult(
            title: "Movie.2025.1080p.BluRay.VC 1-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        let ranked = TorrentRanker.score(result)
        #expect(ranked.excluded == true)
    }

    @Test func uhdRemuxReceivesVisibleTopTierBonus() {
        let topTier = TorrentSearchResult(
            title: "Movie.2025.2160p.UHD.BluRay.REMUX.TrueHD.7.1.HDR.HEVC-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )
        let nonTopTier = TorrentSearchResult(
            title: "Movie.2025.2160p.UHD.BluRay.TrueHD.7.1.HDR.HEVC-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        let rankedTopTier = TorrentRanker.score(topTier)
        let rankedNonTopTier = TorrentRanker.score(nonTopTier)
        #expect(rankedTopTier.score == rankedNonTopTier.score + 122)
        #expect(rankedTopTier.notes.contains { $0.contains("Top tier bonus: +100") })
    }

    @Test func ddpAtmosBeatsLosslessAudioWithoutAtmos() {
        let ddpAtmos = TorrentSearchResult(
            title: "Movie.2025.2160p.BluRay.DDP5.1.Atmos.HDR.HEVC-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )
        let trueHD = TorrentSearchResult(
            title: "Movie.2025.2160p.BluRay.TrueHD.5.1.HDR.HEVC-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        #expect(TorrentRanker.score(ddpAtmos).score > TorrentRanker.score(trueHD).score)
    }

    @Test func imaxReceivesScoreBonus() {
        let imax = TorrentSearchResult(
            title: "Movie.2025.1080p.BluRay.IMAX.DDP5.1.x265-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )
        let standard = TorrentSearchResult(
            title: "Movie.2025.1080p.BluRay.DDP5.1.x265-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        #expect(TorrentRanker.score(imax).score == TorrentRanker.score(standard).score + 13)
    }

}

private struct MockTorrentProvider: TorrentProvider {
    let config: ProviderConfig
    let searchHandler: @Sendable (_ query: String, _ onProgress: (@concurrent @Sendable (_ addedResults: [TorrentSearchResult]) async -> Void)?) async throws -> [TorrentSearchResult]

    init(
        config: ProviderConfig,
        searchHandler: @escaping @Sendable (_ query: String, _ onProgress: (@concurrent @Sendable (_ addedResults: [TorrentSearchResult]) async -> Void)?) async throws -> [TorrentSearchResult]
    ) {
        self.config = config
        self.searchHandler = searchHandler
    }

    static func singleResult(_ result: TorrentSearchResult, id: String, name: String) -> MockTorrentProvider {
        MockTorrentProvider(
            config: ProviderConfig(
                id: id,
                name: name,
                enabled: true,
                searchURLTemplate: "https://example.com",
                resultBlockPattern: "",
                titlePattern: "",
                detailURLPattern: nil,
                magnetPattern: nil,
                fetchMagnetFromDetailDuringSearch: false,
                seedersPattern: "",
                leechersPattern: "",
                detailBaseURL: nil
            )
        ) { _, onProgress in
            if let onProgress {
                await onProgress([result])
            }
            return [result]
        }
    }

    @concurrent
    func search(
        _ query: String,
        onProgress: (@concurrent @Sendable (_ addedResults: [TorrentSearchResult]) async -> Void)?
    ) async throws -> [TorrentSearchResult] {
        try await searchHandler(query, onProgress)
    }
}

private final class MockURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> MockResponsePlan
    private static var handler: Handler?
    private var isStopped = false

    static func ephemeralConfiguration(handler: @escaping Handler) -> URLSessionConfiguration {
        self.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return config
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let plan = handler(request)
        let sendResponse = { [weak self] (status: Int, body: String) in
            guard let self, !self.isStopped else { return }
            let url = self.request.url ?? URL(string: "https://example.com")!
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }

        switch plan {
        case .immediate(let status, let body):
            sendResponse(status, body)
        case .delayed(let status, let body, let seconds):
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                sendResponse(status, body)
            }
        }
    }

    override func stopLoading() {
        isStopped = true
    }
}

private enum MockResponsePlan {
    case immediate(status: Int, body: String)
    case delayed(status: Int, body: String, seconds: TimeInterval)
}
