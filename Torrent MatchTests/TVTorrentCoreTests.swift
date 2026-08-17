import Foundation
import Testing
import TorrentMatcherCore

@Suite(.serialized)
struct TVTorrentCoreTests {
    @Test func typedRequestsProduceTVQueriesAndNumericEZTVIMDbIDs() {
        let episodeRequest = TorrentSearchRequest.tvEpisode(
            seriesTitle: "The Last of Us",
            year: 2023,
            imdbID: "tt3581920",
            aliases: ["Last of Us"],
            season: 1,
            episode: 2
        )
        let packRequest = TorrentSearchRequest.tvSeasonPack(
            seriesTitle: "The Last of Us",
            imdbID: "3581920",
            season: 1
        )
        let missingIMDbRequest = TorrentSearchRequest.tvEpisode(
            seriesTitle: "The Last of Us",
            season: 1,
            episode: 2
        )

        #expect(episodeRequest.rankingProfile == .television)
        #expect(episodeRequest.target.providerQuery == "The Last of Us S01E02")
        #expect(episodeRequest.providerQueries(for: "1337x") == [
            "The Last of Us 2023 S01E02",
            "The Last of Us S01E02"
        ])
        #expect(episodeRequest.providerQuery(for: "1337x") == "The Last of Us 2023 S01E02")
        #expect(episodeRequest.providerQuery(for: "eztv") == "3581920")
        #expect(episodeRequest.providerQueries(for: "eztv") == ["3581920"])
        #expect(packRequest.target.providerQuery == "The Last of Us S01")
        #expect(packRequest.providerQuery(for: "eztv") == "3581920")
        #expect(missingIMDbRequest.providerQuery(for: "eztv") == nil)

        let movieRequest = TorrentSearchRequest.movie("The Matrix 1999")
        #expect(movieRequest.rankingProfile == .movie)
        #expect(movieRequest.providerQuery(for: "1337x") == "The Matrix 1999")
        #expect(movieRequest.providerQueries(for: "1337x") == ["The Matrix 1999"])
        #expect(movieRequest.providerQuery(for: "eztv") == nil)
    }

    @Test func televisionProvidersUseTVCategoriesAndOmitMovieOnlyYTS() {
        let ids = Set(BuiltInProviderConfigs.television.map(\.id))

        #expect(ids == ["1337x", "pirate-bay", "torrentgalaxy", "magnetz", "eztv"])
        #expect(!ids.contains("yts"))
        #expect(BuiltInProviderConfigs.x1337TV.searchURLTemplate.contains("/TV/"))
        #expect(BuiltInProviderConfigs.pirateBayTV.searchURLTemplate.contains("cat=205"))
        #expect(BuiltInProviderConfigs.pirateBayTV.alternateSearchURLTemplates.contains {
            $0.contains("cat=208")
        })
        #expect(BuiltInProviderConfigs.torrentGalaxyTV.searchURLTemplate.contains("category:TV"))
        #expect(BuiltInProviderConfigs.eztv.searchURLTemplate.contains("imdb_id={{query}}"))
        #expect(BuiltInProviderConfigs.default == BuiltInProviderConfigs.movies)
    }

    @Test func parserRecognizesEpisodeSpellingsChainsAndRanges() throws {
        let compact = try #require(TVReleaseParser.parse(
            "The.Show.S01E02.Pilot.2160p.WEB-DL.HEVC-GROUP"
        ))
        let alternate = try #require(TVReleaseParser.parse(
            "The Show 1x02 Pilot 1080p WEB-DL x264-GROUP"
        ))
        let verbose = try #require(TVReleaseParser.parse(
            "The Show Season 1 Episode 2 Pilot 1080p HDTV x264-GROUP"
        ))
        let chained = try #require(TVReleaseParser.parse(
            "The.Show.S01E01E02E03.1080p.WEB-DL.x264-GROUP"
        ))
        let ranged = try #require(TVReleaseParser.parse(
            "The.Show.S01E03-E05.1080p.WEB-DL.x264-GROUP"
        ))

        #expect(compact.seriesTitle == "The.Show")
        #expect(compact.coverage == .episodes([TVEpisodeIdentifier(season: 1, episode: 2)]))
        #expect(alternate.coverage.contains(TVEpisodeIdentifier(season: 1, episode: 2)))
        #expect(verbose.coverage.contains(TVEpisodeIdentifier(season: 1, episode: 2)))
        #expect(chained.coverage.episodes == [
            TVEpisodeIdentifier(season: 1, episode: 1),
            TVEpisodeIdentifier(season: 1, episode: 2),
            TVEpisodeIdentifier(season: 1, episode: 3)
        ])
        #expect(ranged.coverage.episodes == [
            TVEpisodeIdentifier(season: 1, episode: 3),
            TVEpisodeIdentifier(season: 1, episode: 4),
            TVEpisodeIdentifier(season: 1, episode: 5)
        ])
    }

    @Test func parserRecognizesSeasonAndCompleteSeriesCoverage() throws {
        let singleSeason = try #require(TVReleaseParser.parse(
            "The.Show.Season.2.Complete.1080p.BluRay.x265-GROUP"
        ))
        let seasonRange = try #require(TVReleaseParser.parse(
            "The.Show.S01-S03.Complete.1080p.BluRay.x265-GROUP"
        ))
        let completeSeries = try #require(TVReleaseParser.parse(
            "The.Show.The.Complete.Series.1080p.BluRay.x265-GROUP"
        ))
        let verboseSeasonRange = try #require(TVReleaseParser.parse(
            "The.Show.Season.1-3.Complete.1080p.BluRay.x265-GROUP"
        ))
        let pluralSeasonRange = try #require(TVReleaseParser.parse(
            "The.Show.Seasons.1-3.Complete.1080p.BluRay.x265-GROUP"
        ))
        let wordSeasonRange = try #require(TVReleaseParser.parse(
            "The.Show.Season.1.to.3.Complete.1080p.BluRay.x265-GROUP"
        ))

        #expect(singleSeason.coverage == .seasons([2]))
        #expect(seasonRange.coverage == .seasons([1, 2, 3]))
        #expect(verboseSeasonRange.coverage == .seasons([1, 2, 3]))
        #expect(pluralSeasonRange.coverage == .seasons([1, 2, 3]))
        #expect(wordSeasonRange.coverage == .seasons([1, 2, 3]))
        #expect(completeSeries.coverage == .completeSeries)
        #expect(singleSeason.coverage.isSeasonPack)
        #expect(completeSeries.coverage.contains(TVEpisodeIdentifier(season: 99, episode: 1)))
    }

    @Test func seasonPackTargetRejectsMultiSeasonAndCompleteSeriesBundles() {
        let target = TorrentSearchTarget.tvSeasonPack(
            series: TVSeriesIdentity(title: "The Show"),
            season: 2
        )

        #expect(TVReleaseParser.matches(
            "The.Show.S02.Complete.1080p.BluRay.x265-GROUP",
            target: target
        ))
        #expect(!TVReleaseParser.matches(
            "The.Show.S01-S03.Complete.1080p.BluRay.x265-GROUP",
            target: target
        ))
        #expect(!TVReleaseParser.matches(
            "The.Show.Season.1-3.Complete.1080p.BluRay.x265-GROUP",
            target: target
        ))
        #expect(!TVReleaseParser.matches(
            "The.Show.Seasons.1-3.Complete.1080p.BluRay.x265-GROUP",
            target: target
        ))
        #expect(!TVReleaseParser.matches(
            "The.Show.Season.1.to.3.Complete.1080p.BluRay.x265-GROUP",
            target: target
        ))
        #expect(!TVReleaseParser.matches(
            "The.Show.The.Complete.Series.1080p.BluRay.x265-GROUP",
            target: target
        ))
    }

    @Test func episodeTargetRejectsBundlesChainsAndRanges() {
        let target = TorrentSearchTarget.tvEpisode(
            series: TVSeriesIdentity(title: "The Show"),
            episode: TVEpisodeIdentifier(season: 1, episode: 2)
        )

        #expect(TVReleaseParser.matches(
            "The.Show.S01E02.1080p.WEB-DL.x265-GROUP",
            target: target
        ))
        #expect(!TVReleaseParser.matches(
            "The.Show.S01E01E02E03.1080p.WEB-DL.x265-GROUP",
            target: target
        ))
        #expect(!TVReleaseParser.matches(
            "The.Show.S01E01-E03.1080p.WEB-DL.x265-GROUP",
            target: target
        ))
        #expect(!TVReleaseParser.matches(
            "The.Show.S01.Complete.1080p.BluRay.x265-GROUP",
            target: target
        ))
    }

    @Test func titleMatchingIsSeriesExactAliasAwareAndUnicodeSafe() {
        let episode = TVEpisodeIdentifier(season: 1, episode: 2)
        let target = TorrentSearchTarget.tvEpisode(
            series: TVSeriesIdentity(
                title: "Straße",
                year: 2024,
                aliases: ["Street"]
            ),
            episode: episode
        )

        #expect(TVReleaseParser.matches(
            "Straße.S01E02.1080p.WEB-DL.x264-GROUP",
            target: target
        ))
        #expect(TVReleaseParser.matches(
            "Street.2024.S01E02.1080p.WEB-DL.x264-GROUP",
            target: target
        ))
        #expect(!TVReleaseParser.matches(
            "Street Food.S01E02.1080p.WEB-DL.x264-GROUP",
            target: target
        ))
        #expect(!TVReleaseParser.matches(
            "Straße.S01E03.1080p.WEB-DL.x264-GROUP",
            target: target
        ))

        let regionalTarget = TorrentSearchTarget.tvEpisode(
            series: TVSeriesIdentity(title: "The Office", year: 2005),
            episode: episode
        )
        #expect(TVReleaseParser.matches(
            "The.Office.US.S01E02.1080p.WEB-DL.x264-GROUP",
            target: regionalTarget
        ))
        #expect(!TVReleaseParser.matches(
            "The.Office.Most.Wanted.S01E02.1080p.WEB-DL.x264-GROUP",
            target: regionalTarget
        ))
    }

    @Test func searchServiceUsesTVIdentityInsteadOfMovieTitleShape() async {
        let results = [
            makeResult("Severance.S01E02.Half.Loop.2160p.WEB-DL.DDP5.1.HEVC-GROUP"),
            makeResult("Severance.S01E03.In.Perpetuity.2160p.WEB-DL.DDP5.1.HEVC-GROUP"),
            makeResult("Severance Explained.S01E02.1080p.WEB-DL.x264-GROUP")
        ]
        let service = TorrentSearchService(providers: [
            TVCoreStaticProvider(id: "tv-old-provider", name: "TV Old Provider", results: results)
        ])
        let request = TorrentSearchRequest.tvEpisode(
            seriesTitle: "Severance",
            year: 2022,
            season: 1,
            episode: 2
        )

        let report = await service.searchAndRankReport(request)

        #expect(report.failures.isEmpty)
        #expect(report.results.map(\.raw.title) == [
            "Severance.S01E02.Half.Loop.2160p.WEB-DL.DDP5.1.HEVC-GROUP"
        ])
    }

    @Test func tvSearchUsesYearFirstThenContextualYearlessFallback() async {
        let recorder = TVCoreQueryRecorder()
        let match = makeResult(
            "The.Office.US.S01E02.1080p.WEB-DL.DDP5.1.x264-GROUP"
        )
        let provider = TVCoreQueryProvider(
            id: "query-provider",
            name: "Query Provider",
            resultsByQuery: [
                "The Office 2005 S01E02": [
                    makeResult("The.Office.Most.Wanted.S01E02.1080p.WEB-DL.x264-GROUP")
                ],
                "The Office S01E02": [match, match]
            ],
            recorder: recorder
        )
        let service = TorrentSearchService(providers: [provider])
        let request = TorrentSearchRequest.tvEpisode(
            seriesTitle: "The Office",
            year: 2005,
            season: 1,
            episode: 2
        )

        let report = await service.searchAndRankReport(request)

        #expect(await recorder.snapshot() == [
            "The Office 2005 S01E02",
            "The Office S01E02"
        ])
        #expect(report.failures.isEmpty)
        #expect(report.results.map(\.raw.title) == [match.title])
    }

    @Test func matchingYearQueryStopsBeforeYearlessFallback() async {
        let recorder = TVCoreQueryRecorder()
        let provider = TVCoreQueryProvider(
            id: "query-provider",
            name: "Query Provider",
            resultsByQuery: [
                "Severance 2022 S01E02": [
                    makeResult("Severance.2022.S01E02.2160p.WEB-DL.DDP5.1.HEVC-GROUP")
                ],
                "Severance S01E02": [
                    makeResult("Severance.S01E02.1080p.WEB-DL.x264-GROUP")
                ]
            ],
            recorder: recorder
        )
        let service = TorrentSearchService(providers: [provider])
        let request = TorrentSearchRequest.tvEpisode(
            seriesTitle: "Severance",
            year: 2022,
            season: 1,
            episode: 2
        )

        let report = await service.searchAndRankReport(request)

        #expect(await recorder.snapshot() == ["Severance 2022 S01E02"])
        #expect(report.results.map(\.raw.title) == [
            "Severance.2022.S01E02.2160p.WEB-DL.DDP5.1.HEVC-GROUP"
        ])
    }

    @Test func legacyStringSearchAPIStillBehavesAsMovieSearch() async {
        let results = [
            makeResult("Arrival 2016 2160p BluRay HEVC-GROUP"),
            makeResult("Arrival S01E01 1080p WEB-DL x264-GROUP")
        ]
        let service = TorrentSearchService(providers: [
            TVCoreStaticProvider(id: "legacy-provider", name: "Legacy Provider", results: results)
        ])

        let legacy = await service.searchAll("Arrival 2016")
        let typed = await service.searchAll(.movie("Arrival 2016"))

        #expect(legacy == typed)
        #expect(legacy.map(\.title) == ["Arrival 2016 2160p BluRay HEVC-GROUP"])
    }

    @Test func eztvProviderDecodesFlexibleFieldsAndFiltersExactEpisode() async throws {
        let response = """
        {
          "torrents_count": "2",
          "limit": "100",
          "page": 1,
          "torrents": [{
            "filename": "The.Last.of.Us.S01E02.2160p.WEB-DL.DDP5.1.HEVC-GROUP",
            "hash": "0123456789ABCDEF0123456789ABCDEF01234567",
            "magnet_url": "magnet:?xt=urn:btih:0123456789ABCDEF0123456789ABCDEF01234567",
            "torrent_url": "https://eztvx.to/ep/1.torrent",
            "episode_url": "https://eztvx.to/ep/1",
            "seeds": "41",
            "peers": 7,
            "size_bytes": "5000000000"
          }, {
            "filename": "The.Last.of.Us.S01E03.2160p.WEB-DL.DDP5.1.HEVC-GROUP",
            "hash": "1123456789ABCDEF0123456789ABCDEF01234567",
            "seeds": 99,
            "peers": "4",
            "size_bytes": 4900000000
          }]
        }
        """
        let configuration = TVCoreMockURLProtocol.configuration { request in
            guard request.url?.absoluteString.contains("imdb_id=3581920") == true,
                  request.url?.absoluteString.contains("page=1") == true else {
                return (400, #"{"torrents":[]}"#)
            }
            return (200, response)
        }
        let provider = EZTVAPIProvider(
            config: BuiltInProviderConfigs.eztv,
            session: URLSession(configuration: configuration)
        )
        let target = TorrentSearchRequest.tvEpisode(
            seriesTitle: "The Last of Us",
            imdbID: "tt3581920",
            season: 1,
            episode: 2
        )
        let providerRequest = TorrentProviderSearchRequest(
            query: try #require(target.providerQuery(for: "eztv")),
            target: target.target
        )

        let results = try await provider.search(providerRequest, onProgress: nil)

        #expect(results.count == 1)
        #expect(results.first?.title.contains("S01E02") == true)
        #expect(results.first?.seeders == 41)
        #expect(results.first?.leechers == 7)
        #expect(results.first?.magnet?.hasPrefix("magnet:?xt=urn:btih:") == true)
        #expect(results.first?.detailURL?.absoluteString == "https://eztvx.to/ep/1")
        #expect(results.first?.size != nil)
    }

    @Test func televisionScoringOmitsIMAXAndMovieOnlyRiffTraxRules() {
        let standard = makeResult(
            "Mystery.Science.Theater.3000.S01E01.2160p.WEB-DL.DDP5.1.HEVC-GROUP"
        )
        let imax = makeResult(
            "Mystery.Science.Theater.3000.S01E01.IMAX.2160p.WEB-DL.DDP5.1.HEVC-GROUP"
        )
        let riffTrax = makeResult(
            "Mystery.Science.Theater.3000.S01E01.RiffTrax.1080p.WEB-DL.DDP5.1.x264-GROUP"
        )

        let standardTV = TorrentRanker.score(standard, profile: .television)
        let imaxTV = TorrentRanker.score(imax, profile: .television)
        let riffTraxTV = TorrentRanker.score(riffTrax, profile: .television)
        let riffTraxMovie = TorrentRanker.score(riffTrax, profile: .movie)

        #expect(standardTV.score == imaxTV.score)
        #expect(!standardTV.notes.contains { $0.contains("Expanded aspect ratio") })
        #expect(!standardTV.notes.contains { $0.contains("Weak source penalty") })
        #expect(!riffTraxTV.excluded)
        #expect(riffTraxMovie.excluded)
    }

    @Test func televisionScoringRetainsAppleTVCodecAndHDRRules() {
        let av1 = makeResult(
            "The.Show.S01E01.2160p.WEB-DL.DDP5.1.AV1-GROUP"
        )
        let avcHDR = makeResult(
            "The.Show.S01E01.2160p.HDR.WEB-DL.DDP5.1.x264-GROUP"
        )

        let av1Score = TorrentRanker.score(av1, profile: .television)
        let avcHDRScore = TorrentRanker.score(avcHDR, profile: .television)

        #expect(av1Score.excluded)
        #expect(av1Score.notes.contains("Excluded: unsupported video codec"))
        #expect(!avcHDRScore.excluded)
        #expect(avcHDRScore.notes.contains {
            $0.hasPrefix("Dynamic range:") && $0.hasSuffix(" - sdr")
        })
    }

    @Test func seasonPackSizeIsNotDividedBySingleEpisodeRuntime() {
        let specs = TorrentDetailSpecs(
            bestEnglishAudioBitrate: "640 kb/s",
            runtime: "45 min"
        )
        let pack = makeResult(
            "Severance.S01.Complete.2160p.BluRay.REMUX.DDP5.1.HEVC-GROUP",
            size: "50 GB",
            detailSpecs: specs
        )
        let episode = makeResult(
            "Severance.S01E01.2160p.BluRay.REMUX.DDP5.1.HEVC-GROUP",
            size: "5 GB",
            detailSpecs: specs
        )
        let episodeBundle = makeResult(
            "Severance.S01E01-E03.2160p.BluRay.REMUX.DDP5.1.HEVC-GROUP",
            size: "15 GB",
            detailSpecs: specs
        )

        let packTV = TorrentRanker.qualityBreakdown(for: pack, profile: .television)
        let packMovie = TorrentRanker.qualityBreakdown(for: pack, profile: .movie)
        let episodeTV = TorrentRanker.qualityBreakdown(for: episode, profile: .television)
        let episodeBundleTV = TorrentRanker.qualityBreakdown(
            for: episodeBundle,
            profile: .television
        )

        #expect(packTV.video.bitrateSourceLabel == "estimated")
        #expect(packTV.video.bitrateIsEstimated)
        #expect(packMovie.video.bitrateSourceLabel == "calculated from size ÷ runtime - audio")
        #expect(episodeTV.video.bitrateSourceLabel == "calculated from size ÷ runtime - audio")
        #expect(episodeBundleTV.video.bitrateSourceLabel == "estimated")
    }
}

private func makeResult(
    _ title: String,
    size: String? = nil,
    detailSpecs: TorrentDetailSpecs? = nil
) -> TorrentSearchResult {
    TorrentSearchResult(
        title: title,
        detailSpecs: detailSpecs,
        magnet: "magnet:?xt=urn:btih:\(title.hashValue.magnitude)",
        detailURL: nil,
        seeders: 20,
        leechers: 3,
        provider: "TV Test",
        size: size
    )
}

private struct TVCoreStaticProvider: TorrentProvider {
    let config: ProviderConfig
    let results: [TorrentSearchResult]

    init(id: String, name: String, results: [TorrentSearchResult]) {
        config = ProviderConfig(
            id: id,
            name: name,
            enabled: true,
            searchURLTemplate: "https://example.com/{{query}}",
            resultBlockPattern: "",
            titlePattern: "",
            detailURLPattern: nil,
            magnetPattern: nil,
            fetchMagnetFromDetailDuringSearch: false,
            seedersPattern: "",
            leechersPattern: "",
            detailBaseURL: nil
        )
        self.results = results.map {
            TorrentSearchResult(
                id: $0.id,
                title: $0.title,
                detailMetadata: $0.detailMetadata,
                detailSpecs: $0.detailSpecs,
                magnet: $0.magnet,
                detailURL: $0.detailURL,
                seeders: $0.seeders,
                leechers: $0.leechers,
                provider: name,
                size: $0.size
            )
        }
    }

    @concurrent
    func search(
        _ query: String,
        onProgress: (@concurrent @Sendable (_ addedResults: [TorrentSearchResult]) async -> Void)?
    ) async throws -> [TorrentSearchResult] {
        if let onProgress {
            await onProgress(results)
        }
        return results
    }
}

private actor TVCoreQueryRecorder {
    private var queries: [String] = []

    func record(_ query: String) {
        queries.append(query)
    }

    func snapshot() -> [String] {
        queries
    }
}

private struct TVCoreQueryProvider: TorrentProvider {
    let config: ProviderConfig
    let resultsByQuery: [String: [TorrentSearchResult]]
    let recorder: TVCoreQueryRecorder

    init(
        id: String,
        name: String,
        resultsByQuery: [String: [TorrentSearchResult]],
        recorder: TVCoreQueryRecorder
    ) {
        config = ProviderConfig(
            id: id,
            name: name,
            enabled: true,
            searchURLTemplate: "https://example.com/{{query}}",
            resultBlockPattern: "",
            titlePattern: "",
            detailURLPattern: nil,
            magnetPattern: nil,
            fetchMagnetFromDetailDuringSearch: false,
            seedersPattern: "",
            leechersPattern: "",
            detailBaseURL: nil
        )
        self.resultsByQuery = resultsByQuery
        self.recorder = recorder
    }

    @concurrent
    func search(
        _ query: String,
        onProgress: (@concurrent @Sendable (_ addedResults: [TorrentSearchResult]) async -> Void)?
    ) async throws -> [TorrentSearchResult] {
        await recorder.record(query)
        let results = resultsByQuery[query] ?? []
        if let onProgress {
            await onProgress(results)
        }
        return results
    }
}

private final class TVCoreMockURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (status: Int, body: String)
    private static var handler: Handler?
    private var stopped = false

    static func configuration(handler: @escaping Handler) -> URLSessionConfiguration {
        self.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TVCoreMockURLProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let result = handler(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://eztvx.to")!,
            statusCode: result.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        guard !stopped else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        stopped = true
    }
}
