import Foundation
import CryptoKit
import Security

enum NetworkSecurityPolicy {
    struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int
    }

    static func origin(for url: URL) -> Origin? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              let port = url.port ?? defaultPort(for: scheme) else {
            return nil
        }
        return Origin(scheme: scheme, host: host, port: port)
    }

    static func allowsRedirect(from oldURL: URL?, to newURL: URL, configuredURL: URL) -> Bool {
        guard let configuredOrigin = origin(for: configuredURL),
              let oldURL,
              origin(for: oldURL) == configuredOrigin,
              origin(for: newURL) == configuredOrigin else {
            return false
        }
        return true
    }

    static func matchesProtectionSpace(
        host: String,
        port: Int,
        protocolName: String?,
        configuredURL: URL
    ) -> Bool {
        guard let configuredOrigin = origin(for: configuredURL) else {
            return false
        }
        let normalizedProtocol = protocolName?.lowercased() ?? configuredOrigin.scheme
        let normalizedPort = port > 0 ? port : (defaultPort(for: normalizedProtocol) ?? -1)
        return normalizedProtocol == configuredOrigin.scheme
            && host.lowercased() == configuredOrigin.host
            && normalizedPort == configuredOrigin.port
    }

    static func normalizedCertificateSHA256(_ input: String?) -> String? {
        guard var value = input?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("sha256:") {
            value.removeFirst("sha256:".count)
        }

        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":-"))
        var normalized = ""
        for scalar in value.unicodeScalars {
            if hex.contains(scalar) {
                normalized.unicodeScalars.append(scalar)
            } else if !separators.contains(scalar) {
                return nil
            }
        }
        return normalized.count == 64 ? normalized : nil
    }

    static func matchesPinnedCertificate(_ trust: SecTrust, expectedSHA256: String?) -> Bool {
        guard let expected = normalizedCertificateSHA256(expectedSHA256),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first else {
            return false
        }
        let data = SecCertificateCopyData(certificate) as Data
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return actual == expected
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "https": 443
        case "http": 80
        default: nil
        }
    }
}

enum NetworkResponseError: LocalizedError {
    case tooLarge(limit: Int)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let limit):
            "服务器响应超过安全上限（\(limit / 1_024) KiB）"
        }
    }
}

enum NetworkResponsePolicy {
    static let successLimit = 5 * 1_024 * 1_024
    static let errorLimit = 16 * 1_024

    static func limit(for response: URLResponse) -> Int {
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return errorLimit
        }
        return successLimit
    }

    static func validate(_ data: Data, response: URLResponse) throws {
        let maximum = limit(for: response)
        guard data.count <= maximum else {
            throw NetworkResponseError.tooLarge(limit: maximum)
        }
    }

    static func data(for request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        let maximum = limit(for: response)
        if response.expectedContentLength > Int64(maximum) {
            throw NetworkResponseError.tooLarge(limit: maximum)
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(maximum, Int(response.expectedContentLength)))
        }
        for try await byte in bytes {
            guard data.count < maximum else {
                throw NetworkResponseError.tooLarge(limit: maximum)
            }
            data.append(byte)
        }
        return (data, response)
    }
}

final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let configuredURL: URL

    init(configuredURL: URL) {
        self.configuredURL = configuredURL
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let newURL = request.url,
              NetworkSecurityPolicy.allowsRedirect(
                  from: task.currentRequest?.url ?? task.originalRequest?.url,
                  to: newURL,
                  configuredURL: configuredURL
              ) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
