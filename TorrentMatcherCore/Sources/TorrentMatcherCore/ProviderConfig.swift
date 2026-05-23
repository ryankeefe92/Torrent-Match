import Foundation

public struct ProviderConfig: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let enabled: Bool
    public let searchURLTemplate: String
    public let resultBlockPattern: String
    public let titlePattern: String
    public let detailURLPattern: String?
    public let magnetPattern: String?
    public let seedersPattern: String
    public let leechersPattern: String
    public let detailBaseURL: String?

    public init(
        id: String,
        name: String,
        enabled: Bool,
        searchURLTemplate: String,
        resultBlockPattern: String,
        titlePattern: String,
        detailURLPattern: String?,
        magnetPattern: String?,
        seedersPattern: String,
        leechersPattern: String,
        detailBaseURL: String?
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.searchURLTemplate = searchURLTemplate
        self.resultBlockPattern = resultBlockPattern
        self.titlePattern = titlePattern
        self.detailURLPattern = detailURLPattern
        self.magnetPattern = magnetPattern
        self.seedersPattern = seedersPattern
        self.leechersPattern = leechersPattern
        self.detailBaseURL = detailBaseURL
    }
}

public protocol TorrentProvider: Sendable {
    var config: ProviderConfig { get }
    func search(_ query: String) async throws -> [TorrentSearchResult]
}

public enum ProviderError: Error, LocalizedError, Sendable {
    case missingURLTemplate(provider: String)
    case invalidURL(String)
    case badStatus(provider: String, status: Int)

    public var errorDescription: String? {
        switch self {
        case .missingURLTemplate(let provider): return "Missing searchURLTemplate for provider: \(provider)"
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .badStatus(let provider, let status): return "Provider \(provider) returned HTTP status \(status)"
        }
    }
}
