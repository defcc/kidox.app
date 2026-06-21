import AppKit
import Foundation

@MainActor
enum DesktopWallpaperProvider {
    private static var cachedURL: URL?
    private static var cachedImage: NSImage?

    static func currentWallpaperImage() async -> NSImage? {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            return nil
        }

        if cachedURL == url, let cachedImage {
            return cachedImage
        }

        let image = await Task.detached(priority: .utility) {
            NSImage(contentsOf: url)
        }.value

        cachedURL = url
        cachedImage = image
        return image
    }

    static func clearCache() {
        cachedURL = nil
        cachedImage = nil
    }
}
