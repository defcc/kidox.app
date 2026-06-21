import Foundation

struct ApplicationScanner: Sendable {
    var scanRoots: [URL] {
        let fileManager = FileManager.default
        var roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true)
        ]

        if let homeApplications = fileManager.urls(for: .applicationDirectory, in: .userDomainMask).first {
            roots.append(homeApplications)
        }

        return roots
    }

    func scan() async -> [LaunchItem] {
        let roots = scanRoots
        return await Task.detached(priority: .userInitiated) {
            roots.flatMap { Self.scan(root: $0) }
                .deduplicatedByBundleOrPath()
                .sorted { lhs, rhs in
                    lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                }
                .enumerated()
                .map { index, item in
                    var copy = item
                    copy.sortIndex = index
                    return copy
                }
        }.value
    }

    private static func scan(root: URL) -> [LaunchItem] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return [] }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .localizedNameKey,
            .nameKey,
            .addedToDirectoryDateKey,
            .creationDateKey,
            .contentModificationDateKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var applications: [LaunchItem] = []

        for case let url as URL in enumerator {
            guard url.pathExtension == "app" else { continue }
            if let item = Self.makeApplicationItem(url: url, fallbackIndex: applications.count) {
                applications.append(item)
            }
            enumerator.skipDescendants()
        }

        return applications
    }

    static func makeApplicationItem(url: URL, fallbackIndex: Int = 0) -> LaunchItem? {
        guard url.pathExtension == "app" else { return nil }

        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary
        let localizedInfo = bundle?.localizedInfoDictionary

        let localizedName = localizedInfo?["CFBundleDisplayName"] as? String
            ?? localizedInfo?["CFBundleName"] as? String
            ?? info?["CFBundleDisplayName"] as? String
            ?? info?["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent

        let bundleIdentifier = bundle?.bundleIdentifier
        let version = info?["CFBundleShortVersionString"] as? String
        let parentName = url.deletingLastPathComponent().lastPathComponent
        let resourceValues = try? url.resourceValues(forKeys: [
            .addedToDirectoryDateKey,
            .creationDateKey,
            .contentModificationDateKey
        ])
        let addedAt = resourceValues?.addedToDirectoryDate
            ?? resourceValues?.creationDate
            ?? resourceValues?.contentModificationDate
            ?? Date()

        return LaunchItem(
            kind: .application,
            displayName: localizedName,
            subtitle: parentName,
            url: url,
            bundleIdentifier: bundleIdentifier,
            bundleName: info?["CFBundleName"] as? String,
            version: version,
            sourcePath: url.path,
            sortIndex: fallbackIndex,
            addedAt: addedAt
        )
    }
}

private extension Array where Element == LaunchItem {
    func deduplicatedByBundleOrPath() -> [LaunchItem] {
        var seen = Set<String>()
        var items: [LaunchItem] = []

        for item in self {
            let key = item.bundleIdentifier ?? item.sourcePath
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            items.append(item)
        }

        return items
    }
}
