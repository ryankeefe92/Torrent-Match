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
    private let searchService = TorrentSearchService(configs: BuiltInProviderConfigs.default)

    // MARK: - Search / Results State
    @State private var query: String = ""
    @State private var isSearching: Bool = false
    @State private var results: [SearchResult] = []
    @State private var errorMessage: String? = nil
    @State private var selected: SearchResult? = nil
    @State private var magnetMessage: String? = nil

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
            .alert("Selected Magnet", isPresented: magnetAlertIsPresented) {
                Button("OK") {
                    magnetMessage = nil
                }
            } message: {
                Text(magnetMessage ?? "")
            }
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        Button {
                            magnetMessage = selected?.magnet ?? "No magnet is available for the selected result."
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
                        magnetMessage = selected?.magnet ?? "No magnet is available for the selected result."
                    } label: {
                        Text("Send to Transmission")
                    }
                    .labelStyle(.titleOnly)
                    .disabled(selected == nil)
                }
                #else
                ToolbarItem(placement: .automatic) {
                    Button {
                        magnetMessage = selected?.magnet ?? "No magnet is available for the selected result."
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

    private var magnetAlertIsPresented: Binding<Bool> {
        Binding(
            get: { magnetMessage != nil },
            set: { isPresented in
                if !isPresented {
                    magnetMessage = nil
                }
            }
        )
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
            let report = await searchService.searchAndRankReport(trimmed)
            results = report.results.map(SearchResult.init)
            if results.isEmpty, let failure = report.failures.first {
                errorMessage = "\(failure.providerName) search is currently blocked. \(failure.message)"
            }
            isSearching = false
        }
    }
}

// MARK: - Models
struct SearchResult: Identifiable, Hashable {
    let id: UUID
    let title: String
    let source: String
    let resolution: String
    let dynamicRange: String
    let audio: String
    let seeders: Int?
    let leechers: Int?
    let magnet: String?
    let detailURL: URL?
    let score: Int

    init(ranked: RankedTorrentResult) {
        id = ranked.id
        title = ranked.raw.title
        source = ranked.parsed.sourceType.rawValue.capitalized
        resolution = ranked.parsed.resolution.rawValue
        dynamicRange = ParserRankerAdapter.displayName(for: ranked.parsed.dynamicRange)
        audio = ParserRankerAdapter.audioSummary(codec: ranked.parsed.audioCodec, channels: ranked.parsed.channels, atmos: ranked.parsed.atmos)
        seeders = ranked.raw.seeders
        leechers = ranked.raw.leechers
        magnet = ranked.raw.magnet
        detailURL = ranked.raw.detailURL
        score = ranked.score
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

    static func channelsString(_ c: ChannelLayout) -> String? {
        switch c {
        case .sevenOne: return "7.1"
        case .fiveOne: return "5.1"
        case .twoOrUnknown: return nil
        }
    }

    static func displayName(for dr: DynamicRange) -> String {
        switch dr {
        case .dolbyVision: return "Dolby Vision"
        case .hdr10plus: return "HDR10+"
        case .hdr10: return "HDR10"
        case .hdr: return "HDR"
        case .sdr: return "SDR"
        case .unknown: return "Unknown"
        }
    }

    static func displayName(for ac: AudioCodec, atmos: Bool) -> String {
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

    static func audioSummary(codec: AudioCodec, channels: ChannelLayout, atmos: Bool) -> String {
        let audio = displayName(for: codec, atmos: atmos)
        if let channelText = channelsString(channels) {
            return "\(audio) \(channelText)"
        }
        return audio
    }
}

// MARK: - Views
private struct SearchBar: View {
    @Binding var query: String
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .trailing) {
                TextField("Search movies or shows", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.trailing, query.isEmpty ? 0 : 28)
                    .onSubmit(onSubmit)

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 10)
                }
            }
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
                    }
                    if result.seeders != nil || result.leechers != nil {
                        HStack(spacing: 12) {
                            if let seeders = result.seeders {
                                MetaChip(text: "\(seeders)", systemImage: "arrow.up.circle")
                            }
                            if let leechers = result.leechers {
                                MetaChip(text: "\(leechers)", systemImage: "arrow.down.circle")
                            }
                        }
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
