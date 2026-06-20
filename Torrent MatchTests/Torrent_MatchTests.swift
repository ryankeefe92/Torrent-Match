//
//  Torrent_MatchTests.swift
//  Torrent MatchTests
//
//  Created by Ryan Keefe on 5/17/26.
//

import Foundation
import Testing
import TorrentMatcherCore

@Suite(.serialized)
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

    @Test func x1337RelativeDetailURLsUseRespondingMirrorHost() async throws {
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
            detailBaseURL: "https://dead.example",
            timeoutSeconds: 5,
            searchPageCount: 1
        )

        let session = URLSession(configuration: MockURLProtocol.ephemeralConfiguration { request in
            request.url?.host == "live.example"
                ? .immediate(status: 200, body: sampleHTML)
                : .immediate(status: 200, body: "<table></table>")
        })
        let provider = RegexHTMLProvider(config: config, session: session)
        let results = try await provider.search("The Matrix", onProgress: nil)

        #expect(results.count == 1)
        #expect(results.first?.detailURL?.absoluteString == "https://live.example/torrent/12345/test/")
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

    @Test func runtimeAndFileSizePopulateCalculatedOverallBitrate() async {
        let result = TorrentSearchResult(
            title: "The.Matrix.1999.1080p.WEB-DL.x265-GROUP",
            detailSpecs: TorrentDetailSpecs(runtime: "2 h 16 min"),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A",
            size: "10.00 GB"
        )
        let service = TorrentSearchService(providers: [
            MockTorrentProvider.singleResult(result, id: "a", name: "A")
        ])

        let report = await service.searchAndRankReport("The Matrix 1999")
        let specs = report.results.first?.raw.detailSpecs

        #expect(specs?.runtime == "2 h 16 min")
        #expect(specs?.overallBitrate?.contains("kb/s") == true)
        #expect(specs?.calculatedFields.contains("overallBitrate") == true)
        #expect(specs?.calculatedFields.contains("runtime") == false)
    }

    @Test func onlineRuntimeLookupParsesWikipediaRunningTime() async {
        let lookup = OnlineRuntimeLookup()
        let runtime = await lookup.runtime(from: """
        {{Infobox film
        | running_time = 154 minutes
        }}
        """)

        #expect(runtime?.displayText == "2 h 34 min")
    }

    @Test func onlineRuntimeLookupParsesAlternateRuntimeFromSearchSnippetText() async {
        let lookup = OnlineRuntimeLookup()
        let runtime = await lookup.runtime(fromSearchText: """
        Movie Censorship comparison: the director's cut runtime is 154 minutes, compared with the theatrical version.
        """)

        #expect(runtime?.displayText == "2 h 34 min")
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

    @Test func dedupePrefersProperWhenTitlesAreOtherwiseIdentical() {
        let standard = TorrentSearchResult(
            title: "Movie.2025.2160p.WEB-DL.DDP5.1.Atmos.HDR.H.265-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 40,
            leechers: 2,
            provider: "A"
        )
        let proper = TorrentSearchResult(
            title: "Movie.2025.2160p.WEB-DL.PROPER.DDP5.1.Atmos.HDR.H.265-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 5,
            leechers: 1,
            provider: "B"
        )

        let deduped = TorrentResultDedupe.dedupe([standard, proper])
        #expect(deduped.count == 1)
        #expect(deduped.first?.title == proper.title)
    }

    @Test func dedupeMergesMissingMetadataIntoPreferredDuplicate() {
        let popular = TorrentSearchResult(
            title: "Movie.2025.2160p.WEB-DL.DDP5.1.Atmos.HDR.H.265-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 40,
            leechers: 2,
            provider: "A"
        )
        let enriched = TorrentSearchResult(
            title: "Movie.2025.2160p.WEB-DL.DDP5.1.Atmos.HDR.H.265-GROUP",
            detailSpecs: TorrentDetailSpecs(videoBitrate: "20 Mb/s", runtime: "2 h 10 min"),
            magnet: nil,
            detailURL: URL(string: "https://example.com/detail"),
            seeders: 5,
            leechers: 1,
            provider: "B"
        )

        let deduped = TorrentResultDedupe.dedupe([popular, enriched])
        #expect(deduped.count == 1)
        #expect(deduped.first?.provider == "A")
        #expect(deduped.first?.detailSpecs?.runtime == "2 h 10 min")
        #expect(deduped.first?.detailSpecs?.videoBitrate == "20 Mb/s")
        #expect(deduped.first?.detailURL?.absoluteString == "https://example.com/detail")
        #expect(deduped.first?.detailSpecs?.isExternalMetadata("runtime") == true)
        #expect(deduped.first?.detailSpecs?.isExternalMetadata("videoBitrate") == true)
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

    @Test func parserTreatsDD51ChAsFiveOneNotMono() {
        let parsed = ReleaseParser.parse("Movie.2025.1080p.BluRay.DD5.1ch.x264-GROUP")
        #expect(parsed.audioCodec == .dd)
        #expect(parsed.channels == .fiveOne)
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

    @Test func parserTreatsHDRWith10BitAsGenericHDRNotHDR10() {
        let splitHDR10 = ReleaseParser.parse("Movie.2025.2160p.WEB-DL.HDR 10 bit.H.265-GROUP")
        let reversedHDR10 = ReleaseParser.parse("Movie.2025.2160p.WEB-DL.10bit HDR.H.265-GROUP")
        let explicitHDR10 = ReleaseParser.parse("Movie.2025.2160p.WEB-DL.HDR10.H.265-GROUP")
        #expect(splitHDR10.dynamicRange == .hdr)
        #expect(reversedHDR10.dynamicRange == .hdr)
        #expect(explicitHDR10.dynamicRange == .hdr10)
    }

    @Test func parserTreatsDS4KAsDownscaledSourceNot2160p() {
        let parsed = ReleaseParser.parse("Movie.2025.1080p.DS4K.BluRay.x265.10-bit.HDR.AC3-GROUP")
        #expect(parsed.resolution == .p1080)
        #expect(parsed.dynamicRange == .hdr)
    }

    @Test func parserDoesNotInferDDPFromBareAtmosChannelContext() {
        let parsed = ReleaseParser.parse("Movie.2025.2160p.WEB-DL.Atmos.7 1.HDR.H.265-GROUP")
        #expect(parsed.audioCodec == .unknown)
        #expect(parsed.channels == .sevenOne)
        #expect(parsed.atmos == false)
    }

    @Test func parserDoesNotTreatBareAtmosAsDDP51() {
        let parsed = ReleaseParser.parse("Movie.2025.2160p.WEB-DL.Atmos.HDR.H.265-GROUP")
        #expect(parsed.audioCodec == .unknown)
        #expect(parsed.channels == .unknown)
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

    @Test func detailMetadataRejectsTorrentGalaxyReportBoilerplate() async throws {
        let detailHTML = """
        <html><body>
          <div class="description">
            Your report will be reviewed by our moderation team.
          </div>
        </body></html>
        """
        let config = ProviderConfig(
            id: "torrentgalaxy",
            name: "TorrentGalaxy",
            enabled: true,
            searchURLTemplate: "https://torrentgalaxy.example/search/{{query}}",
            resultBlockPattern: "",
            titlePattern: "",
            detailURLPattern: nil,
            detailMetadataPattern: "<div[^>]+class=\\\"[^\\\"]*(?:mediainfo|media-info|nfo|description)[^\\\"]*\\\"[^>]*>([\\s\\S]*?)</div>",
            magnetPattern: nil,
            fetchMagnetFromDetailDuringSearch: false,
            seedersPattern: "",
            leechersPattern: "",
            detailBaseURL: "https://torrentgalaxy.example"
        )
        let session = URLSession(configuration: MockURLProtocol.ephemeralConfiguration { _ in
            .immediate(status: 200, body: detailHTML)
        })
        let provider = RegexHTMLProvider(config: config, session: session)
        let result = TorrentSearchResult(
            title: "Movie 2025 2160p WEB-DL DDP5 1 H265-GROUP",
            magnet: nil,
            detailURL: URL(string: "https://torrentgalaxy.example/post-detail/abc/movie/"),
            seeders: 10,
            leechers: 2,
            provider: config.name
        )

        let metadata = try await provider.fetchDetailMetadata(for: result)
        #expect(metadata?.text == nil)
    }

    @Test func detailMetadataExtractsTorrentGalaxyDescriptionAnchorMediaInfo() async throws {
        let detailHTML = """
        <html><body>
          <a name="description"></a><br>
          <legend class="txlight"><b>Description</b></legend>
          <div class="container-fluid">
            <center>
              <strong>MEDIAINFO</strong><br>
              <div style="white-space: pre-wrap; text-align: left; display: inline-block;">
        General
        Complete name : /downloads/Movie.2025.2160p.WEB-DL.mkv
        Format : Matroska
        Duration : 2 h 16 min
        Overall bit rate : 24.5 Mb/s
        Frame rate : 23.976 FPS

        Video
        Format : HEVC
        HDR format : Dolby Vision, Version 1.0, dvhe.05.06
        Bit rate : 22.0 Mb/s
        Width : 3 840 pixels
        Height : 2 160 pixels
        Display aspect ratio : 16:9
        Frame rate : 23.976 (24000/1001) FPS
        Bit depth : 10 bits
        Color primaries : BT.2020
        Encoding settings : crf=17.5 / preset=slow / pass=2

        Audio #1
        Format : E-AC-3
        Bit rate : 192 kb/s
        Channel(s) : 2 channels
        Language : Spanish

        Audio #2
        Format : E-AC-3 JOC
        Bit rate : 768 kb/s
        Channel(s) : 6 channels
        Language : English (US)
        Sampling rate : 48.0 kHz
        Frame rate : 31.250 FPS (1536 SPF)
              </div>
            </center>
          </div>
          <a name="usercomments"></a>
        </body></html>
        """
        let session = URLSession(configuration: MockURLProtocol.ephemeralConfiguration { _ in
            .immediate(status: 200, body: detailHTML)
        })
        let provider = RegexHTMLProvider(config: BuiltInProviderConfigs.torrentGalaxy, session: session)
        let result = TorrentSearchResult(
            title: "Movie 2025 1080p WEB-DL DDP5 1 H264-GROUP",
            magnet: nil,
            detailURL: URL(string: "https://torrentgalaxy.example/post-detail/abc/movie/"),
            seeders: 10,
            leechers: 2,
            provider: BuiltInProviderConfigs.torrentGalaxy.name
        )

        let metadata = try await provider.fetchDetailMetadata(for: result)
        #expect(metadata?.text?.contains("MEDIAINFO") == true)
        #expect(metadata?.text?.contains("Complete name : /downloads/Movie.2025.2160p.WEB-DL.mkv") == true)
        #expect(metadata?.text?.contains("E-AC-3 JOC") == true)
        #expect(metadata?.specs?.fullTorrentName == "Movie.2025.2160p.WEB-DL.mkv")
        #expect(metadata?.specs?.videoBitrate == "22.0 Mb/s")
        #expect(metadata?.specs?.resolutionWidth == "3840 px")
        #expect(metadata?.specs?.resolutionHeight == "2160 px")
        #expect(metadata?.specs?.frameRate == "23.976 (24000/1001) FPS")
        #expect(metadata?.specs?.bitDepth == "10 bits")
        #expect(metadata?.specs?.crf == "17.5")
        #expect(metadata?.specs?.preset == "slow")
        #expect(metadata?.specs?.encodingPasses == "2 passes")
        #expect(metadata?.specs?.colorGamut == "BT.2020")
        #expect(metadata?.specs?.dolbyVisionProfile == "Profile 5 (05)")
        #expect(metadata?.specs?.aspectRatio == "16:9")
        #expect(metadata?.specs?.bestEnglishAudioBitrate == "768 kb/s")
        #expect(metadata?.specs?.bestEnglishAudioSampleRate == "48.0 kHz")
        #expect(metadata?.specs?.allAudioTrackBitrates == ["Spanish E-AC-3: 192 kb/s", "English (US) E-AC-3 JOC: 768 kb/s"])
        #expect(metadata?.specs?.totalAudioTrackBitrate == "960 kb/s")
        #expect(metadata?.specs?.overallBitrate == "24.5 Mb/s")
        #expect(metadata?.specs?.calculatedVideoBitrate == nil)
        #expect(metadata?.specs?.runtime == "2 h 16 min")
    }

    @Test func detailMetadataExtractsTorrentGalaxyFileListFullName() async throws {
        let detailHTML = """
        <html><body>
          <div class="mediainfo">
            General<br>
            Format : Matroska<br>
            Duration : 1 h 40 min<br>
            Overall bit rate : 12.0 Mb/s
          </div>
          <div class="file-list">
            <ul><li>
              <li>Movie.2025.2160p.WEB-DL.DDP5.1.Atmos.H.265-GROUP.mkv</li>
            </li></ul>
          </div>
        </body></html>
        """
        let session = URLSession(configuration: MockURLProtocol.ephemeralConfiguration { _ in
            .immediate(status: 200, body: detailHTML)
        })
        let provider = RegexHTMLProvider(config: BuiltInProviderConfigs.torrentGalaxy, session: session)
        let result = TorrentSearchResult(
            title: "Movie 2025...",
            magnet: nil,
            detailURL: URL(string: "https://torrentgalaxy.example/post-detail/abc/movie/"),
            seeders: 10,
            leechers: 2,
            provider: BuiltInProviderConfigs.torrentGalaxy.name
        )

        let metadata = try await provider.fetchDetailMetadata(for: result)

        #expect(metadata?.text?.contains("Movie.2025.2160p.WEB-DL.DDP5.1.Atmos.H.265-GROUP.mkv") == true)
        #expect(metadata?.specs?.fullTorrentName == "Movie.2025.2160p.WEB-DL.DDP5.1.Atmos.H.265-GROUP.mkv")
        #expect(metadata?.specs?.releaseHintText?.contains("2160p") == true)
        #expect(metadata?.specs?.runtime == "1 h 40 min")
    }

    @Test func detailMetadataExtractsTorrentGalaxyFileListByLabelWhenClassIsGeneric() async throws {
        let detailHTML = """
        <html><body>
          <div class="mediainfo">
            General<br>
            Format : Matroska<br>
            Duration : 1 h 40 min<br>
            Overall bit rate : 12.0 Mb/s
          </div>
          <div class="card">
            <b>File List</b>
            <div class="row"><span>Movie.2025.2160p.BluRay.REMUX.TrueHD.7.1-GROUP.mkv</span></div>
          </div>
        </body></html>
        """
        let session = URLSession(configuration: MockURLProtocol.ephemeralConfiguration { _ in
            .immediate(status: 200, body: detailHTML)
        })
        let provider = RegexHTMLProvider(config: BuiltInProviderConfigs.torrentGalaxy, session: session)
        let result = TorrentSearchResult(
            title: "Movie 2025...",
            magnet: nil,
            detailURL: URL(string: "https://torrentgalaxy.example/post-detail/abc/movie/"),
            seeders: 10,
            leechers: 2,
            provider: BuiltInProviderConfigs.torrentGalaxy.name
        )

        let metadata = try await provider.fetchDetailMetadata(for: result)

        #expect(metadata?.specs?.fullTorrentName == "Movie.2025.2160p.BluRay.REMUX.TrueHD.7.1-GROUP.mkv")
        #expect(metadata?.specs?.releaseHintText?.contains("TrueHD") == true)
        #expect(metadata?.specs?.releaseHintText?.contains("7.1") == true)
    }

    @Test func pirateBayDetailMetadataUsesAPIDescription() async throws {
        let detailJSON = """
        {
          "descr": "MediaInfo\\nGeneral\\nDuration : 2 h 16 min\\nVideo\\nFormat : HEVC\\nHDR format : Dolby Vision\\nAudio\\nFormat : E-AC-3 JOC\\nChannel(s) : 6 channels"
        }
        """
        let session = URLSession(configuration: MockURLProtocol.ephemeralConfiguration { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("t.php?id=12345") {
                return .immediate(status: 200, body: detailJSON)
            }
            return .immediate(status: 200, body: "<html></html>")
        })
        let provider = PirateBayAPIProvider(config: BuiltInProviderConfigs.pirateBay, session: session)
        let result = TorrentSearchResult(
            title: "Movie 2025 2160p WEB-DL DDP5 1 H265-GROUP",
            magnet: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
            detailURL: URL(string: "https://thepiratebay.org/description.php?id=12345"),
            seeders: 10,
            leechers: 2,
            provider: BuiltInProviderConfigs.pirateBay.name
        )

        let metadata = try await provider.fetchDetailMetadata(for: result)
        #expect(metadata?.text?.contains("MediaInfo") == true)
        #expect(metadata?.text?.contains("E-AC-3") == true)
        #expect(metadata?.specs?.runtime == "2 h 16 min")
    }

    @Test func detailSpecParserFallsBackToAllAudioBitratesWhenVideoBitrateIsMissing() {
        let text = """
        MediaInfo
        General
        Duration : 1 h 44 min

        Video
        Format : AVC
        Width : 1 920 pixels
        Height : 1 040 pixels

        Audio #1
        Format : AAC
        Bit rate : 128 kb/s
        Language : English

        Audio #2
        Format : AC-3
        Bit rate : 640 kb/s
        Language : English
        """

        let specs = TorrentDetailSpecParser.parse(text)

        #expect(specs?.videoBitrate == nil)
        #expect(specs?.allAudioTrackBitrates == ["English AAC: 128 kb/s", "English AC-3: 640 kb/s"])
        #expect(specs?.totalAudioTrackBitrate == "768 kb/s")
        #expect(specs?.bestEnglishAudioBitrate == "640 kb/s")
    }

    @Test func detailSpecParserUsesDetailPageTitleWhenCompleteNameIsMissing() {
        let text = """
        MediaInfo
        General
        Duration : 1 h 44 min

        Video
        Format : AVC
        Width : 1 920 pixels
        Height : 1 040 pixels
        """

        let specs = TorrentDetailSpecParser.parse(
            text,
            detailTitle: "Movie.2025.1080p.WEB-DL.x264-GROUP",
            fallbackTitle: "Movie 2025..."
        )

        #expect(specs?.fullTorrentName == "Movie.2025.1080p.WEB-DL.x264-GROUP")
    }

    @Test func detailSpecParserHandles1337xDescriptionSpecs() {
        let text = """
        Title : Mortal Kombat II 2026 2160p iT WEB-DL DDP5 1 Atmos DV HDR H 265-BYNDR
        File Size : 20.01 GB
        Duration : 1 h 55 min
        Format : Matroska

        Video:
        Codec : HEVC
        Resolution : 3 840 pixels x 1 606 pixels
        Frame Rate : 23.976 FPS
        Bitrate : 24.0 Mb/s
        Overall Bitrate : 24.8 Mb/s

        Audio:
        Codec : E-AC-3 JOC
        Bitrate : 768 kb/s
        Language(s) : English
        """

        let specs = TorrentDetailSpecParser.parse(text)

        #expect(specs?.fullTorrentName == "Mortal Kombat II 2026 2160p iT WEB-DL DDP5 1 Atmos DV HDR H 265-BYNDR")
        #expect(specs?.videoBitrate == "24.0 Mb/s")
        #expect(specs?.resolutionWidth == "3840 px")
        #expect(specs?.resolutionHeight == "1606 px")
        #expect(specs?.frameRate == "23.976 FPS")
        #expect(specs?.overallBitrate == "24.8 Mb/s")
        #expect(specs?.totalAudioTrackBitrate == "768 kb/s")
        #expect(specs?.calculatedVideoBitrate == nil)
        #expect(specs?.runtime == "1 h 55 min")
        #expect(specs?.bestEnglishAudioBitrate == "768 kb/s")
        #expect(specs?.releaseHintText?.contains("HEVC") == true)
        #expect(specs?.releaseHintText?.contains("DDP 5.1 Atmos") == true)
    }

    @Test func detailSpecParserHandlesUploaderNoteStyleSpecs() {
        let text = """
        The.Matrix.1999.1080p.BluRay.DDP5.1.x265.10bit-GalaxyRG265[TGx]

        NOTE
        SOURCE: The.Matrix.1999.RERIP.2160p.BluRay.x265.10bit.SDR.DTS-HD.MA.TrueHD.7.1.Atmos-SWTYBLZ

        MEDIAINFO
        Container = Matroska (mkv)
        Duration = 02:16:18.671
        Filesize = 3 GiB
        --Video
        Codec info = HEVC Main 10@L4@Main | V_MPEGH/ISO/HEVC
        Resolution = 1920x800
        Display AR = 2.400 | 2.40:1
        Bitrate = 52.2 Mb/s
        Framerate = CFR 23.976
        Encoder = x265 - 3.5:[Linux][GCC 10.2.1][64 bit] 10bit
        --Audio
        Codec info = E-AC-3 | A_EAC3
        Channels = 6
        Bitrate = CBR 384 kb/s
        Samplerate = 48.0 kHz
        Language = English
        """

        let specs = TorrentDetailSpecParser.parse(text)

        #expect(specs?.fullTorrentName == "The.Matrix.1999.1080p.BluRay.DDP5.1.x265.10bit-GalaxyRG265[TGx]")
        #expect(specs?.runtime == "02:16:18.671")
        #expect(specs?.resolutionWidth == "1920 px")
        #expect(specs?.resolutionHeight == "800 px")
        #expect(specs?.aspectRatio == "2.400 | 2.40:1")
        #expect(specs?.videoBitrate == "52.2 Mb/s")
        #expect(specs?.frameRate == "CFR 23.976")
        #expect(specs?.bitDepth == "10 bits")
        #expect(specs?.bestEnglishAudioBitrate == "CBR 384 kb/s")
        #expect(specs?.bestEnglishAudioSampleRate == "48.0 kHz")
        #expect(specs?.allAudioTrackBitrates == ["English E-AC-3 | A_EAC3: CBR 384 kb/s"])
        #expect(specs?.totalAudioTrackBitrate == "384 kb/s")
        #expect(specs?.releaseHintText?.contains("HEVC") == true)
        #expect(specs?.releaseHintText?.contains("DDP 5.1") == true)
    }

    @Test func detailSpecParserSumsAudioBitratesAcrossUploaderFormats() {
        let text = """
        MEDIAINFO
        General
        Duration : 01:50:00
        Overall BitRate = 12.0 Mb/s

        Video #1
        Codec: HEVC
        Resolution: 1920 x 804
        FrameRate: 23.976 fps

        Audio #1 English
        Codec: DTS-HD MA
        BitRate = 1 536 kb/s
        Language: English

        Audio #2 English Commentary
        Codec: AC-3
        BitRate=640 kb/s
        Language: English

        Audio: Spanish AAC 160 kb/s
        """

        let specs = TorrentDetailSpecParser.parse(text)

        #expect(specs?.videoBitrate == "9.66 Mb/s (9664 kb/s)")
        #expect(specs?.overallBitrate == "12.0 Mb/s")
        #expect(specs?.allAudioTrackBitrates == [
            "English DTS-HD MA: 1 536 kb/s",
            "English AC-3: 640 kb/s",
            "Spanish AAC: 160 kb/s"
        ])
        #expect(specs?.bestEnglishAudioBitrate == "1 536 kb/s")
        #expect(specs?.totalAudioTrackBitrate == "2.34 Mb/s (2336 kb/s)")
        #expect(specs?.calculatedVideoBitrate == "9.66 Mb/s (9664 kb/s)")
        #expect(specs?.calculatedFields.contains("videoBitrate") == true)
        #expect(specs?.calculatedFields.contains("calculatedVideoBitrate") == true)
    }

    @Test func detailSpecParserCalculatesMissingSpecsFromExistingData() {
        let text = """
        MEDIAINFO
        General
        Duration : 01:40:00

        Files
        Movie.2026.1080p.WEB-DL.mkv 9.00 GB
        Movie.2026.Sample.mkv 100 MB
        Movie.2026.nfo 10 KB

        Video
        Format : HEVC
        Width : 1920 pixels

        Audio #1
        Format : E-AC-3
        Bit rate : 640 kb/s
        Language : English

        Audio #2
        Format : AAC
        Bit rate : 128 kb/s
        Language : Spanish
        """

        let specs = TorrentDetailSpecParser.parse(text)

        #expect(specs?.resolutionWidth == "1920 px")
        #expect(specs?.resolutionHeight == nil)
        #expect(specs?.overallBitrate == "12 Mb/s (12000 kb/s)")
        #expect(specs?.totalAudioTrackBitrate == "768 kb/s")
        #expect(specs?.videoBitrate == "11.23 Mb/s (11232 kb/s)")
        #expect(specs?.calculatedVideoBitrate == "11.23 Mb/s (11232 kb/s)")
        #expect(specs?.calculatedFields.contains("overallBitrate") == true)
        #expect(specs?.calculatedFields.contains("videoBitrate") == true)
        #expect(specs?.calculatedFields.contains("totalAudioTrackBitrate") == true)
    }

    @Test func detailSpecParserSubtractsSubtitleFileSizesBeforeOverallBitrateFallback() {
        let text = """
        MEDIAINFO
        General
        Duration : 01:40:00
        File Size : 9.10 GB

        Files
        Movie.2026.en.srt 50 MB
        Movie.2026.es.srt 50 MB

        Video
        Format : HEVC

        Audio
        Format : E-AC-3
        Bit rate : 640 kb/s
        Language : English
        """

        let specs = TorrentDetailSpecParser.parse(text)

        #expect(specs?.overallBitrate == "12 Mb/s (12000 kb/s)")
        #expect(specs?.videoBitrate == "11.36 Mb/s (11360 kb/s)")
    }

    @Test func detailSpecParserSubtractsSubtitleBitratesFromCalculatedVideoBitrate() {
        let text = """
        MEDIAINFO
        General
        Overall bit rate : 12.0 Mb/s

        Video
        Format : HEVC

        Audio
        Format : E-AC-3
        Bit rate : 640 kb/s
        Language : English

        Subtitle
        Format : PGS
        Bit rate : 80 kb/s
        """

        let specs = TorrentDetailSpecParser.parse(text)

        #expect(specs?.videoBitrate == "11.28 Mb/s (11280 kb/s)")
    }

    @Test func detailSpecParserDerivesAudioFromOverallMinusExplicitVideo() {
        let specs = TorrentDetailSpecParser.parse("""
        MediaInfo
        General
        Overall bit rate : 12.0 Mb/s

        Video
        Bit rate : 10.0 Mb/s

        Audio
        Format : E-AC-3
        Channel(s) : 6 channels
        Language : English
        """)

        #expect(specs?.videoBitrate == "10.0 Mb/s")
        #expect(specs?.calculatedVideoBitrate == nil)
        #expect(specs?.bestEnglishAudioBitrate == "2 Mb/s (2000 kb/s)")
        #expect(specs?.calculatedFields.contains("bestEnglishAudioBitrate") == true)
    }

    @Test func detailSpecParserDoesNotFoldChannelSuffixIntoAudioBitrate() {
        let specs = TorrentDetailSpecParser.parse("""
        MediaInfo
        General
        Overall bit rate : 50.0 Mb/s

        Audio #1 TrueHD 7.1 4338 kbps
        Format : TrueHD

        Audio #2 DD 5.1 640 kbps
        Format : AC-3
        """)

        #expect(specs?.allAudioTrackBitrates == [
            "TrueHD: 4338 kbps",
            "AC-3: 640 kbps"
        ])
        #expect(specs?.totalAudioTrackBitrate == "4.98 Mb/s (4978 kb/s)")
        #expect(specs?.bestEnglishAudioBitrate == "4338 kbps")
        #expect(specs?.releaseHintText?.contains("TrueHD 7.1") == true)
    }

    @Test func detailSpecParserUsesBestAudioTrackWhenLanguageIsMissing() {
        let result = TorrentSearchResult(
            title: "Movie.2025.1080p.BluRay.x265-GROUP",
            detailSpecs: TorrentDetailSpecParser.parse("""
            MediaInfo
            Audio #1 TrueHD 7.1 4338 kbps
            Format : TrueHD
            """),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        let ranked = TorrentRanker.score(result)

        #expect(ranked.parsed.audioCodec == .truehd)
        #expect(ranked.parsed.channels == .sevenOne)
    }

    @Test func detailSpecParserSplitsCompoundInlineAudioTracks() {
        let result = TorrentSearchResult(
            title: "Movie.2025.1080p.BluRay.x265-GROUP",
            detailSpecs: TorrentDetailSpecParser.parse("""
            MediaInfo
            Audio 1.........: English TrueHD 7.1 Ch 4426 kbps /English DD5.1 Ch 640 kbps
            """),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        let ranked = TorrentRanker.score(result)

        #expect(result.detailSpecs?.allAudioTrackBitrates == [
            "English TrueHD: 4426 kbps",
            "English AC-3: 640 kbps"
        ])
        #expect(result.detailSpecs?.totalAudioTrackBitrate == "5.07 Mb/s (5066 kb/s)")
        #expect(ranked.parsed.audioCodec == .truehd)
        #expect(ranked.parsed.channels == .sevenOne)
    }

    @Test func detailSpecParserTreatsLooseAudioRowsAsStructuredTracks() {
        let result = TorrentSearchResult(
            title: "Movie.2025.1080p.BluRay.DD.x264-GROUP",
            detailSpecs: TorrentDetailSpecParser.parse("""
            Audio: Dolby AC3 48000Hz stereo [A: Czech [cze] (ac3, 48000 Hz, stereo, 384 kb/s) [default]]: 384kbps
            Audio: DTS 48000Hz 6ch [A: English [eng] (dts-hd ma, 48000 Hz, 5.1(side), s16)]: 4608kbps
            Audio: DTS 48000Hz 6ch [A: English [eng] (dts, 48000 Hz, 5.1(side), 1536 kb/s)]: 1536kbps
            """),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        let ranked = TorrentRanker.score(result)

        #expect(result.detailSpecs?.bestEnglishAudioBitrate == "4608kbps")
        #expect(result.detailSpecs?.bestEnglishAudioSampleRate == "48000 Hz")
        #expect(ranked.parsed.audioCodec == .dtsHDMA)
        #expect(ranked.parsed.channels == .fiveOne)
    }

    @Test func detailSpecParserLetsDetailedBitrateAndChannelsChooseAACOverAC3() {
        let result = TorrentSearchResult(
            title: "Movie.2025.1080p.WEB-DL.AC3.5.1-GROUP",
            detailSpecs: TorrentDetailSpecParser.parse("""
            Audio: English AC3 5.1 640 kbps
            Audio: English AAC 7.1 1 008 kbps
            """),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        let ranked = TorrentRanker.score(result)

        #expect(result.detailSpecs?.bestEnglishAudioBitrate == "1 008 kbps")
        #expect(ranked.parsed.audioCodec == .aac)
        #expect(ranked.parsed.channels == .sevenOne)
    }

    @Test func detailSpecParserStopsAudioAtSubtitleSectionBoundary() {
        let specs = TorrentDetailSpecParser.parse("""
        Audio #5
        ID : 6
        Format : AAC
        Format/Info : Advanced Audio Codec
        Format profile : LC
        Codec ID : A_AAC
        Duration : 1 h 55 min
        Bit rate : 72.0 kb/s
        Channel(s) : 2 channels
        Sampling rate : 48.0 kHz
        Title : Alternate music score
        Language : English

        Subtitle #1
        ID : 7
        Format : UTF-8
        Codec ID : S_TEXT/UTF8
        Codec ID/Info : UTF-8 Plain Text
        Bit rate : 40 b/s
        Language : English
        """)

        #expect(specs?.allAudioTrackBitrates == ["English AAC: 72.0 kb/s"])
        #expect(specs?.releaseHintText?.contains("UTF-8") != true)
    }

    @Test func detailSpecParserSplitsParallelSlashDelimitedAudioFields() {
        let specs = TorrentDetailSpecParser.parse("""
        Audio                 : English
        Format                : DTS-HD MA
        Bit rate              : 5000 Kbps / 1509 Kbps
        Channel(s)            : 8 (7.1) / 6 (5.1)
        Sampling rate         : 48.0 KHz 24-bit
        Compression mode      : Lossless / Lossy
        """)

        #expect(specs?.allAudioTrackBitrates == [
            "English DTS-HD MA: 5000 Kbps",
            "English DTS: 1509 Kbps"
        ])
        #expect(specs?.totalAudioTrackBitrate == "6.51 Mb/s (6509 kb/s)")
        #expect(specs?.releaseHintText?.contains("DTS-HD MA 7.1") == true)
    }

    @Test func detailSpecParserParsesWrappedTorrentGalaxyAudioRowsAndPrefersDDPAtmos() {
        let specs = TorrentDetailSpecParser.parse("""
        Audio 01: Dolby TrueHD + ATMOS 7.1 Lossless (English/Main) @9216
        kb/s (vbr) 48.0 KHZ
        Audio 02: DD+ ATMOS 7.1 [5.1.2] (English/Main) @1664 kb/s (cbr) 48.0
        kHz None Lossless English Players I gotcha'
        Audio 03: Dolby Surround EX 5.1 (English/Main) @640 kb/s (cbr) 48.0 kHz Audio 04: DTS-HD Master Audio 5.1 Lossless (English/Main) @6912 kb/s
        (vbr) 48.0 kHz Original UHD Bluray Audio
        Audio 05: Dolby Digital 5.1 (English/Main) @640 kb/s (cbr) 48.0 kHz [
        Audio Descriptive ]
        Audio 06: DTS-HD Master Audio 5.1 Lossless (French/Main) @4608 kb/s
        (vbr) 48.0 kHz Original UHD Bluray Audio
        Audio 07: DTS-HD Master Audio 5.1 Lossless (German/Main) @4608 kb/s
        (vbr) 48.0 kHz Original UHD Bluray Audio
        Audio 08: Dolby Digital 5.1 (Italian/Main) @640 kb/s (cbr) 48.0 kHz
        Audio 09: Dolby Digital 5.1 (Portuguese/Main) @640 kb/s (cbr) 48.0 kHz
        Audio 10: Dolby Digital 5.1 (Spanish/Main) @640 kb/s (cbr) 48.0 kHz Audio 11: Dolby Digital 5.1 (Latin American/Spanish/Main) @640 kb/s
        (cbr) 48.0 kHz
        Audio 12: Dolby Digital 5.1 (Czech/Main) @640 kb/s (cbr) 48.0 kHz Audio 13: Dolby Digital 5.1 (Polish/Main) @640 kb/s (cbr) 48.0 KHz Audio 14: Dolby Digital 5.1 (Russian/Main) @640 kb/s (cbr) 48.0 kHz Audio 15: Dolby Digital 5.1 (Japanese/Main) @640 kb/s (cbr) 48.0 kHz
        """)

        let ranked = TorrentRanker.score(TorrentSearchResult(
            title: "Movie.2025.2160p.UHD.BluRay.REMUX.TrueHD.7.1.Atmos.H265-GROUP",
            detailSpecs: specs,
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        ))

        #expect(specs?.allAudioTrackBitrates.count == 15)
        #expect(specs?.totalAudioTrackBitrate == "33.41 Mb/s (33408 kb/s)")
        #expect(specs?.bestEnglishAudioBitrate == "1664 kb/s")
        #expect(specs?.bestEnglishAudioSampleRate == "48.0 kHz")
        #expect(specs?.releaseHintText?.contains("DDP 7.1 Atmos") == true)
        #expect(ranked.parsed.audioCodec == .ddp)
        #expect(ranked.parsed.channels == .sevenOne)
        #expect(ranked.parsed.atmos == true)
    }

    @Test func detailSpecParserParsesTorrentGalaxyOverallBitrateAndAllWrappedAudioRows() {
        let specs = TorrentDetailSpecParser.parse("""
        [I Video File iNFO:......................:-]]
        Release:
        The.Matrix.1999.UNCUT.UHD.2160p.REMUX.Hybrid.HDR10.DV.P7.DTS-
        HD.TrueHD.7.1.ATMOS.H265-KC
        File Name: the.matrix.1999.uncut.4k-kc.mkv
        Container: Matroska v4
        Codec iNFO: V_MPEGH / ISO / HEVC
        Colour Space: YUV / iSO Subsampling 4:2:0 / BT.2020 / HDR10 /
        Dolby Vision P7.6 / BL+EL+RPU / SMPTE ST 2086
        Profile: Main 10@ L5.1 @High
        Bit Depth: 10 Bit
        Size: 56.4 GB approx.
        Chapters: 1 to 38 (Fixed & named)
        Runtime: 2 Hour 17 minutes approx.
        Resolution: 3840×2160
        Aspect Ratio: 16:9 (w/Bars/Borders)
        Frame Rate: 23.976
        Overall Bitrate: 59.2 Mb/s (obr)
        Language: English
        [[ Audio & Subtitle iNFO:........................:-]]
        Audio 3: DTS-HD Master Audio 7.1 Lossless (English/Main) @9216
        kb/s (vbr) 48.0 kHz
        Audio 2: DD+ 7.1 with 5.1 Core (English/Main) @1024 kb/s (cbr) 48.0 kHz None Lossless English Players I gotcha'
        Audio 1: Dolby TrueHD + ATMOS 7.1 Lossless (English/Main) @9216
        kb/s (vbr) 48.0 kHz
        Audio 4: DD 2.0 (English/Commentary #1) @192 kb/s (cbr) 48.0 kHz
        Philosopher Commentary by Dr. Cornel West and Ken Wilber
        Audio 5: DD 2.0 (English/Commentary #2) @192 kb/s (cbr) 48.0 kHz
        Critics Commentary by Todd McCarthy John Powers and David Thomson
        """)

        #expect(specs?.overallBitrate == "59.2 Mb/s")
        #expect(specs?.allAudioTrackBitrates.count == 5)
        #expect(specs?.totalAudioTrackBitrate == "19.84 Mb/s (19840 kb/s)")
        #expect(specs?.bestEnglishAudioBitrate == "9216 kb/s")
        #expect(specs?.bestEnglishAudioSampleRate == "48.0 kHz")
    }

    @Test func detailSpecParserUsesNominalVideoBitrateWhenBitrateIsVariable() {
        let specs = TorrentDetailSpecParser.parse("""
        Video
        Runtime: 1:44:47 (h:m:s)
        Bit rate: Variable
        Nominal Bit rate: 9 531 Kbps
        Width: 1 920 pixels
        Height: 1 080 pixels
        Display aspect ratio : 16:9
        Frame rate: 23.976 fps
        Total Bit rate: 14.6 Mbps
        """)

        #expect(specs?.videoBitrate == "9 531 Kbps")
        #expect(specs?.overallBitrate == "14.6 Mbps")
        #expect(specs?.resolutionWidth == "1920 px")
        #expect(specs?.resolutionHeight == "1080 px")
    }

    @Test func detailSpecParserParses1337xSummaryStyleMediaInfoBlocks() {
        let specs = TorrentDetailSpecParser.parse("""
        General : Contact 1997 Upscaled BluRay 2160p HDR10 HEVC DTS-HD MA 5.1 x265-E\\Contact 1997.mkv
        Format : Matroska at 25.4 Mb/s
        Length : 26.5 GiB for 2 h 29 min 40 s 388 ms

        Video #0 : HEVC at 22.2 Mb/s
        Aspect : 3840 x 1606 (2.391) at 23.976 fps

        Audio #0 : DTS at 2 290 kb/s
        Infos : 6 channels, 48.0 kHz
        Language : en

        Audio #1 : AC-3 at 192 kb/s
        Infos : 2 channels, 48.0 kHz
        Language : en

        Audio #2 : AC-3 at 192 kb/s
        Infos : 2 channels, 48.0 kHz
        Language : en

        Audio #3 : AC-3 at 192 kb/s
        Infos : 2 channels, 48.0 kHz
        Language : en

        Text #0 : PGS
        Language : en

        HEVC, Main [email protected]@High, SMPTE ST 2086, HDR10 compatible
        """)

        #expect(specs?.fullTorrentName == "Contact 1997.mkv")
        #expect(specs?.runtime == "2 h 29 min 40 s 388 ms")
        #expect(specs?.overallBitrate == "25.4 Mb/s")
        #expect(specs?.videoBitrate == "22.2 Mb/s")
        #expect(specs?.resolutionWidth == "3840 px")
        #expect(specs?.resolutionHeight == "1606 px")
        #expect(specs?.aspectRatio == "2.391:1")
        #expect(specs?.frameRate == "23.976 fps")
        #expect(specs?.allAudioTrackBitrates == [
            "English DTS: 2 290 kb/s",
            "English AC-3: 192 kb/s",
            "English AC-3: 192 kb/s",
            "English AC-3: 192 kb/s"
        ])
        #expect(specs?.totalAudioTrackBitrate == "2.87 Mb/s (2866 kb/s)")
        #expect(specs?.bestEnglishAudioBitrate == "2 290 kb/s")
        #expect(specs?.bestEnglishAudioSampleRate == "48.0 kHz")
        #expect(specs?.releaseHintText?.contains("DTS 5.1") == true)
    }

    @Test func detailSpecParserCalculatesAspectRatioAndMissingDimension() {
        let dimensionsOnly = """
        Video
        Width : 1 920 pixels
        Height : 800 pixels
        """
        let widthAndAspectRatio = """
        Video
        Width : 1 920 pixels
        Display aspect ratio : 16:9
        """

        let dimensionsOnlySpecs = TorrentDetailSpecParser.parse(dimensionsOnly)
        let widthAndAspectRatioSpecs = TorrentDetailSpecParser.parse(widthAndAspectRatio)

        #expect(dimensionsOnlySpecs?.aspectRatio == "12:5 (2.40:1)")
        #expect(dimensionsOnlySpecs?.calculatedFields.contains("aspectRatio") == true)
        #expect(widthAndAspectRatioSpecs?.resolutionHeight == "1080 px")
        #expect(widthAndAspectRatioSpecs?.calculatedFields.contains("resolutionHeight") == true)
        #expect(widthAndAspectRatioSpecs?.aspectRatio == "16:9")
        #expect(widthAndAspectRatioSpecs?.calculatedFields.contains("aspectRatio") == false)
    }

    @Test func detailSpecParserRejectsWildlyInvalidResolutionAndFallsBackToTitle() {
        let specs = TorrentDetailSpecParser.parse("""
        MediaInfo
        General
        Complete name : Contact.1997.1080p.BluRay.REMUX.mkv

        Video
        Format : AVC
        Width : 1 920 pixels
        Height : 108023 pixels
        """)

        #expect(specs?.resolutionWidth == "1920 px")
        #expect(specs?.resolutionHeight == "1080 px")
        #expect(specs?.calculatedFields.contains("resolutionHeight") == true)

        let ranked = TorrentRanker.score(TorrentSearchResult(
            title: "Contact.1997.1080p.BluRay.REMUX-GROUP",
            detailSpecs: specs,
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        ))

        #expect(ranked.parsed.resolution == .p1080)
        #expect(ranked.parsed.sourceType == .remux)
        #expect(ranked.parsed.videoCodec == .avc)
        #expect(ranked.notes.contains { $0.contains("Source context") && $0.contains("+15") })
    }

    @Test func detailSpecParserParsesTotalBitRateAsOverallAndParenthesizedTwoPass() {
        let specs = TorrentDetailSpecParser.parse("""
        MediaInfo
        General
        Total bit rate : 12.0 Mb/s

        Video
        Format : AVC
        Bit rate : 10.0 Mb/s (2 pass)
        """)

        #expect(specs?.overallBitrate == "12.0 Mb/s")
        #expect(specs?.encodingPasses == "2 passes")
    }

    @Test func detailSpecParserSelectsDDPAtmosOverLosslessForAppleTV() {
        let specs = TorrentDetailSpecParser.parse("""
        General
        Complete name : Movie.2025.2160p.BluRay.REMUX.mkv

        Audio
        Format : MLP FBA
        Commercial name : Dolby TrueHD with Dolby Atmos
        Channel(s) : 8 channels
        Bit rate : 4 000 kb/s
        Language : English

        Audio
        Format : E-AC-3 JOC
        Bit rate : 768 kb/s
        Language : English
        """)

        #expect(specs?.bestEnglishAudioBitrate == "768 kb/s")
        #expect(specs?.releaseHintText?.contains("DDP 5.1 Atmos") == true)
    }

    @Test func detailSpecParserUsesCommercialNameForDDPAtmosPriority() {
        let specs = TorrentDetailSpecParser.parse("""
        General
        Complete name : Movie.2025.2160p.WEB-DL.mkv

        Audio
        Format : MLP FBA
        Commercial name : Dolby TrueHD with Dolby Atmos
        Channel(s) : 8 channels
        Bit rate : 4 000 kb/s
        Language : English

        Audio
        Format : E-AC-3
        Commercial name : Dolby Digital Plus with Dolby Atmos
        Channel(s) : 8 channels
        Bit rate : 1 024 kb/s
        Language : English
        """)

        #expect(specs?.bestEnglishAudioBitrate == "1 024 kb/s")
        #expect(specs?.releaseHintText?.contains("DDP 7.1 Atmos") == true)
    }

    @Test func detailPageTitleCleanupRejectsGenericProviderTitles() {
        #expect("Download Latest Top Torrents by Subcategories torrentGalaxy".cleanedDetailPageTitle.isEmpty)
        #expect("Search for Category: Movies, Free Fast, Download. Torrent torrentGalaxy".cleanedDetailPageTitle.isEmpty)
        #expect("Download Mortal Kombat II 2026 2160p iT WEB-DL DDP5 1 Atmos DV HDR H 265-BYNDR Torrent | 1337x".cleanedDetailPageTitle == "Mortal Kombat II 2026 2160p iT WEB-DL DDP5 1 Atmos DV HDR H 265-BYNDR")
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

    @Test func rankerAllowsVc1ButStillExcludesUnsupportedLegacyCodecVariants() {
        let vc1 = TorrentSearchResult(
            title: "Movie.2025.1080p.BluRay.VC 1-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )
        let divx = TorrentSearchResult(
            title: "Movie.2025.1080p.BluRay.DivX-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        let rankedVC1 = TorrentRanker.score(vc1)
        let rankedDivX = TorrentRanker.score(divx)
        #expect(rankedVC1.excluded == false)
        #expect(rankedVC1.parsed.videoCodec == .vc1)
        #expect(rankedVC1.notes.contains { $0.contains("Video codec compatibility") && $0.contains("-30") })
        #expect(rankedDivX.excluded == true)
    }

    @Test func uhdRemuxReceivesSourceAndRemuxContextWithoutOldTopTierBonus() {
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
        #expect(rankedTopTier.score > rankedNonTopTier.score)
        #expect(rankedTopTier.notes.contains { $0.contains("Encode/remux signal") && $0.contains("+15") })
        #expect(rankedTopTier.notes.contains { $0.contains("Source context") && $0.contains("+25") })
    }

    @Test func plain1080pBlurayRemuxDoesNotBecomeUHDRemux() {
        let result = TorrentSearchResult(
            title: "Contact.1997.1080p.BluRay.REMUX-GROUP",
            detailSpecs: TorrentDetailSpecParser.parse("""
            MediaInfo
            General
            Complete name : Contact.1997.1080p.BluRay.REMUX.mkv

            Video
            Format : AVC
            Width : 1 920 pixels
            Height : 1 080 pixels
            """),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        let ranked = TorrentRanker.score(result)
        #expect(ranked.parsed.resolution == .p1080)
        #expect(ranked.parsed.dynamicRange == .sdr)
        #expect(ranked.parsed.videoCodec == .avc)
        #expect(ranked.notes.contains { $0.contains("Source context") && $0.contains("+15") })
    }

    @Test func rankerUsesFullDetailTorrentNameForMissingSearchResultTokens() {
        let result = TorrentSearchResult(
            title: "Movie 2025...",
            detailSpecs: TorrentDetailSpecParser.parse("""
            File list
            Movie.2025.2160p.WEB-DL.DDP5.1.Atmos.H.265-GROUP.mkv
            """, fallbackTitle: "Movie 2025..."),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        let ranked = TorrentRanker.score(result)

        #expect(ranked.parsed.resolution == .p2160)
        #expect(ranked.parsed.audioCodec == .ddp)
        #expect(ranked.parsed.channels == .fiveOne)
        #expect(ranked.parsed.atmos == true)
    }

    @Test func rankerAlwaysExcludesRiffTraxReleases() {
        let result = TorrentSearchResult(
            title: "Movie.2025.1080p.BluRay.RiffTrax.x264-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        let ranked = TorrentRanker.score(result)

        #expect(ranked.excluded == true)
        #expect(ranked.notes.contains("Excluded: RiffTrax release"))
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

        let imaxScore = TorrentRanker.score(imax)
        let standardScore = TorrentRanker.score(standard)
        #expect(imaxScore.score > standardScore.score)
        #expect(imaxScore.notes.contains { $0.contains("Expanded aspect ratio") && $0.contains("+15") })
    }

    @Test func pictureQualityUsesBitrateDensityAndResolutionTogether() {
        let healthy2160p = TorrentSearchResult(
            title: "Movie.2025.2160p.WEB-DL.DDP5.1.HDR.HEVC-GROUP",
            detailSpecs: TorrentDetailSpecs(
                videoBitrate: "22 Mb/s",
                resolutionWidth: "3840 px",
                resolutionHeight: "2160 px",
                frameRate: "23.976 FPS",
                bestEnglishAudioBitrate: "768 kb/s",
                releaseHintText: "2160p HEVC HDR DDP 5.1"
            ),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )
        let perfect1080p = TorrentSearchResult(
            title: "Movie.2025.1080p.BluRay.DDP5.1.HDR.HEVC-GROUP",
            detailSpecs: TorrentDetailSpecs(
                videoBitrate: "60 Mb/s",
                resolutionWidth: "1920 px",
                resolutionHeight: "1080 px",
                frameRate: "23.976 FPS",
                bestEnglishAudioBitrate: "768 kb/s",
                releaseHintText: "1080p HEVC HDR DDP 5.1"
            ),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )
        let bad2160p = TorrentSearchResult(
            title: "Movie.2025.2160p.WEBRip.DDP5.1.HDR.HEVC-GROUP",
            detailSpecs: TorrentDetailSpecs(
                videoBitrate: "3 Mb/s",
                resolutionWidth: "3840 px",
                resolutionHeight: "2160 px",
                frameRate: "23.976 FPS",
                bestEnglishAudioBitrate: "768 kb/s",
                releaseHintText: "2160p HEVC HDR DDP 5.1"
            ),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        #expect(TorrentRanker.score(healthy2160p).score > TorrentRanker.score(perfect1080p).score)
        #expect(TorrentRanker.score(bad2160p).score < TorrentRanker.score(perfect1080p).score)
    }

    @Test func rankerDerivesVideoBitrateFromSizeRuntimeAndAudio() {
        let result = TorrentSearchResult(
            title: "Movie.2025.1080p.WEB-DL.DDP5.1.H265-GROUP",
            detailSpecs: TorrentDetailSpecs(
                bestEnglishAudioBitrate: "640 kb/s",
                runtime: "1 h 40 min"
            ),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A",
            size: "4.98 GB"
        )

        let breakdown = TorrentRanker.qualityBreakdown(for: result)
        #expect(breakdown.video.bitrateIsEstimated == false)
        #expect(breakdown.video.bitrateSourceLabel == "derived from size/runtime")
        #expect(breakdown.video.bitrateKbps > 5_900)
        #expect(breakdown.video.bitrateKbps < 6_100)
    }

    @Test func rankerDerivesVideoBitrateFromTitleEstimatedAudioWhenDetailAudioIsMissing() {
        let result = TorrentSearchResult(
            title: "Movie.2025.1080p.WEB-DL.DDP5.1.H265-GROUP",
            detailSpecs: TorrentDetailSpecs(runtime: "1 h 40 min"),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A",
            size: "4.98 GB"
        )

        let breakdown = TorrentRanker.qualityBreakdown(for: result)
        #expect(breakdown.audio.bitrateKbps == 640)
        #expect(breakdown.audio.bitrateIsEstimated == true)
        #expect(breakdown.video.bitrateIsEstimated == false)
        #expect(breakdown.video.bitrateSourceLabel == "derived from size/runtime + estimated audio")
        #expect(breakdown.video.bitrateKbps > 5_900)
        #expect(breakdown.video.bitrateKbps < 6_100)
    }

    @Test func rankerEstimatesLosslessAudioBitrateFromTitleCodecAndChannels() {
        let result = TorrentSearchResult(
            title: "Movie.2025.2160p.UHD.BluRay.TrueHD.7.1.HEVC-GROUP",
            detailSpecs: TorrentDetailSpecs(runtime: "2 h 0 min"),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A",
            size: "40 GB"
        )

        let breakdown = TorrentRanker.qualityBreakdown(for: result)

        #expect(breakdown.audio.bitrateKbps == 4_500)
        #expect(breakdown.audio.bitrateIsEstimated == true)
        #expect(breakdown.video.bitrateIsEstimated == false)
        #expect(breakdown.video.bitrateSourceLabel == "derived from size/runtime + estimated audio")
    }

    @Test func calculatedFallbackSpecsDoNotCountAsDetailPageMetadata() {
        let fallback = TorrentDetailSpecs().withFallbackRuntime("1 h 40 min", overallBitrate: "6.64 Mb/s (6640 kb/s)")
        let detail = TorrentDetailSpecs(
            videoBitrate: "9.66 Mb/s (9664 kb/s)",
            calculatedFields: ["videoBitrate"]
        )
        let explicitDetail = TorrentDetailSpecs(videoBitrate: "10.0 Mb/s")

        #expect(fallback.hasDisplayableFields == true)
        #expect(fallback.hasDetailPageMetadataFields == false)
        #expect(detail.hasDetailPageMetadataFields == false)
        #expect(explicitDetail.hasDetailPageMetadataFields == true)
    }

    @Test func explicitDetailRuntimeAndOverallReplaceCalculatedFallbacks() {
        let fallback = TorrentDetailSpecs(
            overallBitrate: "6.64 Mb/s (6640 kb/s)",
            runtime: "1 h 40 min",
            calculatedFields: ["overallBitrate", "runtime"]
        )
        let detail = TorrentDetailSpecs(
            overallBitrate: "8.0 Mb/s",
            runtime: "1 h 45 min"
        )

        let merged = detail.mergedMissingFields(from: fallback)

        #expect(merged.overallBitrate == "8.0 Mb/s")
        #expect(merged.runtime == "1 h 45 min")
        #expect(merged.calculatedFields.contains("overallBitrate") == false)
        #expect(merged.calculatedFields.contains("runtime") == false)
    }

    @Test func explicitFallbackCanReplaceCalculatedPreferredRuntimeAndOverall() {
        let calculated = TorrentDetailSpecs(
            overallBitrate: "6.64 Mb/s (6640 kb/s)",
            runtime: "1 h 40 min",
            calculatedFields: ["overallBitrate", "runtime"]
        )
        let explicit = TorrentDetailSpecs(
            overallBitrate: "8.0 Mb/s",
            runtime: "1 h 45 min"
        )

        let merged = calculated.mergedMissingFields(from: explicit)

        #expect(merged.overallBitrate == "8.0 Mb/s")
        #expect(merged.runtime == "1 h 45 min")
        #expect(merged.calculatedFields.contains("overallBitrate") == false)
        #expect(merged.calculatedFields.contains("runtime") == false)
    }

    @Test func rankerDoesNotIncludeVideoBitrateHeadroomScore() {
        let result = TorrentSearchResult(
            title: "Movie.2025.2160p.BluRay.REMUX.HDR.TrueHD.7.1-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        let ranked = TorrentRanker.score(result)
        #expect(!ranked.notes.contains { $0.contains("Video bitrate headroom") })
    }

    @Test func sourceEstimatedVideoBitrateIsCappedByOverallBitrateShare() {
        let standard = TorrentSearchResult(
            title: "Movie.2025.2160p.WEB-DL.HDR.HEVC-GROUP",
            detailSpecs: TorrentDetailSpecs(overallBitrate: "10 Mb/s"),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )
        let multi = TorrentSearchResult(
            title: "Movie.2025.2160p.WEB-DL.MULTi.HDR.HEVC-GROUP",
            detailSpecs: TorrentDetailSpecs(overallBitrate: "10 Mb/s"),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )
        let multiverse = TorrentSearchResult(
            title: "Movie.Multiverse.2025.2160p.WEB-DL.HDR.HEVC-GROUP",
            detailSpecs: TorrentDetailSpecs(overallBitrate: "10 Mb/s"),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        #expect(TorrentRanker.qualityBreakdown(for: standard).video.bitrateKbps == 9_000)
        #expect(TorrentRanker.qualityBreakdown(for: multi).video.bitrateKbps == 8_000)
        #expect(TorrentRanker.qualityBreakdown(for: multiverse).video.bitrateKbps == 9_000)
    }

    @Test func audioDensityCurveHasHigherFloorAndEarlierCeiling() {
        let highDensity = TorrentSearchResult(
            title: "Movie.2025.2160p.BluRay.REMUX.TrueHD.7.1.HEVC-GROUP",
            detailSpecs: TorrentDetailSpecs(bestEnglishAudioBitrate: "6.4 Mb/s"),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )
        let lowDensity = TorrentSearchResult(
            title: "Movie.2025.1080p.WEB-DL.AAC.2.0.x264-GROUP",
            detailSpecs: TorrentDetailSpecs(bestEnglishAudioBitrate: "64 kb/s"),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        let highBreakdown = TorrentRanker.qualityBreakdown(for: highDensity)
        let lowBreakdown = TorrentRanker.qualityBreakdown(for: lowDensity)

        #expect(highBreakdown.audio.density == 800)
        #expect(highBreakdown.audio.compressionHealth == 1.0)
        #expect((lowBreakdown.audio.density ?? 0) > 35)
        #expect((lowBreakdown.audio.density ?? 0) < 36)
        #expect(lowBreakdown.audio.compressionHealth > 0.82)
    }

    @Test func estimatedAudioBitrateIncreasesWithChannelCount() {
        let stereo = TorrentSearchResult(
            title: "Movie.2025.1080p.BluRay.DTS.2.0.x264-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )
        let surround = TorrentSearchResult(
            title: "Movie.2025.1080p.BluRay.DTS.5.1.x264-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        #expect(TorrentRanker.qualityBreakdown(for: stereo).audio.bitrateKbps == 768)
        #expect(TorrentRanker.qualityBreakdown(for: surround).audio.bitrateKbps == 1_509)
    }

    @Test func aacEfficiencyDoesNotOverrideAc3CodecCompatibilityScore() {
        let ranked = TorrentRanker.score(TorrentSearchResult(
            title: "Movie.2025.1080p.WEB-DL.AAC.5.1.x264-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        ))
        let breakdown = TorrentRanker.qualityBreakdown(for: ranked.raw)

        #expect(breakdown.audio.codecFactor == 1.10)
        #expect(ranked.notes.contains { $0.contains("Audio codec quality") && $0.contains("+3") && $0.contains("aac") })
    }

    @Test func rankerExcludesExplicitNonEnglishOnlyAudioTracks() {
        let result = TorrentSearchResult(
            title: "Movie.2025.1080p.WEB-DL.x264-GROUP",
            detailSpecs: TorrentDetailSpecParser.parse("""
            MediaInfo
            Audio
            Format : E-AC-3
            Channel(s) : 6 channels
            Language : Spanish
            """),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        let ranked = TorrentRanker.score(result)

        #expect(result.detailSpecs?.hasOnlyExplicitNonEnglishAudioTracks == true)
        #expect(ranked.excluded == true)
        #expect(ranked.notes.contains { $0.contains("non-English only") })
    }

    @Test func rankerDoesNotExcludeUnlabeledAudioTracks() {
        let result = TorrentSearchResult(
            title: "Movie.2025.1080p.WEB-DL.x264-GROUP",
            detailSpecs: TorrentDetailSpecParser.parse("""
            MediaInfo
            Audio
            Format : E-AC-3
            Channel(s) : 6 channels
            """),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        let ranked = TorrentRanker.score(result)

        #expect(result.detailSpecs?.hasOnlyExplicitNonEnglishAudioTracks == false)
        #expect(ranked.excluded == false)
    }

    @Test func explicitEightBitReceivesNoBitDepthCreditEvenForUHDBluray() {
        let result = TorrentSearchResult(
            title: "Movie.2025.2160p.BluRay.8-bit.HEVC-GROUP",
            detailSpecs: TorrentDetailSpecs(bitDepth: "8 bits"),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        let ranked = TorrentRanker.score(result)
        #expect(ranked.notes.contains { $0.contains("Bit depth") && $0.contains("+0") })
    }

    @Test func h264HDRReceivesNoDynamicRangeCredit() {
        let h264HDR = TorrentSearchResult(
            title: "Movie.2025.1080p.WEB-DL.HDR.H264.DDP5.1-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        let ranked = TorrentRanker.score(h264HDR)
        #expect(ranked.parsed.dynamicRange == .hdr)
        #expect(ranked.notes.contains { $0.contains("Dynamic range") && $0.contains("+0") && $0.contains("sdr") })
    }

    @Test func webHDRDoesNotInferUHDBluraySource() {
        let webHDR = TorrentSearchResult(
            title: "Movie.2025.1080p.WEB-DL.HDR.DV.HEVC.DDP5.1-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )
        let blurayHDR = TorrentSearchResult(
            title: "Movie.2025.1080p.BluRay.HDR.HEVC.DDP5.1-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        let webRanked = TorrentRanker.score(webHDR)
        let blurayRanked = TorrentRanker.score(blurayHDR)

        #expect(ReleaseParser.parse(webHDR.title).sourceType == .webdl)
        #expect(webRanked.notes.contains { $0.contains("Bit depth") && $0.contains("+0") })
        #expect(webRanked.notes.contains { $0.contains("Source context") && $0.contains("+6") })
        #expect(blurayRanked.notes.contains { $0.contains("Bit depth") && $0.contains("+12") })
        #expect(blurayRanked.notes.contains { $0.contains("Source context") && $0.contains("+18") })
    }

    @Test func rankerUsesDetailMetadataWhenPresent() {
        let titleOnly = TorrentSearchResult(
            title: "Movie 2025 1080p WEB-DL TrueHD 7.1 H264-GROUP",
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )
        let enriched = TorrentSearchResult(
            title: "Movie 2025 1080p WEB-DL TrueHD 7.1 H264-GROUP",
            detailSpecs: TorrentDetailSpecParser.parse("""
            MediaInfo
            General
            Complete name : Movie.2025.2160p.WEB-DL.mkv

            Video
            Format : HEVC
            HDR format : Dolby Vision, Version 1.0, dvhe.05.06
            Width : 3 840 pixels
            Height : 2 160 pixels

            Audio
            Format : E-AC-3 JOC
            Channel(s) : 6 channels
            Language : English
            """),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        let titleScore = TorrentRanker.score(titleOnly)
        let enrichedScore = TorrentRanker.score(enriched)
        #expect(enrichedScore.score > titleScore.score)
        #expect(enrichedScore.parsed.resolution == .p2160)
        #expect(enrichedScore.parsed.videoCodec == .hevc)
        #expect(enrichedScore.parsed.dynamicRange == .dolbyVision)
        #expect(enrichedScore.parsed.audioCodec == .ddp)
        #expect(enrichedScore.parsed.channels == .fiveOne)
        #expect(enrichedScore.parsed.atmos == true)
    }

    @Test func rankerUsesDetailResolutionOverDS4KTitleForScoring() {
        let result = TorrentSearchResult(
            title: "Movie.2025.1080p.DS4K.BluRay.x265.10-bit.HDR.AC3-GROUP",
            detailSpecs: TorrentDetailSpecs(
                videoBitrate: "10 Mb/s",
                resolutionWidth: "1920 px",
                resolutionHeight: "1080 px",
                frameRate: "23.976 FPS",
                releaseHintText: "1080p HEVC HDR DD 5.1"
            ),
            magnet: nil,
            detailURL: nil,
            seeders: 10,
            leechers: 2,
            provider: "A"
        )

        let ranked = TorrentRanker.score(result)
        #expect(ranked.parsed.resolution == .p1080)
        #expect(ranked.parsed.dynamicRange == .hdr)
        #expect(ranked.notes.contains { $0.contains("Picture quality") && $0.contains("1920x1080") })
        #expect(ranked.notes.contains { $0.contains("Source context") && $0.contains("+18") })
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
