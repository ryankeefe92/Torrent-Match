//
//  Torrent_MatchTests.swift
//  Torrent MatchTests
//
//  Created by Ryan Keefe on 5/17/26.
//

import Testing
import TorrentMatcherCore

struct Torrent_MatchTests {

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

    @Test func parserInfersUHDDefaults() {
        let parsed = ReleaseParser.parse("Movie.2025.UHD.BluRay.REMUX-GROUP")
        #expect(parsed.sourceType == .remux)
        #expect(parsed.resolution == .p2160)
        #expect(parsed.dynamicRange == .likelyHDR)
        #expect(parsed.videoCodec == .hevc)
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

        #expect(TorrentRanker.score(imax).score == TorrentRanker.score(standard).score + 8)
    }

}
