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
    @State private var selected: SearchResult? = nil

    var sortedResults: [SearchResult] {
        results.sorted { $0.score > $1.score }
    }

    var body: some View {
        NavigationViewWrapper {
            VStack(spacing: 0) {
                // Search Bar + Action
                SearchBar(query: $query, onSubmit: performSearch)
                    .padding([.horizontal, .top])
                    .padding(.bottom, 6)

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
                        ResultsListView(results: sortedResults, selected: $selected)
                    }
                }
            }
            .navigationTitle("Search")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        Button {
                            // TODO: Hook up to Transmission client using `selected`
                        } label: {
                            Text("Send to Transmission")
                        }
                        .labelStyle(.titleOnly)
                        .disabled(selected == nil)
                    }
                }
                #elseif os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        // TODO: Hook up to Transmission client using `selected`
                    } label: {
                        Text("Send to Transmission")
                    }
                    .labelStyle(.titleOnly)
                    .disabled(selected == nil)
                }
                #else
                ToolbarItem(placement: .automatic) {
                    Button {
                        // TODO: Hook up to Transmission client using `selected`
                    } label: {
                        Text("Send to Transmission")
                    }
                    .labelStyle(.titleOnly)
                    .disabled(selected == nil)
                }
                #endif
            }
#if os(macOS)
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
#endif
        }
    }

    // MARK: - Actions
    private func performSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSearching else { return }
#if os(iOS)
        UIApplication.shared.endEditing()
#endif
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

private struct MetaChip: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .lineLimit(1)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    init(spacing: CGFloat = 8, lineSpacing: CGFloat = 4) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        y += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct ScoreBadge: View {
    let score: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(scoreColor)
                .frame(width: 44, height: 44)
            Text("\(score)")
                .font(.headline.weight(.semibold))
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

// Removed ChipsFlow and HeightPreferenceKey structs as requested

// Removed ResultDetailView struct as requested

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

private struct ResultsListView: View {
    let results: [SearchResult]
    @Binding var selected: SearchResult?

    var body: some View {
        List(results) { result in
            ResultRow(result: result) {
                selected = result
            }
            .listRowBackground(selected?.id == result.id ? Color.accentColor.opacity(0.1) : Color.clear)
        }
        .listStyle(.plain)
        .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
        .modifier(ContentMarginsZero())
    }
}

private struct ContentMarginsZero: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            content.contentMargins(.all, 0)
        } else {
            content
        }
    }
}

private struct ResultRow: View {
    let result: SearchResult
    var onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                ScoreBadge(score: result.score)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(prettifiedTitle(result.title))
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .allowsTightening(false)
                    FlowLayout(spacing: 8, lineSpacing: 4) {
                        MetaChip(text: result.source, systemImage: "film")
                        MetaChip(text: result.resolution, systemImage: "rectangle.3.group")
                        MetaChip(text: result.dynamicRange, systemImage: "circle.lefthalf.filled")
                        MetaChip(text: result.audio, systemImage: "speaker.wave.2")
                        if let ch = result.channels { MetaChip(text: ch, systemImage: "dot.radiowaves.left.and.right") }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .padding(.vertical, 4)
    }
    
    private func prettifiedTitle(_ title: String) -> String {
        var s = title.replacingOccurrences(of: ".", with: " ")
        s = s.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: "-", with: "-") // keep hyphen as a token but avoid mid-word joiners
        // Collapse multiple spaces
        let parts = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }
}

fileprivate struct NavigationViewWrapper<Content: View>: View {
    let content: () -> Content

    var body: some View {
        content()
    }
}

#if os(iOS)
private extension UIApplication {
    func endEditing() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
#endif

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

#Preview("iOS Preview") {
#if os(iOS)
    ContentView()
#endif
}

