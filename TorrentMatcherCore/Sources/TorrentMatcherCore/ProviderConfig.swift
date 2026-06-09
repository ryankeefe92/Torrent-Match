import Foundation

public struct ProviderConfig: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let enabled: Bool
    public let timeoutSeconds: Int?
    public let searchURLTemplate: String
    public let alternateSearchURLTemplates: [String]
    public let resultBlockPattern: String
    public let titlePattern: String
    public let detailURLPattern: String?
    public let detailMetadataPattern: String?
    public let magnetPattern: String?
    public let fetchMagnetFromDetailDuringSearch: Bool
    public let seedersPattern: String
    public let leechersPattern: String
    public let sizePattern: String?
    public let detailBaseURL: String?
    public let searchPageCount: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case enabled
        case timeoutSeconds
        case searchURLTemplate
        case alternateSearchURLTemplates
        case resultBlockPattern
        case titlePattern
        case detailURLPattern
        case detailMetadataPattern
        case magnetPattern
        case fetchMagnetFromDetailDuringSearch
        case seedersPattern
        case leechersPattern
        case sizePattern
        case detailBaseURL
        case searchPageCount
    }

    public init(
        id: String,
        name: String,
        enabled: Bool,
        searchURLTemplate: String,
        alternateSearchURLTemplates: [String] = [],
        resultBlockPattern: String,
        titlePattern: String,
        detailURLPattern: String?,
        detailMetadataPattern: String? = nil,
        magnetPattern: String?,
        fetchMagnetFromDetailDuringSearch: Bool = true,
        seedersPattern: String,
        leechersPattern: String,
        sizePattern: String? = nil,
        detailBaseURL: String?,
        timeoutSeconds: Int? = nil,
        searchPageCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.timeoutSeconds = timeoutSeconds
        self.searchURLTemplate = searchURLTemplate
        self.alternateSearchURLTemplates = alternateSearchURLTemplates
        self.resultBlockPattern = resultBlockPattern
        self.titlePattern = titlePattern
        self.detailURLPattern = detailURLPattern
        self.detailMetadataPattern = detailMetadataPattern
        self.magnetPattern = magnetPattern
        self.fetchMagnetFromDetailDuringSearch = fetchMagnetFromDetailDuringSearch
        self.seedersPattern = seedersPattern
        self.leechersPattern = leechersPattern
        self.sizePattern = sizePattern
        self.detailBaseURL = detailBaseURL
        self.searchPageCount = searchPageCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
        searchURLTemplate = try container.decode(String.self, forKey: .searchURLTemplate)
        alternateSearchURLTemplates = try container.decodeIfPresent([String].self, forKey: .alternateSearchURLTemplates) ?? []
        resultBlockPattern = try container.decode(String.self, forKey: .resultBlockPattern)
        titlePattern = try container.decode(String.self, forKey: .titlePattern)
        detailURLPattern = try container.decodeIfPresent(String.self, forKey: .detailURLPattern)
        detailMetadataPattern = try container.decodeIfPresent(String.self, forKey: .detailMetadataPattern)
        magnetPattern = try container.decodeIfPresent(String.self, forKey: .magnetPattern)
        fetchMagnetFromDetailDuringSearch = try container.decodeIfPresent(Bool.self, forKey: .fetchMagnetFromDetailDuringSearch) ?? true
        seedersPattern = try container.decode(String.self, forKey: .seedersPattern)
        leechersPattern = try container.decode(String.self, forKey: .leechersPattern)
        sizePattern = try container.decodeIfPresent(String.self, forKey: .sizePattern)
        detailBaseURL = try container.decodeIfPresent(String.self, forKey: .detailBaseURL)
        searchPageCount = try container.decodeIfPresent(Int.self, forKey: .searchPageCount)
    }
}

public protocol TorrentProvider: Sendable {
    var config: ProviderConfig { get }
    func search(
        _ query: String,
        onProgress: (@Sendable (_ addedResults: [TorrentSearchResult]) async -> Void)?
    ) async throws -> [TorrentSearchResult]
    func resolveMagnet(for result: TorrentSearchResult) async throws -> String?
    func fetchDetailMetadata(for result: TorrentSearchResult) async throws -> TorrentDetailMetadata?
}

public extension TorrentProvider {
    func search(_ query: String) async throws -> [TorrentSearchResult] {
        try await search(query, onProgress: nil)
    }

    func resolveMagnet(for result: TorrentSearchResult) async throws -> String? {
        result.magnet
    }

    func fetchDetailMetadata(for result: TorrentSearchResult) async throws -> TorrentDetailMetadata? {
        nil
    }
}

public enum ProviderError: Error, LocalizedError, Sendable {
    case missingURLTemplate(provider: String)
    case invalidURL(String)
    case badStatus(provider: String, status: Int)
    case accessBlocked(provider: String, reason: String)
    case timedOut(provider: String, seconds: Int)

    public var errorDescription: String? {
        switch self {
        case .missingURLTemplate(let provider): return "Missing searchURLTemplate for provider: \(provider)"
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .badStatus(let provider, let status): return "Provider \(provider) returned HTTP status \(status)"
        case .accessBlocked(let provider, let reason): return "Provider \(provider) blocked access: \(reason)"
        case .timedOut(let provider, let seconds): return "Provider \(provider) timed out after \(seconds)s"
        }
    }
}
