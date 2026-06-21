import AppKit
import Foundation

func envString(_ key: String, _ fallback: String) -> String {
    ProcessInfo.processInfo.environment[key] ?? fallback
}

func envDouble(_ key: String, _ fallback: Double) -> Double {
    guard let value = ProcessInfo.processInfo.environment[key],
          let number = Double(value) else {
        return fallback
    }
    return number
}

let outputURL = URL(fileURLWithPath: envString("DMG_BACKGROUND_OUTPUT", "/private/tmp/KidoXDMG/assets/dmg-background.png"))
let arrowURL = URL(fileURLWithPath: envString("DMG_ARROW_IMAGE", "Packaging/DMG/assets/install-arrow.png"))

let width = envDouble("DMG_WINDOW_WIDTH", 720)
let height = envDouble("DMG_WINDOW_HEIGHT", 440)
let scale = Int(envDouble("DMG_BACKGROUND_SCALE", 2))
let size = NSSize(width: width, height: height)

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(width) * scale,
    pixelsHigh: Int(height) * scale,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
rep.size = size

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let bounds = NSRect(origin: .zero, size: size)
NSColor(calibratedRed: 0.972, green: 0.978, blue: 0.986, alpha: 1).setFill()
bounds.fill()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.988, green: 0.992, blue: 0.996, alpha: 1),
    NSColor(calibratedRed: 0.936, green: 0.958, blue: 0.980, alpha: 1)
])!
gradient.draw(in: bounds, angle: 90)

let text = NSColor(calibratedWhite: 0.13, alpha: 1)
let secondary = NSColor(calibratedWhite: 0.36, alpha: 1)

let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 27, weight: .semibold),
    .foregroundColor: text
]
let subtitleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 14, weight: .regular),
    .foregroundColor: secondary
]

"Install KidoX".draw(
    at: NSPoint(x: envDouble("DMG_TITLE_X", 48), y: envDouble("DMG_TITLE_Y", 350)),
    withAttributes: titleAttrs
)
"Drag the app icon into Applications.".draw(
    at: NSPoint(x: envDouble("DMG_SUBTITLE_X", 50), y: envDouble("DMG_SUBTITLE_Y", 324)),
    withAttributes: subtitleAttrs
)

let cardRect = NSRect(
    x: envDouble("DMG_CARD_X", 56),
    y: envDouble("DMG_CARD_Y", 82),
    width: envDouble("DMG_CARD_WIDTH", 608),
    height: envDouble("DMG_CARD_HEIGHT", 220)
)
let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 22, yRadius: 22)
NSColor.white.withAlphaComponent(0.72).setFill()
cardPath.fill()
NSColor(calibratedWhite: 0.72, alpha: 0.28).setStroke()
cardPath.lineWidth = 1
cardPath.stroke()

if let arrow = NSImage(contentsOf: arrowURL) {
    arrow.draw(
        in: NSRect(
            x: envDouble("DMG_ARROW_X", 282),
            y: envDouble("DMG_ARROW_Y", 145),
            width: envDouble("DMG_ARROW_WIDTH", 156),
            height: envDouble("DMG_ARROW_HEIGHT", 73)
        ),
        from: .zero,
        operation: .sourceOver,
        fraction: CGFloat(envDouble("DMG_ARROW_OPACITY", 0.84))
    )
}

let footerAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
    .foregroundColor: NSColor(calibratedWhite: 0.48, alpha: 1)
]
"Launch KidoX from Applications after copying.".draw(
    at: NSPoint(x: envDouble("DMG_FOOTER_X", 50), y: envDouble("DMG_FOOTER_Y", 34)),
    withAttributes: footerAttrs
)

NSGraphicsContext.restoreGraphicsState()

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Could not render DMG background.")
}

try png.write(to: outputURL)
