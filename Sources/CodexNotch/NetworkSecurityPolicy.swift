import Foundation

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

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "https": 443
        case "http": 80
        default: nil
        }
    }
}
