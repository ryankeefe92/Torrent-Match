import Foundation

public enum BuiltInProviderConfigs {
    public static let x1337 = ProviderConfig(
        id: "1337x",
        name: "1337x",
        enabled: true,
        searchURLTemplate: "https://1337x.to/search/{{query}}/1/",
        resultBlockPattern: #"<tr[^>]*>([\s\S]*?)</tr>"#,
        titlePattern: #"<a[^>]+href=[\"'](?:https?://[^\"']+)?/torrent/[^\"']+[\"'][^>]*>([^<]+)</a>"#,
        detailURLPattern: #"<a[^>]+href=[\"']((?:https?://[^\"']+)?/torrent/[^\"']+)[\"'][^>]*>[^<]+</a>"#,
        magnetPattern: #"href=[\"'](magnet:\?[^\"'#]+)[\"']"#,
        seedersPattern: #"<td[^>]*class=[\"'][^\"']*seeds[^\"']*[\"'][^>]*>\s*(\d+)\s*</td>"#,
        leechersPattern: #"<td[^>]*class=[\"'][^\"']*leeches[^\"']*[\"'][^>]*>\s*(\d+)\s*</td>"#,
        detailBaseURL: "https://1337x.to"
    )

    public static let pirateBay = ProviderConfig(
        id: "pirate-bay",
        name: "Pirate Bay",
        enabled: true,
        searchURLTemplate: "https://apibay.org/q.php?q={{query}}",
        resultBlockPattern: "",
        titlePattern: "",
        detailURLPattern: nil,
        magnetPattern: nil,
        seedersPattern: "",
        leechersPattern: "",
        detailBaseURL: "https://thepiratebay.org"
    )

    public static let torrentGalaxy = ProviderConfig(
        id: "torrentgalaxy",
        name: "TorrentGalaxy",
        enabled: true,
        searchURLTemplate: "https://torrentgalaxy.one/get-posts/keywords:{{query}}",
        resultBlockPattern: "(<div class=\\\"tgxtablerow txlight\\\"[\\s\\S]*?)(?=<div class=\\\"tgxtablerow txlight\\\"|<script src=\\\"/static/tgx/js/added-date.js\\\"|$)",
        titlePattern: "<a[^>]+class=\\\"txlight\\\"[^>]+title=\\\"([^\\\"]+)\\\"[^>]+href=\\\"/post-detail/[^\\\"]+/\\\"",
        detailURLPattern: "<a[^>]+href=\\\"(/post-detail/[^\\\"]+/)\\\"",
        magnetPattern: "href=\\\"(magnet:\\?[^\\\"]+)\\\"",
        seedersPattern: "Seeders/Leechers\\\">\\[<font color=\\\"green\\\">\\s*<b>(\\d+)</b>",
        leechersPattern: "</font>/<font color=\\\"#ff0000\\\"><b>(\\d+)</b></font>",
        detailBaseURL: "https://torrentgalaxy.one"
    )

    public static let `default`: [ProviderConfig] = [
        x1337,
        pirateBay,
        torrentGalaxy
    ]
}
