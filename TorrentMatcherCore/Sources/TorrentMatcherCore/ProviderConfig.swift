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
    public let magnetPattern: String?
    public let fetchMagnetFromDetailDuringSearch: Bool
    public let seedersPattern: String
    public let leechersPattern: String
    public let sizePattern: String?
    public let detailBaseURL: String?
    public let searchPageCount: Int?

    public init(
        id: String,
        name: String,
        enabled: Bool,
        searchURLTemplate: String,
        alternateSearchURLTemplates: [String] = [],
        resultBlockPattern: String,
        titlePattern: String,
        detailURLPattern: String?,
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
        self.magnetPattern = magnetPattern
        self.fetchMagnetFromDetailDuringSearch = fetchMagnetFromDetailDuringSearch
        self.seedersPattern = seedersPattern
        self.leechersPattern = leechersPattern
        self.sizePattern = sizePattern
        self.detailBaseURL = detailBaseURL
        self.searchPageCount = searchPageCount
    }
}

public protocol TorrentProvider: Sendable {
    var config: ProviderConfig { get }
    func search(_ query: String) async throws -> [TorrentSearchResult]
    func resolveMagnet(for result: TorrentSearchResult) async throws -> String?
}

public extension TorrentProvider {
    func resolveMagnet(for result: TorrentSearchResult) async throws -> String? {
        result.magnet
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
