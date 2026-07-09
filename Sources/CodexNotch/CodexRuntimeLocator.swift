import AppKit
import Foundation

enum CodexRuntimeLocator {
    private static let bundleIdentifier = "com.openai.codex"

    static func executable(
        named name: String,
        workspace: NSWorkspace = .shared,
        fileManager: FileManager = .default
    ) -> String? {
        firstExecutable(
            named: name,
            in: applicationCandidates(workspace: workspace, fileManager: fileManager),
            fileManager: fileManager
        )
    }

    static func firstExecutable(
        named name: String,
        in applications: [URL],
        fileManager: FileManager = .default
    ) -> String? {
        applications.lazy
            .map { $0.appendingPathComponent("Contents/Resources/\(name)").standardizedFileURL.path }
            .first { fileManager.isExecutableFile(atPath: $0) }
    }

    private static func applicationCandidates(
        workspace: NSWorkspace,
        fileManager: FileManager
    ) -> [URL] {
        var applications: [URL] = []
        if let discovered = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            applications.append(discovered)
        }

        let homeApplications = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        applications.append(contentsOf: [
            URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true),
            homeApplications.appendingPathComponent("ChatGPT.app", isDirectory: true),
            homeApplications.appendingPathComponent("Codex.app", isDirectory: true)
        ])

        var seen = Set<String>()
        return applications.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
