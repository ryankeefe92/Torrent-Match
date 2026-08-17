import Foundation

public final class YTSAPIProvider: TorrentProvider, @unchecked Sendable {
    public let config: ProviderConfig
    private let session: URLSession

    public init(config: ProviderConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func search(
        _ query: String,
        onProgress: (@concurrent @Sendable (_ addedResults: [TorrentSearchResult]) async -> Void)?
    ) async throws -> [TorrentSearchResult] {
        guard config.enabled else { return [] }

        var firstError: Error?
        for template in [config.searchURLTemplate] + config.alternateSearchURLTemplates {
            do {
                let results = try await search(template: template, query: query)
                if let onProgress, !results.isEmpty {
                    await onProgress(results)
                }
                return results
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if let firstError {
            throw firstError
        }
        return []
    }

    private func search(template: String, query: String) async throws -> [TorrentSearchResult] {
        let urlValue = template.replacingOccurrences(of: "{{query}}", with: query.encodedYTSQueryValue)
        guard let url = URL(string: urlValue) else {
            throw ProviderError.invalidURL(urlValue)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(config.timeoutSeconds ?? 20)
        request.setValue("Mozilla/5.0 (Torrent Match)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.badStatus(provider: config.name, status: http.statusCode)
        }

        let payload = try JSONDecoder().decode(YTSSearchResponse.self, from: data)
        guard payload.status == "ok" else {
            return []
        }

        return (payload.data?.movies ?? []).flatMap { movie in
            movie.torrents.map { torrent in
                let title = releaseTitle(movie: movie, torrent: torrent)
                return TorrentSearchResult(
                    title: title,
                    magnet: magnet(hash: torrent.hash, displayName: title),
                    detailURL: URL(string: movie.url),
                    seeders: max(0, torrent.seeds),
                    leechers: max(0, torrent.peers),
                    provider: config.name,
                    size: torrent.size
                )
            }
        }
    }

    private func releaseTitle(movie: YTSMovie, torrent: YTSTorrent) -> String {
        let source: String
        switch torrent.type.lowercased() {
        case "bluray":
            source = "BluRay"
        case "web":
            source = "WEB-DL"
        default:
            source = torrent.type
        }

        let repack = torrent.isRepack == "1" ? " REPACK" : ""
        return "\(movie.title) \(movie.year) \(torrent.quality) \(source) \(torrent.videoCodec) \(torrent.bitDepth)-bit \(torrent.audioChannels)\(repack)-YTS"
    }

    private func magnet(hash: String, displayName: String) -> String {
        var components = URLComponents()
        components.scheme = "magnet"
        components.queryItems = [
            URLQueryItem(name: "xt", value: "urn:btih:\(hash)"),
            URLQueryItem(name: "dn", value: displayName),
            URLQueryItem(name: "tr", value: "udp://tracker.opentrackr.org:1337/announce"),
            URLQueryItem(name: "tr", value: "udp://tracker.torrent.eu.org:451/announce"),
            URLQueryItem(name: "tr", value: "udp://open.stealth.si:80/announce")
        ]
        return components.string ?? "magnet:?xt=urn:btih:\(hash)"
    }
}

private struct YTSSearchResponse: Decodable {
    let status: String
    let data: YTSSearchData?
}

private struct YTSSearchData: Decodable {
    let movies: [YTSMovie]?
}

private struct YTSMovie: Decodable {
    let title: String
    let year: Int
    let url: String
    let torrents: [YTSTorrent]
}

private struct YTSTorrent: Decodable {
    let hash: String
    let quality: String
    let type: String
    let isRepack: String
    let videoCodec: String
    let bitDepth: String
    let audioChannels: String
    let seeds: Int
    let peers: Int
    let size: String

    private enum CodingKeys: String, CodingKey {
        case hash
        case quality
        case type
        case isRepack = "is_repack"
        case videoCodec = "video_codec"
        case bitDepth = "bit_depth"
        case audioChannels = "audio_channels"
        case seeds
        case peers
        case size
    }
}

private extension String {
    var encodedYTSQueryValue: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
