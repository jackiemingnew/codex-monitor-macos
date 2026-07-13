import Darwin
import Foundation

enum SkillJSONLStopReason: Equatable, Sendable {
    case endOfFile
    case byteBudget
    case wallTimeBudget
    case cpuBudget
    case cancelled
}

enum SkillJSONLRowClassification: Sendable {
    case parse
    case irrelevant
}

struct SkillJSONLReadResult: Sendable {
    let processedOffset: UInt64
    let analyzedBytes: UInt64
    let analyzedLines: Int
    let parsedRows: Int
    let filteredRows: Int
    let skippedOversizedRows: Int
    let skippedIrrelevantOversizedRows: Int
    let peakPhysicalFootprintBytes: UInt64
    let discardingOversizedRow: Bool
    let hasIncompleteRow: Bool
    let stopReason: SkillJSONLStopReason
}

enum SkillJSONLReader {
    private static let chunkBytes = 256 * 1024
    private static let budgetCheckBytes = 1024 * 1024
    private static let pressureReliefBytes = 16 * 1024 * 1024

    static func read(
        handle: FileHandle,
        startOffset: UInt64,
        fileSize: UInt64,
        byteBudget: UInt64,
        maxRowBytes: Int,
        initialDiscardingOversizedRow: Bool,
        wallDeadlineUptime: TimeInterval,
        cpuDeadlineNanoseconds: UInt64,
        shouldCancel: @escaping @Sendable () -> Bool,
        classify: (Data) -> SkillJSONLRowClassification = SkillJSONLRowClassifier.classify,
        process: (Data, UInt64) -> Void
    ) throws -> SkillJSONLReadResult {
        try handle.seek(toOffset: startOffset)
        let readableBytes = min(byteBudget, fileSize > startOffset ? fileSize - startOffset : 0)
        var consumed: UInt64 = 0
        var currentOffset = startOffset
        var lineStartOffset = startOffset
        var lineBuffer = Data()
        lineBuffer.reserveCapacity(min(maxRowBytes, chunkBytes))
        var discardingOversizedRow = initialDiscardingOversizedRow
        var oversizedRowClassification: SkillJSONLRowClassification = .parse
        var analyzedLines = 0
        var parsedRows = 0
        var filteredRows = 0
        var skippedOversizedRows = 0
        var skippedIrrelevantOversizedRows = 0
        var bytesSinceBudgetCheck = Self.budgetCheckBytes
        var bytesSincePressureRelief = 0
        var peakPhysicalFootprintBytes = SkillProcessResourceSnapshot.capture().physicalFootprintBytes
        var stopReason: SkillJSONLStopReason?

        while consumed < readableBytes {
            if bytesSincePressureRelief >= Self.pressureReliefBytes {
                bytesSincePressureRelief = 0
                _ = malloc_zone_pressure_relief(nil, 0)
            }
            if bytesSinceBudgetCheck >= Self.budgetCheckBytes {
                bytesSinceBudgetCheck = 0
                peakPhysicalFootprintBytes = max(
                    peakPhysicalFootprintBytes,
                    SkillProcessResourceSnapshot.capture().physicalFootprintBytes
                )
                if shouldCancel() {
                    stopReason = .cancelled
                    break
                }
                if ProcessInfo.processInfo.systemUptime >= wallDeadlineUptime {
                    stopReason = .wallTimeBudget
                    break
                }
                if SkillProcessResourceSnapshot.processCPUNanoseconds() >= cpuDeadlineNanoseconds {
                    stopReason = .cpuBudget
                    break
                }
            }

            let requested = Int(min(UInt64(Self.chunkBytes), readableBytes - consumed))
            guard requested > 0 else {
                break
            }
            let chunkStartOffset = currentOffset
            let chunkCount = try autoreleasepool { () throws -> Int in
                guard let chunk = try handle.read(upToCount: requested),
                      !chunk.isEmpty else {
                    return 0
                }
                chunk.withUnsafeBytes { rawBuffer in
                    guard let base = rawBuffer.baseAddress else {
                        return
                    }
                    var cursor = 0
                    while cursor < rawBuffer.count {
                        let searchStart = base.advanced(by: cursor)
                        let remaining = rawBuffer.count - cursor
                        let newlinePointer = memchr(searchStart, Int32(0x0A), remaining)
                        let newlineIndex = newlinePointer.map {
                            cursor + searchStart.distance(to: $0)
                        }
                        let segmentEnd = newlineIndex ?? rawBuffer.count
                        let segmentCount = segmentEnd - cursor

                        if !discardingOversizedRow, segmentCount > 0 {
                            let allowed = max(0, maxRowBytes - lineBuffer.count)
                            let appendedCount = min(allowed, segmentCount)
                            if appendedCount > 0 {
                                lineBuffer.append(
                                    searchStart.assumingMemoryBound(to: UInt8.self),
                                    count: appendedCount
                                )
                            }
                            if appendedCount < segmentCount {
                                oversizedRowClassification = classify(lineBuffer)
                                lineBuffer.removeAll(keepingCapacity: true)
                                discardingOversizedRow = true
                            }
                        }

                        guard let newlineIndex else {
                            cursor = rawBuffer.count
                            continue
                        }

                        analyzedLines += 1
                        if discardingOversizedRow {
                            if oversizedRowClassification == .irrelevant {
                                skippedIrrelevantOversizedRows += 1
                                filteredRows += 1
                            } else {
                                skippedOversizedRows += 1
                            }
                            discardingOversizedRow = false
                            oversizedRowClassification = .parse
                        } else if !lineBuffer.isEmpty {
                            switch classify(lineBuffer) {
                            case .parse:
                                parsedRows += 1
                                process(lineBuffer, lineStartOffset)
                            case .irrelevant:
                                filteredRows += 1
                            }
                        }
                        lineBuffer.removeAll(keepingCapacity: true)
                        cursor = newlineIndex + 1
                        lineStartOffset = chunkStartOffset + UInt64(cursor)
                    }
                }
                return chunk.count
            }
            guard chunkCount > 0 else {
                break
            }
            consumed += UInt64(chunkCount)
            currentOffset += UInt64(chunkCount)
            bytesSinceBudgetCheck += chunkCount
            bytesSincePressureRelief += chunkCount
        }

        if stopReason == nil {
            if currentOffset >= fileSize {
                stopReason = .endOfFile
            } else if consumed >= readableBytes {
                stopReason = .byteBudget
            } else {
                stopReason = .endOfFile
            }
        }

        peakPhysicalFootprintBytes = max(
            peakPhysicalFootprintBytes,
            SkillProcessResourceSnapshot.capture().physicalFootprintBytes
        )
        return SkillJSONLReadResult(
            processedOffset: discardingOversizedRow ? currentOffset : lineStartOffset,
            analyzedBytes: consumed,
            analyzedLines: analyzedLines,
            parsedRows: parsedRows,
            filteredRows: filteredRows,
            skippedOversizedRows: skippedOversizedRows,
            skippedIrrelevantOversizedRows: skippedIrrelevantOversizedRows,
            peakPhysicalFootprintBytes: peakPhysicalFootprintBytes,
            discardingOversizedRow: discardingOversizedRow,
            hasIncompleteRow: !lineBuffer.isEmpty,
            stopReason: stopReason ?? .endOfFile
        )
    }
}

enum SkillJSONLRowClassifier {
    private static let relevantValues = [
        "\"session_meta\"", "\"turn_context\"", "\"user_message\"",
        "\"agent_message\"", "\"token_count\"", "\"task_complete\"",
        "\"message\"", "\"function_call\"", "\"custom_tool_call\""
    ].map { Data($0.utf8) }
    private static let irrelevantValues = [
        "\"reasoning\"", "\"reasoning_summary\"", "\"function_call_output\"",
        "\"custom_tool_call_output\"", "\"web_search_call\"", "\"ghost_snapshot\""
    ].map { Data($0.utf8) }
    private static let inspectionLimit = 8 * 1024

    static func classify(_ row: Data) -> SkillJSONLRowClassification {
        let prefix = row.prefix(inspectionLimit)
        if relevantValues.contains(where: { prefix.range(of: $0) != nil }) {
            return .parse
        }
        if irrelevantValues.contains(where: { prefix.range(of: $0) != nil }) {
            return .irrelevant
        }
        return .parse
    }
}
