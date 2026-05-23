import Foundation
import TorrentMatcherCore

func exampleSearch() async {
    var config = SampleProviderConfigs.tableBased
    // In your app, create your own ProviderConfig with searchURLTemplate and detailBaseURL filled in.
    // searchURLTemplate example shape only: "https://example.invalid/search?q={{query}}"

    let service = TorrentSearchService(configs: [config])
    let ranked = await service.searchAndRank("example title")

    for result in ranked {
        print("\(result.score): \(result.raw.title)")
        print(result.notes.joined(separator: "\n"))
    }
}

func exampleRankOnly() {
    let raw = TorrentSearchResult(
        title: "Example.2024.2160p.REMUX.Dolby.Vision.TrueHD.7.1.Atmos.HEVC",
        magnet: "magnet:?xt=urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        detailURL: nil,
        seeders: 10,
        leechers: 1,
        provider: "Manual Test"
    )
    let ranked = TorrentRanker.rank([raw])
    print(ranked.first?.score ?? 0)
}
