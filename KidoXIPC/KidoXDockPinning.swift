import Foundation

public enum KidoXDockPinning {
    public static func pinKidoXAppIfNeeded() {
        pinAppIfNeeded(at: Bundle.main.bundleURL, label: displayName)
    }

    public static func isKidoXAppPinned() -> Bool {
        isAppPinned(at: Bundle.main.bundleURL)
    }

    private static var displayName: String {
        let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        return displayName ?? bundleName ?? Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
    }

    private static func pinAppIfNeeded(at appURL: URL, label: String) {
        let appURL = appURL.standardizedFileURL
        guard appURL.pathExtension == "app" else { return }

        writeDebugLog("Pinning requested for appURL=\(appURL.path)")
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        let persistentApps = dockDefaults?.array(forKey: "persistent-apps") ?? []
        guard !containsWellFormedDockTile(for: appURL, in: persistentApps) else {
            writeDebugLog("Skipping Dock pinning because a well-formed dock-extra tile already exists")
            return
        }

        writeDebugLog("Rewriting Dock tile with dock-extra=1")
        var updatedApps = persistentApps.filter { item in
            !isDockTile(item, for: appURL)
        }
        updatedApps.append(dockTile(for: appURL, label: label))
        dockDefaults?.set(updatedApps, forKey: "persistent-apps")
        dockDefaults?.synchronize()
        writeDebugLog("Updated com.apple.dock persistent-apps; relaunching Dock")
        relaunchDock()
    }

    private static func isAppPinned(at appURL: URL) -> Bool {
        let appURL = appURL.standardizedFileURL
        guard appURL.pathExtension == "app" else { return false }

        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        dockDefaults?.synchronize()
        let persistentApps = dockDefaults?.array(forKey: "persistent-apps") ?? []
        return containsWellFormedDockTile(for: appURL, in: persistentApps)
    }

    private static func containsWellFormedDockTile(for appURL: URL, in persistentApps: [Any]) -> Bool {
        persistentApps.contains { item in
            guard isDockTile(item, for: appURL),
                  let item = item as? [String: Any],
                  let tileData = item["tile-data"] as? [String: Any],
                  let fileData = tileData["file-data"] as? [String: Any]
            else { return false }

            return fileData["_CFURLStringType"] as? Int == 15
                && tileData["dock-extra"] as? Int == 1
        }
    }

    private static func isDockTile(_ item: Any, for appURL: URL) -> Bool {
        guard
            let item = item as? [String: Any],
            let tileData = item["tile-data"] as? [String: Any],
            let fileData = tileData["file-data"] as? [String: Any],
            let urlString = fileData["_CFURLString"] as? String
        else {
            return false
        }

        return normalizedPath(from: urlString) == appURL.path
    }

    private static func dockTile(for appURL: URL, label: String) -> [String: Any] {
        [
            "tile-type": "file-tile",
            "tile-data": [
                "dock-extra": 1,
                "file-data": [
                    "_CFURLString": appURL.absoluteString,
                    "_CFURLStringType": 15
                ],
                "file-label": label,
                "file-type": 41
            ]
        ]
    }

    private static func normalizedPath(from dockURLString: String) -> String? {
        if dockURLString.hasPrefix("file://") {
            return URL(string: dockURLString)?.standardizedFileURL.path
        }

        return URL(fileURLWithPath: dockURLString).standardizedFileURL.path
    }

    private static func relaunchDock() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        do {
            try process.run()
            writeDebugLog("Started killall Dock")
        } catch {
            writeDebugLog("Failed to run killall Dock: \(error.localizedDescription)")
        }
    }

    private static func writeDebugLog(_ message: String) {
        let fileManager = FileManager.default
        let logsDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        let logURL = logsDirectory.appendingPathComponent("KidoXDockIcon.log")

        do {
            try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            let line = "[\(ISO8601DateFormatter().string(from: Date()))] [KidoX] \(message)\n"
            if let data = line.data(using: .utf8) {
                if fileManager.fileExists(atPath: logURL.path),
                   let handle = try? FileHandle(forWritingTo: logURL) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: logURL, options: .atomic)
                }
            }
        } catch {
            NSLog("KidoX failed to write Dock pinning debug log: %@", error.localizedDescription)
        }
    }
}
