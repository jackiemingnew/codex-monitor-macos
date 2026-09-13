import Foundation
import Security

enum AntigravityLocalProbeRequestError: Error, Equatable {
    case wrongResponseTarget
    case httpStatus(Int)
    case oversizedResponse
    case redirected
    case missingResponse
}

enum AntigravityLocalProbe {
    struct Response: Sendable {
        let path: String
        let data: Data
    }

    static let quotaSummaryPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    static let userStatusPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    static let commandModelConfigsPath = "/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs"
    static let maximumResponseBytes = 256 * 1024
    static let startupBackoffNanoseconds: [UInt64] = [250_000_000, 400_000_000, 650_000_000, 900_000_000]

    static func accepts(host: String, port: Int, allowedPorts: Set<Int>) -> Bool {
        host == "127.0.0.1" && AntigravityLocalPortDiscovery.valid(port: port) && allowedPorts.contains(port)
    }

    static func requestBody(for path: String) -> Data? {
        let value: [String: Any]
        switch path {
        case quotaSummaryPath:
            value = ["forceRefresh": true]
        case userStatusPath, commandModelConfigsPath:
            value = ["metadata": [
                "ideName": "antigravity", "extensionName": "antigravity",
                "ideVersion": "unknown", "locale": "en"
            ]]
        default:
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    static func acceptsResponse(host: String?, port: Int?, statusCode: Int, expectedBytes: Int64, actualBytes: Int, redirected: Bool) -> Bool {
        host == "127.0.0.1" && !redirected && (200..<300).contains(statusCode)
            && (expectedBytes < 0 || expectedBytes <= Int64(maximumResponseBytes))
            && actualBytes <= maximumResponseBytes
    }

    static func fetchQuotaReading(
        ports: [Int],
        timeout: TimeInterval,
        receivedAt: Date
    ) async throws -> AntigravityQuotaReading {
        let allowed = Set(ports.filter(AntigravityLocalPortDiscovery.valid))
        guard !allowed.isEmpty else { throw AntigravityQuotaClientError.localSessionUnavailable }
        let deadline = Date().addingTimeInterval(timeout)
        let sortedPorts = allowed.sorted()
        var startingPorts: Set<Int> = []

        // A newly launched AGY publishes its HTTPS port before its quota backend
        // is ready. A 5xx response proves that the exact loopback endpoint is
        // reachable, so retry only that endpoint with a short bounded backoff.
        for port in sortedPorts {
            do {
                return try await fetchAndParse(
                    path: quotaSummaryPath,
                    port: port,
                    allowedPorts: allowed,
                    deadline: deadline,
                    receivedAt: receivedAt
                )
            } catch let error as AntigravityLocalProbeRequestError where error.isStartupTransient {
                startingPorts.insert(port)
            } catch {
                _ = error
            }
        }

        for delay in startupBackoffNanoseconds {
            guard !startingPorts.isEmpty,
                  deadline.timeIntervalSinceNow > Double(delay) / 1_000_000_000 + 0.1 else { break }
            try await Task.sleep(nanoseconds: delay)
            for port in startingPorts.sorted() {
                do {
                    return try await fetchAndParse(
                        path: quotaSummaryPath,
                        port: port,
                        allowedPorts: allowed,
                        deadline: deadline,
                        receivedAt: receivedAt
                    )
                } catch let error as AntigravityLocalProbeRequestError where error.isStartupTransient {
                    continue
                } catch {
                    startingPorts.remove(port)
                }
            }
        }

        let fallbackPorts = startingPorts.sorted() + sortedPorts.filter { !startingPorts.contains($0) }
        for path in [userStatusPath, commandModelConfigsPath] {
            for port in fallbackPorts {
                do {
                    return try await fetchAndParse(
                        path: path,
                        port: port,
                        allowedPorts: allowed,
                        deadline: deadline,
                        receivedAt: receivedAt
                    )
                } catch {
                    _ = error
                }
            }
        }
        throw AntigravityQuotaClientError.localSessionUnavailable
    }

    private static func fetchAndParse(
        path: String,
        port: Int,
        allowedPorts: Set<Int>,
        deadline: Date,
        receivedAt: Date
    ) async throws -> AntigravityQuotaReading {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw AntigravityQuotaClientError.localSessionUnavailable }
        let data = try await request(
            path: path,
            port: port,
            allowedPorts: allowedPorts,
            timeout: min(remaining, 3.5)
        )
        return try AntigravityQuotaParser.parseLocalResponse(
            Response(path: path, data: data),
            receivedAt: receivedAt
        )
    }

    private static func request(path: String, port: Int, allowedPorts: Set<Int>, timeout: TimeInterval) async throws -> Data {
        guard accepts(host: "127.0.0.1", port: port, allowedPorts: allowedPorts),
              let body = requestBody(for: path),
              let url = URL(string: "https://127.0.0.1:\(port)\(path)") else {
            throw AntigravityQuotaClientError.localSessionUnavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        let delegate = AntigravityLoopbackDelegate(expectedPort: port)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await delegate.data(for: request, session: session)
    }
}

private extension AntigravityLocalProbeRequestError {
    var isStartupTransient: Bool {
        guard case let .httpStatus(status) = self else { return false }
        return (500..<600).contains(status)
    }
}

private final class AntigravityLoopbackDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private let expectedPort: Int
    private var continuation: CheckedContinuation<Data, Error>?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var finished = false

    init(expectedPort: Int) {
        self.expectedPort = expectedPort
    }

    func data(for request: URLRequest, session: URLSession) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                session.dataTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse,
              response.url?.host == "127.0.0.1", response.url?.port == expectedPort else {
            complete(.failure(AntigravityLocalProbeRequestError.wrongResponseTarget)); completionHandler(.cancel); return
        }
        guard (200..<300).contains(response.statusCode) else {
            complete(.failure(AntigravityLocalProbeRequestError.httpStatus(response.statusCode))); completionHandler(.cancel); return
        }
        guard response.expectedContentLength < 0
                || response.expectedContentLength <= Int64(AntigravityLocalProbe.maximumResponseBytes) else {
            complete(.failure(AntigravityLocalProbeRequestError.oversizedResponse)); completionHandler(.cancel); return
        }
        self.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        guard self.data.count <= AntigravityLocalProbe.maximumResponseBytes - data.count else {
            complete(.failure(AntigravityLocalProbeRequestError.oversizedResponse)); dataTask.cancel(); return
        }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        complete(.failure(AntigravityLocalProbeRequestError.redirected)); completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { complete(.failure(error)); return }
        guard response != nil else { complete(.failure(AntigravityLocalProbeRequestError.missingResponse)); return }
        complete(.success(data))
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        challengeResult(challenge)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        challengeResult(challenge)
    }

    private func challengeResult(
        _ challenge: URLAuthenticationChallenge
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let protection = challenge.protectionSpace
        guard protection.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              protection.host == "127.0.0.1",
              let trust = protection.serverTrust else {
            return (.cancelAuthenticationChallenge, nil)
        }
        // CFNetwork may omit the custom port from the protection space. The
        // request and response remain pinned to `expectedPort`, and redirects
        // are rejected, so trust cannot escape this exact loopback task.
        return (.useCredential, URLCredential(trust: trust))
    }

    private func complete(_ result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
