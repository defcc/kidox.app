import AppKit
import Foundation

struct ApplicationUninstallTarget: Hashable, Sendable {
    let url: URL
    let byteCount: Int64
}

struct ApplicationUninstallPlan: Sendable {
    let bundleIdentifier: String
    let appURL: URL
    let appByteCount: Int64
    let dataTargets: [ApplicationUninstallTarget]

    var dataByteCount: Int64 {
        dataTargets.reduce(0) { $0 + $1.byteCount }
    }

    var totalRecoverableByteCount: Int64 {
        appByteCount + dataByteCount
    }
}

struct ApplicationUninstallResult: Sendable {
    struct RemovalFailure: Sendable {
        let target: ApplicationUninstallTarget
        let errorDescription: String

        var url: URL {
            target.url
        }
    }

    let bundleIdentifier: String
    let appURL: URL
    let appByteCount: Int64
    let trashedAppURL: URL?
    let removedDataTargets: [ApplicationUninstallTarget]
    let failedDataRemovals: [RemovalFailure]

    var hasDataRemovalFailures: Bool {
        !failedDataRemovals.isEmpty
    }

    var removedDataURLs: [URL] {
        removedDataTargets.map(\.url)
    }

    var removedDataByteCount: Int64 {
        removedDataTargets.reduce(0) { $0 + $1.byteCount }
    }
}

private struct ApplicationUninstallMetadata: Sendable {
    let relatedBundleIdentifiers: Set<String>
    let appNames: Set<String>
    let vendorNames: Set<String>
    let productNames: Set<String>
}

enum ApplicationUninstallError: LocalizedError {
    case unsupportedItem
    case missingBundleIdentifier
    case missingApplication(URL)
    case protectedSystemApplication(URL)
    case trashTimedOut(URL)
    case trashFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .unsupportedItem:
            "Only applications can be uninstalled."
        case .missingBundleIdentifier:
            "This app does not have a bundle identifier, so KidoX cannot safely remove its stored data."
        case .missingApplication(let url):
            "The app could not be found at \(url.path)."
        case .protectedSystemApplication(let url):
            "\(url.lastPathComponent) is installed on the protected macOS system volume and cannot be moved to Trash by KidoX."
        case .trashTimedOut(let url):
            "Moving \(url.lastPathComponent) to Trash took too long. The app may be protected by macOS or blocked by a permissions prompt."
        case .trashFailed(let url, let reason):
            "Could not move \(url.lastPathComponent) to Trash. \(reason)"
        }
    }
}

private final class TrashMoveContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL?, Error>?

    init(_ continuation: CheckedContinuation<URL?, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<URL?, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else { return }

        switch result {
        case .success(let url):
            continuation.resume(returning: url)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

struct ApplicationUninstaller: Sendable {
    static func canUninstallApplication(at url: URL) -> Bool {
        !isProtectedSystemApplicationURL(url)
    }

    func makePlan(for item: LaunchItem) async throws -> ApplicationUninstallPlan {
        guard item.kind == .application else {
            throw ApplicationUninstallError.unsupportedItem
        }

        let bundleIdentifier = try Self.normalizedBundleIdentifier(from: item)
        let appURL = URL(fileURLWithPath: item.sourcePath)
        guard Self.canUninstallApplication(at: appURL) else {
            throw ApplicationUninstallError.protectedSystemApplication(appURL)
        }
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw ApplicationUninstallError.missingApplication(appURL)
        }

        return await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let metadata = Self.uninstallMetadata(
                mainBundleIdentifier: bundleIdentifier,
                appURL: appURL,
                fileManager: fileManager
            )
            let existingDataURLs = Self.dataURLs(metadata: metadata, fileManager: fileManager)
                .filter { fileManager.fileExists(atPath: $0.path) }
            let dataTargets = Self.deduplicatedFileSystemURLs(existingDataURLs)
                .map { ApplicationUninstallTarget(url: $0, byteCount: Self.allocatedByteCount(at: $0)) }

            return ApplicationUninstallPlan(
                bundleIdentifier: bundleIdentifier,
                appURL: appURL,
                appByteCount: Self.allocatedByteCount(at: appURL),
                dataTargets: dataTargets
            )
        }.value
    }

    func uninstall(_ item: LaunchItem) async throws -> ApplicationUninstallResult {
        let plan = try await makePlan(for: item)
        return try await uninstall(plan)
    }

    func uninstall(_ plan: ApplicationUninstallPlan) async throws -> ApplicationUninstallResult {
        guard Self.canUninstallApplication(at: plan.appURL) else {
            throw ApplicationUninstallError.protectedSystemApplication(plan.appURL)
        }
        guard FileManager.default.fileExists(atPath: plan.appURL.path) else {
            throw ApplicationUninstallError.missingApplication(plan.appURL)
        }

        let trashedAppURL = try await moveApplicationToTrash(plan.appURL)
        let dataRemoval = await Self.removeUserData(targets: plan.dataTargets)

        return ApplicationUninstallResult(
            bundleIdentifier: plan.bundleIdentifier,
            appURL: plan.appURL,
            appByteCount: plan.appByteCount,
            trashedAppURL: trashedAppURL,
            removedDataTargets: dataRemoval.removed,
            failedDataRemovals: dataRemoval.failed
        )
    }

    private func moveApplicationToTrash(_ url: URL) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            let continuationBox = TrashMoveContinuationBox(continuation)

            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                continuationBox.resume(.failure(ApplicationUninstallError.trashTimedOut(url)))
            }

            NSWorkspace.shared.recycle([url]) { newURLs, error in
                if let error {
                    continuationBox.resume(.failure(ApplicationUninstallError.trashFailed(
                        url,
                        error.localizedDescription
                    )))
                    return
                }

                continuationBox.resume(.success(newURLs[url]))
            }
        }
    }

    private static func normalizedBundleIdentifier(from item: LaunchItem) throws -> String {
        let bundleIdentifier = item.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            throw ApplicationUninstallError.missingBundleIdentifier
        }
        return bundleIdentifier
    }

    private static func isProtectedSystemApplicationURL(_ url: URL) -> Bool {
        let standardizedPath = url.standardizedFileURL.path
        return standardizedPath == "/System"
            || standardizedPath.hasPrefix("/System/")
            || standardizedPath == "/Library/Apple"
            || standardizedPath.hasPrefix("/Library/Apple/")
    }

    private static func removeUserData(
        targets: [ApplicationUninstallTarget]
    ) async -> (removed: [ApplicationUninstallTarget], failed: [ApplicationUninstallResult.RemovalFailure]) {
        await Task.detached(priority: .utility) {
            var removed: [ApplicationUninstallTarget] = []
            var failed: [ApplicationUninstallResult.RemovalFailure] = []
            let fileManager = FileManager.default

            for target in targets {
                let url = target.url
                guard fileManager.fileExists(atPath: url.path) else { continue }

                do {
                    try fileManager.removeItem(at: url)
                    removed.append(target)
                } catch {
                    failed.append(ApplicationUninstallResult.RemovalFailure(
                        target: target,
                        errorDescription: error.localizedDescription
                    ))
                }
            }

            return (removed, failed)
        }.value
    }

    private static func uninstallMetadata(
        mainBundleIdentifier: String,
        appURL: URL,
        fileManager: FileManager
    ) -> ApplicationUninstallMetadata {
        var identifiers: Set<String> = isReverseDNSBundleIdentifier(mainBundleIdentifier) ? [mainBundleIdentifier] : []
        var appNames: Set<String> = [appURL.deletingPathExtension().lastPathComponent]
        var inferredVendorNames: Set<String> = []
        var inferredProductNames: Set<String> = []
        if let tokens = bundleTokens(from: mainBundleIdentifier) {
            inferredVendorNames.formUnion(pathComponentVariants(for: tokens.vendor))
            inferredProductNames.formUnion(pathComponentVariants(for: tokens.product))
        }
        if let mainInfo = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")) {
            appNames.formUnion([
                mainInfo["CFBundleName"] as? String,
                mainInfo["CFBundleDisplayName"] as? String
            ].compactMap { $0 })
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey]

        guard let enumerator = fileManager.enumerator(
            at: appURL,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return ApplicationUninstallMetadata(
                relatedBundleIdentifiers: identifiers,
                appNames: sanitizedPathComponents(appNames),
                vendorNames: sanitizedPathComponents(inferredVendorNames),
                productNames: sanitizedPathComponents(inferredProductNames)
            )
        }

        for case let infoURL as URL in enumerator where infoURL.lastPathComponent == "Info.plist" {
            guard shouldCollectEmbeddedInfoPlist(infoURL, appURL: appURL) else { continue }
            guard let dictionary = NSDictionary(contentsOf: infoURL) else { continue }

            if let identifier = dictionary["CFBundleIdentifier"] as? String {
                let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
                if isReverseDNSBundleIdentifier(trimmedIdentifier),
                   trimmedIdentifier != mainBundleIdentifier,
                   !shouldSkipEmbeddedBundleIdentifier(trimmedIdentifier) {
                    identifiers.insert(trimmedIdentifier)
                    if let tokens = bundleTokens(from: trimmedIdentifier) {
                        inferredVendorNames.formUnion(pathComponentVariants(for: tokens.vendor))
                        inferredProductNames.formUnion(pathComponentVariants(for: tokens.product))
                    }
                }
            }

            // Embedded frameworks and helper apps often expose generic names
            // like Electron. Use them for bundle-id exact matches only, not
            // app-name directory matching.
        }

        return ApplicationUninstallMetadata(
            relatedBundleIdentifiers: identifiers,
            appNames: sanitizedPathComponents(appNames),
            vendorNames: sanitizedPathComponents(inferredVendorNames),
            productNames: sanitizedPathComponents(inferredProductNames)
        )
    }

    private static func shouldCollectEmbeddedInfoPlist(_ infoURL: URL, appURL: URL) -> Bool {
        let appPath = appURL.standardizedFileURL.path
        let infoPath = infoURL.standardizedFileURL.path
        let suffix = "/Contents/Info.plist"
        guard infoPath.hasSuffix(suffix) else { return false }

        let bundlePath = String(infoPath.dropLast(suffix.count))
        guard bundlePath != appPath else { return false }

        let bundleName = URL(fileURLWithPath: bundlePath).lastPathComponent
        switch bundleName.split(separator: ".").last?.lowercased() {
        case "xpc", "appex":
            return true
        case "app":
            return bundlePath.hasPrefix("\(appPath)/Contents/Library/LoginItems/")
        default:
            return false
        }
    }

    private static func shouldSkipEmbeddedBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier.hasPrefix("org.sparkle-project.")
    }

    private static func dataURLs(metadata: ApplicationUninstallMetadata, fileManager: FileManager) -> [URL] {
        guard let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return []
        }

        let exactLibraryChildren = metadata.relatedBundleIdentifiers.flatMap { bundleIdentifier in
            [
                "Application Scripts/\(bundleIdentifier)",
                "Application Support/FileProvider/\(bundleIdentifier)",
                "Application Support/\(bundleIdentifier)",
                "Autosave Information/\(bundleIdentifier)",
                "Caches/\(bundleIdentifier)",
                "Containers/\(bundleIdentifier)",
                "Cookies/\(bundleIdentifier).binarycookies",
                "HTTPStorages/\(bundleIdentifier)",
                "HTTPStorages/\(bundleIdentifier).binarycookies",
                "LaunchAgents/\(bundleIdentifier).plist",
                "Logs/\(bundleIdentifier)",
                "Preferences/\(bundleIdentifier).plist",
                "Saved Application State/\(bundleIdentifier).savedState",
                "SyncedPreferences/\(bundleIdentifier).plist",
                "WebKit/com.apple.WebKit.WebContent/\(bundleIdentifier)",
                "WebKit/\(bundleIdentifier)"
            ].map { libraryURL.appendingPathComponent($0) }
        }

        let appNameVariants = sanitizedPathComponents(Set(metadata.appNames.flatMap { pathComponentVariants(for: $0) }))
        let productNameVariants = sanitizedPathComponents(Set(metadata.productNames.flatMap { pathComponentVariants(for: $0) }))
        let appOrProductNameVariants = appNameVariants.union(productNameVariants)

        let directNameLibraryChildren = directNameLibraryURLs(libraryURL: libraryURL, appNames: metadata.appNames)
        let directNameHomeChildren = directNameHomeURLs(
            homeURL: fileManager.homeDirectoryForCurrentUser,
            appNames: metadata.appNames
        )

        let vendorNestedLibraryChildren = vendorNestedURLs(
            libraryURL: libraryURL,
            vendorNames: metadata.vendorNames,
            appNames: appOrProductNameVariants,
            fileManager: fileManager
        )

        let boundaryMatchedLibraryChildren = boundaryMatchedURLs(
            libraryURL: libraryURL,
            bundleIdentifiers: metadata.relatedBundleIdentifiers,
            fileManager: fileManager
        )

        let relatedPreferenceURLs = contents(
            of: libraryURL.appendingPathComponent("Preferences", isDirectory: true),
            fileManager: fileManager
        ).filter {
            metadata.relatedBundleIdentifiers.contains($0.deletingPathExtension().lastPathComponent)
                && $0.pathExtension == "plist"
        }

        let byHostPreferenceURLs = contents(
            of: libraryURL.appendingPathComponent("Preferences/ByHost", isDirectory: true),
            fileManager: fileManager
        ).filter {
            Self.isByHostPreferenceMatch(
                $0.deletingPathExtension().lastPathComponent,
                bundleIdentifiers: metadata.relatedBundleIdentifiers
            )
                && $0.pathExtension == "plist"
        }

        return Array(Set(
            exactLibraryChildren
                + directNameLibraryChildren
                + directNameHomeChildren
                + vendorNestedLibraryChildren
                + boundaryMatchedLibraryChildren
                + relatedPreferenceURLs
                + byHostPreferenceURLs
        ))
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func bundleTokens(from bundleIdentifier: String) -> (vendor: String, product: String)? {
        let parts = bundleIdentifier.split(separator: ".").map(String.init)
        guard parts.count >= 3 else { return nil }
        let vendor = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let product = parts[parts.count - 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUsefulBundleToken(vendor), isUsefulBundleToken(product) else { return nil }
        return (vendor, product)
    }

    private static func isReverseDNSBundleIdentifier(_ identifier: String) -> Bool {
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { character in
                character.isLetter || character.isNumber || character == "-"
            }
        }
    }

    private static func isUsefulBundleToken(_ token: String) -> Bool {
        token.count >= 3 && token.allSatisfy { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
        }
    }

    private static func pathComponentVariants(for component: String) -> Set<String> {
        let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var variants: Set<String> = [trimmed]
        if trimmed.contains(" ") {
            variants.insert(trimmed.replacingOccurrences(of: " ", with: ""))
            variants.insert(trimmed.replacingOccurrences(of: " ", with: "-"))
            variants.insert(trimmed.replacingOccurrences(of: " ", with: "_"))
        }

        for variant in Array(variants) {
            variants.insert(variant.lowercased())
            variants.insert(variant.capitalized)
        }

        return variants
    }

    private static func sanitizedPathComponents(_ components: Set<String>) -> Set<String> {
        Set(components.compactMap { component in
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.contains("/"),
                  trimmed != ".",
                  trimmed != ".."
            else {
                return nil
            }
            return trimmed
        })
    }

    private static func isByHostPreferenceMatch(_ candidate: String, bundleIdentifiers: Set<String>) -> Bool {
        bundleIdentifiers.contains(candidate) || bundleIdentifiers.contains { bundleIdentifier in
            nameStartsWithBundleIdentifierBoundary(candidate, bundleIdentifier: bundleIdentifier)
        }
    }

    private static func directNameLibraryURLs(libraryURL: URL, appNames: Set<String>) -> [URL] {
        directNameLibraryPathComponents(appNames: appNames).flatMap { appName in
            [
                "Application Support/\(appName)",
                "Caches/\(appName)",
                "Logs/\(appName)",
                "Preferences/\(appName)",
                "Preferences/\(appName).plist",
                "Saved Application State/\(appName).savedState"
            ].map { libraryURL.appendingPathComponent($0) }
        }
    }

    private static func directNameHomeURLs(homeURL: URL, appNames: Set<String>) -> [URL] {
        appNames.flatMap { appName -> [URL] in
            let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { return [] }

            let lowercaseName = trimmed.lowercased()
            var urls = [
                homeURL.appendingPathComponent(".config/\(trimmed)"),
                homeURL.appendingPathComponent(".cache/\(trimmed)"),
                homeURL.appendingPathComponent(".cache/\(lowercaseName)"),
                homeURL.appendingPathComponent(".local/share/\(trimmed)"),
                homeURL.appendingPathComponent(".\(trimmed)"),
                homeURL.appendingPathComponent(".\(trimmed)rc")
            ]

            if trimmed.count > 3 && trimmed.contains(" ") {
                let lowercaseVariants = Set([
                    trimmed.replacingOccurrences(of: " ", with: "").lowercased(),
                    trimmed.replacingOccurrences(of: " ", with: "-").lowercased(),
                    trimmed.replacingOccurrences(of: " ", with: "_").lowercased()
                ])
                urls += lowercaseVariants.flatMap { variant in
                    [
                        homeURL.appendingPathComponent(".config/\(variant)"),
                        homeURL.appendingPathComponent(".cache/\(variant)"),
                        homeURL.appendingPathComponent(".local/share/\(variant)")
                    ]
                }
            }

            return urls.filter { !belongsToIndependentCLIPath($0) }
        }
    }

    private static func directNameLibraryPathComponents(appNames: Set<String>) -> Set<String> {
        sanitizedPathComponents(Set(appNames.flatMap { appName -> [String] in
            let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { return [] }

            var components = [trimmed]
            if trimmed.count > 3 && trimmed.contains(" ") {
                components.append(trimmed.replacingOccurrences(of: " ", with: ""))
                components.append(trimmed.replacingOccurrences(of: " ", with: "_"))
                components.append(trimmed.replacingOccurrences(of: " ", with: "-"))
            }
            return components
        }))
    }

    private static func vendorNestedURLs(
        libraryURL: URL,
        vendorNames: Set<String>,
        appNames: Set<String>,
        fileManager: FileManager
    ) -> [URL] {
        guard !vendorNames.isEmpty, !appNames.isEmpty else { return [] }

        let vendorNamesLowercased = Set(vendorNames.map { $0.lowercased() })
        let appNamesLowercased = Set(appNames.map { $0.lowercased() })
        let roots = [
            libraryURL.appendingPathComponent("Application Support", isDirectory: true),
            libraryURL.appendingPathComponent("Caches", isDirectory: true),
            libraryURL.appendingPathComponent("Logs", isDirectory: true)
        ]

        return roots.flatMap { rootURL in
            contents(of: rootURL, fileManager: fileManager).flatMap { vendorURL -> [URL] in
                guard isDirectory(vendorURL),
                      vendorNamesLowercased.contains(vendorURL.lastPathComponent.lowercased())
                else {
                    return []
                }

                return contents(of: vendorURL, fileManager: fileManager).filter { childURL in
                    guard isDirectory(childURL) else { return false }
                    return appNamesLowercased.contains(childURL.lastPathComponent.lowercased())
                }
            }
        }
    }

    private static func boundaryMatchedURLs(
        libraryURL: URL,
        bundleIdentifiers: Set<String>,
        fileManager: FileManager
    ) -> [URL] {
        guard !bundleIdentifiers.isEmpty else { return [] }

        let scanRoots = [
            libraryURL.appendingPathComponent("Application Scripts", isDirectory: true),
            libraryURL.appendingPathComponent("Application Support/FileProvider", isDirectory: true),
            libraryURL.appendingPathComponent("Containers", isDirectory: true),
            libraryURL.appendingPathComponent("Group Containers", isDirectory: true)
        ]

        return scanRoots.flatMap { rootURL in
            contents(of: rootURL, fileManager: fileManager).filter { candidateURL in
                guard isDirectory(candidateURL) else { return false }
                return bundleIdentifiers.contains { bundleIdentifier in
                    nameHasBundleIdentifierBoundary(candidateURL.lastPathComponent, bundleIdentifier: bundleIdentifier)
                }
            }
        }
    }

    private static func nameHasBundleIdentifierBoundary(_ candidate: String, bundleIdentifier: String) -> Bool {
        nameStartsWithBundleIdentifierBoundary(candidate, bundleIdentifier: bundleIdentifier)
            || candidate.hasSuffix(".\(bundleIdentifier)")
            || candidate.contains(".\(bundleIdentifier).")
    }

    private static func nameStartsWithBundleIdentifierBoundary(_ candidate: String, bundleIdentifier: String) -> Bool {
        candidate == bundleIdentifier
            || candidate.hasPrefix("\(bundleIdentifier).")
    }

    private static func belongsToIndependentCLIPath(_ url: URL) -> Bool {
        let name = url.lastPathComponent.trimmingPrefix(".").lowercased()
        let independentCLINames: Set<String> = ["claude", "opencode", "codex", "gemini"]
        guard independentCLINames.contains(name) else { return false }

        let parentPath = url.deletingLastPathComponent().standardizedFileURL.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return parentPath == homePath
            || parentPath == "\(homePath)/.config"
            || parentPath == "\(homePath)/.cache"
            || parentPath == "\(homePath)/.local/share"
    }

    private static func deduplicatedFileSystemURLs(_ urls: [URL]) -> [URL] {
        var seenKeys: Set<String> = []
        var result: [URL] = []

        for url in urls {
            let key = url
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
                .lowercased()

            guard seenKeys.insert(key).inserted else { continue }
            result.append(url)
        }

        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func contents(of directoryURL: URL, fileManager: FileManager) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func allocatedByteCount(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ]

        func resourceByteCount(_ url: URL) -> Int64 {
            guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }

        var total = resourceByteCount(url)
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true,
              let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: [],
                errorHandler: { _, _ in true }
              )
        else {
            return total
        }

        for case let childURL as URL in enumerator {
            total += resourceByteCount(childURL)
        }

        return total
    }
}
