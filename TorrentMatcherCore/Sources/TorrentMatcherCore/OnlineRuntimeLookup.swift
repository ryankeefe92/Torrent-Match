import Foundation

public actor OnlineRuntimeLookup {
    public static let shared = OnlineRuntimeLookup()

    private let session: URLSession
    private var cache: [String: MovieCatalogRuntime] = [:]

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func runtime(for releaseTitle: String, query: String) async -> MovieCatalogRuntime? {
        guard releaseTitle.containsAlternateCutToken else { return nil }
        let cacheKey = "\(query)|\(releaseTitle)".lowercased()
        if let cached = cache[cacheKey] {
            return cached
        }

        if let runtime = await fetchRuntime(for: releaseTitle, query: query) {
            cache[cacheKey] = runtime
            return runtime
        }
        return nil
    }

    private func fetchRuntime(for releaseTitle: String, query: String) async -> MovieCatalogRuntime? {
        for searchTerm in searchTermsForRuntimeLookup(releaseTitle: releaseTitle, query: query) {
            if let runtime = await wikipediaRuntime(for: searchTerm) {
                return runtime
            }
            if let runtime = await wikidataRuntime(for: searchTerm) {
                return runtime
            }
            if let runtime = await searchSnippetRuntime(for: searchTerm) {
                return runtime
            }
        }
        return nil
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("TorrentMatch/1.0 (runtime lookup)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func searchTermsForRuntimeLookup(releaseTitle: String, query: String) -> [String] {
        let edition = releaseTitle.alternateCutSearchToken ?? "alternate cut"
        let titleAndYear = releaseTitle.movieTitleAndYearForRuntimeLookup ?? query
        return [
            "\(titleAndYear) \(edition) film running time",
            "\(titleAndYear) \(edition) runtime",
            "\(titleAndYear) \(edition) movie-censorship runtime",
            "\(releaseTitle) runtime"
        ].uniquedPreservingOrder()
    }

    private func wikipediaRuntime(for searchTerm: String) async -> MovieCatalogRuntime? {
        guard let searchURL = wikipediaSearchURL(for: searchTerm),
              let searchData = try? await fetch(searchURL),
              let titles = wikipediaSearchTitles(from: searchData),
              !titles.isEmpty else { return nil }

        for title in titles.prefix(4) {
            guard let parseURL = wikipediaParseURL(for: title),
                  let pageData = try? await fetch(parseURL),
                  let pageText = wikipediaPageText(from: pageData),
                  let runtime = runtime(from: pageText) else { continue }
            return runtime
        }
        return nil
    }

    private func wikidataRuntime(for searchTerm: String) async -> MovieCatalogRuntime? {
        guard let searchURL = wikidataSearchURL(for: searchTerm),
              let searchData = try? await fetch(searchURL),
              let entityIDs = wikidataEntityIDs(from: searchData),
              !entityIDs.isEmpty else { return nil }

        for entityID in entityIDs.prefix(4) {
            guard let entityURL = wikidataEntityURL(for: entityID),
                  let entityData = try? await fetch(entityURL),
                  let runtime = wikidataRuntime(from: entityData) else { continue }
            return runtime
        }
        return nil
    }

    private func searchSnippetRuntime(for searchTerm: String) async -> MovieCatalogRuntime? {
        guard let url = duckDuckGoSearchURL(for: searchTerm),
              let data = try? await fetch(url),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        return runtime(fromSearchText: html.htmlDecoded.readableMetadataText)
    }

    private func wikipediaSearchURL(for term: String) -> URL? {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: term),
            URLQueryItem(name: "srlimit", value: "5"),
            URLQueryItem(name: "format", value: "json")
        ]
        return components?.url
    }

    private func wikipediaParseURL(for title: String) -> URL? {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "parse"),
            URLQueryItem(name: "page", value: title),
            URLQueryItem(name: "prop", value: "wikitext"),
            URLQueryItem(name: "format", value: "json")
        ]
        return components?.url
    }

    private func wikidataSearchURL(for term: String) -> URL? {
        var components = URLComponents(string: "https://www.wikidata.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "wbsearchentities"),
            URLQueryItem(name: "search", value: term),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "format", value: "json")
        ]
        return components?.url
    }

    private func wikidataEntityURL(for entityID: String) -> URL? {
        let components = URLComponents(string: "https://www.wikidata.org/wiki/Special:EntityData/\(entityID).json")
        return components?.url
    }

    private func duckDuckGoSearchURL(for term: String) -> URL? {
        var components = URLComponents(string: "https://duckduckgo.com/html/")
        components?.queryItems = [
            URLQueryItem(name: "q", value: term)
        ]
        return components?.url
    }

    private func wikipediaSearchTitles(from data: Data) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = object["query"] as? [String: Any],
              let search = query["search"] as? [[String: Any]] else { return nil }
        return search.compactMap { $0["title"] as? String }
    }

    private func wikipediaPageText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parse = object["parse"] as? [String: Any],
              let wikitext = parse["wikitext"] as? [String: Any],
              let text = wikitext["*"] as? String else { return nil }
        return text
    }

    private func wikidataEntityIDs(from data: Data) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let search = object["search"] as? [[String: Any]] else { return nil }
        return search.compactMap { $0["id"] as? String }
    }

    private func wikidataRuntime(from data: Data) -> MovieCatalogRuntime? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entities = object["entities"] as? [String: Any],
              let entity = entities.values.first as? [String: Any],
              let claims = entity["claims"] as? [String: Any],
              let runtimeClaims = claims["P2047"] as? [[String: Any]] else { return nil }

        for claim in runtimeClaims {
            guard let mainsnak = claim["mainsnak"] as? [String: Any],
                  let datavalue = mainsnak["datavalue"] as? [String: Any],
                  let value = datavalue["value"] as? [String: Any],
                  let amountText = value["amount"] as? String,
                  let amount = Double(amountText.replacingOccurrences(of: "+", with: "")) else { continue }
            let minutes = amount > 1_000 ? Int((amount / 60).rounded()) : Int(amount.rounded())
            if (45...400).contains(minutes) {
                return MovieCatalogRuntime(minutes: minutes)
            }
        }
        return nil
    }

    public func runtime(from text: String) -> MovieCatalogRuntime? {
        let patterns = [
            #"(?i)running[_\s]*time\s*=\s*([^\n\r\|<>{}]{1,120})"#,
            #"(?i)running\s*time[^0-9]{0,40}([0-9]{2,3})\s*(?:minutes?|mins?|m)\b"#,
            #"(?i)([0-9]{1,2})\s*h(?:ours?)?\s*([0-9]{1,2})\s*m(?:in(?:utes?)?)?"#
        ]
        for pattern in patterns {
            guard let captures = regexCaptures(pattern, in: text) else { continue }
            if captures.count >= 2,
               let hours = Int(captures[0]),
               let minutes = Int(captures[1]) {
                let total = hours * 60 + minutes
                if (45...400).contains(total) {
                    return MovieCatalogRuntime(minutes: total)
                }
            }
            if let minutes = minutesFromRuntimeLabel(captures[0]) {
                return MovieCatalogRuntime(minutes: minutes)
            }
        }
        return nil
    }

    public func runtime(fromSearchText text: String) -> MovieCatalogRuntime? {
        let patterns = [
            #"(?i)(?:director'?s?\s*cut|extended\s*cut|final\s*cut|special\s*edition|alternate\s*cut|runtime|running\s*time)[^0-9]{0,80}([0-9]{2,3})\s*(?:minutes?|mins?|m)\b"#,
            #"(?i)(?:director'?s?\s*cut|extended\s*cut|final\s*cut|special\s*edition|alternate\s*cut|runtime|running\s*time)[^0-9]{0,80}([0-9]{1,2})\s*h(?:ours?)?\s*([0-9]{1,2})\s*m"#
        ]
        for pattern in patterns {
            guard let captures = regexCaptures(pattern, in: text) else { continue }
            if captures.count >= 2,
               let hours = Int(captures[0]),
               let minutes = Int(captures[1]) {
                let total = hours * 60 + minutes
                if (45...400).contains(total) { return MovieCatalogRuntime(minutes: total) }
            }
            if let minutes = Int(captures[0]), (45...400).contains(minutes) {
                return MovieCatalogRuntime(minutes: minutes)
            }
        }
        return nil
    }

    private func minutesFromRuntimeLabel(_ raw: String) -> Int? {
        let cleaned = raw
            .replacingOccurrences(of: #"&nbsp;"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\{\{[^\}]+\}\}"#, with: " ", options: .regularExpression)

        if let captures = regexCaptures(#"(?i)([0-9]{1,2})\s*h(?:ours?)?\s*([0-9]{1,2})\s*m"#, in: cleaned),
           captures.count >= 2,
           let hours = Int(captures[0]),
           let minutes = Int(captures[1]) {
            let total = hours * 60 + minutes
            return (45...400).contains(total) ? total : nil
        }

        guard let minutesText = firstRegexCapture(#"(?i)([0-9]{2,3})\s*(?:minutes?|mins?|m)\b"#, in: cleaned),
              let minutes = Int(minutesText),
              (45...400).contains(minutes) else { return nil }
        return minutes
    }

    private func firstRegexCapture(_ pattern: String, in text: String) -> String? {
        regexCaptures(pattern, in: text)?.first
    }

    private func regexCaptures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else { return nil }
        let captures = (1..<match.numberOfRanges).compactMap { index -> String? in
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        return captures.isEmpty ? nil : captures
    }
}

private extension Array where Element: Hashable {
    func uniquedPreservingOrder() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private extension String {
    var containsAlternateCutToken: Bool {
        range(
            of: #"(?i)(^|[^a-z0-9])(dc|director'?s?\s*cut|extended|unrated|uncut|alternate\s*cut|assembly\s*cut|final\s*cut|special\s*edition|roadshow|redux|criterion\s*cut)([^a-z0-9]|$)"#,
            options: .regularExpression
        ) != nil
    }

    var alternateCutSearchToken: String? {
        let lower = lowercased()
        if lower.range(of: #"(^|[^a-z0-9])dc([^a-z0-9]|$)"#, options: .regularExpression) != nil { return "director's cut" }
        if lower.contains("director") { return "director's cut" }
        if lower.contains("extended") { return "extended cut" }
        if lower.contains("unrated") { return "unrated cut" }
        if lower.contains("uncut") { return "uncut" }
        if lower.contains("final") { return "final cut" }
        if lower.contains("redux") { return "redux" }
        if lower.contains("roadshow") { return "roadshow version" }
        if lower.contains("special") { return "special edition" }
        return nil
    }

    var movieTitleAndYearForRuntimeLookup: String? {
        let tokens = split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard let yearIndex = tokens.firstIndex(where: { token in
            token.count == 4 && (Int(token) ?? 0) >= 1900 && (Int(token) ?? 0) <= 2100
        }), yearIndex > 0 else { return nil }
        return (Array(tokens[..<yearIndex]) + [tokens[yearIndex]]).joined(separator: " ")
    }
}
