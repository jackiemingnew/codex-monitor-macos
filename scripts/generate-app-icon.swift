import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resourcesDirectory = CommandLine.arguments.dropFirst().first.map {
    URL(fileURLWithPath: $0, isDirectory: true)
} ?? root.appendingPathComponent("Resources", isDirectory: true)
let iconsetDirectory = resourcesDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let icnsURL = resourcesDirectory.appendingPathComponent("AppIcon.icns")

try FileManager.default.createDirectory(at: resourcesDirectory, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconsetDirectory)
try FileManager.default.createDirectory(at: iconsetDirectory, withIntermediateDirectories: true)

let iconFiles: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for iconFile in iconFiles {
    let image = makeIcon(pixelSize: iconFile.pixels)
    let destination = iconsetDirectory.appendingPathComponent(iconFile.name)
    try writePNG(image, to: destination)
}

try? FileManager.default.removeItem(at: icnsURL)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
    "-c",
    "icns",
    iconsetDirectory.path,
    "-o",
    icnsURL.path
]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    throw NSError(
        domain: "CodexNotchIcon",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "iconutil failed"]
    )
}

try? FileManager.default.removeItem(at: iconsetDirectory)

print("Generated \(icnsURL.path)")

func makeIcon(pixelSize: Int) -> NSImage {
    let size = NSSize(width: pixelSize, height: pixelSize)
    let image = NSImage(size: size)
    image.lockFocus()

    let rect = NSRect(origin: .zero, size: size)
    NSColor.clear.setFill()
    rect.fill()

    let radius = CGFloat(pixelSize) * 0.22
    let basePath = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
    NSGradient(
        starting: NSColor(calibratedRed: 0.01, green: 0.012, blue: 0.015, alpha: 1),
        ending: NSColor(calibratedRed: 0.035, green: 0.045, blue: 0.055, alpha: 1)
    )?.draw(in: basePath, angle: -45)

    let islandRect = NSRect(
        x: CGFloat(pixelSize) * 0.15,
        y: CGFloat(pixelSize) * 0.30,
        width: CGFloat(pixelSize) * 0.70,
        height: CGFloat(pixelSize) * 0.40
    )
    let islandPath = NSBezierPath(
        roundedRect: islandRect,
        xRadius: islandRect.height * 0.50,
        yRadius: islandRect.height * 0.50
    )
    NSColor.black.withAlphaComponent(0.94).setFill()
    islandPath.fill()

    let glowSize = CGFloat(pixelSize) * 0.25
    let glowRect = NSRect(
        x: CGFloat(pixelSize) * 0.19,
        y: CGFloat(pixelSize) * 0.375,
        width: glowSize,
        height: glowSize
    )
    NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 1.0, blue: 0.45, alpha: 0.34),
        NSColor(calibratedRed: 0.20, green: 1.0, blue: 0.45, alpha: 0.00)
    ])?.draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: .zero)

    let dotSize = CGFloat(pixelSize) * 0.115
    let dotRect = NSRect(
        x: CGFloat(pixelSize) * 0.255,
        y: CGFloat(pixelSize) * 0.442,
        width: dotSize,
        height: dotSize
    )
    NSColor(calibratedRed: 0.20, green: 1.0, blue: 0.45, alpha: 1).setFill()
    NSBezierPath(ovalIn: dotRect).fill()

    let graphPath = NSBezierPath()
    graphPath.lineWidth = max(2, CGFloat(pixelSize) * 0.032)
    graphPath.lineCapStyle = .round
    graphPath.lineJoinStyle = .round
    let startX = CGFloat(pixelSize) * 0.46
    let midY = CGFloat(pixelSize) * 0.50
    graphPath.move(to: NSPoint(x: startX, y: midY))
    graphPath.line(to: NSPoint(x: CGFloat(pixelSize) * 0.54, y: CGFloat(pixelSize) * 0.50))
    graphPath.line(to: NSPoint(x: CGFloat(pixelSize) * 0.60, y: CGFloat(pixelSize) * 0.40))
    graphPath.line(to: NSPoint(x: CGFloat(pixelSize) * 0.67, y: CGFloat(pixelSize) * 0.61))
    graphPath.line(to: NSPoint(x: CGFloat(pixelSize) * 0.76, y: CGFloat(pixelSize) * 0.50))
    NSColor(calibratedRed: 0.30, green: 0.74, blue: 1.0, alpha: 1).setStroke()
    graphPath.stroke()

    let bottomLine = NSBezierPath()
    bottomLine.lineWidth = max(1, CGFloat(pixelSize) * 0.018)
    bottomLine.move(to: NSPoint(x: CGFloat(pixelSize) * 0.18, y: CGFloat(pixelSize) * 0.22))
    bottomLine.line(to: NSPoint(x: CGFloat(pixelSize) * 0.82, y: CGFloat(pixelSize) * 0.22))
    NSColor(calibratedRed: 0.0, green: 0.55, blue: 0.78, alpha: 0.95).setStroke()
    bottomLine.stroke()

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: "CodexNotchIcon",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG data"]
        )
    }
    try pngData.write(to: url)
}
