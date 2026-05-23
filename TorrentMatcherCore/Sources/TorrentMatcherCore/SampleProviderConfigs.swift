import Foundation

public enum SampleProviderConfigs {
    // Generic profiles. Add your own searchURLTemplate and detailBaseURL.
    public static let tableBased = ProviderConfig(
        id: "table-provider",
        name: "Table-Based HTML Provider",
        enabled: true,
        searchURLTemplate: "",
        resultBlockPattern: #"<tr[^>]*>([\s\S]*?)</tr>"#,
        titlePattern: #"<a[^>]+href=[\"'][^\"']+[\"'][^>]*>([^<]+)</a>"#,
        detailURLPattern: #"<a[^>]+href=[\"']([^\"']+)[\"'][^>]*>[^<]+</a>"#,
        magnetPattern: #"href=[\"'](magnet:\?[^\"']+)[\"']"#,
        seedersPattern: #"(?:seeders|seeds|se)[^>]*>\s*(\d+)\s*<"#,
        leechersPattern: #"(?:leechers|leeches|le)[^>]*>\s*(\d+)\s*<"#,
        detailBaseURL: ""
    )

    public static let cardBased = ProviderConfig(
        id: "card-provider",
        name: "Card-Based HTML Provider",
        enabled: true,
        searchURLTemplate: "",
        resultBlockPattern: #"<div[^>]+class=[\"'][^\"']*(?:result|torrent|card|item)[^\"']*[\"'][^>]*>([\s\S]*?)</div>\s*</div>"#,
        titlePattern: #"(?:title|name)[^>]*>\s*(?:<a[^>]*>)?([^<]+)"#,
        detailURLPattern: #"<a[^>]+href=[\"']([^\"']+)[\"'][^>]*(?:title|name|torrent|detail)?"#,
        magnetPattern: #"(magnet:\?xt=urn:btih:[^\"'\s<]+)"#,
        seedersPattern: #"(?:seeders|seeds|seed|se)[^0-9]{0,20}(\d+)"#,
        leechersPattern: #"(?:leechers|leeches|leech|le)[^0-9]{0,20}(\d+)"#,
        detailBaseURL: ""
    )

    public static let listBased = ProviderConfig(
        id: "list-provider",
        name: "List-Based HTML Provider",
        enabled: true,
        searchURLTemplate: "",
        resultBlockPattern: #"<li[^>]*>([\s\S]*?)</li>"#,
        titlePattern: #"<a[^>]*>([^<]+)</a>"#,
        detailURLPattern: #"<a[^>]+href=[\"']([^\"']+)[\"']"#,
        magnetPattern: #"href=[\"'](magnet:\?[^\"']+)[\"']"#,
        seedersPattern: #"(?:S|Seeders|Seeds)\s*[:\-]?\s*(\d+)"#,
        leechersPattern: #"(?:L|Leechers|Leeches)\s*[:\-]?\s*(\d+)"#,
        detailBaseURL: ""
    )
}
