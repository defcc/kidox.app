import AppKit
import Foundation

public enum KidoXDockIcon: String, CaseIterable, Identifiable, Sendable {
    case standard
    case minimal

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: "Default"
        case .minimal:  "Minimal"
        }
    }

    var resourceName: String {
        switch self {
        case .standard: "KidoX"
        case .minimal:  "KidoXMinimal"
        }
    }
}

public enum KidoXDockIconPreference {
    public static let defaultsSuiteName = "com.clyapps.KidoX"
    public static let key = "KidoX.dockIcon"

    public static var current: KidoXDockIcon {
        get {
            let rawValue = defaults.string(forKey: key)
            return rawValue.flatMap(KidoXDockIcon.init(rawValue:)) ?? .standard
        }
        set {
            defaults.set(newValue.rawValue, forKey: key)
        }
    }

    @MainActor
    public static func applyCurrentIcon(bundle: Bundle = .main, application: NSApplication = .shared) {
        apply(current, bundle: bundle, application: application)
    }

    @MainActor
    public static func apply(
        _ icon: KidoXDockIcon,
        bundle: Bundle = .main,
        application: NSApplication = .shared
    ) {
        writeDebugLog("Applying Dock icon preference: \(icon.rawValue)")
        current = icon
        defaults.synchronize()
        guard let image = icon.image(in: bundle) else {
            writeDebugLog("Failed to load Dock icon image resource: \(icon.resourceName)")
            return
        }
        writeDebugLog("Loaded Dock icon image resource: \(icon.resourceName)")
        application.applicationIconImage = image
        applyDockTileImage(image, application: application)
        postDockIconChangedNotification(icon)
        application.dockTile.display()
        writeDebugLog("Applied Dock icon preference in app process: \(icon.rawValue)")
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: defaultsSuiteName) ?? .standard
    }

    private static func postDockIconChangedNotification(_ icon: KidoXDockIcon) {
        writeDebugLog("Posting Dock icon change notification: \(KidoXIPC.dockIconChangedNotificationName.rawValue), icon=\(icon.rawValue)")
        DistributedNotificationCenter.default().postNotificationName(
            KidoXIPC.dockIconChangedNotificationName,
            object: nil,
            userInfo: ["dockIcon": icon.rawValue],
            deliverImmediately: true
        )
        writeDebugLog("Posted Dock icon change notification")
    }

    @MainActor
    private static func applyDockTileImage(_ image: NSImage, application: NSApplication) {
        let dockTile = application.dockTile
        let tileSize = dockTile.size == .zero ? NSSize(width: 512, height: 512) : dockTile.size
        let container = NSView(frame: NSRect(origin: .zero, size: tileSize))
        let imageView = NSImageView(frame: container.bounds)
        imageView.autoresizingMask = [.width, .height]
        imageView.image = image
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(imageView)

        dockTile.contentView = container
        dockTile.display()
        writeDebugLog("Updated NSApplication dockTile contentView in app process")
    }

    private static func writeDebugLog(_ message: String) {
        let directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        let logURL = directoryURL.appendingPathComponent("KidoXDockIcon.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [KidoX] \(message)\n"

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
            try handle.close()
        } catch {
            assertionFailure("Failed to write Dock icon debug log: \(error)")
        }
    }
}

private extension KidoXDockIcon {
    func image(in bundle: Bundle) -> NSImage? {
        if let url = bundle.url(forResource: resourceName, withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        return NSImage(named: NSImage.Name(resourceName))
    }
}
