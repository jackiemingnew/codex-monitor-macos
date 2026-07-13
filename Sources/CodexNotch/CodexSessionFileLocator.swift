import Foundation

enum CodexSessionFileLocator {
    static func recentRolloutPaths(
        roots: [URL],
        modifiedSince: Date? = nil,
        limit: Int? = nil,
        fileManager: FileManager = .default
    ) -> [String] {
        var files: [(path: String, modifiedAt: Date)] = []
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                ), values.isRegularFile == true else {
                    continue
                }
                let modifiedAt = values.contentModificationDate ?? .distantPast
                if let modifiedSince, modifiedAt < modifiedSince {
                    continue
                }
                files.append((url.standardizedFileURL.path, modifiedAt))
            }
        }

        let sorted = files.sorted {
            if $0.modifiedAt != $1.modifiedAt {
                return $0.modifiedAt > $1.modifiedAt
            }
            return $0.path < $1.path
        }
        guard let limit else {
            return sorted.map(\.path)
        }
        return Array(sorted.prefix(max(0, limit))).map(\.path)
    }
}
