import Combine
import Foundation
import TorrentMatcherCore

@MainActor
final class MovieAutocompleteViewModel: ObservableObject {
    @Published private(set) var suggestions: [MovieCatalogSuggestion] = []

    private var selectedSuggestionValue: MovieCatalogSuggestion?
    private var searchTask: Task<Void, Never>?

    init() {
        Task {
            await MovieCatalog.shared.warm()
        }
    }

    func updateQuery(_ query: String) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestions = []
            selectedSuggestionValue = nil
            return
        }

        if let selectedSuggestion = selectedSuggestion, selectedSuggestion.displayTitle != trimmed {
            selectedSuggestionValue = nil
        }

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }

            let loadedSuggestions = await MovieCatalog.shared.suggestions(for: trimmed, limit: 12)
            guard !Task.isCancelled else { return }

            suggestions = loadedSuggestions
        }
    }

    func selectSuggestion(_ suggestion: MovieCatalogSuggestion) {
        selectedSuggestionValue = suggestion
        suggestions = []
    }

    func clearSuggestions() {
        suggestions = []
    }

    var selectedSuggestion: MovieCatalogSuggestion? {
        selectedSuggestionValue
    }

    func resolvedSuggestion(for query: String) -> MovieCatalogSuggestion? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let selectedSuggestion, selectedSuggestion.displayTitle == trimmed {
            return selectedSuggestion
        }
        return suggestions.first(where: { $0.displayTitle == trimmed })
    }
}
