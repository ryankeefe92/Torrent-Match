import Foundation

public struct ProviderConfigTestResult: Sendable {
    public let providerName: String
    public let resultBlockCount: Int
    public let sampleResults: [TorrentSearchResult]
    public let warnings: [String]
}

public enum ProviderConfigTester {
    public static func test(config: ProviderConfig, sampleHTML: String) -> ProviderConfigTestResult {
        let blocks = RegexTools.captureMatches(pattern: config.resultBlockPattern, in: sampleHTML)
        var warnings: [String] = []
        var results: [TorrentSearchResult] = []

        if blocks.isEmpty { warnings.append("No result blocks found. Check resultBlockPattern.") }

        for block in blocks.prefix(5) {
            let title = RegexTools.firstCapture(pattern: config.titlePattern, in: block)?.htmlDecoded.cleanedText ?? ""
            let seeders = RegexTools.firstCapture(pattern: config.seedersPattern, in: block).flatMap(Int.init) ?? 0
            let leechers = RegexTools.firstCapture(pattern: config.leechersPattern, in: block).flatMap(Int.init) ?? 0
            let size = config.sizePattern.flatMap { RegexTools.firstCapture(pattern: $0, in: block) }?.htmlDecoded.cleanedText
            let magnet = config.magnetPattern.flatMap { RegexTools.firstCapture(pattern: $0, in: block) }?.htmlDecoded
            let detailURLString = config.detailURLPattern.flatMap { RegexTools.firstCapture(pattern: $0, in: block) }?.htmlDecoded
            let detailURL = detailURLString.flatMap(URL.init(string:))

            if title.isEmpty { warnings.append("A result block did not produce a title.") }
            if magnet == nil && detailURLString == nil { warnings.append("A result block had neither magnet nor detail URL.") }

            results.append(TorrentSearchResult(
                title: title,
                magnet: magnet,
                detailURL: detailURL,
                seeders: seeders,
                leechers: leechers,
                provider: config.name,
                size: size
            ))
        }

        return ProviderConfigTestResult(
            providerName: config.name,
            resultBlockCount: blocks.count,
            sampleResults: results,
            warnings: Array(Set(warnings)).sorted()
        )
    }
}
