import AppKit
import Foundation
import ImageIO

@MainActor
enum DesktopWallpaperProvider {
    private static let maxCachedWallpaperLongEdgePixels = 4096

    private static var cachedURL: URL?
    private static var cachedImage: NSImage?
    private static var cachedMaxPixelSize = 0

    static func cachedWallpaperImage() -> NSImage? {
        guard let context = currentWallpaperContext(),
              cachedURL == context.url,
              cachedMaxPixelSize >= context.maxPixelSize
        else {
            return nil
        }

        return cachedImage
    }

    static func currentWallpaperImage() async -> NSImage? {
        guard let context = currentWallpaperContext() else {
            return nil
        }

        if cachedURL == context.url,
           cachedMaxPixelSize >= context.maxPixelSize,
           let cachedImage {
            return cachedImage
        }

        let url = context.url
        let maxPixelSize = context.maxPixelSize
        let image = await Task.detached(priority: .utility) {
            downsampledImage(contentsOf: url, maxPixelSize: maxPixelSize)
        }.value

        cachedURL = url
        cachedImage = image
        cachedMaxPixelSize = image == nil ? 0 : maxPixelSize
        return image
    }

    private static func currentWallpaperContext() -> (url: URL, maxPixelSize: Int)? {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen,
              let url = NSWorkspace.shared.desktopImageURL(for: screen)
        else {
            return nil
        }

        let screenLongEdgePixels = Int(ceil(max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor))
        let maxPixelSize = max(1024, min(screenLongEdgePixels, maxCachedWallpaperLongEdgePixels))
        return (url, maxPixelSize)
    }

    nonisolated private static func downsampledImage(contentsOf url: URL, maxPixelSize: Int) -> NSImage? {
        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    static func clearCache() {
        cachedURL = nil
        cachedImage = nil
        cachedMaxPixelSize = 0
    }
}
