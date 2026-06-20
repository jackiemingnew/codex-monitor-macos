import Foundation
import SwiftUI

enum BalancePanelState: Equatable {
    case disabled
    case notConfigured
    case loading
    case healthy
    case warning
    case error
}

enum BalanceAccountState: Equatable {
    case healthy
    case warning
    case error

    var label: String {
        switch self {
        case .healthy:
            "正常"
        case .warning:
            "提醒"
        case .error:
            "异常"
        }
    }

    var color: Color {
        switch self {
        case .healthy:
            Color(red: 0.61, green: 0.95, blue: 0.68)
        case .warning:
            Color(red: 1.0, green: 0.55, blue: 0.25)
        case .error:
            Color(red: 1.0, green: 0.28, blue: 0.30)
        }
    }

    var severity: RemoteAlertSeverity {
        switch self {
        case .healthy:
            .none
        case .warning:
            .warning
        case .error:
            .error
        }
    }
}

struct BalanceAccount: Identifiable, Equatable {
    let id: String
    let source: BalanceMonitorSource
    let name: String
    let kind: String
    let statusCode: Int?
    let amountText: String
    let usedText: String?
    let requestCount: Int?
    let updatedAt: String?
    let state: BalanceAccountState

    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(source.title) 账户" : name
    }

    var detailText: String {
        var parts = [kind]
        if let usedText {
            parts.append("已用 \(usedText)")
        }
        if let requestCount {
            parts.append("请求 \(requestCount)")
        }
        if let updatedAt, !updatedAt.isEmpty {
            parts.append(updatedAt)
        }
        return parts.joined(separator: " · ")
    }
}

struct BalanceMonitorSnapshot: Equatable {
    var source: BalanceMonitorSource
    var panelState: BalancePanelState
    var accounts: [BalanceAccount]
    var message: String?
    var lastUpdated: Date?

    static func disabled(source: BalanceMonitorSource) -> BalanceMonitorSnapshot {
        BalanceMonitorSnapshot(
            source: source,
            panelState: .disabled,
            accounts: [],
            message: "\(source.title) 监测未启用",
            lastUpdated: nil
        )
    }

    static func notConfigured(source: BalanceMonitorSource) -> BalanceMonitorSnapshot {
        BalanceMonitorSnapshot(
            source: source,
            panelState: .notConfigured,
            accounts: [],
            message: "请在设置中填写 \(source.title) 地址和访问密钥",
            lastUpdated: nil
        )
    }

    var panelSeverity: RemoteAlertSeverity {
        switch panelState {
        case .disabled, .notConfigured, .loading, .healthy:
            return accountSeverity
        case .warning:
            return max(.warning, accountSeverity)
        case .error:
            return .error
        }
    }

    var healthyCount: Int {
        accounts.filter { $0.state == .healthy }.count
    }

    var warningCount: Int {
        accounts.filter { $0.state == .warning }.count
    }

    var errorCount: Int {
        accounts.filter { $0.state == .error }.count
    }

    var totalAmountText: String {
        let values = accounts.compactMap { account -> Double? in
            guard account.amountText.hasPrefix("$") else {
                return nil
            }
            return Double(account.amountText.dropFirst())
        }
        guard !values.isEmpty else {
            return accounts.first?.amountText ?? "--"
        }
        return Self.currencyText(values.reduce(0, +))
    }

    var summaryText: String {
        if accounts.isEmpty {
            return message ?? "暂无账户"
        }
        var parts = ["正常 \(healthyCount)"]
        if warningCount > 0 {
            parts.append("提醒 \(warningCount)")
        }
        if errorCount > 0 {
            parts.append("异常 \(errorCount)")
        }
        return parts.joined(separator: " · ")
    }

    private var accountSeverity: RemoteAlertSeverity {
        accounts.reduce(.none) { max($0, $1.state.severity) }
    }

    static func currencyText(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}
