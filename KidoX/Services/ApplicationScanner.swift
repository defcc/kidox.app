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
        let localizedName = localizedApplicationName(bundle: bundle, info: info, fallbackURL: url)
            ?? info?["CFBundleDisplayName"] as? String
            ?? info?["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent

        let bundleIdentifier = bundle?.bundleIdentifier
        let applicationCategory = info?["LSApplicationCategoryType"] as? String
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
            applicationCategory: applicationCategory,
            version: version,
            sourcePath: url.path,
            sortIndex: fallbackIndex,
            addedAt: addedAt
        )
    }

    private static func localizedApplicationName(
        bundle: Bundle?,
        info: [String: Any]?,
        fallbackURL: URL
    ) -> String? {
        let keys = ["CFBundleDisplayName", "CFBundleName"]
        let selectedLanguage = KidoXLanguage.selected(
            from: UserDefaults.standard.string(forKey: KidoXLanguage.storageKey) ?? KidoXLanguage.system.rawValue
        )

        if selectedLanguage == .system {
            return keys.compactMap { bundle?.localizedInfoDictionary?[$0] as? String }.firstNonEmptyString
        }

        for identifier in selectedLanguage.bundleLocalizationIdentifiers {
            if let localized = localizedInfoPlistString(in: bundle, lprojIdentifier: identifier, keys: keys) {
                return localized
            }
            if let localized = localizedInfoPlistLoctableString(in: bundle, localizationIdentifier: identifier, keys: keys) {
                return localized
            }
        }

        return localizedNameFromFileSystem(fallbackURL)
    }

    private static func localizedInfoPlistString(
        in bundle: Bundle?,
        lprojIdentifier: String,
        keys: [String]
    ) -> String? {
        guard
            let url = bundle?.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil, localization: lprojIdentifier),
            let strings = NSDictionary(contentsOf: url) as? [String: String]
        else {
            return nil
        }

        return keys.compactMap { strings[$0] }.firstNonEmptyString
    }

    private static func localizedInfoPlistLoctableString(
        in bundle: Bundle?,
        localizationIdentifier: String,
        keys: [String]
    ) -> String? {
        guard
            let loctableURL = bundle?.url(forResource: "InfoPlist", withExtension: "loctable"),
            let table = NSDictionary(contentsOf: loctableURL) as? [String: Any],
            let localizedStrings = table[localizationIdentifier] as? [String: String]
        else {
            return nil
        }

        return keys.compactMap { localizedStrings[$0] }.firstNonEmptyString
    }

    private static func localizedNameFromFileSystem(_ url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName)
            .flatMap { name in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed.replacingOccurrences(of: ".app", with: "")
            }
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

private extension KidoXLanguage {
    var bundleLocalizationIdentifiers: [String] {
        switch self {
        case .system:
            []
        case .english:
            ["en", "English"]
        case .simplifiedChinese:
            ["zh-Hans", "zh_CN", "zh-Hans-CN", "zh"]
        case .japanese:
            ["ja", "Japanese"]
        }
    }
}

private extension Array where Element == String {
    var firstNonEmptyString: String? {
        for value in self {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}
