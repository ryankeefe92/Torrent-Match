//
//  ContentView.swift
//  Torrent Match
//
//  Created by Ryan Keefe on 5/17/26.
//

import SwiftUI
import SwiftData
import TorrentMatcherCore

struct ContentView: View {
    // MARK: - Search / Results State
    @State private var query: String = ""
    @State private var isSearching: Bool = false
    @State private var results: [SearchResult] = []
    @State private var errorMessage: String? = nil
    @State private var sortByScoreDescending: Bool = true

    var sortedResults: [SearchResult] {
        results.sorted { a, b in
            sortByScoreDescending ? a.score > b.score : a.score < b.score
        }
    }

    var body: some View {
        NavigationViewWrapper {
            VStack(spacing: 0) {
                // Search Bar + Action
                SearchBar(query: $query, onSubmit: performSearch)
                    .padding([.horizontal, .top])

                // Toolbar-like controls row
                ControlsBar(isSearching: isSearching,
                            sortDescending: $sortByScoreDescending,
                            onSearchTapped: performSearch)
                    .padding(.horizontal)

                Divider()

                // Results / Loading / Error / Empty
                Group {
                    if let message = errorMessage {
                        ErrorStateView(message: message, retry: performSearch)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if isSearching {
                        ProgressView("Searching providers…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if sortedResults.isEmpty {
                        EmptyResultsView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ResultsListView(results: sortedResults)
                    }
                }
            }
            .navigationTitle("Search")
#if os(macOS)
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
#endif
        }
    }

    // MARK: - Actions
    private func performSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSearching else { return }
        errorMessage = nil
        isSearching = true
        results = []

        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
                let names = SampleGenerator.makeSamples(for: trimmed)
                let mapped: [SearchResult] = names.map { name in
                    let (meta, score) = ParserRankerAdapter.parseAndScore(releaseName: name)
                    return SearchResult(title: name,
                                        source: meta.source,
                                        resolution: meta.resolution,
                                        dynamicRange: meta.dynamicRange,
                                        audio: meta.audio,
                                        channels: meta.channels,
                                        seeders: nil,
                                        score: score)
                }
                results = mapped
            } catch {
                errorMessage = "Search failed. Please try again."
            }
            isSearching = false
        }
    }
}

// MARK: - Models
struct SearchResult: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let source: String
    let resolution: String
    let dynamicRange: String
    let audio: String
    let channels: String?
    let seeders: Int?
    let score: Int
}

// MARK: - Sample Generation (no providers yet)
enum SampleGenerator {
    static func makeSamples(for query: String) -> [String] {
        // Generate plausible release names derived from the query
        // Keep it deterministic for now
        let base = query.replacingOccurrences(of: " ", with: ".")
        return [
            "\(base).2023.UHD.2160p.REMUX.HEVC.TrueHD.Atmos.Dolby.Vision",
            "\(base).2023.2160p.WEB-DL.HEVC.DDP.Atmos.HDR10",
            "\(base).2023.1080p.BluRay.AVC.DTS-HD.MA.SDR",
            "\(base).2023.1080p.WEBRip.x264.AAC.HDR",
            "\(base).2023.720p.WEBRip.x264.AAC.SDR"
        ]
    }
}

// MARK: - Parser + Ranker adapter (uses core)
enum ParserRankerAdapter {
    struct ParsedMeta {
        var source: String
        var resolution: String
        var dynamicRange: String
        var audio: String
        var channels: String?
        var atmos: Bool
    }

    static func parseAndScore(releaseName: String) -> (ParsedMeta, Int) {
        // Use the real core
        let parsed = ReleaseParser.parse(releaseName)
        let mockRaw = TorrentSearchResult(
            title: releaseName,
            magnet: nil,
            detailURL: nil,
            seeders: 10, // tie-break only, not used in score
            leechers: 5,
            provider: "Sample"
        )
        let ranked = TorrentRanker.score(mockRaw)

        let meta = ParsedMeta(
            source: parsed.sourceType.rawValue.capitalized,
            resolution: parsed.resolution.rawValue,
            dynamicRange: displayName(for: parsed.dynamicRange),
            audio: displayName(for: parsed.audioCodec, atmos: parsed.atmos),
            channels: channelsString(parsed.channels),
            atmos: parsed.atmos
        )
        return (meta, ranked.score)
    }

    private static func channelsString(_ c: ChannelLayout) -> String? {
        switch c {
        case .sevenOne: return "7.1"
        case .fiveOne: return "5.1"
        case .twoOrUnknown: return nil
        }
    }

    private static func displayName(for dr: DynamicRange) -> String {
        switch dr {
        case .dolbyVision: return "Dolby Vision"
        case .hdr10plus: return "HDR10+"
        case .hdr10: return "HDR10"
        case .hdr: return "HDR"
        case .sdr: return "SDR"
        case .unknown: return "Unknown"
        }
    }

    private static func displayName(for ac: AudioCodec, atmos: Bool) -> String {
        let base: String
        switch ac {
        case .truehd: base = "TrueHD"
        case .dtsHDMA: base = "DTS-HD MA"
        case .ddp: base = "DDP"
        case .dd: base = "DD/AC3"
        case .aac: base = "AAC"
        case .unknown: base = "Unknown"
        }
        if atmos { return base + " Atmos" } else { return base }
    }
}

// MARK: - Views
private struct SearchBar: View {
    @Binding var query: String
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Search movies or shows", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onSubmit)
            Button(action: onSubmit) {
                Label("Search", systemImage: "magnifyingglass")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

private struct ControlsBar: View {
    var isSearching: Bool
    @Binding var sortDescending: Bool
    var onSearchTapped: () -> Void

    var body: some View {
        HStack {
            Button(action: onSearchTapped) {
                Label(isSearching ? "Searching…" : "Search", systemImage: isSearching ? "hourglass" : "magnifyingglass")
            }
            .disabled(isSearching)

            Spacer()

            Button(action: { sortDescending.toggle() }) {
                Label(sortDescending ? "Score: High → Low" : "Score: Low → High",
                      systemImage: sortDescending ? "arrow.down" : "arrow.up")
            }
            .help("Toggle score sort order")
        }
        .padding(.vertical, 8)
    }
}

private struct ResultsListView: View {
    let results: [SearchResult]

    var body: some View {
        List(results) { result in
            NavigationLink {
                ResultDetailView(result: result)
            } label: {
                ResultRow(result: result)
            }
        }
#if os(iOS) || os(watchOS) || os(tvOS)
        .listStyle(.insetGrouped)
#else
        .listStyle(.automatic)
#endif
    }
}

private struct ResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ScoreBadge(score: result.score)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(result.title)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    MetaChip(text: result.source, systemImage: "film")
                    MetaChip(text: result.resolution, systemImage: "rectangle.3.group")
                    MetaChip(text: result.dynamicRange, systemImage: "circle.lefthalf.filled")
                    MetaChip(text: result.audio, systemImage: "speaker.wave.2")
                    if let ch = result.channels { MetaChip(text: ch, systemImage: "dot.radiowaves.left.and.right") }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
    }
}

private struct MetaChip: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
    }
}

private struct ScoreBadge: View {
    let score: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(scoreColor)
                .frame(width: 36, height: 36)
            Text("\(score)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .accessibilityLabel("Score \(score)")
    }

    private var scoreColor: Color {
        switch score {
        case 80...: return .green
        case 60..<80: return .orange
        default: return .red
        }
    }
}

private struct ResultDetailView: View {
    let result: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(result.title)
                .font(.title2.bold())
            HStack(spacing: 12) {
                Tag("Source", value: result.source)
                Tag("Resolution", value: result.resolution)
                Tag("Dynamic Range", value: result.dynamicRange)
                Tag("Audio", value: result.audio)
                Tag("Seeders", value: String(result.seeders ?? 0))
                Tag("Score", value: String(result.score))
            }
            .font(.footnote)

            Spacer()

            HStack {
                Spacer()
                Button {
                    // TODO: Hook up to Transmission client
                } label: {
                    Label("Send to Transmission", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
        }
        .padding()
        .navigationTitle("Result")
    }
}

private struct Tag: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label + ":")
                .foregroundStyle(.secondary)
            Text(value)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
    }
}

private struct ErrorStateView: View {
    let message: String
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
            Button("Try Again", action: retry)
        }
        .padding()
    }
}

private struct EmptyResultsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("Search for a movie or show to see ranked results")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

fileprivate struct NavigationViewWrapper<Content: View>: View {
    let content: () -> Content

    var body: some View {
#if os(macOS)
        NavigationSplitView {
            content()
        } detail: {
            Text("Select a result")
        }
#else
        content()
#endif
    }
}

#Preview("macOS Wide Preview") {
#if os(macOS)
    // Seeded preview with a wider frame so rows don't truncate vertically
    ContentView_PreviewWrapper()
        .frame(width: 900, height: 600)
#else
    ContentView()
#endif
}
// Helper to preview ContentView with seeded results on macOS
private struct ContentView_PreviewWrapper: View {
    @State private var query: String = "Movie X"
    @State private var results: [SearchResult] = SampleGenerator.makeSamples(for: "Movie X").map { name in
        let (meta, score) = ParserRankerAdapter.parseAndScore(releaseName: name)
        return SearchResult(title: name,
                            source: meta.source,
                            resolution: meta.resolution,
                            dynamicRange: meta.dynamicRange,
                            audio: meta.audio,
                            channels: meta.channels,
                            seeders: nil,
                            score: score)
    }

    var body: some View {
        ContentView()
            .onAppear { /* no-op; ContentView drives its own state */ }
    }
}

