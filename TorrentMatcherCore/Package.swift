// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TorrentMatcherCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "TorrentMatcherCore", targets: ["TorrentMatcherCore"])
    ],
    targets: [
        .target(name: "TorrentMatcherCore", path: "Sources/TorrentMatcherCore")
    ]
)
