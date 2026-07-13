import Foundation

typealias AuthoritativeSkillCatalogLoader = @Sendable (Date, Bool) throws -> SkillCatalogSnapshot

final class SkillCatalogLoader: @unchecked Sendable {
    private struct ConfigEntry {
        let name: String?
        let path: String?
        let enabled: Bool
    }

    private struct ParsedConfig {
        let entries: [ConfigEntry]
        let diagnostics: [String]
    }

    private struct Frontmatter {
        let name: String
        let description: String
    }

    private struct DiscoveredSkill {
        let canonicalPath: String
        let frontmatter: Frontmatter
    }

    private let codexDirectory: URL
    private let configURL: URL
    private let explicitSkillRoots: [URL]?
    private let fileManager: FileManager
    private let authoritativeCatalogLoader: AuthoritativeSkillCatalogLoader?
    private let maxFrontmatterBytes = 64 * 1024
    private let maxConfigBytes = 2 * 1024 * 1024

    init(
        codexDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
        configURL: URL? = nil,
        skillRoots: [URL]? = nil,
        authoritativeCatalogLoader: AuthoritativeSkillCatalogLoader? = nil,
        fileManager: FileManager = .default
    ) {
        let standardizedCodexDirectory = codexDirectory.standardizedFileURL
        self.codexDirectory = standardizedCodexDirectory
        self.configURL = configURL ?? standardizedCodexDirectory.appendingPathComponent("config.toml")
        self.explicitSkillRoots = skillRoots
        self.fileManager = fileManager
        if let authoritativeCatalogLoader {
            self.authoritativeCatalogLoader = authoritativeCatalogLoader
        } else if skillRoots == nil {
            let client = CodexSkillsAppServerClient(
                codexDirectory: standardizedCodexDirectory,
                workingDirectory: fileManager.homeDirectoryForCurrentUser
            )
            self.authoritativeCatalogLoader = { now, forceReload in
                try client.load(now: now, forceReload: forceReload)
            }
        } else {
            self.authoritativeCatalogLoader = nil
        }
    }

    func load(
        now: Date = Date(),
        forceReload: Bool = false
    ) -> SkillCatalogSnapshot {
        var diagnostics: [String] = []
        if let authoritativeCatalogLoader {
            do {
                return try authoritativeCatalogLoader(now, forceReload)
            } catch {
                diagnostics.append(
                    "Codex skills/list is unavailable; filesystem fallback may include inactive plugin cache entries."
                )
            }
        }

        let parsedConfig = loadConfig()
        diagnostics.append(contentsOf: parsedConfig.diagnostics)

        let skillFiles = discoverSkillFiles()
        if skillFiles.isEmpty {
            diagnostics.append("No discoverable SKILL.md frontmatter was found.")
        }

        let discoveredSkills = skillFiles.compactMap { skillFile -> DiscoveredSkill? in
            let canonicalPath = skillFile.resolvingSymlinksInPath().standardizedFileURL.path
            guard let frontmatter = readFrontmatter(at: skillFile) else {
                diagnostics.append("Unreadable Skill frontmatter: \(redactedPathLabel(canonicalPath))")
                return nil
            }
            return DiscoveredSkill(canonicalPath: canonicalPath, frontmatter: frontmatter)
        }
        let nameCounts = Dictionary(grouping: discoveredSkills) {
            $0.frontmatter.name.lowercased()
        }.mapValues(\.count)

        var entries: [SkillCatalogEntry] = []
        for discovered in discoveredSkills {
            let canonicalPath = discovered.canonicalPath
            let frontmatter = discovered.frontmatter
            let enabled = enabledState(
                name: frontmatter.name,
                canonicalPath: canonicalPath,
                matchingNameCount: nameCounts[frontmatter.name.lowercased()] ?? 1,
                configEntries: parsedConfig.entries,
                diagnostics: &diagnostics
            )
            let characterCount = frontmatter.name.count + frontmatter.description.count
            let tokenEstimate = max(1, Int(ceil(Double(characterCount) / 4.0)))
            entries.append(
                SkillCatalogEntry(
                    id: Self.stableID(for: canonicalPath),
                    name: frontmatter.name,
                    description: frontmatter.description,
                    path: canonicalPath,
                    enabled: enabled,
                    catalogCharacterCount: characterCount,
                    catalogTokenEstimate: tokenEstimate,
                    protectsHighRiskWorkflow: Self.protectsHighRiskWorkflow(
                        name: frontmatter.name,
                        description: frontmatter.description
                    )
                )
            )
        }

        let sortedEntries = entries.sorted {
            if $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame {
                return $0.path < $1.path
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let quality: SkillInsightsQuality
        if sortedEntries.isEmpty {
            quality = .unavailable
        } else if diagnostics.isEmpty {
            quality = .complete
        } else {
            quality = .partial
        }

        return SkillCatalogSnapshot(
            skills: sortedEntries,
            quality: quality,
            diagnostics: Array(Set(diagnostics)).sorted(),
            loadedAt: now
        )
    }

    private func discoverSkillFiles() -> [URL] {
        let roots = explicitSkillRoots ?? defaultSkillRoots()
        var seen = Set<String>()
        var results: [URL] = []

        for root in roots where fileManager.fileExists(atPath: root.path) {
            if root.lastPathComponent == "SKILL.md" {
                let path = root.resolvingSymlinksInPath().standardizedFileURL.path
                if seen.insert(path).inserted {
                    results.append(root)
                }
                continue
            }

            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
            ) else {
                continue
            }
            for case let url as URL in enumerator where url.lastPathComponent == "SKILL.md" {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }
                let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                if seen.insert(path).inserted {
                    results.append(url)
                }
            }
        }

        return results.sorted { $0.path < $1.path }
    }

    private func defaultSkillRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = [
            codexDirectory.appendingPathComponent("skills", isDirectory: true),
            home.appendingPathComponent(".agents/skills", isDirectory: true)
        ]
        roots.append(contentsOf: activePluginSkillRoots(
            cacheRoot: codexDirectory.appendingPathComponent("plugins/cache", isDirectory: true)
        ))
        return roots
    }

    private func activePluginSkillRoots(cacheRoot: URL) -> [URL] {
        guard let providers = try? fileManager.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var roots: [URL] = []
        for provider in providers where isDirectory(provider) {
            guard let plugins = try? fileManager.contentsOfDirectory(
                at: provider,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for plugin in plugins where isDirectory(plugin) {
                guard let versions = try? fileManager.contentsOfDirectory(
                    at: plugin,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continue
                }
                let activeVersion = versions
                    .filter(isDirectory)
                    .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("skills").path) }
                    .max { lhs, rhs in
                        lhs.lastPathComponent.compare(
                            rhs.lastPathComponent,
                            options: [.numeric, .caseInsensitive]
                        ) == .orderedAscending
                    }
                if let activeVersion {
                    roots.append(activeVersion.appendingPathComponent("skills", isDirectory: true))
                }
            }
        }
        return roots
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func readFrontmatter(at url: URL) -> Frontmatter? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        var data = Data()
        while data.count < maxFrontmatterBytes,
              let chunk = try? handle.read(upToCount: min(512, maxFrontmatterBytes - data.count)),
              !chunk.isEmpty {
            data.append(chunk)
            if frontmatterRange(in: data) != nil {
                break
            }
        }
        guard let range = frontmatterRange(in: data) else {
            return nil
        }

        let text = String(decoding: data[range], as: UTF8.self)
        var name: String?
        var description: String?
        var multilineKey: String?
        var multilineValues: [String] = []

        func commitMultiline() {
            guard let multilineKey else {
                return
            }
            let value = multilineValues
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if multilineKey == "name" {
                name = value
            } else if multilineKey == "description" {
                description = value
            }
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).replacingOccurrences(of: "\r", with: "")
            if line.first?.isWhitespace == true, multilineKey != nil {
                multilineValues.append(line)
                continue
            }
            commitMultiline()
            multilineKey = nil
            multilineValues = []

            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == "name" || key == "description" else {
                continue
            }
            if rawValue == ">" || rawValue == "|" || rawValue == ">-" || rawValue == "|-" {
                multilineKey = key
                continue
            }
            let value = unquoted(rawValue)
            if key == "name" {
                name = value
            } else {
                description = value
            }
        }
        commitMultiline()

        guard let resolvedName = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !resolvedName.isEmpty,
              let resolvedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines),
              !resolvedDescription.isEmpty else {
            return nil
        }
        return Frontmatter(name: resolvedName, description: resolvedDescription)
    }

    private func frontmatterRange(in data: Data) -> Range<Data.Index>? {
        let delimiter = Data("---".utf8)
        guard data.starts(with: delimiter) else {
            return nil
        }
        let newlineDelimiter = Data("\n---".utf8)
        guard let closing = data.range(of: newlineDelimiter, in: 3..<data.endIndex) else {
            return nil
        }
        let contentStart = data.index(data.startIndex, offsetBy: 3)
        return contentStart..<closing.lowerBound
    }

    private func loadConfig() -> ParsedConfig {
        guard fileManager.fileExists(atPath: configURL.path) else {
            return ParsedConfig(
                entries: [],
                diagnostics: ["config.toml is missing; discovered Skills default to enabled."]
            )
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: configURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= maxConfigBytes,
              let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return ParsedConfig(
                entries: [],
                diagnostics: ["config.toml could not be read safely; discovered Skills default to enabled."]
            )
        }

        var diagnostics: [String] = []
        var entries: [ConfigEntry] = []
        var inSkillConfig = false
        var currentName: String?
        var currentPath: String?
        var currentEnabled: Bool?

        func commitEntry() {
            guard inSkillConfig else {
                return
            }
            guard let currentEnabled, currentName != nil || currentPath != nil else {
                diagnostics.append("A skills.config entry is missing name/path or enabled.")
                return
            }
            entries.append(ConfigEntry(name: currentName, path: currentPath, enabled: currentEnabled))
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripTOMLComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                continue
            }
            if line.hasPrefix("[[") {
                commitEntry()
                inSkillConfig = line == "[[skills.config]]"
                currentName = nil
                currentPath = nil
                currentEnabled = nil
                continue
            }
            if line.hasPrefix("[") {
                commitEntry()
                inSkillConfig = false
                currentName = nil
                currentPath = nil
                currentEnabled = nil
                continue
            }
            guard inSkillConfig, let equals = line.firstIndex(of: "=") else {
                continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "name":
                currentName = unquoted(value)
            case "path":
                currentPath = expandedPath(unquoted(value))
            case "enabled":
                if value == "true" {
                    currentEnabled = true
                } else if value == "false" {
                    currentEnabled = false
                } else {
                    diagnostics.append("A skills.config enabled value is invalid.")
                }
            default:
                continue
            }
        }
        commitEntry()

        for entry in entries {
            if let path = entry.path, !fileManager.fileExists(atPath: path) {
                diagnostics.append("Configured Skill path is unavailable: \(redactedPathLabel(path))")
            }
        }
        return ParsedConfig(entries: entries, diagnostics: diagnostics)
    }

    private func enabledState(
        name: String,
        canonicalPath: String,
        matchingNameCount: Int,
        configEntries: [ConfigEntry],
        diagnostics: inout [String]
    ) -> Bool {
        let exactPathMatches = configEntries.filter { entry in
            guard let path = entry.path else {
                return false
            }
            return URL(fileURLWithPath: path)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path == canonicalPath
        }
        if let exact = exactPathMatches.last {
            return exact.enabled
        }

        let nameMatches = configEntries.filter {
            $0.path == nil && $0.name?.caseInsensitiveCompare(name) == .orderedSame
        }
        if matchingNameCount > 1, !nameMatches.isEmpty {
            diagnostics.append("A name-only skills.config entry matches multiple paths: \(name).")
        }
        return nameMatches.last?.enabled ?? true
    }

    private func stripTOMLComment(_ line: String) -> String {
        var quoted = false
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" && quoted {
                escaped = true
                continue
            }
            if character == "\"" {
                quoted.toggle()
                continue
            }
            if character == "#" && !quoted {
                return String(line[..<index])
            }
        }
        return line
    }

    private func unquoted(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"" else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private func expandedPath(_ path: String) -> String {
        guard path.hasPrefix("~/") else {
            return path
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(String(path.dropFirst(2)))
            .path
    }

    private func redactedPathLabel(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? url.lastPathComponent : "\(parent)/\(url.lastPathComponent)"
    }

    static func stableID(for value: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    static func analysisFingerprint(
        for skills: [SkillCatalogEntry],
        analyzerVersion: Int
    ) -> String {
        let payload = skills.sorted { $0.id < $1.id }.map { skill in
            [
                skill.id,
                skill.name,
                skill.description,
                skill.path
            ].joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}")
        return stableID(for: "analyzer=\(analyzerVersion)\u{1D}\(payload)")
    }

    // Compatibility with P0 databases written before enabled state was made a
    // report-time concern. Accepting this once avoids an unnecessary 7-day
    // rescan; the next completed run stores the neutral fingerprint above.
    static func legacyAnalysisFingerprint(
        for skills: [SkillCatalogEntry],
        analyzerVersion: Int
    ) -> String {
        let payload = skills.sorted { $0.id < $1.id }.map { skill in
            [
                skill.id,
                skill.name,
                skill.description,
                skill.path,
                skill.enabled ? "enabled" : "disabled"
            ].joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}")
        return stableID(for: "analyzer=\(analyzerVersion)\u{1D}\(payload)")
    }

    static func protectsHighRiskWorkflow(name: String, description: String) -> Bool {
        let text = "\(name) \(description)".lowercased()
        return [
            "security", "hardening", "credential", "authentication", "migration",
            "recovery", "restore", "release", "publishing", "deployment", "merge conflict",
            "安全", "迁移", "恢复", "发布", "凭证"
        ].contains { text.contains($0) }
    }
}
