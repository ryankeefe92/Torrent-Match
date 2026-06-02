import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct MovieCatalogSuggestion: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let year: Int
    public let providerQuery: String

    public init(id: String, title: String, year: Int, providerQuery: String) {
        self.id = id
        self.title = title
        self.year = year
        self.providerQuery = providerQuery
    }

    public var displayTitle: String {
        "\(title) (\(year))"
    }
}

public actor MovieCatalog {
    public static let shared = MovieCatalog()

    private var database: OpaquePointer?

    public init() {}

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    public func warm() async {
        do {
            _ = try openDatabase()
        } catch {
            print("Movie catalog warm-up failed: \(error)")
        }
    }

    public func suggestions(for query: String, limit: Int = 12) async -> [MovieCatalogSuggestion] {
        let normalizedQuery = Self.normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }

        do {
            let database = try openDatabase()
            let strongSuggestions = try querySuggestions(
                in: database,
                normalizedQuery: normalizedQuery,
                limit: limit,
                minimumVotes: 1_000
            )

            if strongSuggestions.count >= min(5, limit) {
                return strongSuggestions
            }

            if strongSuggestions.count >= limit {
                return strongSuggestions
            }

            let relaxedSuggestions = try querySuggestions(
                in: database,
                normalizedQuery: normalizedQuery,
                limit: limit,
                minimumVotes: 0
            )

            return merge(strongSuggestions: strongSuggestions, relaxedSuggestions: relaxedSuggestions, limit: limit)
        } catch {
            print("Movie catalog query failed: \(error)")
            return []
        }
    }

    private func openDatabase() throws -> OpaquePointer {
        if let database {
            return database
        }

        guard let url = Bundle.module.url(forResource: "MovieCatalog", withExtension: "sqlite") else {
            throw MovieCatalogError.missingResource
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            let message = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown sqlite error"
            if let handle {
                sqlite3_close(handle)
            }
            throw MovieCatalogError.openFailed(message)
        }

        database = handle
        return handle
    }

    private func querySuggestions(
        in database: OpaquePointer,
        normalizedQuery: String,
        limit: Int,
        minimumVotes: Int
    ) throws -> [MovieCatalogSuggestion] {
        let prefixPattern = normalizedQuery + "%"
        let compactPrefixPattern = normalizedQuery.replacingOccurrences(of: " ", with: "") + "%"

        let sql = """
        SELECT id, title, year, provider_query
        FROM movies
        WHERE (
                normalized_title LIKE ?1
             OR canonical_title LIKE ?1
             OR REPLACE(normalized_title, ' ', '') LIKE ?2
             OR REPLACE(canonical_title, ' ', '') LIKE ?2
        )
          AND (
                num_votes >= ?4
             OR canonical_title = ?3
             OR normalized_title = ?3
          )
        ORDER BY
            CASE
                WHEN canonical_title = ?3 THEN 0
                WHEN normalized_title = ?3 THEN 1
                WHEN canonical_title LIKE ?1 THEN 2
                WHEN normalized_title LIKE ?1 THEN 3
                WHEN REPLACE(canonical_title, ' ', '') LIKE ?2 THEN 4
                ELSE 5
            END,
            CASE
                WHEN runtime_minutes IS NULL THEN 1
                WHEN runtime_minutes >= 45 THEN 0
                ELSE 1
            END,
            num_votes DESC,
            english_bias DESC,
            year ASC
        LIMIT ?5
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MovieCatalogError.prepareFailed(sqlite3ErrorMessage(from: database))
        }
        defer { sqlite3_finalize(statement) }

        bind(prefixPattern, at: 1, in: statement)
        bind(compactPrefixPattern, at: 2, in: statement)
        bind(normalizedQuery, at: 3, in: statement)
        sqlite3_bind_int(statement, 4, Int32(minimumVotes))
        sqlite3_bind_int(statement, 5, Int32(limit))

        var suggestions: [MovieCatalogSuggestion] = []
        suggestions.reserveCapacity(limit)

        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idCString = sqlite3_column_text(statement, 0),
                let titleCString = sqlite3_column_text(statement, 1),
                let providerQueryCString = sqlite3_column_text(statement, 3)
            else {
                continue
            }

            suggestions.append(
                MovieCatalogSuggestion(
                    id: String(cString: idCString),
                    title: String(cString: titleCString),
                    year: Int(sqlite3_column_int(statement, 2)),
                    providerQuery: String(cString: providerQueryCString)
                )
            )
        }

        return suggestions
    }

    private func merge(
        strongSuggestions: [MovieCatalogSuggestion],
        relaxedSuggestions: [MovieCatalogSuggestion],
        limit: Int
    ) -> [MovieCatalogSuggestion] {
        var merged = strongSuggestions
        var seenIDs = Set(strongSuggestions.map(\.id))

        for suggestion in relaxedSuggestions where !seenIDs.contains(suggestion.id) {
            merged.append(suggestion)
            seenIDs.insert(suggestion.id)
            if merged.count == limit {
                break
            }
        }

        return merged
    }

    static func normalize(_ text: String) -> String {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "&", with: " and ")

        let cleaned = String(
            folded.unicodeScalars.map { scalar in
                CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : " "
            }.joined()
        )

        return cleaned
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

private enum MovieCatalogError: Error {
    case missingResource
    case openFailed(String)
    case prepareFailed(String)
}

private func sqlite3ErrorMessage(from database: OpaquePointer?) -> String {
    guard let database, let message = sqlite3_errmsg(database) else {
        return "unknown sqlite error"
    }
    return String(cString: message)
}

private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) {
    _ = value.withCString { pointer in
        sqlite3_bind_text(statement, index, pointer, -1, sqliteTransient)
    }
}
