import Foundation

public enum BuiltInProviderConfigs {
    public static let x1337 = ProviderConfig(
        id: "1337x",
        name: "1337x",
        enabled: true,
        searchURLTemplate: "https://www.1337xx.to/category-search/{{query}}/Movies/{{page}}/",
        alternateSearchURLTemplates: [
            "https://www.1337xx.to/sort-category-search/{{query}}/Movies/seeders/desc/{{page}}/",
            "https://13377x.click/category-search/{{query}}/Movies/{{page}}/",
            "https://13377x.click/sort-category-search/{{query}}/Movies/seeders/desc/{{page}}/"
        ],
        resultBlockPattern: #"<tr[^>]*>([\s\S]*?)</tr>"#,
        titlePattern: #"<a[^>]+href=[\"'](?:https?://[^\"']+)?/torrent/[^\"']+[\"'][^>]*>([^<]+)</a>"#,
        detailURLPattern: #"<a[^>]+href=[\"']((?:https?://[^\"']+)?/torrent/[^\"']+)[\"'][^>]*>[^<]+</a>"#,
        magnetPattern: #"href=[\"'](magnet:\?[^\"'#]+)[\"']"#,
        fetchMagnetFromDetailDuringSearch: false,
        seedersPattern: #"<td[^>]*class=[\"'][^\"']*seeds[^\"']*[\"'][^>]*>\s*(\d+)\s*</td>"#,
        leechersPattern: #"<td[^>]*class=[\"'][^\"']*leeches[^\"']*[\"'][^>]*>\s*(\d+)\s*</td>"#,
        sizePattern: #"<td[^>]*class=[\"'][^\"']*size[^\"']*[\"'][^>]*>\s*([^<]+?)\s*(?:<span|</td>)"#,
        detailBaseURL: "https://www.1337xx.to",
        timeoutSeconds: 30,
        searchPageCount: 3
    )

    public static let pirateBay = ProviderConfig(
        id: "pirate-bay",
        name: "Pirate Bay",
        enabled: true,
        searchURLTemplate: "https://apibay.org/q.php?q={{query}}&cat=201",
        alternateSearchURLTemplates: [
            "https://apibay.org/q.php?q={{query}}&cat=207",
            "https://apibay.org/q.php?q={{query}}&cat=211"
        ],
        resultBlockPattern: "",
        titlePattern: "",
        detailURLPattern: nil,
        magnetPattern: nil,
        fetchMagnetFromDetailDuringSearch: false,
        seedersPattern: "",
        leechersPattern: "",
        sizePattern: nil,
        detailBaseURL: "https://thepiratebay.org",
        timeoutSeconds: 30
    )

    public static let torrentGalaxy = ProviderConfig(
        id: "torrentgalaxy",
        name: "TorrentGalaxy",
        enabled: true,
        searchURLTemplate: "https://torrentgalaxy.one/get-posts/keywords:{{query}}:category:Movies/?page={{page}}",
        alternateSearchURLTemplates: [],
        resultBlockPattern: "(<div class=\\\"tgxtablerow txlight\\\"[\\s\\S]*?)(?=<div class=\\\"tgxtablerow txlight\\\"|<script src=\\\"/static/tgx/js/added-date.js\\\"|$)",
        titlePattern: "<a[^>]+class=\\\"txlight\\\"[^>]+title=\\\"([^\\\"]+)\\\"[^>]+href=\\\"/post-detail/[^\\\"]+/\\\"",
        detailURLPattern: "<a[^>]+href=\\\"(/post-detail/[^\\\"]+/)\\\"",
        magnetPattern: "href=\\\"(magnet:\\?[^\\\"]+)\\\"",
        fetchMagnetFromDetailDuringSearch: false,
        seedersPattern: "Seeders/Leechers\\\">\\[<font color=\\\"green\\\">\\s*<b>(\\d+)</b>",
        leechersPattern: "</font>/<font color=\\\"#ff0000\\\"><b>(\\d+)</b></font>",
        sizePattern: #"<span[^>]*class=\"badge badge-secondary[^\"]*\"[^>]*>\s*([^<]+?)\s*</span>"#,
        detailBaseURL: "https://torrentgalaxy.one",
        timeoutSeconds: 30,
        searchPageCount: 3
    )

    public static let `default`: [ProviderConfig] = [
        x1337,
        pirateBay,
        torrentGalaxy
    ]
}
