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
        #expect(metadata?.specs?.calculatedVideoBitrate == "23.54 Mb/s (23540 kb/s)")
        #expect(metadata?.specs?.runtime == "2 h 16 min")
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
        #expect(specs?.calculatedVideoBitrate == "24.03 Mb/s (24032 kb/s)")
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
            "Audio: Spanish AAC: 160 kb/s"
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
