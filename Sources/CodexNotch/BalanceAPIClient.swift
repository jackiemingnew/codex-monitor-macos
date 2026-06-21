import Foundation

struct BalanceAPIConfiguration: Equatable {
    let panelURL: String
    let accessToken: String
    let newAPIUserID: String
    let timeout: TimeInterval
    let allowInsecureTLS: Bool
}

enum BalanceAPIError: LocalizedError {
    case invalidURL
    case missingKey
    case missingNewAPIUserID
    case httpStatus(Int)
    case emptyResponse
    case unsupportedResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "面板地址无效"
        case .missingKey:
            "缺少认证信息"
        case .missingNewAPIUserID:
            "缺少 NewAPI 用户 ID"
        case .httpStatus(let status):
            status == 401 || status == 403 ? "认证信息无效或无权限" : "面板返回 HTTP \(status)"
        case .emptyResponse:
            "面板返回空数据"
        case .unsupportedResponse(let message):
            message.isEmpty ? "面板返回格式不兼容" : message.redactedForDisplay
        }
    }
}

final class BalanceAPIClient: NSObject, URLSessionDelegate {
    private let configuration: BalanceAPIConfiguration

    init(configuration: BalanceAPIConfiguration) {
        self.configuration = configuration
    }

    func fetchSnapshot(source: BalanceMonitorSource) async throws -> BalanceMonitorSnapshot {
        let headers = try Self.authenticationHeaders(for: configuration, source: source)
        guard let baseURL = Self.apiBaseURL(from: configuration.panelURL) else {
            throw BalanceAPIError.invalidURL
        }

        switch source {
        case .newAPI:
            return try await fetchNewAPISnapshot(baseURL: baseURL, headers: headers, source: source)
        case .subAPI:
            return try await fetchSubAPISnapshot(baseURL: baseURL, headers: headers, source: source)
        }
    }

    static func authenticationHeaders(
        for configuration: BalanceAPIConfiguration,
        source: BalanceMonitorSource
    ) throws -> [String: String] {
        let token = configuration.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw BalanceAPIError.missingKey
        }

        switch source {
        case .newAPI:
            let userID = configuration.newAPIUserID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !userID.isEmpty else {
                throw BalanceAPIError.missingNewAPIUserID
            }
            return [
                "Authorization": "Bearer \(token)",
                "New-Api-User": userID,
                "Accept": "application/json"
            ]
        case .subAPI:
            return [
                "x-api-key": token,
                "Accept": "application/json"
            ]
        }
    }

    private func fetchNewAPISnapshot(
        baseURL: URL,
        headers: [String: String],
        source: BalanceMonitorSource
    ) async throws -> BalanceMonitorSnapshot {
        let selfEndpoint = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("user")
            .appendingPathComponent("self")
        let selfData = try await authenticatedGET(selfEndpoint, headers: headers, timeout: configuration.timeout)
        var accounts = [try Self.decodeUserAccount(selfData, source: source)]
        var partialMessage: String?

        if let channelEndpoint = Self.channelListURL(baseURL: baseURL),
           !channelEndpoint.absoluteString.isEmpty {
            do {
                let channelData = try await authenticatedGET(channelEndpoint, headers: headers, timeout: configuration.timeout)
                let channels = try Self.decodeChannelAccounts(channelData, source: source)
                accounts.append(contentsOf: channels)
            } catch {
                partialMessage = "渠道列表读取失败：\(Self.localizedMessage(for: error))"
            }
        }

        return BalanceMonitorSnapshot(
            source: source,
            panelState: Self.panelState(for: accounts, partialMessage: partialMessage),
            accounts: accounts,
            message: partialMessage ?? (accounts.isEmpty ? "没有找到 \(source.title) 账户" : nil),
            lastUpdated: Date()
        )
    }

    private func fetchSubAPISnapshot(
        baseURL: URL,
        headers: [String: String],
        source: BalanceMonitorSource
    ) async throws -> BalanceMonitorSnapshot {
        guard let usersEndpoint = Self.subAPIUsersURL(baseURL: baseURL) else {
            throw BalanceAPIError.invalidURL
        }
        let usersData = try await authenticatedGET(usersEndpoint, headers: headers, timeout: configuration.timeout)
        let accounts = try Self.decodeSubAPIUserAccounts(usersData)

        return BalanceMonitorSnapshot(
            source: source,
            panelState: Self.panelState(for: accounts, partialMessage: nil),
            accounts: accounts,
            message: accounts.isEmpty ? "没有找到 Sub2API 用户余额" : nil,
            lastUpdated: Date()
        )
    }

    private func authenticatedGET(
        _ endpoint: URL,
        headers: [String: String],
        timeout: TimeInterval
    ) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = timeout
        sessionConfig.timeoutIntervalForResource = timeout
        let session = URLSession(
            configuration: sessionConfig,
            delegate: configuration.allowInsecureTLS ? self : nil,
            delegateQueue: nil
        )
        defer {
            session.finishTasksAndInvalidate()
        }

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw BalanceAPIError.httpStatus(httpResponse.statusCode)
        }
        guard !data.isEmpty else {
            throw BalanceAPIError.emptyResponse
        }
        return data
    }

    private static func panelState(for accounts: [BalanceAccount], partialMessage: String?) -> BalancePanelState {
        var state: BalancePanelState
        if accounts.isEmpty {
            state = .warning
        } else if accounts.contains(where: { $0.state == .error }) {
            state = .error
        } else if accounts.contains(where: { $0.state == .warning }) {
            state = .warning
        } else {
            state = .healthy
        }
        if partialMessage != nil, state == .healthy {
            state = .warning
        }
        return state
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard configuration.allowInsecureTLS,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    static func apiBaseURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        guard scheme == "https" || scheme == "http" else {
            return nil
        }
        if scheme == "http", !isLocalHost(host) {
            return nil
        }

        components.scheme = scheme
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func channelListURL(baseURL: URL) -> URL? {
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("api")
                .appendingPathComponent("channel")
                .appendingPathComponent(""),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "p", value: "1"),
            URLQueryItem(name: "page_size", value: "100")
        ]
        return components?.url
    }

    private static func subAPIUsersURL(baseURL: URL) -> URL? {
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("api")
                .appendingPathComponent("v1")
                .appendingPathComponent("admin")
                .appendingPathComponent("users"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "page_size", value: "100"),
            URLQueryItem(name: "sort_by", value: "balance"),
            URLQueryItem(name: "sort_order", value: "desc")
        ]
        return components?.url
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
    }

    static func decodeUserAccount(
        _ data: Data,
        source: BalanceMonitorSource
    ) throws -> BalanceAccount {
        let user = try decodePayload(NewAPIUserData.self, from: data)
        return user.balanceAccount(source: source)
    }

    static func decodeChannelAccounts(
        _ data: Data,
        source: BalanceMonitorSource
    ) throws -> [BalanceAccount] {
        if let list = try? decodePayload(NewAPIChannelListData.self, from: data) {
            return list.items.map { $0.balanceAccount(source: source) }
        }
        if let channels = try? decodePayload([NewAPIChannelData].self, from: data) {
            return channels.map { $0.balanceAccount(source: source) }
        }
        throw BalanceAPIError.unsupportedResponse("渠道余额格式不兼容")
    }

    static func decodeSubAPIUserAccounts(_ data: Data) throws -> [BalanceAccount] {
        if let list = try? decodeSubAPIPayload(SubAPIUserListData.self, from: data) {
            return list.items.map { $0.balanceAccount() }
        }
        if let users = try? decodeSubAPIPayload([SubAPIUserData].self, from: data) {
            return users.map { $0.balanceAccount() }
        }
        throw BalanceAPIError.unsupportedResponse("Sub2API 用户余额格式不兼容")
    }

    private static func decodePayload<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(NewAPIEnvelope<T>.self, from: data) {
            if envelope.success == false {
                throw BalanceAPIError.unsupportedResponse((envelope.message ?? "").redactedForDisplay)
            }
            if let payload = envelope.data {
                return payload
            }
        }
        return try decoder.decode(T.self, from: data)
    }

    private static func decodeSubAPIPayload<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(SubAPIEnvelope<T>.self, from: data) {
            if let code = envelope.code, code != 0 {
                throw BalanceAPIError.unsupportedResponse((envelope.message ?? "").redactedForDisplay)
            }
            if let payload = envelope.data {
                return payload
            }
        }
        return try decoder.decode(T.self, from: data)
    }

    private static func localizedMessage(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized.redactedForDisplay
        }
        return error.localizedDescription.redactedForDisplay
    }
}

private struct NewAPIEnvelope<T: Decodable>: Decodable {
    let success: Bool?
    let message: String?
    let data: T?
}

private struct SubAPIEnvelope<T: Decodable>: Decodable {
    let code: Int?
    let message: String?
    let data: T?
}

private struct NewAPIUserData: Decodable {
    let username: String?
    let displayName: String?
    let quota: Int?
    let usedQuota: Int?
    let requestCount: Int?
    let status: Int?

    enum CodingKeys: String, CodingKey {
        case username
        case displayName = "display_name"
        case displayNameCamel = "displayName"
        case quota
        case usedQuota = "used_quota"
        case usedQuotaCamel = "usedQuota"
        case requestCount = "request_count"
        case requestCountCamel = "requestCount"
        case status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = container.flexibleString(for: [.username])
        displayName = container.flexibleString(for: [.displayName, .displayNameCamel])
        quota = container.flexibleInt(for: [.quota])
        usedQuota = container.flexibleInt(for: [.usedQuota, .usedQuotaCamel])
        requestCount = container.flexibleInt(for: [.requestCount, .requestCountCamel])
        status = container.flexibleInt(for: [.status])
    }

    func balanceAccount(source: BalanceMonitorSource) -> BalanceAccount {
        let state: BalanceAccountState = status == nil || status == 1 ? .healthy : .warning
        return BalanceAccount(
            id: "\(source.rawValue)-self",
            source: source,
            name: displayName ?? username ?? "\(source.title) 用户",
            kind: "用户额度",
            statusCode: status,
            amountText: quota.map(Formatters.compactTokens(_:)) ?? "--",
            usedText: usedQuota.map(Formatters.compactTokens(_:)),
            requestCount: requestCount,
            updatedAt: nil,
            state: state
        )
    }
}

private struct NewAPIChannelListData: Decodable {
    let items: [NewAPIChannelData]
    let total: Int?

    enum CodingKeys: String, CodingKey {
        case items
        case total
    }
}

private struct NewAPIChannelData: Decodable {
    let id: Int?
    let name: String?
    let status: Int?
    let balance: Double?
    let usedQuota: Int?
    let balanceUpdatedTime: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case balance
        case usedQuota = "used_quota"
        case usedQuotaCamel = "usedQuota"
        case balanceUpdatedTime = "balance_updated_time"
        case balanceUpdatedTimeCamel = "balanceUpdatedTime"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleInt(for: [.id])
        name = container.flexibleString(for: [.name])
        status = container.flexibleInt(for: [.status])
        balance = container.flexibleDouble(for: [.balance])
        usedQuota = container.flexibleInt(for: [.usedQuota, .usedQuotaCamel])
        balanceUpdatedTime = container.flexibleInt(for: [.balanceUpdatedTime, .balanceUpdatedTimeCamel])
    }

    func balanceAccount(source: BalanceMonitorSource) -> BalanceAccount {
        let state: BalanceAccountState = status == nil || status == 1 ? .healthy : .warning
        return BalanceAccount(
            id: "\(source.rawValue)-channel-\(id.map(String.init) ?? name ?? UUID().uuidString)",
            source: source,
            name: name ?? "渠道 \(id.map(String.init) ?? "")",
            kind: "渠道余额",
            statusCode: status,
            amountText: balance.map(BalanceMonitorSnapshot.currencyText(_:)) ?? "--",
            usedText: usedQuota.map(Formatters.compactTokens(_:)),
            requestCount: nil,
            updatedAt: balanceUpdatedTime.map { "更新 \($0)" },
            state: state
        )
    }
}

private struct SubAPIUserListData: Decodable {
    let items: [SubAPIUserData]
    let total: Int?
}

private struct SubAPIUserData: Decodable {
    let id: Int?
    let email: String?
    let username: String?
    let role: String?
    let balance: Double?
    let concurrency: Int?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case username
        case role
        case balance
        case concurrency
        case status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleInt(for: [.id])
        email = container.flexibleString(for: [.email])
        username = container.flexibleString(for: [.username])
        role = container.flexibleString(for: [.role])
        balance = container.flexibleDouble(for: [.balance])
        concurrency = container.flexibleInt(for: [.concurrency])
        status = container.flexibleString(for: [.status])
    }

    func balanceAccount() -> BalanceAccount {
        let normalizedStatus = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let state: BalanceAccountState = normalizedStatus == nil || normalizedStatus == "active" ? .healthy : .warning
        let roleText = role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "admin" ? "管理员余额" : "用户余额"
        let details = [
            concurrency.map { "并发 \($0)" },
            normalizedStatus.map { "状态 \($0)" }
        ].compactMap { $0 }.joined(separator: " · ")
        return BalanceAccount(
            id: "subapi-user-\(id.map(String.init) ?? email ?? username ?? UUID().uuidString)",
            source: .subAPI,
            name: email ?? username ?? "用户 \(id.map(String.init) ?? "")",
            kind: roleText,
            statusCode: nil,
            amountText: balance.map(BalanceMonitorSnapshot.currencyText(_:)) ?? "--",
            usedText: nil,
            requestCount: nil,
            updatedAt: details.isEmpty ? nil : details,
            state: state
        )
    }
}

private extension KeyedDecodingContainer {
    func flexibleString(for keys: [Key]) -> String? {
        for key in keys {
            if let value = try? decodeIfPresent(String.self, forKey: key) {
                return value
            }
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return String(value)
            }
            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return String(value)
            }
        }
        return nil
    }

    func flexibleInt(for keys: [Key]) -> Int? {
        for key in keys {
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return Int(value.rounded())
            }
            if let value = try? decodeIfPresent(String.self, forKey: key),
               let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return Int(number.rounded())
            }
        }
        return nil
    }

    func flexibleDouble(for keys: [Key]) -> Double? {
        for key in keys {
            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return value
            }
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return Double(value)
            }
            if let value = try? decodeIfPresent(String.self, forKey: key),
               let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return number
            }
        }
        return nil
    }
}

private extension String {
    var redactedForDisplay: String {
        var redacted = self
        let patterns = [
            #"(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}"#,
            #"(?i)(token|authorization|api[_ -]?key|password|secret)\s*[:= ]+\s*[A-Za-z0-9._~+/=-]{6,}"#,
            #"sk-[A-Za-z0-9_-]{6,}"#,
            #"Bearer\s+[A-Za-z0-9._~+/=-]{8,}"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
            redacted = regex.stringByReplacingMatches(
                in: redacted,
                range: range,
                withTemplate: "[已隐藏]"
            )
        }

        return redacted
    }
}
