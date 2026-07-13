import CoreGraphics
import Foundation

let screenFrame = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
let visibleFrame = CGRect(x: 0, y: 70, width: 1_920, height: 980)

let defaultTopEdge = IslandMetrics.floatingHUDTopEdge(
    screenFrame: screenFrame,
    visibleFrame: visibleFrame,
    avoidsMenuBarReveal: false
)
guard defaultTopEdge == screenFrame.maxY else {
    fatalError("default floating HUD placement must preserve the notch-aligned top edge")
}

let compatibleTopEdge = IslandMetrics.floatingHUDTopEdge(
    screenFrame: screenFrame,
    visibleFrame: visibleFrame,
    avoidsMenuBarReveal: true
)
let maximumSafeTopEdge = visibleFrame.maxY - IslandMetrics.menuBarRevealSafetyGap
guard compatibleTopEdge <= maximumSafeTopEdge else {
    fatalError(
        "Barbee-compatible floating HUD placement must stay below the menu bar reveal zone "
            + "(actual: \(compatibleTopEdge), maximum: \(maximumSafeTopEdge))"
    )
}

var menuBarCompatibility = MenuBarRevealCompatibility(barbeeIsRunning: true)
guard !menuBarCompatibility.handleApplicationLifecycle(
    bundleIdentifier: "com.apple.TextEdit",
    didLaunch: false
) else {
    fatalError("unrelated application lifecycle events must not change Barbee compatibility")
}
guard menuBarCompatibility.avoidsMenuBarReveal else {
    fatalError("an unrelated application event must not move the HUD back into the menu bar")
}
guard menuBarCompatibility.handleApplicationLifecycle(
    bundleIdentifier: MenuBarRevealCompatibility.barbeeBundleIdentifier,
    didLaunch: false
), !menuBarCompatibility.avoidsMenuBarReveal else {
    fatalError("terminating Barbee must disable the menu bar reveal avoidance")
}
guard menuBarCompatibility.handleApplicationLifecycle(
    bundleIdentifier: MenuBarRevealCompatibility.barbeeBundleIdentifier,
    didLaunch: true
), menuBarCompatibility.avoidsMenuBarReveal else {
    fatalError("launching Barbee must enable the menu bar reveal avoidance")
}

let detailHeight: CGFloat = 488
let verticalRange = IslandMetrics.floatingHUDTopEdgeRange(
    screenFrame: screenFrame,
    visibleFrame: visibleFrame,
    detailHeight: detailHeight,
    avoidsMenuBarReveal: true
)
let lowestTopEdge = IslandMetrics.floatingHUDTopEdge(
    screenFrame: screenFrame,
    visibleFrame: visibleFrame,
    detailHeight: detailHeight,
    avoidsMenuBarReveal: true,
    normalizedVerticalPosition: 1
)
guard lowestTopEdge == verticalRange.lowerBound else {
    fatalError("the lowest normalized vertical position must reach the safe lower bound")
}
let lowestDetailBottom = lowestTopEdge
    - IslandMetrics.collapsedHeight
    - detailHeight
    + IslandMetrics.detailOverlap
guard lowestDetailBottom >= visibleFrame.minY else {
    fatalError("vertical dragging must keep the expanded detail panel inside the visible screen")
}

let middleTopEdge = IslandMetrics.floatingHUDTopEdge(
    screenFrame: screenFrame,
    visibleFrame: visibleFrame,
    detailHeight: detailHeight,
    avoidsMenuBarReveal: true,
    normalizedVerticalPosition: 0.5
)
let restoredVerticalPosition = IslandMetrics.normalizedOverlayVerticalPosition(
    topEdge: middleTopEdge,
    screenFrame: screenFrame,
    visibleFrame: visibleFrame,
    detailHeight: detailHeight,
    avoidsMenuBarReveal: true
)
guard abs(restoredVerticalPosition - 0.5) < 0.001 else {
    fatalError("normalized vertical position must round-trip")
}

let dragScreenFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)
let dragTopEdgeRange: ClosedRange<CGFloat> = 430...900
var dragSession = OverlayDragSession(
    pointer: CGPoint(x: 720, y: 800),
    centerX: 720,
    topEdge: 850
)
let movedPosition = dragSession.update(
    pointer: CGPoint(x: 820, y: 700),
    screenFrame: dragScreenFrame,
    topEdgeRange: dragTopEdgeRange
)
guard movedPosition.centerX == 820, movedPosition.topEdge == 750 else {
    fatalError("overlay drag must follow horizontal and vertical pointer movement one-to-one")
}
let bottomClampedPosition = dragSession.update(
    pointer: CGPoint(x: 820, y: 100),
    screenFrame: dragScreenFrame,
    topEdgeRange: dragTopEdgeRange
)
guard bottomClampedPosition.topEdge == dragTopEdgeRange.lowerBound else {
    fatalError("overlay drag must clamp at the lower vertical edge")
}
let reversedPosition = dragSession.update(
    pointer: CGPoint(x: 820, y: 101),
    screenFrame: dragScreenFrame,
    topEdgeRange: dragTopEdgeRange
)
guard reversedPosition.topEdge == dragTopEdgeRange.lowerBound + 1 else {
    fatalError("overlay drag must leave a clamped vertical edge after one point of reverse movement")
}

print("HUD placement regression tests passed")
