import Foundation

final class TestRunner {
    private(set) var failures = 0

    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard !condition() else { return }
        failures += 1
        FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
    }

    func checkEqual<T: Equatable>(_ actual: @autoclosure () -> T, _ expected: T, _ message: String) {
        let value = actual()
        guard value == expected else {
            failures += 1
            FileHandle.standardError.write(Data("FAILED: \(message) (actual: \(value), expected: \(expected))\n".utf8))
            return
        }
    }
}

actor RecordingProcessRunner: AGYSidecarProcessRunning {
    enum Response: Sendable {
        case success(AGYSidecarProcessResult)
        case failure(AGYSidecarProcessRunnerError)
    }

    private let response: Response
    private let delayNanoseconds: UInt64
    private var recorded: [AGYSidecarProcessRequest] = []

    init(response: Response, delayNanoseconds: UInt64 = 0) {
        self.response = response
        self.delayNanoseconds = delayNanoseconds
    }

    func run(_ request: AGYSidecarProcessRequest) async throws -> AGYSidecarProcessResult {
        recorded.append(request)
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        switch response {
        case let .success(result): return result
        case let .failure(error): throw error
        }
    }

    func requests() -> [AGYSidecarProcessRequest] { recorded }
}

struct StubFixture: AGYSidecarFixturePreparing {
    let url: URL
    let shouldFail: Bool

    func prepare() throws -> URL {
        if shouldFail { throw AGYSidecarFixtureError.invalid }
        return url
    }
}

actor StubHealthService: AGYSidecarHealthServicing {
    private let cached: AGYSidecarHealthCacheEntry
    private let doctorResult: AGYSidecarDoctorSnapshot
    private let e2eResult: AGYSidecarE2ESnapshot
    private let delayNanoseconds: UInt64
    private var doctorCallCount = 0
    private var e2eCallCount = 0

    init(
        cached: AGYSidecarHealthCacheEntry,
        doctorResult: AGYSidecarDoctorSnapshot,
        e2eResult: AGYSidecarE2ESnapshot = .neverRun,
        delayNanoseconds: UInt64 = 0
    ) {
        self.cached = cached
        self.doctorResult = doctorResult
        self.e2eResult = e2eResult
        self.delayNanoseconds = delayNanoseconds
    }

    func cachedEntry() -> AGYSidecarHealthCacheEntry { cached }

    func checkDoctor(at date: Date) async throws -> AGYSidecarDoctorSnapshot {
        doctorCallCount += 1
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        return doctorResult
    }

    func runCanary(at date: Date, liveAuthorized: Bool) async throws -> AGYSidecarE2ESnapshot {
        e2eCallCount += 1
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        return e2eResult
    }

    func counts() -> (doctor: Int, e2e: Int) { (doctorCallCount, e2eCallCount) }
}

func replaceSourceField(_ data: Data, key: String, value: Any) -> Data {
    var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    var source = object["source"] as! [String: Any]
    source[key] = value
    object["source"] = source
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

func writePythonScript(at url: URL, body: String) throws {
    try Data(body.utf8).write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

func reviewReceipt(
    status: String = "COMPLETE",
    secondaryRequired: Bool = false,
    includeSecondary: Bool = false,
    findingFile: String = "clamp.py",
    findingEvidence: String = "The lower and upper bounds are applied in reversed min/max order.",
    snapshotDiffReads: Int = 1,
    otherToolCalls: Int = 0,
    includeUsage: Bool = true
) -> Data {
    func route(_ model: String) -> [String: Any] {
        var result: [String: Any] = [
            "model": model,
            "review": [
                "verdict": "CHANGES_REQUIRED",
                "summary": "Deliberate fixture regression found.",
                "findings": [[
                    "severity": "P2",
                    "file": findingFile,
                    "line": 2,
                    "title": "Clamp bound order is reversed",
                    "evidence": findingEvidence,
                    "impact": "Values can escape the requested bounds.",
                    "recommendation": "Apply max to the lower bound before min to the upper bound.",
                    "test": "Check values below, inside, and above the range.",
                    "confidence": "high"
                ]],
                "uncertainties": [],
                "review_scope": ["clamp.py"]
            ],
            "tool_audit": [
                "snapshot_diff_reads": snapshotDiffReads,
                "read_only_file_calls": max(1, snapshotDiffReads),
                "failed_read_only_file_calls": 0,
                "other_tool_calls": otherToolCalls
            ]
        ]
        if includeUsage {
            result["usage"] = [
                "input_tokens": 100,
                "output_tokens": 20,
                "thinking_tokens": 5,
                "cache_read_tokens": 10,
                "total_tokens": 120
            ]
        }
        return result
    }

    var object: [String: Any] = [
        "status": status,
        "risk": "normal",
        "source": [
            "kind": "repo-snapshot",
            "diff_delivery": "read-only-workspace-file",
            "tracked_diff_bytes": 240,
            "untracked_files_omitted": 1,
            "original_repository_exposed": false,
            "git_metadata_exposed": false,
            "snapshot_read_only": true
        ],
        "codex_receipt_budget": [
            "maximum_bytes": 96 * 1024,
            "maximum_findings_per_model": 6
        ],
        "attempted_models": (includeSecondary || (status == "PARTIAL" && secondaryRequired))
            ? [AGYSidecarHealthPolicy.primaryModel, AGYSidecarHealthPolicy.secondaryModel]
            : [AGYSidecarHealthPolicy.primaryModel],
        "primary": route(AGYSidecarHealthPolicy.primaryModel),
        "secondary_required": secondaryRequired,
        "sol_validation_required": true
    ]
    if includeSecondary {
        object["secondary"] = route(AGYSidecarHealthPolicy.secondaryModel)
    }
    if status == "PARTIAL" {
        object["reason"] = "secondary unavailable"
        object["missing_review"] = AGYSidecarHealthPolicy.secondaryModel
    }
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

func versionedReceipt(
    _ data: Data,
    contractVersion: Int = 1,
    primaryFamily: String = "gemini-flash-high",
    primaryModel: String = "gemini-4.0-flash-high",
    secondaryFamily: String = "claude-sonnet",
    secondaryModel: String = "claude-sonnet-5-0"
) -> Data {
    var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    object["contract_version"] = contractVersion
    object["model_roles"] = [
        "primary": ["family": primaryFamily, "model": primaryModel],
        "secondary": ["family": secondaryFamily, "model": secondaryModel]
    ]
    if var attempted = object["attempted_models"] as? [String] {
        attempted = attempted.map {
            if $0 == AGYSidecarHealthPolicy.primaryModel { return primaryModel }
            if $0 == AGYSidecarHealthPolicy.secondaryModel { return secondaryModel }
            return $0
        }
        object["attempted_models"] = attempted
    }
    if var primary = object["primary"] as? [String: Any] {
        primary["model"] = primaryModel
        object["primary"] = primary
    }
    if var secondary = object["secondary"] as? [String: Any] {
        secondary["model"] = secondaryModel
        object["secondary"] = secondary
    }
    if object["missing_review"] as? String == AGYSidecarHealthPolicy.secondaryModel {
        object["missing_review"] = secondaryModel
    }
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

func versionedDoctorReceipt(
    contractVersion: Int = 1,
    primaryFamily: String = "gemini-flash-high",
    primaryModel: String = "gemini-4.0-flash-high",
    secondaryFamily: String = "claude-sonnet",
    secondaryModel: String = "claude-sonnet-5-0"
) -> Data {
    let object: [String: Any] = [
        "contract_version": contractVersion,
        "model_roles": [
            "primary": ["family": primaryFamily, "model": primaryModel],
            "secondary": ["family": secondaryFamily, "model": secondaryModel]
        ],
        "agy_binary": "/opt/homebrew/bin/agy",
        "models": [primaryModel: true, secondaryModel: true],
        "repo_snapshot": [
            "command_permission_required": false,
            "diff_delivery": "read-only-workspace-file",
            "ready": true
        ],
        "status": "READY"
    ]
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

@main
struct AGYSidecarHealthTestMain {
    static func main() async {
        let runner = TestRunner()
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let readyDoctor = Data("""
        {"agy_binary":"/opt/homebrew/bin/agy","models":{"claude-sonnet-4-6":true,"gemini-3.6-flash-high":true},"repo_snapshot":{"command_permission_required":false,"diff_delivery":"read-only-workspace-file","ready":true},"status":"READY"}
        """.utf8)
        let doctor = try? AGYSidecarReceiptParser.parseDoctor(readyDoctor, checkedAt: checkedAt)
        runner.checkEqual(doctor?.status, .ready, "doctor READY should decode")
        runner.checkEqual(doctor?.repositoryModeReady, true, "doctor should require repository mode")
        runner.checkEqual(doctor?.models.count, 2, "doctor should retain only the two pinned models")

        let upgradedDoctor = try? AGYSidecarReceiptParser.parseDoctor(
            versionedDoctorReceipt(),
            checkedAt: checkedAt
        )
        runner.checkEqual(upgradedDoctor?.status, .ready, "a supported role family must survive a model version upgrade")
        runner.checkEqual(
            upgradedDoctor?.models.map(\.model),
            ["gemini-4.0-flash-high", "claude-sonnet-5-0"],
            "doctor should retain the actual upgraded model IDs"
        )

        let unknownContractDoctor = try? AGYSidecarReceiptParser.parseDoctor(
            versionedDoctorReceipt(contractVersion: 2),
            checkedAt: checkedAt
        )
        runner.checkEqual(
            unknownContractDoctor?.status.rawValue,
            "COMPATIBILITY_WARNING",
            "an otherwise safe future contract must be a compatibility warning, not BROKEN"
        )
        runner.checkEqual(
            unknownContractDoctor?.errorCode?.rawValue,
            "CONTRACT_UNSUPPORTED",
            "future contracts should use a sanitized compatibility code"
        )

        let unknownFamilyDoctor = try? AGYSidecarReceiptParser.parseDoctor(
            versionedDoctorReceipt(primaryFamily: "gemini-next-review", primaryModel: "gemini-next-review-1"),
            checkedAt: checkedAt
        )
        runner.checkEqual(
            unknownFamilyDoctor?.status.rawValue,
            "COMPATIBILITY_WARNING",
            "an unknown but well-formed model family should request compatibility confirmation"
        )
        runner.checkEqual(
            unknownFamilyDoctor?.errorCode?.rawValue,
            "MODEL_ROLE_UNSUPPORTED",
            "unknown model families should use a sanitized compatibility code"
        )

        for unsafeModel in ["gemini-4.0-flash-high\nunsafe", "gemini-４.0-flash-high"] {
            do {
                _ = try AGYSidecarReceiptParser.parseDoctor(
                    versionedDoctorReceipt(primaryModel: unsafeModel),
                    checkedAt: checkedAt
                )
                runner.check(false, "unsafe model identifiers must fail closed")
            } catch {
                runner.check(true, "unsafe model identifier rejected")
            }
        }

        let unavailableDoctor = Data("""
        {"models":{"claude-sonnet-4-6":false,"gemini-3.6-flash-high":false},"reason":"AGY unavailable","repo_snapshot":{"ready":false},"status":"UNAVAILABLE"}
        """.utf8)
        let unavailableDoctorSnapshot = try? AGYSidecarReceiptParser.parseDoctor(unavailableDoctor, checkedAt: checkedAt)
        runner.checkEqual(unavailableDoctorSnapshot?.status, .unavailable, "doctor failure receipt should be UNAVAILABLE")
        runner.checkEqual(unavailableDoctorSnapshot?.errorCode, .sidecarUnavailable, "doctor failure should keep only a sanitized code")

        let complete = try? AGYSidecarReceiptParser.parseReview(reviewReceipt(), checkedAt: checkedAt)
        runner.checkEqual(complete?.status, .complete, "valid repository receipt should be COMPLETE")
        runner.checkEqual(complete?.findingMatched, true, "fixture finding should match clamp regression")
        runner.checkEqual(complete?.toolAudit?.snapshotDiffReads, 1, "diff read audit should be retained")
        runner.checkEqual(complete?.usage.total, 120, "reported total tokens should be retained")
        runner.checkEqual(complete?.receiptBytes, reviewReceipt().count, "receipt bytes should use actual stdout size")
        runner.checkEqual(complete?.codexTokenUsageLabel, "CODEX_TOKEN_USAGE=UNAVAILABLE", "bytes must never become Codex tokens")

        let upgradedReview = try? AGYSidecarReceiptParser.parseReview(
            versionedReceipt(reviewReceipt()),
            checkedAt: checkedAt
        )
        runner.checkEqual(upgradedReview?.status, .complete, "a supported role family must survive a review-model version upgrade")
        runner.checkEqual(
            upgradedReview?.attemptedModels,
            ["gemini-4.0-flash-high"],
            "review should retain the actual upgraded model ID"
        )

        let unknownContractReview = try? AGYSidecarReceiptParser.parseReview(
            versionedReceipt(reviewReceipt(), contractVersion: 2),
            checkedAt: checkedAt
        )
        runner.checkEqual(unknownContractReview?.status, .partial, "a safe future review contract should be PARTIAL")
        runner.checkEqual(
            unknownContractReview?.errorCode?.rawValue,
            "CONTRACT_UNSUPPORTED",
            "future review contracts should retain a sanitized compatibility code"
        )

        let unknownFamilyReview = try? AGYSidecarReceiptParser.parseReview(
            versionedReceipt(
                reviewReceipt(),
                primaryFamily: "gemini-next-review",
                primaryModel: "gemini-next-review-1"
            ),
            checkedAt: checkedAt
        )
        runner.checkEqual(unknownFamilyReview?.status, .partial, "an unknown safe model family should be PARTIAL")
        runner.checkEqual(
            unknownFamilyReview?.errorCode?.rawValue,
            "MODEL_ROLE_UNSUPPORTED",
            "unknown review families should retain a sanitized compatibility code"
        )

        var mismatchedRoleObject = try! JSONSerialization.jsonObject(
            with: versionedReceipt(reviewReceipt())
        ) as! [String: Any]
        var mismatchedPrimary = mismatchedRoleObject["primary"] as! [String: Any]
        mismatchedPrimary["model"] = "claude-sonnet-5-0"
        mismatchedRoleObject["primary"] = mismatchedPrimary
        let mismatchedRoleData = try! JSONSerialization.data(withJSONObject: mismatchedRoleObject, options: [.sortedKeys])
        let mismatchedRoleReview = try? AGYSidecarReceiptParser.parseReview(mismatchedRoleData, checkedAt: checkedAt)
        runner.checkEqual(mismatchedRoleReview?.status, .broken, "a role-to-route mismatch must remain BROKEN")
        runner.checkEqual(mismatchedRoleReview?.errorCode, .protocolViolation, "role mismatch should be a protocol violation")

        let missingUsage = try? AGYSidecarReceiptParser.parseReview(
            reviewReceipt(includeUsage: false),
            checkedAt: checkedAt
        )
        runner.checkEqual(missingUsage?.usage, .unavailable, "missing token fields should remain UNAVAILABLE")

        var partialUsageObject = try! JSONSerialization.jsonObject(with: reviewReceipt()) as! [String: Any]
        var partialUsagePrimary = partialUsageObject["primary"] as! [String: Any]
        var partialUsage = partialUsagePrimary["usage"] as! [String: Any]
        partialUsage.removeValue(forKey: "total_tokens")
        partialUsagePrimary["usage"] = partialUsage
        partialUsageObject["primary"] = partialUsagePrimary
        let partialUsageData = try! JSONSerialization.data(withJSONObject: partialUsageObject, options: [.sortedKeys])
        let partialUsageSnapshot = try? AGYSidecarReceiptParser.parseReview(partialUsageData, checkedAt: checkedAt)
        runner.checkEqual(partialUsageSnapshot?.usage.input, 100, "reported token fields should remain visible")
        runner.checkEqual(partialUsageSnapshot?.usage.total, nil, "missing total_tokens must not be inferred")

        let noDiffRead = try? AGYSidecarReceiptParser.parseReview(
            reviewReceipt(snapshotDiffReads: 0),
            checkedAt: checkedAt
        )
        runner.checkEqual(noDiffRead?.status, .broken, "missing diff read must be BROKEN")

        let extraTool = try? AGYSidecarReceiptParser.parseReview(
            reviewReceipt(otherToolCalls: 1),
            checkedAt: checkedAt
        )
        runner.checkEqual(extraTool?.status, .broken, "any extra tool call must be BROKEN")

        let missedFinding = try? AGYSidecarReceiptParser.parseReview(
            reviewReceipt(findingFile: "other.py", findingEvidence: "unrelated"),
            checkedAt: checkedAt
        )
        runner.checkEqual(missedFinding?.status, .broken, "missing fixture finding must be BROKEN")
        runner.checkEqual(missedFinding?.errorCode, .findingMissed, "finding miss should use a sanitized error code")

        let invalidSourceMutations: [(String, Any)] = [
            ("kind", "bundle"),
            ("diff_delivery", "prompt"),
            ("original_repository_exposed", true),
            ("git_metadata_exposed", true),
            ("snapshot_read_only", false),
            ("untracked_files_omitted", 0)
        ]
        for (key, value) in invalidSourceMutations {
            let snapshot = try? AGYSidecarReceiptParser.parseReview(
                replaceSourceField(reviewReceipt(), key: key, value: value),
                checkedAt: checkedAt
            )
            runner.checkEqual(snapshot?.status, .broken, "source protocol field \(key) must fail closed")
            runner.checkEqual(snapshot?.errorCode, .protocolViolation, "source protocol field \(key) should be a protocol violation")
        }

        let partial = try? AGYSidecarReceiptParser.parseReview(
            reviewReceipt(status: "PARTIAL", secondaryRequired: true),
            checkedAt: checkedAt
        )
        runner.checkEqual(partial?.status, .partial, "legal missing secondary receipt should be PARTIAL")

        let completedSecondary = try? AGYSidecarReceiptParser.parseReview(
            reviewReceipt(secondaryRequired: true, includeSecondary: true),
            checkedAt: checkedAt
        )
        runner.checkEqual(completedSecondary?.status, .complete, "completed required secondary should be COMPLETE")
        runner.checkEqual(completedSecondary?.usage.total, 240, "complete per-model token totals should aggregate")

        let fallback = Data("""
        {"attempted_models":["gemini-3.6-flash-high"],"reason":"gemini-3.6-flash-high exited unsuccessfully","sol_validation_required":true,"source":{"diff_delivery":"read-only-workspace-file","git_metadata_exposed":false,"kind":"repo-snapshot","original_repository_exposed":false,"snapshot_read_only":true,"tracked_diff_bytes":240,"untracked_files_omitted":1},"status":"FALLBACK_SOL"}
        """.utf8)
        let fallbackSnapshot = try? AGYSidecarReceiptParser.parseReview(fallback, checkedAt: checkedAt)
        runner.checkEqual(fallbackSnapshot?.status, .unavailable, "FALLBACK_SOL should map to UNAVAILABLE health")
        runner.checkEqual(fallbackSnapshot?.wrapperStatus, "FALLBACK_SOL", "wrapper route status should remain visible")
        let unsafeFallback = try? AGYSidecarReceiptParser.parseReview(
            replaceSourceField(fallback, key: "original_repository_exposed", value: true),
            checkedAt: checkedAt
        )
        runner.checkEqual(unsafeFallback?.status, .broken, "FALLBACK_SOL must not hide an unsafe source contract")
        runner.checkEqual(unsafeFallback?.errorCode, .protocolViolation, "unsafe fallback source should be a protocol violation")

        let rejected = Data("""
        {"reason":"invalid fixture","sol_validation_required":true,"status":"INPUT_REJECTED"}
        """.utf8)
        let rejectedSnapshot = try? AGYSidecarReceiptParser.parseReview(rejected, checkedAt: checkedAt)
        runner.checkEqual(rejectedSnapshot?.status, .broken, "INPUT_REJECTED should map to BROKEN health")
        runner.checkEqual(rejectedSnapshot?.wrapperStatus, "INPUT_REJECTED", "rejected wrapper status should remain visible")
        runner.checkEqual(rejectedSnapshot?.attemptedModels, [], "input rejection should not invent attempted models")

        var atLimit = reviewReceipt()
        atLimit.append(Data(repeating: 0x20, count: AGYSidecarHealthPolicy.receiptByteLimit - atLimit.count))
        runner.checkEqual(atLimit.count, AGYSidecarHealthPolicy.receiptByteLimit, "test fixture should hit the exact receipt limit")
        runner.check((try? AGYSidecarReceiptParser.parseReview(atLimit, checkedAt: checkedAt)) != nil, "96 KiB receipt should be accepted")
        atLimit.append(0x20)
        do {
            _ = try AGYSidecarReceiptParser.parseReview(atLimit, checkedAt: checkedAt)
            runner.check(false, "receipt above 96 KiB should fail closed")
        } catch let error as AGYSidecarReceiptParserError {
            runner.checkEqual(error, .receiptOversized, "oversized receipt should have a stable error")
        } catch {
            runner.check(false, "oversized receipt returned unexpected error")
        }

        let unknownRoot = Data("{\"status\":\"READY\",\"unknown\":true}".utf8)
        do {
            _ = try AGYSidecarReceiptParser.parseDoctor(unknownRoot, checkedAt: checkedAt)
            runner.check(false, "unknown doctor fields should fail whitelist validation")
        } catch {
            runner.check(true, "unknown doctor field rejected")
        }

        let testRoot = ProcessInfo.processInfo.environment["AGY_SIDECAR_TEST_TMPDIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let runtimeRoot = testRoot.appendingPathComponent("runtime-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)

        do {
            let script = runtimeRoot.appendingPathComponent("separate.py")
            try writePythonScript(at: script, body: """
            import json, sys
            sys.stderr.write("private-stderr-marker")
            print(json.dumps({"status":"READY"}))
            """)
            let request = AGYSidecarProcessRequest(
                kind: .doctor,
                scriptURL: script,
                arguments: [script.path, "doctor"],
                timeout: 2
            )
            let result = try await AGYSidecarProcessRunner().run(request)
            runner.check(String(decoding: result.stdout, as: UTF8.self).contains("READY"), "runner should return stdout")
            runner.check(!String(decoding: result.stdout, as: UTF8.self).contains("private-stderr-marker"), "stderr must never enter stdout")
            runner.checkEqual(result.stderrBytes, "private-stderr-marker".utf8.count, "runner should count but not retain stderr")
        } catch {
            runner.check(false, "stdout/stderr separation test threw \(error)")
        }

        do {
            let script = runtimeRoot.appendingPathComponent("timeout.py")
            try writePythonScript(at: script, body: "import time\ntime.sleep(5)\n")
            let request = AGYSidecarProcessRequest(
                kind: .doctor,
                scriptURL: script,
                arguments: [script.path, "doctor"],
                timeout: 0.1
            )
            do {
                _ = try await AGYSidecarProcessRunner().run(request)
                runner.check(false, "runner timeout should fail")
            } catch let error as AGYSidecarProcessRunnerError {
                runner.checkEqual(error, .timedOut, "runner should expose sanitized timeout")
            }
        } catch {
            runner.check(false, "timeout fixture setup threw \(error)")
        }

        do {
            let script = runtimeRoot.appendingPathComponent("oversized.py")
            try writePythonScript(
                at: script,
                body: "import sys\nsys.stdout.write('x' * \(AGYSidecarHealthPolicy.receiptByteLimit + 1))\nsys.stdout.flush()\n"
            )
            let request = AGYSidecarProcessRequest(
                kind: .doctor,
                scriptURL: script,
                arguments: [script.path, "doctor"],
                timeout: 2
            )
            do {
                _ = try await AGYSidecarProcessRunner().run(request)
                runner.check(false, "oversized stdout should fail")
            } catch let error as AGYSidecarProcessRunnerError {
                runner.checkEqual(error, .stdoutOversized, "runner must stop oversized stdout")
            }
        } catch {
            runner.check(false, "oversized fixture setup threw \(error)")
        }

        do {
            let fixtureURL = runtimeRoot.appendingPathComponent("fixture", isDirectory: true)
            let fixture = AGYSidecarCanaryFixture(repositoryURL: fixtureURL)
            let prepared = try fixture.prepare()
            runner.checkEqual(prepared.standardizedFileURL, fixtureURL.standardizedFileURL, "fixture should stay under its configured Application Support root")
            let statusProcess = Process()
            statusProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            statusProcess.arguments = ["-C", fixtureURL.path, "status", "--porcelain=v1", "--untracked-files=all"]
            let output = Pipe()
            statusProcess.standardOutput = output
            statusProcess.standardError = Pipe()
            try statusProcess.run()
            statusProcess.waitUntilExit()
            let status = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            runner.checkEqual(status, " M clamp.py\n?? canary-note.txt\n", "fixture should have one tracked diff and one untracked file")
            let unknownURL = fixtureURL.appendingPathComponent("unknown.txt")
            try Data("unknown".utf8).write(to: unknownURL)
            do {
                _ = try fixture.prepare()
                runner.check(false, "unknown fixture content should fail closed")
            } catch let error as AGYSidecarFixtureError {
                runner.checkEqual(error, .invalid, "unknown fixture content should be FIXTURE_INVALID")
                runner.check(FileManager.default.fileExists(atPath: unknownURL.path), "unknown fixture content must not be deleted")
            }
        } catch {
            runner.check(false, "fixture contract test threw \(error)")
        }

        do {
            let linkTarget = runtimeRoot.appendingPathComponent("link-target", isDirectory: true)
            let linkFixture = runtimeRoot.appendingPathComponent("fixture-link", isDirectory: true)
            try FileManager.default.createDirectory(at: linkTarget, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: linkFixture, withDestinationURL: linkTarget)
            do {
                _ = try AGYSidecarCanaryFixture(repositoryURL: linkFixture).prepare()
                runner.check(false, "symlink fixture should fail closed")
            } catch let error as AGYSidecarFixtureError {
                runner.checkEqual(error, .invalid, "symlink fixture should be FIXTURE_INVALID")
                runner.check(FileManager.default.fileExists(atPath: linkFixture.path), "symlink fixture must not be deleted")
            }
        } catch {
            runner.check(false, "symlink fixture setup threw \(error)")
        }

        let successfulProcess = AGYSidecarProcessResult(
            stdout: reviewReceipt(),
            stderrBytes: 99,
            exitCode: 0,
            duration: 0.2
        )
        let serviceRunner = RecordingProcessRunner(response: .success(successfulProcess))
        let servicePaths = AGYSidecarHealthPaths(homeDirectory: runtimeRoot, applicationSupportDirectory: runtimeRoot)
        let diagnostics = MonitorDiagnostics(logURL: runtimeRoot.appendingPathComponent("diagnostics.jsonl"))
        let service = AGYSidecarHealthService(
            runner: serviceRunner,
            paths: servicePaths,
            fixture: StubFixture(url: runtimeRoot, shouldFail: false),
            cache: AGYSidecarHealthCache(fileURL: runtimeRoot.appendingPathComponent("health.json")),
            diagnostics: diagnostics
        )
        do {
            _ = try await service.runCanary(at: checkedAt, liveAuthorized: true)
            let requests = await serviceRunner.requests()
            runner.checkEqual(requests.count, 1, "one canary plan must perform exactly one wrapper call")
            runner.checkEqual(requests.first?.kind, .review, "canary should use only the review command")
            runner.checkEqual(requests.first?.arguments.filter { $0 == "review" }.count, 1, "review argv must contain one review invocation")
        } catch {
            runner.check(false, "simulated service canary threw \(error)")
        }

        let unauthorizedRunner = RecordingProcessRunner(response: .success(successfulProcess))
        let unauthorizedService = AGYSidecarHealthService(
            runner: unauthorizedRunner,
            paths: servicePaths,
            fixture: StubFixture(url: runtimeRoot, shouldFail: false),
            cache: AGYSidecarHealthCache(fileURL: runtimeRoot.appendingPathComponent("unauthorized-health.json")),
            diagnostics: diagnostics
        )
        do {
            _ = try await unauthorizedService.runCanary(at: checkedAt, liveAuthorized: false)
            runner.check(false, "unauthorized canary should not run")
        } catch let error as AGYSidecarHealthServiceError {
            runner.checkEqual(error, .liveCanaryNotAuthorized, "live canary authorization must fail closed")
        } catch {
            runner.check(false, "unauthorized canary returned unexpected error")
        }
        let unauthorizedRequestCount = await unauthorizedRunner.requests().count
        runner.checkEqual(unauthorizedRequestCount, 0, "unauthorized canary must make zero process calls")

        let timeoutRunner = RecordingProcessRunner(response: .failure(.timedOut))
        let timeoutService = AGYSidecarHealthService(
            runner: timeoutRunner,
            paths: servicePaths,
            fixture: StubFixture(url: runtimeRoot, shouldFail: false),
            cache: AGYSidecarHealthCache(fileURL: runtimeRoot.appendingPathComponent("timeout-health.json")),
            diagnostics: diagnostics
        )
        do {
            let snapshot = try await timeoutService.checkDoctor(at: checkedAt)
            runner.checkEqual(snapshot.status, .unavailable, "doctor timeout should be UNAVAILABLE")
            runner.checkEqual(snapshot.errorCode, .timedOut, "doctor timeout should use TIMED_OUT")
            let timeoutRequestCount = await timeoutRunner.requests().count
            runner.checkEqual(timeoutRequestCount, 1, "doctor must not auto-retry")
        } catch {
            runner.check(false, "doctor timeout mapping threw \(error)")
        }

        let malformedRunner = RecordingProcessRunner(
            response: .success(
                AGYSidecarProcessResult(
                    stdout: Data("not-json".utf8),
                    stderrBytes: 1_024,
                    exitCode: 0,
                    duration: 0.1
                )
            )
        )
        let malformedService = AGYSidecarHealthService(
            runner: malformedRunner,
            paths: servicePaths,
            fixture: StubFixture(url: runtimeRoot, shouldFail: false),
            cache: AGYSidecarHealthCache(fileURL: runtimeRoot.appendingPathComponent("malformed-health.json")),
            diagnostics: diagnostics
        )
        do {
            let snapshot = try await malformedService.checkDoctor(at: checkedAt)
            runner.checkEqual(snapshot.status, .broken, "doctor malformed stdout should be BROKEN")
            runner.checkEqual(snapshot.errorCode, .outputInvalid, "doctor malformed stdout should expose only OUTPUT_INVALID")
        } catch {
            runner.check(false, "malformed doctor mapping threw \(error)")
        }

        do {
            let cacheURL = runtimeRoot.appendingPathComponent("roundtrip-health.json")
            let cache = AGYSidecarHealthCache(fileURL: cacheURL)
            let value = AGYSidecarHealthCacheEntry(
                doctor: AGYSidecarDoctorSnapshot(
                    status: .ready,
                    checkedAt: checkedAt,
                    models: [AGYSidecarModelAvailability(model: AGYSidecarHealthPolicy.primaryModel, available: true)],
                    repositoryModeReady: true,
                    errorCode: nil
                ),
                e2e: complete ?? .neverRun
            )
            try cache.save(value)
            let reloaded = try cache.load()
            runner.checkEqual(reloaded, value, "health cache should round-trip only structured summaries")
            let permissions = try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.posixPermissions] as? NSNumber
            runner.checkEqual(permissions.map { $0.intValue & 0o777 }, 0o600, "health cache should be mode 0600")
            let persisted = String(decoding: try Data(contentsOf: cacheURL), as: UTF8.self)
            runner.check(!persisted.contains("private-stderr-marker"), "cache must not persist raw stderr")
            runner.check(!persisted.contains("deliberate fixture regression"), "cache must not persist finding text")
        } catch {
            runner.check(false, "health cache test threw \(error)")
        }

        let readySnapshot = AGYSidecarDoctorSnapshot(
            status: .ready,
            checkedAt: checkedAt,
            models: [
                AGYSidecarModelAvailability(model: AGYSidecarHealthPolicy.primaryModel, available: true),
                AGYSidecarModelAvailability(model: AGYSidecarHealthPolicy.secondaryModel, available: true)
            ],
            repositoryModeReady: true,
            errorCode: nil
        )
        let staleService = StubHealthService(
            cached: AGYSidecarHealthCacheEntry(doctor: .neverRun, e2e: .neverRun),
            doctorResult: readySnapshot,
            delayNanoseconds: 100_000_000
        )
        let viewModel = await MainActor.run {
            AGYSidecarHealthViewModel(service: staleService, liveCanaryAuthorized: false, startAutomatically: false)
        }
        async let firstCheck: Void = viewModel.checkDoctorNow(now: checkedAt)
        async let secondCheck: Void = viewModel.checkDoctorNow(now: checkedAt)
        _ = await (firstCheck, secondCheck)
        let staleCounts = await staleService.counts()
        let publishedDoctorStatus = await MainActor.run { viewModel.doctorSnapshot.status }
        runner.checkEqual(staleCounts.doctor, 1, "ViewModel doctor checks should be single-flight")
        runner.checkEqual(publishedDoctorStatus, .ready, "ViewModel should publish doctor transition")

        let freshService = StubHealthService(
            cached: AGYSidecarHealthCacheEntry(doctor: readySnapshot, e2e: .neverRun),
            doctorResult: readySnapshot
        )
        let freshViewModel = await MainActor.run {
            AGYSidecarHealthViewModel(service: freshService, liveCanaryAuthorized: false, startAutomatically: false)
        }
        await freshViewModel.start(now: checkedAt.addingTimeInterval(60))
        let freshStartupCounts = await freshService.counts()
        let freshE2EStatus = await MainActor.run { freshViewModel.e2eSnapshot.status }
        runner.checkEqual(freshStartupCounts.doctor, 0, "fresh startup cache should avoid a repeated doctor process")
        runner.checkEqual(freshE2EStatus, .neverRun, "no live canary should remain NEVER_RUN")
        await MainActor.run {
            freshViewModel.configureAutomaticCanary(enabled: true, interval: 1, now: checkedAt)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let freshAutomaticCounts = await freshService.counts()
        runner.checkEqual(freshAutomaticCounts.e2e, 0, "unauthorized automatic canary must make zero calls")
        runner.checkEqual(
            AGYSidecarHealthPolicy.automaticInterval(1),
            AGYSidecarHealthPolicy.minimumAutomaticCanaryInterval,
            "automatic canary interval must clamp to at least 24 hours"
        )
        runner.checkEqual(
            AGYSidecarHealthPolicy.automaticInterval(.greatestFiniteMagnitude),
            AGYSidecarHealthPolicy.maximumAutomaticCanaryInterval,
            "automatic canary interval should stay within the persisted 30-day range"
        )
        let futureDoctor = AGYSidecarDoctorSnapshot(
            status: .ready,
            checkedAt: checkedAt.addingTimeInterval(60),
            models: readySnapshot.models,
            repositoryModeReady: true,
            errorCode: nil
        )
        runner.check(
            !AGYSidecarHealthPolicy.doctorIsFresh(futureDoctor, now: checkedAt),
            "future cache timestamps must not suppress a doctor check"
        )

        let cachedFailure = AGYSidecarDoctorSnapshot(
            status: .unavailable,
            checkedAt: checkedAt,
            models: [],
            repositoryModeReady: false,
            errorCode: .sidecarUnavailable
        )
        let cachedFailureService = StubHealthService(
            cached: AGYSidecarHealthCacheEntry(doctor: cachedFailure, e2e: complete ?? .neverRun),
            doctorResult: readySnapshot
        )
        let cachedFailureViewModel = await MainActor.run {
            AGYSidecarHealthViewModel(service: cachedFailureService, liveCanaryAuthorized: false, startAutomatically: false)
        }
        await cachedFailureViewModel.start(now: checkedAt.addingTimeInterval(60))
        let cachedFailureCounts = await cachedFailureService.counts()
        let cachedFailureLabel = await MainActor.run { cachedFailureViewModel.indicatorLabel }
        runner.checkEqual(cachedFailureCounts.doctor, 0, "fresh failed doctor state should also use the low-frequency cache")
        runner.checkEqual(cachedFailureLabel, "自检不可用", "a cached E2E success must not hide a current doctor failure")

        let compatibilityDoctor = AGYSidecarDoctorSnapshot(
            status: .compatibilityWarning,
            checkedAt: checkedAt,
            models: [
                AGYSidecarModelAvailability(model: "gemini-next-review-1", available: true),
                AGYSidecarModelAvailability(model: "claude-sonnet-5-0", available: true)
            ],
            repositoryModeReady: true,
            errorCode: .modelRoleUnsupported
        )
        let compatibilityService = StubHealthService(
            cached: AGYSidecarHealthCacheEntry(doctor: compatibilityDoctor, e2e: complete ?? .neverRun),
            doctorResult: compatibilityDoctor
        )
        let compatibilityViewModel = await MainActor.run {
            AGYSidecarHealthViewModel(service: compatibilityService, liveCanaryAuthorized: false, startAutomatically: false)
        }
        await compatibilityViewModel.start(now: checkedAt.addingTimeInterval(60))
        let compatibilityLabel = await MainActor.run { compatibilityViewModel.indicatorLabel }
        let compatibilityAccessibility = await MainActor.run { compatibilityViewModel.accessibilitySummary }
        runner.checkEqual(compatibilityLabel, "兼容待确认", "a compatibility warning should remain visible even with a historical COMPLETE E2E")
        runner.check(
            compatibilityAccessibility.contains("具体模型版本只记录"),
            "accessibility should explain the version-independent health contract"
        )

        let cancellationService = StubHealthService(
            cached: AGYSidecarHealthCacheEntry(doctor: .neverRun, e2e: .neverRun),
            doctorResult: readySnapshot,
            delayNanoseconds: 5_000_000_000
        )
        let cancellationViewModel = await MainActor.run {
            AGYSidecarHealthViewModel(service: cancellationService, liveCanaryAuthorized: false, startAutomatically: false)
        }
        let cancellationTask = Task { await cancellationViewModel.checkDoctorNow(now: checkedAt) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await MainActor.run { cancellationViewModel.cancelDoctorCheck() }
        await cancellationTask.value
        let cancelledStatus = await MainActor.run { cancellationViewModel.doctorSnapshot.status }
        runner.checkEqual(cancelledStatus, .neverRun, "cancelled doctor should preserve the prior state")

        if let repositoryRoot = ProcessInfo.processInfo.environment["AGY_SIDECAR_REPO_ROOT"] {
            let settingsSource = (try? String(contentsOfFile: "\(repositoryRoot)/Sources/CodexNotch/SettingsView.swift", encoding: .utf8)) ?? ""
            let stripSource = (try? String(contentsOfFile: "\(repositoryRoot)/Sources/CodexNotch/NotchIslandView.swift", encoding: .utf8)) ?? ""
            runner.check(settingsSource.contains("AGY 旁路健康"), "settings should expose the sidecar health section")
            runner.check(settingsSource.contains("重新自检") && settingsSource.contains("立即验收"), "settings should expose both manual actions")
            runner.check(settingsSource.contains(".help(sidecarHealthHelp)"), "settings should provide consistent help text")
            runner.check(settingsSource.contains(".accessibilityLabel(sidecarHealthHelp)"), "settings should provide the same accessibility summary")
            runner.check(settingsSource.contains("secondary_required"), "settings should expose the receipt secondary_required field")
            runner.check(settingsSource.contains("original_repository_exposed"), "settings should expose the source protocol summary")
            runner.check(settingsSource.contains("具体版本升级不会单独判为故障"), "settings should explain version-independent Doctor health")
            runner.check(settingsSource.contains("case .compatibilityWarning: MonitorTheme.settingsWarning"), "settings should render compatibility as warning, not error")
            runner.check(stripSource.contains("旁路 \\(agySidecarHealthViewModel.indicatorLabel)"), "AGY strip should retain a compact sidecar indicator")
            runner.check(stripSource.contains("agySidecarHealthViewModel.accessibilitySummary"), "AGY strip accessibility should include the independent sidecar state")
            runner.check(stripSource.contains("doctorSnapshot.status == .compatibilityWarning"), "AGY strip should render compatibility as warning, not error")
        } else {
            runner.check(false, "test repository root was unavailable")
        }

        try? FileManager.default.removeItem(at: runtimeRoot)

        runner.checkEqual(
            AGYSidecarProcessRequest.doctor(scriptURL: URL(fileURLWithPath: "/x/agy_review.py")).arguments,
            ["/x/agy_review.py", "doctor"],
            "doctor argv must be exact"
        )
        runner.checkEqual(
            AGYSidecarProcessRequest.review(
                scriptURL: URL(fileURLWithPath: "/x/agy_review.py"),
                repositoryURL: URL(fileURLWithPath: "/fixture")
            ).arguments,
            [
                "/x/agy_review.py", "review", "--repo", "/fixture", "--task",
                AGYSidecarHealthPolicy.canaryTask, "--risk", "normal"
            ],
            "review argv must be fixed and contain exactly one review invocation"
        )

        if runner.failures == 0 {
            print("AGY sidecar health tests passed")
        } else {
            exit(1)
        }
    }
}
