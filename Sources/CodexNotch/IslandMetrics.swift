import CoreGraphics

enum IslandMetrics {
    static let shoulderWidth: CGFloat = 148
    static let notchWidth: CGFloat = 224
    static let collapsedWidth: CGFloat = 264
    static let collapsedHeight: CGFloat = 38
    static let collapsedPillHorizontalPadding: CGFloat = 10
    static let detailHeaderHeight: CGFloat = 22
    static let detailPageSwitcherHeight: CGFloat = 30
    static let detailTopPadding: CGFloat = 26
    static let detailBottomPadding: CGFloat = 12
    static let detailOverlap: CGFloat = 18
    static let detailQuotaHeight: CGFloat = 66
    static let detailSparkHeight: CGFloat = 32
    static let detailTaskHeaderHeight: CGFloat = 28
    static let detailTaskRowHeight: CGFloat = 34
    static let detailTaskEmptySpace: CGFloat = 50
    static let detailPeriodFooterHeight: CGFloat = 44
    static let minimumDetailHeight: CGFloat = 390
    static let visibleTaskRows = 5

    static var detailHeight: CGFloat {
        detailHeight(taskRows: 2, showsPeriodUsage: true, showsSparkQuota: false)
    }

    static var width: CGFloat {
        shoulderWidth * 2 + notchWidth
    }

    static func clampedOverlayCenterX(_ proposedCenterX: CGFloat, in screenFrame: CGRect) -> CGFloat {
        guard screenFrame.width >= width else {
            return screenFrame.midX
        }
        let halfDetailWidth = width / 2
        return min(
            max(proposedCenterX, screenFrame.minX + halfDetailWidth),
            screenFrame.maxX - halfDetailWidth
        )
    }

    static func overlayHorizontalTravel(in screenFrame: CGRect) -> CGFloat {
        max(0, (screenFrame.width - width) / 2)
    }

    static func overlayCenterX(normalizedPosition: CGFloat, in screenFrame: CGRect) -> CGFloat {
        let position = min(1, max(-1, normalizedPosition))
        return screenFrame.midX + position * overlayHorizontalTravel(in: screenFrame)
    }

    static func normalizedOverlayPosition(centerX: CGFloat, in screenFrame: CGRect) -> CGFloat {
        let travel = overlayHorizontalTravel(in: screenFrame)
        guard travel > 0 else {
            return 0
        }
        let clampedCenterX = clampedOverlayCenterX(centerX, in: screenFrame)
        return min(1, max(-1, (clampedCenterX - screenFrame.midX) / travel))
    }

    static func detailHeight(taskRows: Int, showsPeriodUsage: Bool, showsSparkQuota: Bool = false) -> CGFloat {
        let rows = max(1, min(visibleTaskRows, taskRows))
        let sparkHeight: CGFloat = showsSparkQuota ? 8 + detailSparkHeight : 0
        let periodHeight: CGFloat = showsPeriodUsage ? 12 + detailPeriodFooterHeight : 0
        let contentHeight = detailTopPadding
            + detailHeaderHeight
            + 10
            + detailPageSwitcherHeight
            + 10
            + detailQuotaHeight
            + 8
            + sparkHeight
            + taskTableHeight(taskRows: rows)
            + periodHeight
            + detailBottomPadding
        return max(minimumDetailHeight, ceil(contentHeight))
    }

    static func taskTableHeight(taskRows: Int) -> CGFloat {
        let rows = max(1, min(visibleTaskRows, taskRows))
        return detailTaskHeaderHeight
            + CGFloat(rows) * detailTaskRowHeight
            + detailTaskEmptySpace
    }

    static var visibleTaskRowsHeight: CGFloat {
        CGFloat(visibleTaskRows) * detailTaskRowHeight
    }

    static func remoteDetailHeight(accountRows: Int, usesTallRows: Bool = false) -> CGFloat {
        let rows = max(1, min(4, accountRows))
        let rowHeight: CGFloat = usesTallRows ? 74 : 62
        let accountStackHeight = CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1)) * 7
        let cpaUsageHeight: CGFloat = 47
        let contentHeight = detailTopPadding
            + detailHeaderHeight
            + 10
            + detailPageSwitcherHeight
            + 10
            + 36
            + 8
            + accountStackHeight
            + 8
            + cpaUsageHeight
            + detailBottomPadding
        return max(minimumDetailHeight, ceil(contentHeight))
    }
}

struct OverlayDragSession {
    private var anchorPointerX: CGFloat
    private var anchorCenterX: CGFloat

    init(pointerX: CGFloat, centerX: CGFloat) {
        anchorPointerX = pointerX
        anchorCenterX = centerX
    }

    mutating func update(pointerX: CGFloat, in screenFrame: CGRect) -> CGFloat {
        let proposedCenterX = anchorCenterX + pointerX - anchorPointerX
        let centerX = IslandMetrics.clampedOverlayCenterX(proposedCenterX, in: screenFrame)
        if centerX != proposedCenterX {
            anchorPointerX = pointerX
            anchorCenterX = centerX
        }
        return centerX
    }
}
