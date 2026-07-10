import Darwin
import Foundation

typealias CodexRadarRequestExecutor = @Sendable (URLRequest) async throws -> (Data, URLResponse)

struct CodexRadarClient: Sendable {
    static let publicSummaryURL = URL(string: "https://codexradar.com/current.json")!
    static let authorizedCurrentURL = URL(string: "https://codexradar.com/api/v1/current")!

    let publicEndpoint: URL
    let authorizedEndpoint: URL
    let tokenProvider: CodexRadarTokenProvider
    let timeout: TimeInterval
    let requestExecutor: CodexRadarRequestExecutor?

    init(
        publicEndpoint: URL = Self.publicSummaryURL,
        authorizedEndpoint: URL = Self.authorizedCurrentURL,
        tokenProvider: CodexRadarTokenProvider = CodexRadarTokenProvider(),
        timeout: TimeInterval = 8,
        requestExecutor: CodexRadarRequestExecutor? = nil
    ) {
        self.publicEndpoint = publicEndpoint
        self.authorizedEndpoint = authorizedEndpoint
        self.tokenProvider = tokenProvider
        self.timeout = timeout
        self.requestExecutor = requestExecutor
    }

    func fetchSummary() async throws -> CodexRadarFetchResult {
        if let token = tokenProvider.token() {
            do {
                let data = try await fetch(endpoint: authorizedEndpoint, source: .authorizedAPI, bearerToken: token)
                return CodexRadarFetchResult(data: data, source: .authorizedAPI, fallbackReason: nil)
            } catch {
                guard let reason = Self.fallbackReason(for: error) else {
                    throw error
                }
                let data = try await fetch(endpoint: publicEndpoint, source: .publicSummary, bearerToken: nil)
                return CodexRadarFetchResult(data: data, source: .publicSummary, fallbackReason: reason)
            }
        }

        let data = try await fetch(endpoint: publicEndpoint, source: .publicSummary, bearerToken: nil)
        return CodexRadarFetchResult(data: data, source: .publicSummary, fallbackReason: nil)
    }

    func fetchPublicSummary() async throws -> Data {
        try await fetch(endpoint: publicEndpoint, source: .publicSummary, bearerToken: nil)
    }

    private func fetch(endpoint: URL, source: CodexRadarDataSource, bearerToken: String?) async throws -> Data {
        guard Self.isAllowedURL(endpoint, source: source) else {
            throw CodexRadarClientError.disallowedURL
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-monitor/0.1", forHTTPHeaderField: "User-Agent")
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await execute(request)
        try NetworkResponsePolicy.validate(data, response: response)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexRadarClientError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw CodexRadarClientError.httpStatus(httpResponse.statusCode)
        }
        guard !data.isEmpty else {
            throw CodexRadarClientError.emptyResponse
        }
        return data
    }

    private func execute(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if let requestExecutor {
            return try await requestExecutor(request)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let redirectDelegate = SameOriginRedirectDelegate(configuredURL: request.url!)
        let session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        defer {
            session.finishTasksAndInvalidate()
        }
        return try await NetworkResponsePolicy.data(for: request, session: session)
    }

    static func fallbackReason(for error: Error) -> CodexRadarFallbackReason? {
        if error is CancellationError {
            return nil
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? nil : .apiUnavailable
        }
        guard let clientError = error as? CodexRadarClientError else {
            return .apiUnavailable
        }
        switch clientError {
        case .disallowedURL:
            return nil
        case .httpStatus(let status) where status == 401 || status == 403:
            return .invalidToken
        case .invalidResponse, .httpStatus, .emptyResponse:
            return .apiUnavailable
        }
    }

    static func isAllowedURL(_ url: URL, source: CodexRadarDataSource) -> Bool {
        switch source {
        case .authorizedAPI:
            isAllowedAuthorizedAPIURL(url)
        case .publicSummary:
            isAllowedPublicSummaryURL(url)
        }
    }

    static func isAllowedPublicSummaryURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "codexradar.com",
              url.path == "/current.json",
              url.user == nil,
              url.password == nil else {
            return false
        }
        return true
    }

    static func isAllowedAuthorizedAPIURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "codexradar.com",
              url.path == "/api/v1/current",
              url.user == nil,
              url.password == nil else {
            return false
        }
        return true
    }
}

struct CodexRadarFetchResult: Sendable {
    let data: Data
    let source: CodexRadarDataSource
    let fallbackReason: CodexRadarFallbackReason?
}

enum CodexRadarFallbackReason: String, Codable, Equatable, Sendable {
    case invalidToken
    case apiUnavailable

    var displayMessage: String {
        switch self {
        case .invalidToken:
            "API Token 无效，已使用公开摘要"
        case .apiUnavailable:
            "API 暂不可用，已使用公开摘要"
        }
    }
}

struct CodexRadarTokenProvider: Sendable {
    static let environmentKey = "CODEXRADAR_API_TOKEN"

    let environment: [String: String]
    let tokenFileURL: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        tokenFileURL: URL = Self.defaultTokenFileURL()
    ) {
        self.environment = environment
        self.tokenFileURL = tokenFileURL
    }

    func token() -> String? {
        if let environmentToken = Self.trimmedToken(environment[Self.environmentKey]) {
            return environmentToken
        }
        return Self.trimmedToken(Self.loadSavedToken(from: tokenFileURL))
    }

    static func defaultTokenFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("CodexNotch", isDirectory: true)
            .appendingPathComponent("CodexRadar", isDirectory: true)
            .appendingPathComponent("token")
    }

    static func loadSavedToken(from tokenFileURL: URL = defaultTokenFileURL()) -> String {
        guard let data = try? Data(contentsOf: tokenFileURL) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func saveToken(_ token: String, to tokenFileURL: URL = defaultTokenFileURL()) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = tokenFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, S_IRWXU)

        guard !trimmed.isEmpty else {
            if FileManager.default.fileExists(atPath: tokenFileURL.path) {
                try FileManager.default.removeItem(at: tokenFileURL)
            }
            return
        }

        try Data(trimmed.utf8).write(to: tokenFileURL, options: .atomic)
        chmod(tokenFileURL.path, S_IRUSR | S_IWUSR)
    }

    private static func trimmedToken(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum CodexRadarClientError: LocalizedError {
    case disallowedURL
    case invalidResponse
    case httpStatus(Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .disallowedURL:
            "Codex Radar 只允许读取官方 API 或公开 summary"
        case .invalidResponse:
            "Codex Radar 返回了无效响应"
        case .httpStatus(let status):
            "Codex Radar HTTP \(status)"
        case .emptyResponse:
            "Codex Radar 返回空数据"
        }
    }
}
