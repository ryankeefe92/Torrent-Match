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

public struct MovieCatalogRuntime: Hashable, Sendable {
    public let minutes: Int

    public var displayText: String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0 {
            return "\(hours) h \(remainder) min"
        }
        return "\(minutes) min"
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

    public func runtime(for query: String) async -> MovieCatalogRuntime? {
        let (title, year) = Self.titleAndYear(from: query)
        let normalizedQuery = Self.normalize(title)
        guard !normalizedQuery.isEmpty else { return nil }

        do {
            let database = try openDatabase()
            if let year,
               let runtime = try queryRuntime(in: database, normalizedQuery: normalizedQuery, year: year) {
                return runtime
            }
            return try queryRuntime(in: database, normalizedQuery: normalizedQuery, year: nil)
        } catch {
            print("Movie catalog runtime query failed: \(error)")
            return nil
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

    private func queryRuntime(
        in database: OpaquePointer,
        normalizedQuery: String,
        year: Int?
    ) throws -> MovieCatalogRuntime? {
        let sql = """
        SELECT runtime_minutes
        FROM movies
        WHERE runtime_minutes IS NOT NULL
          AND (normalized_title = ?1 OR canonical_title = ?1)
          AND (?2 IS NULL OR year = ?2)
        ORDER BY
            CASE WHEN year = ?2 THEN 0 ELSE 1 END,
            num_votes DESC,
            english_bias DESC
        LIMIT 1
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw MovieCatalogError.prepareFailed(sqlite3ErrorMessage(from: database))
        }
        defer { sqlite3_finalize(statement) }

        bind(normalizedQuery, at: 1, in: statement)
        if let year {
            sqlite3_bind_int(statement, 2, Int32(year))
        } else {
            sqlite3_bind_null(statement, 2)
        }

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return MovieCatalogRuntime(minutes: Int(sqlite3_column_int(statement, 0)))
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

    static func titleAndYear(from query: String) -> (title: String, year: Int?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let yearText = RegexTools.firstCapture(pattern: #"(?i)(?:^|[^0-9])((?:19|20)[0-9]{2})(?:[^0-9]|$)"#, in: trimmed),
           let year = Int(yearText) {
            let title = trimmed
                .replacingOccurrences(of: #"(?i)\s*\(?\b(?:19|20)[0-9]{2}\b\)?\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (title.isEmpty ? trimmed : title, year)
        }
        return (trimmed, nil)
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
