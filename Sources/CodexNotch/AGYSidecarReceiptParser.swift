import Foundation

enum AGYSidecarReceiptParserError: Error, Equatable {
    case receiptOversized
    case invalidJSON
    case unknownField
    case invalidContract
}

enum AGYSidecarReceiptParser {
    private static let doctorRootKeys: Set<String> = [
        "contract_version", "model_roles", "status", "agy_binary", "reason", "models", "repo_snapshot"
    ]
    private static let doctorRepositoryKeys: Set<String> = ["ready", "diff_delivery", "command_permission_required"]
    private static let modelRolesKeys: Set<String> = ["primary", "secondary"]
    private static let modelRoleKeys: Set<String> = ["family", "model"]
    private static let reviewRootKeys: Set<String> = [
        "contract_version", "model_roles", "status", "risk", "source", "codex_receipt_budget",
        "attempted_models", "primary", "secondary_required", "secondary", "sol_validation_required",
        "reason", "missing_review"
    ]
    private static let sourceKeys: Set<String> = [
        "kind", "diff_delivery", "tracked_diff_bytes", "untracked_files_omitted",
        "original_repository_exposed", "git_metadata_exposed", "snapshot_read_only"
    ]
    private static let budgetKeys: Set<String> = ["maximum_bytes", "maximum_findings_per_model"]
    private static let routeKeys: Set<String> = ["model", "review", "usage", "tool_audit"]
    private static let reviewKeys: Set<String> = ["verdict", "summary", "findings", "uncertainties", "review_scope"]
    private static let findingKeys: Set<String> = [
        "severity", "file", "line", "title", "evidence", "impact", "recommendation", "test", "confidence"
    ]
    private static let toolAuditKeys: Set<String> = [
        "snapshot_diff_reads", "read_only_file_calls", "failed_read_only_file_calls", "other_tool_calls"
    ]
    private static let usageKeys: Set<String> = [
        "input_tokens", "output_tokens", "thinking_tokens", "cache_read_tokens", "total_tokens"
    ]

    static func parseDoctor(_ data: Data, checkedAt: Date) throws -> AGYSidecarDoctorSnapshot {
        let object = try rootObject(data)
        try requireOnlyKeys(object, allowed: doctorRootKeys)
        guard let models = object["models"] as? [String: Any],
              let repository = object["repo_snapshot"] as? [String: Any] else {
            throw AGYSidecarReceiptParserError.invalidContract
        }
        try validateModelRolesWhitelist(object["model_roles"])
        try requireOnlyKeys(repository, allowed: doctorRepositoryKeys)

        let decoded: DoctorReceipt
        do {
            decoded = try JSONDecoder().decode(DoctorReceipt.self, from: data)
        } catch {
            throw AGYSidecarReceiptParserError.invalidContract
        }
        let resolvedRoles = try resolveModelRoles(
            contractVersion: decoded.contractVersion,
            declaredRoles: decoded.modelRoles,
            observedModelIDs: Set(models.keys)
        )
        let availability = [
            AGYSidecarModelAvailability(
                model: resolvedRoles.primary,
                available: decoded.models[resolvedRoles.primary] == true
            ),
            AGYSidecarModelAvailability(
                model: resolvedRoles.secondary,
                available: decoded.models[resolvedRoles.secondary] == true
            )
        ]
        let repositoryReady = decoded.repoSnapshot.ready
            && decoded.repoSnapshot.diffDelivery == "read-only-workspace-file"
            && decoded.repoSnapshot.commandPermissionRequired == false

        switch decoded.status {
        case "READY":
            let ready = availability.allSatisfy(\.available) && repositoryReady
            return AGYSidecarDoctorSnapshot(
                status: ready
                    ? (resolvedRoles.compatibilityError == nil ? .ready : .compatibilityWarning)
                    : .broken,
                checkedAt: checkedAt,
                models: availability,
                repositoryModeReady: repositoryReady,
                errorCode: ready ? resolvedRoles.compatibilityError : .protocolViolation
            )
        case "UNAVAILABLE":
            return AGYSidecarDoctorSnapshot(
                status: .unavailable,
                checkedAt: checkedAt,
                models: availability,
                repositoryModeReady: repositoryReady,
                errorCode: .sidecarUnavailable
            )
        default:
            throw AGYSidecarReceiptParserError.invalidContract
        }
    }

    static func parseReview(_ data: Data, checkedAt: Date) throws -> AGYSidecarE2ESnapshot {
        let object = try rootObject(data)
        try validateReviewWhitelist(object)
        let decoded: ReviewReceipt
        do {
            decoded = try JSONDecoder().decode(ReviewReceipt.self, from: data)
        } catch {
            throw AGYSidecarReceiptParserError.invalidContract
        }
        let source = decoded.source.map {
            AGYSidecarSourceSummary(
                kind: $0.kind,
                diffDelivery: $0.diffDelivery,
                originalRepositoryExposed: $0.originalRepositoryExposed,
                gitMetadataExposed: $0.gitMetadataExposed,
                snapshotReadOnly: $0.snapshotReadOnly,
                untrackedFilesOmitted: $0.untrackedFilesOmitted
            )
        }
        let routes = [decoded.primary, decoded.secondary].compactMap { $0 }
        let aggregateAudit = aggregateToolAudit(routes)
        let aggregateUsage = aggregateUsage(routes)
        let findingMatched = routes.contains { route in
            route.review.findings.contains(where: findingMatchesCanary)
        }

        if decoded.status == "INPUT_REJECTED" {
            return snapshot(
                status: .broken,
                receipt: decoded,
                checkedAt: checkedAt,
                source: source,
                toolAudit: aggregateAudit,
                usage: aggregateUsage,
                receiptBytes: data.count,
                findingMatched: routes.isEmpty ? nil : findingMatched,
                errorCode: .protocolViolation
            )
        }

        let resolvedRoles = try resolveReviewModelRoles(decoded)
        if decoded.status == "FALLBACK_SOL" {
            let fallbackContractIsHealthy = sourceContractIsHealthy(decoded.source)
                && decoded.attemptedModels == [resolvedRoles.primary]
                && decoded.primary == nil
                && decoded.secondary == nil
                && decoded.solValidationRequired == true
            return snapshot(
                status: fallbackContractIsHealthy ? .unavailable : .broken,
                receipt: decoded,
                checkedAt: checkedAt,
                source: source,
                toolAudit: aggregateAudit,
                usage: aggregateUsage,
                receiptBytes: data.count,
                findingMatched: routes.isEmpty ? nil : findingMatched,
                errorCode: fallbackContractIsHealthy ? .sidecarUnavailable : .protocolViolation
            )
        }
        guard decoded.status == "COMPLETE" || decoded.status == "PARTIAL" else {
            throw AGYSidecarReceiptParserError.invalidContract
        }

        guard sourceContractIsHealthy(decoded.source),
              routeContractsAreHealthy(routes),
              attemptedModelsAreValid(decoded, roles: resolvedRoles),
              decoded.risk == "normal",
              decoded.solValidationRequired == true else {
            return snapshot(
                status: .broken,
                receipt: decoded,
                checkedAt: checkedAt,
                source: source,
                toolAudit: aggregateAudit,
                usage: aggregateUsage,
                receiptBytes: data.count,
                findingMatched: findingMatched,
                errorCode: .protocolViolation
            )
        }
        guard findingMatched else {
            return snapshot(
                status: .broken,
                receipt: decoded,
                checkedAt: checkedAt,
                source: source,
                toolAudit: aggregateAudit,
                usage: aggregateUsage,
                receiptBytes: data.count,
                findingMatched: false,
                errorCode: .findingMissed
            )
        }

        if let compatibilityError = resolvedRoles.compatibilityError {
            return snapshot(
                status: .partial,
                receipt: decoded,
                checkedAt: checkedAt,
                source: source,
                toolAudit: aggregateAudit,
                usage: aggregateUsage,
                receiptBytes: data.count,
                findingMatched: true,
                errorCode: compatibilityError
            )
        }

        let secondaryComplete = decoded.secondaryRequired != true || decoded.secondary != nil
        let complete = decoded.status == "COMPLETE" && secondaryComplete
        return snapshot(
            status: complete ? .complete : .partial,
            receipt: decoded,
            checkedAt: checkedAt,
            source: source,
            toolAudit: aggregateAudit,
            usage: aggregateUsage,
            receiptBytes: data.count,
            findingMatched: true,
            errorCode: complete ? nil : .sidecarUnavailable
        )
    }

    private static func rootObject(_ data: Data) throws -> [String: Any] {
        guard data.count <= AGYSidecarHealthPolicy.receiptByteLimit else {
            throw AGYSidecarReceiptParserError.receiptOversized
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AGYSidecarReceiptParserError.invalidJSON
            }
            return object
        } catch let error as AGYSidecarReceiptParserError {
            throw error
        } catch {
            throw AGYSidecarReceiptParserError.invalidJSON
        }
    }

    private static func validateReviewWhitelist(_ object: [String: Any]) throws {
        try requireOnlyKeys(object, allowed: reviewRootKeys)
        try validateModelRolesWhitelist(object["model_roles"])
        if let source = object["source"] as? [String: Any] {
            try requireOnlyKeys(source, allowed: sourceKeys)
        }
        if let budget = object["codex_receipt_budget"] as? [String: Any] {
            try requireOnlyKeys(budget, allowed: budgetKeys)
        }
        for key in ["primary", "secondary"] {
            guard let route = object[key] as? [String: Any] else { continue }
            try requireOnlyKeys(route, allowed: routeKeys)
            if let review = route["review"] as? [String: Any] {
                try requireOnlyKeys(review, allowed: reviewKeys)
                if let findings = review["findings"] as? [[String: Any]] {
                    for finding in findings {
                        try requireOnlyKeys(finding, allowed: findingKeys)
                    }
                }
            }
            if let audit = route["tool_audit"] as? [String: Any] {
                try requireOnlyKeys(audit, allowed: toolAuditKeys)
            }
            if let usage = route["usage"] as? [String: Any] {
                try requireOnlyKeys(usage, allowed: usageKeys)
            }
        }
    }

    private static func validateModelRolesWhitelist(_ value: Any?) throws {
        guard let value else { return }
        guard let roles = value as? [String: Any] else {
            throw AGYSidecarReceiptParserError.invalidContract
        }
        try requireOnlyKeys(roles, allowed: modelRolesKeys)
        guard Set(roles.keys) == modelRolesKeys else {
            throw AGYSidecarReceiptParserError.invalidContract
        }
        for role in roles.values {
            guard let object = role as? [String: Any] else {
                throw AGYSidecarReceiptParserError.invalidContract
            }
            try requireOnlyKeys(object, allowed: modelRoleKeys)
            guard Set(object.keys) == modelRoleKeys else {
                throw AGYSidecarReceiptParserError.invalidContract
            }
        }
    }

    private static func requireOnlyKeys(_ object: [String: Any], allowed: Set<String>) throws {
        guard Set(object.keys).isSubset(of: allowed) else {
            throw AGYSidecarReceiptParserError.unknownField
        }
    }

    private static func resolveModelRoles(
        contractVersion: Int?,
        declaredRoles: ModelRolesReceipt?,
        observedModelIDs: Set<String>
    ) throws -> ResolvedModelRoles {
        guard observedModelIDs.count == 2,
              observedModelIDs.allSatisfy(isSafeModelIdentifier) else {
            throw AGYSidecarReceiptParserError.invalidContract
        }

        if contractVersion == nil && declaredRoles == nil {
            let primary = observedModelIDs.filter { modelMatchesFamily($0, family: AGYSidecarHealthPolicy.primaryModelFamily) }
            let secondary = observedModelIDs.filter { modelMatchesFamily($0, family: AGYSidecarHealthPolicy.secondaryModelFamily) }
            guard let primaryModel = primary.first, primary.count == 1,
                  let secondaryModel = secondary.first, secondary.count == 1,
                  primaryModel != secondaryModel else {
                throw AGYSidecarReceiptParserError.invalidContract
            }
            return ResolvedModelRoles(primary: primaryModel, secondary: secondaryModel, compatibilityError: nil)
        }

        guard let contractVersion, let declaredRoles,
              declaredRoles.primary.model != declaredRoles.secondary.model,
              isSafeModelIdentifier(declaredRoles.primary.model),
              isSafeModelIdentifier(declaredRoles.secondary.model),
              isSafeFamilyIdentifier(declaredRoles.primary.family),
              isSafeFamilyIdentifier(declaredRoles.secondary.family),
              observedModelIDs == Set([declaredRoles.primary.model, declaredRoles.secondary.model]) else {
            throw AGYSidecarReceiptParserError.invalidContract
        }

        if contractVersion != AGYSidecarHealthPolicy.currentContractVersion {
            return ResolvedModelRoles(
                primary: declaredRoles.primary.model,
                secondary: declaredRoles.secondary.model,
                compatibilityError: .contractUnsupported
            )
        }

        let primaryCompatibility = roleCompatibility(
            declaredRoles.primary,
            expectedFamily: AGYSidecarHealthPolicy.primaryModelFamily
        )
        let secondaryCompatibility = roleCompatibility(
            declaredRoles.secondary,
            expectedFamily: AGYSidecarHealthPolicy.secondaryModelFamily
        )
        guard primaryCompatibility != .invalid, secondaryCompatibility != .invalid else {
            throw AGYSidecarReceiptParserError.invalidContract
        }
        let compatibilityError: AGYSidecarErrorCode? =
            primaryCompatibility == .unsupported || secondaryCompatibility == .unsupported
                ? .modelRoleUnsupported
                : nil
        return ResolvedModelRoles(
            primary: declaredRoles.primary.model,
            secondary: declaredRoles.secondary.model,
            compatibilityError: compatibilityError
        )
    }

    private static func resolveReviewModelRoles(_ receipt: ReviewReceipt) throws -> ResolvedModelRoles {
        if receipt.contractVersion != nil || receipt.modelRoles != nil {
            guard let declaredRoles = receipt.modelRoles else {
                throw AGYSidecarReceiptParserError.invalidContract
            }
            return try resolveModelRoles(
                contractVersion: receipt.contractVersion,
                declaredRoles: declaredRoles,
                observedModelIDs: Set([declaredRoles.primary.model, declaredRoles.secondary.model])
            )
        }

        guard let primary = receipt.primary?.model ?? receipt.attemptedModels.first,
              isSafeModelIdentifier(primary),
              modelMatchesFamily(primary, family: AGYSidecarHealthPolicy.primaryModelFamily) else {
            throw AGYSidecarReceiptParserError.invalidContract
        }
        let secondary = receipt.secondary?.model
            ?? (receipt.attemptedModels.count > 1 ? receipt.attemptedModels[1] : AGYSidecarHealthPolicy.secondaryModel)
        guard isSafeModelIdentifier(secondary),
              primary != secondary,
              modelMatchesFamily(secondary, family: AGYSidecarHealthPolicy.secondaryModelFamily) else {
            throw AGYSidecarReceiptParserError.invalidContract
        }
        return ResolvedModelRoles(primary: primary, secondary: secondary, compatibilityError: nil)
    }

    private static func roleCompatibility(
        _ role: ModelRoleReceipt,
        expectedFamily: String
    ) -> ModelRoleCompatibility {
        if role.family == expectedFamily {
            return modelMatchesFamily(role.model, family: expectedFamily) ? .supported : .invalid
        }
        let knownFamilies = [
            AGYSidecarHealthPolicy.primaryModelFamily,
            AGYSidecarHealthPolicy.secondaryModelFamily
        ]
        return knownFamilies.contains(role.family) ? .invalid : .unsupported
    }

    private static func modelMatchesFamily(_ model: String, family: String) -> Bool {
        guard isSafeModelIdentifier(model) else { return false }
        switch family {
        case AGYSidecarHealthPolicy.primaryModelFamily:
            guard model.hasPrefix("gemini-"), model.hasSuffix("-flash-high") else { return false }
            let version = model.dropFirst("gemini-".count).dropLast("-flash-high".count)
            return versionComponentsAreNumeric(version, separators: ["."])
        case AGYSidecarHealthPolicy.secondaryModelFamily:
            guard model.hasPrefix("claude-sonnet-") else { return false }
            let version = model.dropFirst("claude-sonnet-".count)
            return versionComponentsAreNumeric(version, separators: ["-", "."])
        default:
            return false
        }
    }

    private static func isSafeModelIdentifier(_ value: String) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= 128 else { return false }
        return bytes.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || [45, 46, 95].contains(byte)
        }
    }

    private static func isSafeFamilyIdentifier(_ value: String) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= 64 else { return false }
        return bytes.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (97 ... 122).contains(byte)
                || [45, 95].contains(byte)
        }
    }

    private static func versionComponentsAreNumeric(
        _ version: Substring,
        separators: Set<Character>
    ) -> Bool {
        let components = version.split(omittingEmptySubsequences: false) { separators.contains($0) }
        return !components.isEmpty
            && components.allSatisfy { component in
                !component.isEmpty && component.allSatisfy(\.isNumber)
            }
    }

    private static func sourceContractIsHealthy(_ source: SourceReceipt?) -> Bool {
        guard let source else { return false }
        return source.kind == "repo-snapshot"
            && source.diffDelivery == "read-only-workspace-file"
            && source.originalRepositoryExposed == false
            && source.gitMetadataExposed == false
            && source.snapshotReadOnly == true
            && source.untrackedFilesOmitted == 1
    }

    private static func routeContractsAreHealthy(_ routes: [ReviewRouteReceipt]) -> Bool {
        guard !routes.isEmpty else { return false }
        return routes.allSatisfy { route in
            guard let audit = route.toolAudit,
                  audit.snapshotDiffReads >= 1,
                  audit.readOnlyFileCalls >= audit.snapshotDiffReads,
                  audit.otherToolCalls == 0,
                  ["PASS", "CHANGES_REQUIRED", "BLOCKED"].contains(route.review.verdict),
                  route.review.findings.count <= 6,
                  route.review.uncertainties.count <= 8,
                  route.review.reviewScope.count <= 20,
                  usageIsValid(route.usage) else {
                return false
            }
            return route.review.findings.allSatisfy(validateFinding)
        }
    }

    private static func usageIsValid(_ usage: UsageReceipt) -> Bool {
        [usage.inputTokens, usage.outputTokens, usage.thinkingTokens, usage.cacheReadTokens, usage.totalTokens]
            .allSatisfy { value in value.map { $0 >= 0 } ?? true }
    }

    private static func attemptedModelsAreValid(_ receipt: ReviewReceipt, roles: ResolvedModelRoles) -> Bool {
        let expected: [String]
        if receipt.secondaryRequired == true || receipt.secondary != nil || receipt.status == "PARTIAL" {
            expected = [roles.primary, roles.secondary]
        } else {
            expected = [roles.primary]
        }
        guard receipt.attemptedModels == expected,
              receipt.primary?.model == roles.primary else {
            return false
        }
        if let secondary = receipt.secondary {
            return secondary.model == roles.secondary
        }
        return true
    }

    private static func validateFinding(_ finding: FindingReceipt) -> Bool {
        ["P0", "P1", "P2", "P3"].contains(finding.severity)
            && ["high", "medium", "low"].contains(finding.confidence)
            && finding.file.utf8.count <= 300
            && finding.title.utf8.count <= 160
            && finding.evidence.utf8.count <= 600
            && finding.impact.utf8.count <= 400
            && finding.recommendation.utf8.count <= 600
            && finding.test.utf8.count <= 400
            && (finding.line == nil || finding.line! >= 1)
    }

    private static func findingMatchesCanary(_ finding: FindingReceipt) -> Bool {
        let normalizedFile = finding.file.replacingOccurrences(of: "\\", with: "/").lowercased()
        guard normalizedFile == "clamp.py" || normalizedFile.hasSuffix("/clamp.py") else { return false }
        let text = [finding.title, finding.evidence, finding.impact, finding.recommendation, finding.test]
            .joined(separator: " ")
            .lowercased()
        let namesBothBounds = (text.contains("lower") && text.contains("upper"))
            || (text.contains("min") && text.contains("max"))
        let identifiesOperation = text.contains("order") || text.contains("revers")
            || text.contains("bound") || text.contains("clamp")
        return namesBothBounds && identifiesOperation
    }

    private static func aggregateToolAudit(_ routes: [ReviewRouteReceipt]) -> AGYSidecarToolAuditSummary? {
        let audits = routes.compactMap(\.toolAudit)
        guard audits.count == routes.count, !audits.isEmpty else { return nil }
        return AGYSidecarToolAuditSummary(
            snapshotDiffReads: audits.reduce(0) { $0 + $1.snapshotDiffReads },
            readOnlyFileCalls: audits.reduce(0) { $0 + $1.readOnlyFileCalls },
            otherToolCalls: audits.reduce(0) { $0 + $1.otherToolCalls }
        )
    }

    private static func aggregateUsage(_ routes: [ReviewRouteReceipt]) -> AGYSidecarTokenUsage {
        guard !routes.isEmpty else { return .unavailable }
        let usages = routes.map(\.usage)
        return AGYSidecarTokenUsage(
            input: sumOptional(usages.map(\.inputTokens)),
            output: sumOptional(usages.map(\.outputTokens)),
            thinking: sumOptional(usages.map(\.thinkingTokens)),
            cacheRead: sumOptional(usages.map(\.cacheReadTokens)),
            total: sumOptional(usages.map(\.totalTokens))
        )
    }

    private static func sumOptional(_ values: [Int?]) -> Int? {
        guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else { return nil }
        var total = 0
        for value in values.compactMap({ $0 }) {
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }

    private static func snapshot(
        status: AGYSidecarE2EStatus,
        receipt: ReviewReceipt,
        checkedAt: Date,
        source: AGYSidecarSourceSummary?,
        toolAudit: AGYSidecarToolAuditSummary?,
        usage: AGYSidecarTokenUsage,
        receiptBytes: Int,
        findingMatched: Bool?,
        errorCode: AGYSidecarErrorCode?
    ) -> AGYSidecarE2ESnapshot {
        AGYSidecarE2ESnapshot(
            status: status,
            checkedAt: checkedAt,
            wrapperStatus: receipt.status,
            attemptedModels: receipt.attemptedModels,
            secondaryRequired: receipt.secondaryRequired,
            source: source,
            toolAudit: toolAudit,
            usage: usage,
            receiptBytes: receiptBytes,
            findingMatched: findingMatched,
            codexTokenUsage: nil,
            errorCode: errorCode
        )
    }
}

private struct DoctorReceipt: Decodable {
    let contractVersion: Int?
    let modelRoles: ModelRolesReceipt?
    let status: String
    let models: [String: Bool]
    let repoSnapshot: DoctorRepositoryReceipt

    enum CodingKeys: String, CodingKey {
        case status, models
        case contractVersion = "contract_version"
        case modelRoles = "model_roles"
        case repoSnapshot = "repo_snapshot"
    }
}

private struct ModelRolesReceipt: Decodable {
    let primary: ModelRoleReceipt
    let secondary: ModelRoleReceipt
}

private struct ModelRoleReceipt: Decodable {
    let family: String
    let model: String
}

private struct ResolvedModelRoles {
    let primary: String
    let secondary: String
    let compatibilityError: AGYSidecarErrorCode?
}

private enum ModelRoleCompatibility {
    case supported
    case unsupported
    case invalid
}

private struct DoctorRepositoryReceipt: Decodable {
    let ready: Bool
    let diffDelivery: String?
    let commandPermissionRequired: Bool?

    enum CodingKeys: String, CodingKey {
        case ready
        case diffDelivery = "diff_delivery"
        case commandPermissionRequired = "command_permission_required"
    }
}

private struct ReviewReceipt: Decodable {
    let contractVersion: Int?
    let modelRoles: ModelRolesReceipt?
    let status: String
    let risk: String?
    let source: SourceReceipt?
    let attemptedModels: [String]
    let primary: ReviewRouteReceipt?
    let secondaryRequired: Bool?
    let secondary: ReviewRouteReceipt?
    let solValidationRequired: Bool?

    enum CodingKeys: String, CodingKey {
        case status, risk, source, primary, secondary
        case contractVersion = "contract_version"
        case modelRoles = "model_roles"
        case attemptedModels = "attempted_models"
        case secondaryRequired = "secondary_required"
        case solValidationRequired = "sol_validation_required"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try container.decodeIfPresent(Int.self, forKey: .contractVersion)
        modelRoles = try container.decodeIfPresent(ModelRolesReceipt.self, forKey: .modelRoles)
        status = try container.decode(String.self, forKey: .status)
        risk = try container.decodeIfPresent(String.self, forKey: .risk)
        source = try container.decodeIfPresent(SourceReceipt.self, forKey: .source)
        attemptedModels = try container.decodeIfPresent([String].self, forKey: .attemptedModels) ?? []
        primary = try container.decodeIfPresent(ReviewRouteReceipt.self, forKey: .primary)
        secondaryRequired = try container.decodeIfPresent(Bool.self, forKey: .secondaryRequired)
        secondary = try container.decodeIfPresent(ReviewRouteReceipt.self, forKey: .secondary)
        solValidationRequired = try container.decodeIfPresent(Bool.self, forKey: .solValidationRequired)
    }
}

private struct SourceReceipt: Decodable {
    let kind: String
    let diffDelivery: String?
    let untrackedFilesOmitted: Int?
    let originalRepositoryExposed: Bool?
    let gitMetadataExposed: Bool?
    let snapshotReadOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case kind
        case diffDelivery = "diff_delivery"
        case untrackedFilesOmitted = "untracked_files_omitted"
        case originalRepositoryExposed = "original_repository_exposed"
        case gitMetadataExposed = "git_metadata_exposed"
        case snapshotReadOnly = "snapshot_read_only"
    }
}

private struct ReviewRouteReceipt: Decodable {
    let model: String
    let review: StructuredReviewReceipt
    let usage: UsageReceipt
    let toolAudit: ToolAuditReceipt?

    enum CodingKeys: String, CodingKey {
        case model, review, usage
        case toolAudit = "tool_audit"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        review = try container.decode(StructuredReviewReceipt.self, forKey: .review)
        usage = try container.decodeIfPresent(UsageReceipt.self, forKey: .usage) ?? UsageReceipt()
        toolAudit = try container.decodeIfPresent(ToolAuditReceipt.self, forKey: .toolAudit)
    }
}

private struct StructuredReviewReceipt: Decodable {
    let verdict: String
    let summary: String
    let findings: [FindingReceipt]
    let uncertainties: [String]
    let reviewScope: [String]

    enum CodingKeys: String, CodingKey {
        case verdict, summary, findings, uncertainties
        case reviewScope = "review_scope"
    }
}

private struct FindingReceipt: Decodable {
    let severity: String
    let file: String
    let line: Int?
    let title: String
    let evidence: String
    let impact: String
    let recommendation: String
    let test: String
    let confidence: String
}

private struct ToolAuditReceipt: Decodable {
    let snapshotDiffReads: Int
    let readOnlyFileCalls: Int
    let otherToolCalls: Int

    enum CodingKeys: String, CodingKey {
        case snapshotDiffReads = "snapshot_diff_reads"
        case readOnlyFileCalls = "read_only_file_calls"
        case otherToolCalls = "other_tool_calls"
    }
}

private struct UsageReceipt: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let thinkingTokens: Int?
    let cacheReadTokens: Int?
    let totalTokens: Int?

    init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        thinkingTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        totalTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.thinkingTokens = thinkingTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalTokens = totalTokens
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case thinkingTokens = "thinking_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case totalTokens = "total_tokens"
    }
}
