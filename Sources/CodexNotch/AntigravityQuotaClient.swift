import Foundation

enum AntigravityQuotaClientError: Error, LocalizedError, Equatable {
    case antigravityExecutableUnavailable
    case localSessionUnavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .antigravityExecutableUnavailable: "AGY 不可用"
        case .localSessionUnavailable: "AGY 本地会话不可用"
        case .invalidResponse: "AGY 配额读取失败"
        }
    }
}

struct AntigravityExecutableLocator: @unchecked Sendable {
    let homeDirectory: URL
    let fileManager: FileManager

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    var candidateURLs: [URL] {
        [
            homeDirectory.appendingPathComponent(".local/bin/agy"),
            URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
            URL(fileURLWithPath: "/usr/local/bin/agy")
        ]
    }

    var executableURL: URL? { candidateURLs.first { fileManager.isExecutableFile(atPath: $0.path) } }
}

protocol AntigravityQuotaFetching: Sendable {
    func fetch(now: Date) async throws -> AntigravityQuotaReading
}

struct AntigravityQuotaClient: AntigravityQuotaFetching, Sendable {
    static let timeout: TimeInterval = 12
    private static let refreshGate = AntigravityQuotaRefreshGate()
    let antigravityLocator: AntigravityExecutableLocator
    let sessionFactory: @Sendable () -> AntigravityLocalSession

    init(
        antigravityLocator: AntigravityExecutableLocator = AntigravityExecutableLocator(),
        sessionFactory: @escaping @Sendable () -> AntigravityLocalSession = { AntigravityLocalSession() }
    ) {
        self.antigravityLocator = antigravityLocator
        self.sessionFactory = sessionFactory
    }

    func fetch(now: Date = Date()) async throws -> AntigravityQuotaReading {
        try await Self.refreshGate.fetch { try await fetchOneShot(now: now) }
    }

    private func fetchOneShot(now: Date) async throws -> AntigravityQuotaReading {
        guard let executable = antigravityLocator.executableURL else {
            throw AntigravityQuotaClientError.antigravityExecutableUnavailable
        }
        let session = sessionFactory()
        do {
            let deadline = Date().addingTimeInterval(Self.timeout)
            let ports = try await session.start(executable: executable, timeout: Self.timeout)
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw AntigravityQuotaClientError.localSessionUnavailable }
            let reading = try await AntigravityLocalProbe.fetchQuotaReading(
                ports: ports,
                timeout: remaining,
                receivedAt: now
            )
            await session.stop()
            return reading
        } catch let error as AntigravityQuotaClientError {
            await session.stop()
            throw error
        } catch {
            await session.stop()
            _ = error
            throw AntigravityQuotaClientError.invalidResponse
        }
    }
}

/// Coalesces requests within this Monitor process. No request parameters, user state, or
/// payload bytes are retained after the one-shot task settles.
actor AntigravityQuotaRefreshGate {
    private var inFlight: Task<AntigravityQuotaReading, Error>?

    func fetch(_ operation: @escaping @Sendable () async throws -> AntigravityQuotaReading) async throws -> AntigravityQuotaReading {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await operation() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}
