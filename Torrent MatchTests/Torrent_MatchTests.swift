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

}
