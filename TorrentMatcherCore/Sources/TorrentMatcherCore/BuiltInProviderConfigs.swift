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
            "https://13377x.click/sort-category-search/{{query}}/Movies/seeders/desc/{{page}}/",
            "https://1337x.torrentbay.to/category-search/{{query}}/Movies/{{page}}/",
            "https://1337x.torrentbay.to/sort-category-search/{{query}}/Movies/seeders/desc/{{page}}/",
            "https://1337x.ninjaproxy.live/category-search/{{query}}/Movies/{{page}}/",
            "https://1337x.ninjaproxy.live/sort-category-search/{{query}}/Movies/seeders/desc/{{page}}/"
        ],
        resultBlockPattern: #"<tr[^>]*>([\s\S]*?)</tr>"#,
        titlePattern: #"<a[^>]+href=[\"'](?:https?://[^\"']+)?/torrent/[^\"']+[\"'][^>]*>([^<]+)</a>"#,
        detailURLPattern: #"<a[^>]+href=[\"']((?:https?://[^\"']+)?/torrent/[^\"']+)[\"'][^>]*>[^<]+</a>"#,
        detailMetadataPattern: #"<div[^>]+class=[\"'][^\"']*(?:torrent-detail-page|torrent-detail-info|description)[^\"']*[\"'][^>]*>([\s\S]*?)</div>"#,
        magnetPattern: #"href=[\"'](magnet:\?[^\"'#]+)[\"']"#,
        fetchMagnetFromDetailDuringSearch: false,
        seedersPattern: #"<td[^>]*class=[\"'][^\"']*seeds[^\"']*[\"'][^>]*>\s*(\d+)\s*</td>"#,
        leechersPattern: #"<td[^>]*class=[\"'][^\"']*leeches[^\"']*[\"'][^>]*>\s*(\d+)\s*</td>"#,
        sizePattern: #"<td[^>]*class=[\"'][^\"']*size[^\"']*[\"'][^>]*>\s*([^<]+?)\s*(?:<span|</td>)"#,
        detailBaseURL: "https://www.1337xx.to",
        timeoutSeconds: 30,
        searchPageCount: 3
    )

    public static let x1337TV = ProviderConfig(
        id: "1337x",
        name: "1337x",
        enabled: true,
        searchURLTemplate: "https://www.1337xx.to/category-search/{{query}}/TV/{{page}}/",
        alternateSearchURLTemplates: [
            "https://www.1337xx.to/sort-category-search/{{query}}/TV/seeders/desc/{{page}}/",
            "https://13377x.click/category-search/{{query}}/TV/{{page}}/",
            "https://13377x.click/sort-category-search/{{query}}/TV/seeders/desc/{{page}}/",
            "https://1337x.torrentbay.to/category-search/{{query}}/TV/{{page}}/",
            "https://1337x.torrentbay.to/sort-category-search/{{query}}/TV/seeders/desc/{{page}}/",
            "https://1337x.ninjaproxy.live/category-search/{{query}}/TV/{{page}}/",
            "https://1337x.ninjaproxy.live/sort-category-search/{{query}}/TV/seeders/desc/{{page}}/"
        ],
        resultBlockPattern: #"<tr[^>]*>([\s\S]*?)</tr>"#,
        titlePattern: #"<a[^>]+href=[\"'](?:https?://[^\"']+)?/torrent/[^\"']+[\"'][^>]*>([^<]+)</a>"#,
        detailURLPattern: #"<a[^>]+href=[\"']((?:https?://[^\"']+)?/torrent/[^\"']+)[\"'][^>]*>[^<]+</a>"#,
        detailMetadataPattern: #"<div[^>]+class=[\"'][^\"']*(?:torrent-detail-page|torrent-detail-info|description)[^\"']*[\"'][^>]*>([\s\S]*?)</div>"#,
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
        detailMetadataPattern: nil,
        magnetPattern: nil,
        fetchMagnetFromDetailDuringSearch: false,
        seedersPattern: "",
        leechersPattern: "",
        sizePattern: nil,
        detailBaseURL: "https://thepiratebay.org",
        timeoutSeconds: 30
    )

    public static let pirateBayTV = ProviderConfig(
        id: "pirate-bay",
        name: "Pirate Bay",
        enabled: true,
        searchURLTemplate: "https://apibay.org/q.php?q={{query}}&cat=205",
        alternateSearchURLTemplates: [
            "https://apibay.org/q.php?q={{query}}&cat=208"
        ],
        resultBlockPattern: "",
        titlePattern: "",
        detailURLPattern: nil,
        detailMetadataPattern: nil,
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
        detailMetadataPattern: "<div[^>]+class=\\\"[^\\\"]*(?:mediainfo|media-info|nfo)[^\\\"]*\\\"[^>]*>([\\s\\S]*?)</div>",
        magnetPattern: "href=\\\"(magnet:\\?[^\\\"]+)\\\"",
        fetchMagnetFromDetailDuringSearch: false,
        seedersPattern: "Seeders/Leechers\\\">\\[<font color=\\\"green\\\">\\s*<b>(\\d+)</b>",
        leechersPattern: "</font>/<font color=\\\"#ff0000\\\"><b>(\\d+)</b></font>",
        sizePattern: #"<span[^>]*class=\"badge badge-secondary[^\"]*\"[^>]*>\s*([^<]+?)\s*</span>"#,
        detailBaseURL: "https://torrentgalaxy.one",
        timeoutSeconds: 30,
        searchPageCount: 3
    )

    public static let torrentGalaxyTV = ProviderConfig(
        id: "torrentgalaxy",
        name: "TorrentGalaxy",
        enabled: true,
        searchURLTemplate: "https://torrentgalaxy.one/get-posts/keywords:{{query}}:category:TV/?page={{page}}",
        alternateSearchURLTemplates: [],
        resultBlockPattern: "(<div class=\\\"tgxtablerow txlight\\\"[\\s\\S]*?)(?=<div class=\\\"tgxtablerow txlight\\\"|<script src=\\\"/static/tgx/js/added-date.js\\\"|$)",
        titlePattern: "<a[^>]+class=\\\"txlight\\\"[^>]+title=\\\"([^\\\"]+)\\\"[^>]+href=\\\"/post-detail/[^\\\"]+/\\\"",
        detailURLPattern: "<a[^>]+href=\\\"(/post-detail/[^\\\"]+/)\\\"",
        detailMetadataPattern: "<div[^>]+class=\\\"[^\\\"]*(?:mediainfo|media-info|nfo)[^\\\"]*\\\"[^>]*>([\\s\\S]*?)</div>",
        magnetPattern: "href=\\\"(magnet:\\?[^\\\"]+)\\\"",
        fetchMagnetFromDetailDuringSearch: false,
        seedersPattern: "Seeders/Leechers\\\">\\[<font color=\\\"green\\\">\\s*<b>(\\d+)</b>",
        leechersPattern: "</font>/<font color=\\\"#ff0000\\\"><b>(\\d+)</b></font>",
        sizePattern: #"<span[^>]*class=\"badge badge-secondary[^\"]*\"[^>]*>\s*([^<]+?)\s*</span>"#,
        detailBaseURL: "https://torrentgalaxy.one",
        timeoutSeconds: 30,
        searchPageCount: 3
    )

    public static let magnetz = ProviderConfig(
        id: "magnetz",
        name: "Magnetz",
        enabled: true,
        searchURLTemplate: "https://magnetz.eu/api/magnets/search?query={{query}}&page={{page}}",
        resultBlockPattern: "",
        titlePattern: "",
        detailURLPattern: nil,
        magnetPattern: nil,
        fetchMagnetFromDetailDuringSearch: false,
        seedersPattern: "",
        leechersPattern: "",
        detailBaseURL: "https://magnetz.eu",
        timeoutSeconds: 20,
        searchPageCount: 2
    )

    public static let yts = ProviderConfig(
        id: "yts",
        name: "YTS",
        enabled: true,
        searchURLTemplate: "https://movies-api.accel.li/api/v2/list_movies.json?query_term={{query}}&limit=50&sort_by=seeds&order_by=desc",
        alternateSearchURLTemplates: [
            "https://yts.gg/api/v2/list_movies.json?query_term={{query}}&limit=50&sort_by=seeds&order_by=desc"
        ],
        resultBlockPattern: "",
        titlePattern: "",
        detailURLPattern: nil,
        magnetPattern: nil,
        fetchMagnetFromDetailDuringSearch: false,
        seedersPattern: "",
        leechersPattern: "",
        detailBaseURL: "https://yts.gg",
        timeoutSeconds: 20
    )

    public static let eztv = ProviderConfig(
        id: "eztv",
        name: "EZTV",
        enabled: true,
        searchURLTemplate: "https://eztvx.to/api/get-torrents?imdb_id={{query}}&limit=100&page={{page}}",
        alternateSearchURLTemplates: [],
        resultBlockPattern: "",
        titlePattern: "",
        detailURLPattern: nil,
        detailMetadataPattern: nil,
        magnetPattern: nil,
        fetchMagnetFromDetailDuringSearch: false,
        seedersPattern: "",
        leechersPattern: "",
        sizePattern: nil,
        detailBaseURL: "https://eztvx.to",
        timeoutSeconds: 30
    )

    public static let movies: [ProviderConfig] = [
        x1337,
        pirateBay,
        torrentGalaxy,
        magnetz,
        yts
    ]

    public static let television: [ProviderConfig] = [
        x1337TV,
        pirateBayTV,
        torrentGalaxyTV,
        magnetz,
        eztv
    ]

    public static let `default`: [ProviderConfig] = movies
}
