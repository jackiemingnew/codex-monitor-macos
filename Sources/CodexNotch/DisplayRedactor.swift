import Foundation

enum DisplayRedactor {
    static func redact(_ text: String, maxLength: Int = 600) -> String {
        var redacted = text
        let patterns = [
            #""(?i)(password|access_token|refresh_token|api[_-]?key|secret|authorization|token)"\s*:\s*"[^"]*""#,
            #""(?i)(password|access_token|refresh_token|api[_-]?key|secret|authorization|token)"\s*:\s*[^,}\]]+"#,
            #"(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}"#,
            #"(?i)(token|authorization|api[_ -]?key|password|secret)\s*[:= ]+\s*[A-Za-z0-9._~+/=-]{6,}"#,
            #"sk-[A-Za-z0-9_-]{6,}"#
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

        guard redacted.count > maxLength else {
            return redacted
        }
        return "\(redacted.prefix(maxLength))..."
    }
}

extension String {
    var redactedForDisplay: String {
        DisplayRedactor.redact(self)
    }
}
