import AppKit
import Foundation
import Observation

enum KidoXLaunchSort: String, CaseIterable, Identifiable {
    static let storageKey = "KidoX.launchSort"

    case `default`
    case alphabetical
    case recent
    case mostUsed
    case recentlyAdded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .default:       "Default"
        case .alphabetical:  "Name"
        case .recent:        "Recently Used"
        case .mostUsed:      "Most Used"
        case .recentlyAdded: "Recently Added"
        }
    }

    var requiresPro: Bool {
        self != .default
    }

    var allowsReordering: Bool {
        self == .default
    }
}

private struct VisibleItemsCacheKey: Hashable {
    let sort: KidoXLaunchSort
    let query: String
}

enum IconCache {
    private static let diskCacheDirectory: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KidoX/IconCache", isDirectory: true)
    }()

    nonisolated(unsafe) private static let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 192
        return cache
    }()

    nonisolated(unsafe) private static let rasterizedCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 48 * 1_024 * 1_024
        return cache
    }()

    static func icon(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = iconCache.object(forKey: key) {
            return cached
        }

        let icon = NSWorkspace.shared.icon(forFile: path)
        iconCache.setObject(icon, forKey: key)
        return icon
    }

    static func rasterizedIcon(
        for path: String,
        pointSize: CGFloat,
        scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
    ) -> NSImage {
        let normalizedPointSize = max(1, pointSize.rounded(.toNearestOrAwayFromZero))
        let normalizedScale = max(1, (scale * 100).rounded() / 100)
        let cacheKey = "\(path)|\(Int(normalizedPointSize))|\(normalizedScale)" as NSString

        if let cached = rasterizedCache.object(forKey: cacheKey) {
            return cached
        }

        let diskURL = diskCacheURL(
            path: path,
            pointSize: normalizedPointSize,
            scale: normalizedScale
        )
        if let diskImage = NSImage(contentsOf: diskURL) {
            diskImage.size = NSSize(width: normalizedPointSize, height: normalizedPointSize)
            let pixelSize = max(1, Int((normalizedPointSize * normalizedScale).rounded()))
            rasterizedCache.setObject(diskImage, forKey: cacheKey, cost: pixelSize * pixelSize * 4)
            return diskImage
        }

        let image = icon(for: path)
        let pixelSize = max(1, Int((normalizedPointSize * normalizedScale).rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return image
        }

        bitmap.size = NSSize(width: normalizedPointSize, height: normalizedPointSize)

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            image.draw(
                in: NSRect(x: 0, y: 0, width: normalizedPointSize, height: normalizedPointSize),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        let rasterized = NSImage(size: NSSize(width: normalizedPointSize, height: normalizedPointSize))
        rasterized.addRepresentation(bitmap)
        rasterizedCache.setObject(rasterized, forKey: cacheKey, cost: pixelSize * pixelSize * 4)
        persistToDisk(rasterized, at: diskURL)
        return rasterized
    }

    static func clearMemoryCaches() {
        iconCache.removeAllObjects()
        rasterizedCache.removeAllObjects()
    }

    private static func diskCacheURL(path: String, pointSize: CGFloat, scale: CGFloat) -> URL {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedAt = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let fileSize = values?.fileSize ?? 0
        let identity = [
            path,
            "\(fileSize)",
            "\(modifiedAt)",
            "\(Int(pointSize))",
            "\(scale)"
        ].joined(separator: "|")
        return diskCacheDirectory.appendingPathComponent("\(stableHash(identity)).png")
    }

    private static func persistToDisk(_ image: NSImage, at url: URL) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            return
        }
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(
                at: diskCacheDirectory,
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

@Observable
@MainActor
final class KidoXStore {
    struct UninstallOutcome {
        let uninstallResult: ApplicationUninstallResult
        let pageMutationResult: PageMutationResult
    }

    struct PageMutationResult {
        static let none = PageMutationResult()

        var removedPagePositions: [Int] = []

        var didRemovePages: Bool {
            !removedPagePositions.isEmpty
        }

        mutating func merge(_ other: PageMutationResult) {
            removedPagePositions.append(contentsOf: other.removedPagePositions)
        }
    }

    var pages: [LaunchPage] = [] {
        didSet {
            visibleItemsCache.removeAll()
        }
    }
    var searchQuery = ""
    var searchFocusRequestID = 0
    var selectedItemID: LaunchItem.ID?
    var isLoading = false
    var lastScanDate: Date?
    var errorMessage: String?
    var screenMetrics = ScreenMetrics()
    var openFolderID: UUID?

    private let scanner = ApplicationScanner()
    private let database = KidoXDatabase()
    private let uninstaller = ApplicationUninstaller()
    private var applicationDirectoryMonitor: ApplicationDirectoryMonitor?
    private var didLoadPersistedApplications = false
    private var isRefreshingApplications = false
    private var initialApplicationRefreshTask: Task<Void, Never>?
    private var pendingApplicationRefreshTask: Task<Void, Never>?
    private var presentationPreparationTask: Task<Void, Never>?
    @ObservationIgnored private var visibleItemsCache: [VisibleItemsCacheKey: [LaunchItem]] = [:]
    @ObservationIgnored nonisolated(unsafe) private var externalPagesObserver: NSObjectProtocol?

    init() {
        externalPagesObserver = NotificationCenter.default.addObserver(
            forName: .kidoXPagesDidChangeExternally,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.reloadPagesFromDatabase()
            }
        }
    }

    deinit {
        if let externalPagesObserver {
            NotificationCenter.default.removeObserver(externalPagesObserver)
        }
    }

    var items: [LaunchItem] {
        orderedPages.flatMap(\.items)
    }

    var visibleItems: [LaunchItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else {
            return orderedPages.flatMap { $0.rootItems }
        }

        return cachedSortedVisibleItems(sort: .default, query: query)
    }

    var appCountText: String {
        let count = items.filter { $0.kind == .application && !$0.isHidden }.count
        return count == 1 ? "1 app" : "\(count) apps"
    }

    func markPreparingForInitialPresentation() {
        guard !didLoadPersistedApplications, pages.isEmpty else { return }
        isLoading = true
        errorMessage = nil
    }

    func prepareCachedApplicationsForPresentation() {
        installApplicationDirectoryMonitorIfNeeded()
        guard !didLoadPersistedApplications, pages.isEmpty else { return }

        let cachedPages = database.loadPages()
        guard !cachedPages.isEmpty else { return }

        pages = cachedPages
        didLoadPersistedApplications = true
        isLoading = false
        errorMessage = nil
        refreshApplicationsInBackground()
    }

    private func reloadPagesFromDatabase() async {
        pages = await database.loadPagesAsync()
        didLoadPersistedApplications = true
        isLoading = false
        errorMessage = nil
    }

    func visiblePages(pageSize: Int, sort: KidoXLaunchSort = .default) -> [[LaunchItem]] {
        let boundedPageSize = max(pageSize, 1)
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        guard sort == .default else {
            return cachedSortedVisibleItems(sort: sort, query: query).chunked(into: boundedPageSize)
        }

        guard query.isEmpty else {
            return cachedSortedVisibleItems(sort: .default, query: query).chunked(into: boundedPageSize)
        }

        return orderedPages.map(\.rootItems)
    }

    private func cachedSortedVisibleItems(sort: KidoXLaunchSort, query: String) -> [LaunchItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = VisibleItemsCacheKey(sort: sort, query: normalizedQuery)
        if let cached = visibleItemsCache[key] {
            return cached
        }

        let items = sortedVisibleItems(sort: sort, query: normalizedQuery)
        visibleItemsCache[key] = items
        return items
    }

    private func sortedVisibleItems(sort: KidoXLaunchSort, query: String) -> [LaunchItem] {
        let items: [LaunchItem]
        if query.isEmpty {
            items = orderedPages.flatMap { page in
                page.items
                    .filter { !$0.isHidden && $0.kind != .folder }
                    .sorted { $0.sortIndex < $1.sortIndex }
            }
        } else {
            items = searchMatches(for: query)
                .sorted(by: defaultSearchResultCompare)
                .map(\.item)
        }

        switch sort {
        case .default:
            return items
        case .alphabetical:
            return items.sorted {
                localizedNameCompare($0, $1) == .orderedAscending
            }
        case .recent:
            return items.sorted {
                if $0.lastOpenedAt != $1.lastOpenedAt {
                    return ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast)
                }
                return localizedNameCompare($0, $1) == .orderedAscending
            }
        case .mostUsed:
            return items.sorted {
                if $0.openCount != $1.openCount {
                    return $0.openCount > $1.openCount
                }
                return localizedNameCompare($0, $1) == .orderedAscending
            }
        case .recentlyAdded:
            return items.sorted {
                if $0.addedAt != $1.addedAt {
                    return $0.addedAt > $1.addedAt
                }
                return localizedNameCompare($0, $1) == .orderedAscending
            }
        }
    }

    private func localizedNameCompare(_ lhs: LaunchItem, _ rhs: LaunchItem) -> ComparisonResult {
        lhs.effectiveDisplayName.localizedStandardCompare(rhs.effectiveDisplayName)
    }

    private func searchMatches(for query: String) -> [(item: LaunchItem, match: LaunchItemSearchMatch)] {
        guard let parsedQuery = LaunchItemSearchQuery(query) else { return [] }

        return orderedPages.flatMap { page in
            page.items.compactMap { item in
                guard !item.isHidden, item.kind != .folder, let match = item.searchMatch(for: parsedQuery) else {
                    return nil
                }
                return (item, match)
            }
        }
    }

    private func defaultSearchResultCompare(
        _ lhs: (item: LaunchItem, match: LaunchItemSearchMatch),
        _ rhs: (item: LaunchItem, match: LaunchItemSearchMatch)
    ) -> Bool {
        if lhs.match != rhs.match {
            return lhs.match < rhs.match
        }
        if lhs.item.sortIndex != rhs.item.sortIndex {
            return lhs.item.sortIndex < rhs.item.sortIndex
        }
        return localizedNameCompare(lhs.item, rhs.item) == .orderedAscending
    }

    func children(of folderID: UUID) -> [LaunchItem] {
        guard let location = itemLocation(for: folderID) else { return [] }
        return pages[location.pageIndex].items
            .filter { !$0.isHidden && $0.parentID == folderID }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    @MainActor
    func loadApplications() async {
        await prepareForPresentation()
    }

    @MainActor
    func prepareForPresentation() async {
        if let presentationPreparationTask {
            await presentationPreparationTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performPrepareForPresentation()
        }
        presentationPreparationTask = task
        await task.value
        presentationPreparationTask = nil
    }

    private func performPrepareForPresentation() async {
        installApplicationDirectoryMonitorIfNeeded()
        guard !didLoadPersistedApplications else { return }

        markPreparingForInitialPresentation()
        pages = await database.loadPagesAsync()
        didLoadPersistedApplications = true
        refreshApplicationsInBackground()
    }

    @MainActor
    func refreshApplications() async {
        guard !isRefreshingApplications else { return }
        isRefreshingApplications = true
        let shouldShowLoading = pages.isEmpty
        if shouldShowLoading {
            isLoading = true
        }
        errorMessage = nil
        defer {
            isRefreshingApplications = false
            if shouldShowLoading {
                isLoading = false
            }
        }

        let scannedItems = await scanner.scan()
        pages = merge(existing: pages, scanned: scannedItems)
        await database.savePagesAsync(pages)
        lastScanDate = Date()
    }

    @MainActor
    func open(_ item: LaunchItem) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: item.url, configuration: configuration) { [weak self] application, error in
            Task { @MainActor [weak self] in
                if let error {
                    self?.errorMessage = error.localizedDescription
                    return
                }

                application?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

                guard let self,
                      let location = self.itemLocation(for: item.id)
                else { return }

                self.pages[location.pageIndex].items[location.itemIndex].lastOpenedAt = Date()
                self.pages[location.pageIndex].items[location.itemIndex].openCount += 1
                self.database.savePages(self.pages)
            }
        }
    }

    func revealInFinder(_ item: LaunchItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func hideItem(_ item: LaunchItem) {
        guard let location = itemLocation(for: item.id) else { return }
        guard !pages[location.pageIndex].items[location.itemIndex].isHidden else { return }
        pages[location.pageIndex].items[location.itemIndex].isHidden = true
        database.savePages(pages)
    }

    @MainActor
    func makeUninstallPlan(for item: LaunchItem) async throws -> ApplicationUninstallPlan {
        try await uninstaller.makePlan(for: item)
    }

    @MainActor
    func uninstallApplication(_ item: LaunchItem, plan: ApplicationUninstallPlan) async throws -> UninstallOutcome {
        let uninstallResult = try await uninstaller.uninstall(plan)
        let pageMutationResult = removeApplicationRecord(matching: item)
        database.savePages(pages)
        return UninstallOutcome(
            uninstallResult: uninstallResult,
            pageMutationResult: pageMutationResult
        )
    }

    @MainActor
    func uninstallApplicationKeepingRecord(_ item: LaunchItem, plan: ApplicationUninstallPlan) async throws -> ApplicationUninstallResult {
        try await uninstaller.uninstall(plan)
    }

    @MainActor
    func removeUninstalledApplicationRecord(_ item: LaunchItem) -> PageMutationResult {
        let pageMutationResult = removeApplicationRecord(matching: item)
        database.savePages(pages)
        return pageMutationResult
    }

    @MainActor
    func retryFailedUninstallDataRemovals(from result: ApplicationUninstallResult) async -> ApplicationUninstallResult {
        await uninstaller.retryFailedDataRemovals(from: result)
    }

    // MARK: - Reorder / Folder mutations

    @discardableResult
    func reorder(itemID: UUID, toSlot newSlot: Int) -> PageMutationResult {
        guard let location = itemLocation(for: itemID) else { return .none }
        let parent = pages[location.pageIndex].items[location.itemIndex].parentID

        var siblings = pages[location.pageIndex].items
            .filter { $0.parentID == parent && !$0.isHidden }
            .sorted { $0.sortIndex < $1.sortIndex }

        guard let currentIndex = siblings.firstIndex(where: { $0.id == itemID }) else { return .none }
        let bounded = max(0, min(newSlot, siblings.count - 1))
        guard bounded != currentIndex else { return .none }

        let moved = siblings.remove(at: currentIndex)
        siblings.insert(moved, at: bounded)

        applyOrder(siblings, in: location.pageIndex)
        database.savePages(pages)
        return .none
    }

    @discardableResult
    func insertEmptyPage(atSortedPosition position: Int) -> Int {
        let boundedPosition = max(0, min(position, pages.count))
        for pageIndex in pages.indices where pages[pageIndex].sortIndex >= boundedPosition {
            pages[pageIndex].sortIndex += 1
        }
        pages.append(LaunchPage(sortIndex: boundedPosition))
        compactPageOrder(&pages)
        database.savePages(pages)
        return boundedPosition
    }

    /// 把任意位置的 item（root 或 folder 内）移动到指定 page。
    /// 如果在 folder 内，先把它从 folder 取出，置为 root。
    @discardableResult
    func moveItemToRootPage(itemID: UUID, toPage targetPagePosition: Int, toSlot targetSlot: Int) -> PageMutationResult {
        guard let sourceLocation = itemLocation(for: itemID),
              let targetPageIndex = pageIndex(forSortedPosition: targetPagePosition, in: pages)
        else { return .none }

        let sourceItem = pages[sourceLocation.pageIndex].items[sourceLocation.itemIndex]
        let sourceFolderID = sourceItem.parentID
        if sourceFolderID == nil {
            // 已是 root，走标准 moveRootItem 路径
            return moveRootItem(itemID: itemID, toPage: targetPagePosition, toSlot: targetSlot)
        }

        // folder 内的 item：把 parentID 清掉就变成 root，
        // 然后通过 removeItemGroup + insertItemGroup 把它转移到目标页。
        let sourcePageIndex = sourceLocation.pageIndex
        let sourcePageID = pages[sourcePageIndex].id
        pages[sourcePageIndex].items[sourceLocation.itemIndex].parentID = nil

        guard let movingGroup = removeItemGroup(rootedAt: itemID, from: sourcePageIndex) else { return .none }

        if let sourceFolderID,
           children(of: sourceFolderID).isEmpty,
           let folderIndex = pages[sourcePageIndex].items.firstIndex(where: { $0.id == sourceFolderID }) {
            pages[sourcePageIndex].items.remove(at: folderIndex)
            if openFolderID == sourceFolderID { openFolderID = nil }
        }

        compactRootOrder(in: sourcePageIndex)
        insertItemGroup(
            movingGroup,
            rootedAt: itemID,
            into: targetPageIndex,
            at: targetSlot
        )
        compactPageOrder(&pages)
        var result = removeEmptySourcePageIfNeeded(id: sourcePageID)
        result.merge(trimEmptyBoundaryPages())
        database.savePages(pages)
        return result
    }

    @discardableResult
    func moveRootItem(itemID: UUID, toPage targetPagePosition: Int, toSlot targetSlot: Int) -> PageMutationResult {
        guard let sourceLocation = itemLocation(for: itemID),
              pages[sourceLocation.pageIndex].items[sourceLocation.itemIndex].parentID == nil,
              let targetPageIndex = pageIndex(forSortedPosition: targetPagePosition, in: pages)
        else { return .none }

        if sourceLocation.pageIndex == targetPageIndex {
            return reorder(itemID: itemID, toSlot: targetSlot)
        }

        let sourcePageID = pages[sourceLocation.pageIndex].id
        guard let movingGroup = removeItemGroup(rootedAt: itemID, from: sourceLocation.pageIndex) else {
            return .none
        }

        compactRootOrder(in: sourceLocation.pageIndex)
        insertItemGroup(
            movingGroup,
            rootedAt: itemID,
            into: targetPageIndex,
            at: targetSlot
        )
        compactPageOrder(&pages)
        var result = removeEmptySourcePageIfNeeded(id: sourcePageID)
        result.merge(trimEmptyBoundaryPages())
        database.savePages(pages)
        return result
    }

    @discardableResult
    func dropRootItem(itemID: UUID, on targetID: UUID) -> PageMutationResult {
        guard itemID != targetID,
              let sourceLocation = itemLocation(for: itemID),
              let targetLocation = itemLocation(for: targetID),
              pages[sourceLocation.pageIndex].items[sourceLocation.itemIndex].parentID == nil,
              pages[targetLocation.pageIndex].items[targetLocation.itemIndex].parentID == nil
        else { return .none }

        let movingItem = pages[sourceLocation.pageIndex].items[sourceLocation.itemIndex]
        let targetItem = pages[targetLocation.pageIndex].items[targetLocation.itemIndex]

        if targetItem.kind == .folder {
            return addRootItem(itemID: itemID, toFolder: targetID)
        } else if movingItem.kind != .folder {
            return createFolderForDrop(itemID: itemID, targetID: targetID)
        }
        return .none
    }

    @discardableResult
    func createFolder(seedA: UUID, seedB: UUID, atSlot slot: Int) -> UUID? {
        guard seedA != seedB,
              let aLocation = itemLocation(for: seedA),
              let bLocation = itemLocation(for: seedB),
              aLocation.pageIndex == bLocation.pageIndex
        else { return nil }

        let pageIndex = aLocation.pageIndex
        let aItem = pages[pageIndex].items[aLocation.itemIndex]
        let bItem = pages[pageIndex].items[bLocation.itemIndex]

        guard aItem.parentID == nil, bItem.parentID == nil else { return nil }

        let folderID = UUID()
        let folderURL = URL(string: "kidox://folder/\(folderID.uuidString)") ?? aItem.url
        let folderName = autoFolderName(for: aItem, bItem, on: pageIndex)

        let folder = LaunchItem(
            id: folderID,
            kind: .folder,
            displayName: folderName,
            subtitle: "",
            url: folderURL,
            sourcePath: "",
            sortIndex: 0,
            parentID: nil
        )

        pages[pageIndex].items.append(folder)

        var root = pages[pageIndex].items
            .filter { !$0.isHidden && $0.parentID == nil && $0.id != seedA && $0.id != seedB && $0.id != folderID }
            .sorted { $0.sortIndex < $1.sortIndex }

        let bounded = max(0, min(slot, root.count))
        root.insert(folder, at: bounded)
        applyOrder(root, in: pageIndex)

        if let index = pages[pageIndex].items.firstIndex(where: { $0.id == seedA }) {
            pages[pageIndex].items[index].parentID = folderID
            pages[pageIndex].items[index].sortIndex = 0
        }
        if let index = pages[pageIndex].items.firstIndex(where: { $0.id == seedB }) {
            pages[pageIndex].items[index].parentID = folderID
            pages[pageIndex].items[index].sortIndex = 1
        }

        database.savePages(pages)
        return folderID
    }

    func move(itemID: UUID, intoFolder folderID: UUID) {
        guard itemID != folderID,
              let itemPosition = itemLocation(for: itemID),
              let folderLocation = itemLocation(for: folderID),
              itemPosition.pageIndex == folderLocation.pageIndex
        else { return }

        let pageIndex = itemPosition.pageIndex
        let folder = pages[pageIndex].items[folderLocation.itemIndex]
        guard folder.kind == .folder else { return }

        let existingChildren = children(of: folderID)
        let nextSlot = (existingChildren.map(\.sortIndex).max() ?? -1) + 1

        pages[pageIndex].items[itemPosition.itemIndex].parentID = folderID
        pages[pageIndex].items[itemPosition.itemIndex].sortIndex = nextSlot

        let root = pages[pageIndex].items
            .filter { !$0.isHidden && $0.parentID == nil }
            .sorted { $0.sortIndex < $1.sortIndex }
        applyOrder(root, in: pageIndex)

        database.savePages(pages)
    }

    @discardableResult
    private func addRootItem(itemID: UUID, toFolder folderID: UUID) -> PageMutationResult {
        guard let sourceLocation = itemLocation(for: itemID),
              let folderLocation = itemLocation(for: folderID),
              pages[folderLocation.pageIndex].items[folderLocation.itemIndex].kind == .folder,
              let movingGroup = removeItemGroup(rootedAt: itemID, from: sourceLocation.pageIndex)
        else { return .none }

        let sourcePageID = pages[sourceLocation.pageIndex].id
        compactRootOrder(in: sourceLocation.pageIndex)

        let targetPageIndex = folderLocation.pageIndex
        pages[targetPageIndex].items.append(contentsOf: movingGroup)

        let nextSlot = (children(of: folderID).map(\.sortIndex).max() ?? -1) + 1
        if let rootIndex = pages[targetPageIndex].items.firstIndex(where: { $0.id == itemID }) {
            pages[targetPageIndex].items[rootIndex].parentID = folderID
            pages[targetPageIndex].items[rootIndex].sortIndex = nextSlot
        }

        compactPageOrder(&pages)
        var result = removeEmptySourcePageIfNeeded(id: sourcePageID)
        result.merge(trimEmptyBoundaryPages())
        database.savePages(pages)
        return result
    }

    @discardableResult
    private func createFolderForDrop(itemID: UUID, targetID: UUID) -> PageMutationResult {
        guard let sourceLocation = itemLocation(for: itemID),
              let targetLocation = itemLocation(for: targetID)
        else { return .none }

        let targetPageIndex = targetLocation.pageIndex
        let targetItem = pages[targetPageIndex].items[targetLocation.itemIndex]
        guard targetItem.kind != .folder,
              let movingGroup = removeItemGroup(rootedAt: itemID, from: sourceLocation.pageIndex)
        else { return .none }

        let sourcePageID = pages[sourceLocation.pageIndex].id
        compactRootOrder(in: sourceLocation.pageIndex)
        let folderSlot = pages[targetPageIndex].rootItems.firstIndex { $0.id == targetID }
            ?? pages[targetPageIndex].rootItems.count
        pages[targetPageIndex].items.append(contentsOf: movingGroup)

        guard let movingIndex = pages[targetPageIndex].items.firstIndex(where: { $0.id == itemID }),
              let targetIndex = pages[targetPageIndex].items.firstIndex(where: { $0.id == targetID })
        else { return .none }

        let movingItem = pages[targetPageIndex].items[movingIndex]
        let refreshedTarget = pages[targetPageIndex].items[targetIndex]
        let folderID = UUID()
        let folderURL = URL(string: "kidox://folder/\(folderID.uuidString)") ?? refreshedTarget.url
        let folder = LaunchItem(
            id: folderID,
            kind: .folder,
            displayName: autoFolderName(for: refreshedTarget, movingItem, on: targetPageIndex),
            subtitle: "",
            url: folderURL,
            sourcePath: "",
            sortIndex: 0,
            parentID: nil
        )

        pages[targetPageIndex].items.append(folder)

        var root = pages[targetPageIndex].items
            .filter { !$0.isHidden && $0.parentID == nil && $0.id != targetID && $0.id != itemID && $0.id != folderID }
            .sorted { $0.sortIndex < $1.sortIndex }
        root.insert(folder, at: max(0, min(folderSlot, root.count)))
        applyOrder(root, in: targetPageIndex)

        if let targetIndex = pages[targetPageIndex].items.firstIndex(where: { $0.id == targetID }) {
            pages[targetPageIndex].items[targetIndex].parentID = folderID
            pages[targetPageIndex].items[targetIndex].sortIndex = 0
        }
        if let movingIndex = pages[targetPageIndex].items.firstIndex(where: { $0.id == itemID }) {
            pages[targetPageIndex].items[movingIndex].parentID = folderID
            pages[targetPageIndex].items[movingIndex].sortIndex = 1
        }

        compactPageOrder(&pages)
        var result = removeEmptySourcePageIfNeeded(id: sourcePageID)
        result.merge(trimEmptyBoundaryPages())
        database.savePages(pages)
        return result
    }

    func removeFromFolder(itemID: UUID, toRootSlot slot: Int) {
        guard let itemLocation = itemLocation(for: itemID),
              let folderID = pages[itemLocation.pageIndex].items[itemLocation.itemIndex].parentID
        else { return }

        let pageIndex = itemLocation.pageIndex
        guard let movingGroup = removeItemGroup(rootedAt: itemID, from: pageIndex) else {
            return
        }

        if children(of: folderID).isEmpty,
           let folderIndex = pages[pageIndex].items.firstIndex(where: { $0.id == folderID }) {
            pages[pageIndex].items.remove(at: folderIndex)
            if openFolderID == folderID { openFolderID = nil }
        }

        compactRootOrder(in: pageIndex)
        insertItemGroup(
            movingGroup,
            rootedAt: itemID,
            into: pageIndex,
            at: slot
        )
        database.savePages(pages)
    }

    @discardableResult
    func ungroupFolder(_ folderID: UUID) -> PageMutationResult {
        guard let folderLocation = itemLocation(for: folderID),
              pages[folderLocation.pageIndex].items[folderLocation.itemIndex].kind == .folder
        else { return .none }

        let pageIndex = folderLocation.pageIndex
        let folderSlot = pages[pageIndex].rootItems.firstIndex { $0.id == folderID } ?? pages[pageIndex].rootItems.count
        let childIDs = pages[pageIndex].items
            .filter { $0.parentID == folderID }
            .sorted { $0.sortIndex < $1.sortIndex }
            .map(\.id)

        let childGroups = childIDs.compactMap { childID -> (id: UUID, group: [LaunchItem])? in
            guard let group = removeItemGroup(rootedAt: childID, from: pageIndex) else { return nil }
            return (childID, group)
        }

        if let folderIndex = pages[pageIndex].items.firstIndex(where: { $0.id == folderID }) {
            pages[pageIndex].items.remove(at: folderIndex)
        }
        if openFolderID == folderID { openFolderID = nil }

        compactRootOrder(in: pageIndex)
        for (offset, childGroup) in childGroups.enumerated() {
            insertItemGroup(
                childGroup.group,
                rootedAt: childGroup.id,
                into: pageIndex,
                at: folderSlot + offset
            )
        }

        compactPageOrder(&pages)
        let result = trimEmptyBoundaryPages()
        database.savePages(pages)
        return result
    }

    func renameFolder(_ id: UUID, to name: String) {
        renameItem(id, to: name)
    }

    func renameItem(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let location = itemLocation(for: id)
        else { return }

        if pages[location.pageIndex].items[location.itemIndex].kind == .application {
            pages[location.pageIndex].items[location.itemIndex].customDisplayName = trimmed
        } else {
            pages[location.pageIndex].items[location.itemIndex].displayName = trimmed
        }
        database.savePages(pages)
    }

    private var orderedPages: [LaunchPage] {
        pages.sorted { $0.sortIndex < $1.sortIndex }
    }

    private func itemLocation(for itemID: UUID) -> (pageIndex: Int, itemIndex: Int)? {
        for pageIndex in pages.indices {
            if let itemIndex = pages[pageIndex].items.firstIndex(where: { $0.id == itemID }) {
                return (pageIndex, itemIndex)
            }
        }
        return nil
    }

    private func pageIndex(
        forSortedPosition position: Int,
        in pages: [LaunchPage]
    ) -> Int? {
        let orderedIndices = pages.indices.sorted { pages[$0].sortIndex < pages[$1].sortIndex }
        guard position >= 0, position < orderedIndices.count else { return nil }
        return orderedIndices[position]
    }

    private func removeItemGroup(rootedAt rootID: UUID, from pageIndex: Int) -> [LaunchItem]? {
        guard let root = pages[pageIndex].items.first(where: { $0.id == rootID }) else { return nil }

        let groupIDs = descendantIDs(rootedAt: rootID, in: pages[pageIndex].items)
        let group = pages[pageIndex].items.filter { groupIDs.contains($0.id) }
        pages[pageIndex].items.removeAll { groupIDs.contains($0.id) }

        var normalizedRoot = root
        normalizedRoot.parentID = nil
        return [normalizedRoot] + group
            .filter { $0.id != rootID }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    private func descendantIDs(rootedAt rootID: UUID, in items: [LaunchItem]) -> Set<UUID> {
        var ids: Set<UUID> = [rootID]
        var didCollect = true

        while didCollect {
            didCollect = false
            for item in items {
                guard let parentID = item.parentID,
                      ids.contains(parentID),
                      !ids.contains(item.id)
                else { continue }

                ids.insert(item.id)
                didCollect = true
            }
        }

        return ids
    }

    private func insertItemGroup(
        _ group: [LaunchItem],
        rootedAt rootID: UUID,
        into pageIndex: Int,
        at slot: Int
    ) {
        ensurePageExists(at: pageIndex)

        pages[pageIndex].items.append(contentsOf: group)
        guard let root = pages[pageIndex].items.first(where: { $0.id == rootID }) else { return }

        var roots = pages[pageIndex].rootItems.filter { $0.id != rootID }
        let bounded = max(0, min(slot, roots.count))
        roots.insert(root, at: bounded)
        applyOrder(roots, in: pageIndex)

        guard roots.count > LaunchPage.defaultCapacity,
              let overflowRoot = roots.last
        else { return }

        guard let overflowGroup = removeItemGroup(rootedAt: overflowRoot.id, from: pageIndex) else {
            return
        }
        compactRootOrder(in: pageIndex)
        insertItemGroup(
            overflowGroup,
            rootedAt: overflowRoot.id,
            into: pageIndex + 1,
            at: 0
        )
    }

    private func ensurePageExists(at pageIndex: Int) {
        while pageIndex >= pages.count {
            let nextPageIndex = (pages.map(\.sortIndex).max() ?? -1) + 1
            pages.append(LaunchPage(sortIndex: nextPageIndex))
        }
    }

    private func removeEmptySourcePageIfNeeded(id sourcePageID: UUID) -> PageMutationResult {
        guard pages.count > 1,
              let sourceIndex = pages.firstIndex(where: { $0.id == sourcePageID }),
              pages[sourceIndex].rootItems.isEmpty
        else { return .none }

        return removePage(id: sourcePageID)
    }

    private func trimEmptyBoundaryPages() -> PageMutationResult {
        var result = PageMutationResult()

        while pages.count > 1,
              let firstPageID = pages.sorted(by: { $0.sortIndex < $1.sortIndex }).first?.id,
              let firstIndex = pages.firstIndex(where: { $0.id == firstPageID }),
              pages[firstIndex].rootItems.isEmpty {
            result.merge(removePage(id: firstPageID))
        }

        while pages.count > 1,
              let lastPageID = pages.sorted(by: { $0.sortIndex < $1.sortIndex }).last?.id,
              let lastIndex = pages.firstIndex(where: { $0.id == lastPageID }),
              pages[lastIndex].rootItems.isEmpty {
            result.merge(removePage(id: lastPageID))
        }

        return result
    }

    private func removePage(id pageID: UUID) -> PageMutationResult {
        guard pages.count > 1,
              let position = sortedPosition(forPageID: pageID),
              let pageIndex = pages.firstIndex(where: { $0.id == pageID })
        else { return .none }

        pages.remove(at: pageIndex)
        compactPageOrder(&pages)
        return PageMutationResult(removedPagePositions: [position])
    }

    private func sortedPosition(forPageID pageID: UUID) -> Int? {
        pages
            .sorted { $0.sortIndex < $1.sortIndex }
            .firstIndex { $0.id == pageID }
    }

    private func compactRootOrder(in pageIndex: Int) {
        let root = pages[pageIndex].rootItems
        applyOrder(root, in: pageIndex)
    }

    private func removeApplicationRecord(matching item: LaunchItem) -> PageMutationResult {
        let key = stableKey(for: item)
        var result = PageMutationResult()

        for pageIndex in pages.indices {
            pages[pageIndex].items.removeAll {
                $0.kind == .application && stableKey(for: $0) == key
            }
            removeEmptyFolders(in: pageIndex)
            compactVisibleSiblingOrder(in: pageIndex)
        }

        let emptyPageIDs = pages
            .filter(\.items.isEmpty)
            .sorted { $0.sortIndex < $1.sortIndex }
            .map(\.id)

        for pageID in emptyPageIDs {
            result.merge(removePage(id: pageID))
        }

        compactPageOrder(&pages)
        return result
    }

    private func removeEmptyFolders(in pageIndex: Int) {
        let childParentIDs = Set(pages[pageIndex].items.compactMap(\.parentID))
        pages[pageIndex].items.removeAll {
            $0.kind == .folder && !childParentIDs.contains($0.id)
        }
    }

    private func compactVisibleSiblingOrder(in pageIndex: Int) {
        let parentIDs = Set(pages[pageIndex].items.map(\.parentID))
        for parentID in parentIDs {
            let siblings = pages[pageIndex].items
                .filter { $0.parentID == parentID && !$0.isHidden }
                .sorted { $0.sortIndex < $1.sortIndex }

            for (sortIndex, item) in siblings.enumerated() {
                if let itemIndex = pages[pageIndex].items.firstIndex(where: { $0.id == item.id }) {
                    pages[pageIndex].items[itemIndex].sortIndex = sortIndex
                }
            }
        }
    }

    private func compactRootOrder(in pageIndex: Int, pages: inout [LaunchPage]) {
        let root = pages[pageIndex].rootItems
        for (index, item) in root.enumerated() {
            if let itemIndex = pages[pageIndex].items.firstIndex(where: { $0.id == item.id }) {
                pages[pageIndex].items[itemIndex].sortIndex = index
            }
        }
    }

    private func applyOrder(_ ordered: [LaunchItem], in pageIndex: Int) {
        for (index, item) in ordered.enumerated() {
            if let itemIndex = pages[pageIndex].items.firstIndex(where: { $0.id == item.id }) {
                pages[pageIndex].items[itemIndex].sortIndex = index
            }
        }
    }

    private func autoFolderName(for a: LaunchItem, _ b: LaunchItem, on pageIndex: Int) -> String {
        if let categoryName = sharedApplicationCategoryName(for: a, b) {
            return nextFolderName(basedOn: categoryName, on: pageIndex)
        }
        return nextFolderName(basedOn: "Folder", on: pageIndex)
    }

    private func sharedApplicationCategoryName(for a: LaunchItem, _ b: LaunchItem) -> String? {
        guard
            let categoryA = normalizedApplicationCategory(a.applicationCategory),
            let categoryB = normalizedApplicationCategory(b.applicationCategory),
            categoryA == categoryB
        else { return nil }

        return applicationCategoryDisplayName(categoryA)
    }

    private func normalizedApplicationCategory(_ category: String?) -> String? {
        let trimmed = category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    private func applicationCategoryDisplayName(_ category: String) -> String {
        switch category {
        case "public.app-category.business": "Business"
        case "public.app-category.developer-tools": "Developer Tools"
        case "public.app-category.education": "Education"
        case "public.app-category.entertainment": "Entertainment"
        case "public.app-category.finance": "Finance"
        case "public.app-category.games": "Games"
        case "public.app-category.graphics-design": "Graphics & Design"
        case "public.app-category.healthcare-fitness": "Health & Fitness"
        case "public.app-category.lifestyle": "Lifestyle"
        case "public.app-category.medical": "Medical"
        case "public.app-category.music": "Music"
        case "public.app-category.news": "News"
        case "public.app-category.photography": "Photography"
        case "public.app-category.productivity": "Productivity"
        case "public.app-category.reference": "Reference"
        case "public.app-category.social-networking": "Social Networking"
        case "public.app-category.sports": "Sports"
        case "public.app-category.travel": "Travel"
        case "public.app-category.utilities": "Utilities"
        case "public.app-category.video": "Video"
        case "public.app-category.weather": "Weather"
        default:
            category
                .replacingOccurrences(of: "public.app-category.", with: "")
                .split(separator: "-")
                .map { word in
                    String(word.prefix(1)).uppercased() + String(word.dropFirst())
                }
                .joined(separator: " ")
        }
    }

    private func nextFolderName(basedOn baseName: String, on pageIndex: Int) -> String {
        guard pages.indices.contains(pageIndex) else { return baseName }

        let existingNames = Set(
            pages[pageIndex].items
                .filter { $0.kind == .folder }
                .map { $0.effectiveDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase }
        )
        let normalizedBaseName = baseName.localizedLowercase
        guard existingNames.contains(normalizedBaseName) else { return baseName }

        var suffix = 2
        while existingNames.contains("\(normalizedBaseName) \(suffix)") {
            suffix += 1
        }
        return "\(baseName) \(suffix)"
    }

    private func merge(existing: [LaunchPage], scanned: [LaunchItem]) -> [LaunchPage] {
        guard !existing.isEmpty else {
            return makePages(from: scanned)
        }

        var merged = existing
        let scannedKeys = Set(scanned.map { stableKey(for: $0) })
        removeMissingApplications(from: &merged, scannedKeys: scannedKeys)

        var insertedKeys = Set(merged.flatMap(\.items).map { stableKey(for: $0) })

        for scannedItem in scanned {
            let key = stableKey(for: scannedItem)
            if let location = itemLocation(for: key, in: merged) {
                merged[location.pageIndex].items[location.itemIndex].displayName = scannedItem.displayName
                merged[location.pageIndex].items[location.itemIndex].subtitle = scannedItem.subtitle
                merged[location.pageIndex].items[location.itemIndex].url = scannedItem.url
                merged[location.pageIndex].items[location.itemIndex].bundleIdentifier = scannedItem.bundleIdentifier
                merged[location.pageIndex].items[location.itemIndex].bundleName = scannedItem.bundleName
                merged[location.pageIndex].items[location.itemIndex].localizedDisplayNames = scannedItem.localizedDisplayNames
                merged[location.pageIndex].items[location.itemIndex].applicationCategory = scannedItem.applicationCategory
                merged[location.pageIndex].items[location.itemIndex].version = scannedItem.version
                merged[location.pageIndex].items[location.itemIndex].sourcePath = scannedItem.sourcePath
            } else if !insertedKeys.contains(key) {
                append(scannedItem, to: &merged)
                insertedKeys.insert(key)
            }
        }

        compactPageOrder(&merged)
        return merged
    }

    private func removeMissingApplications(from pages: inout [LaunchPage], scannedKeys: Set<String>) {
        for pageIndex in pages.indices {
            pages[pageIndex].items.removeAll { item in
                item.kind == .application
                    && !scannedKeys.contains(stableKey(for: item))
                    && (!item.isHidden || !FileManager.default.fileExists(atPath: item.sourcePath))
            }
            compactRootOrder(in: pageIndex, pages: &pages)
        }

        pages.removeAll { page in
            page.items.isEmpty
        }
    }

    private func makePages(from scanned: [LaunchItem]) -> [LaunchPage] {
        scanned
            .chunked(into: LaunchPage.defaultCapacity)
            .enumerated()
            .map { pageIndex, chunk in
                let pageItems = chunk.enumerated().map { itemIndex, item in
                    var copy = item
                    copy.parentID = nil
                    copy.sortIndex = itemIndex
                    return copy
                }
                return LaunchPage(sortIndex: pageIndex, items: pageItems)
            }
    }

    private func append(_ scannedItem: LaunchItem, to pages: inout [LaunchPage]) {
        if pages.isEmpty {
            pages.append(LaunchPage(sortIndex: 0))
        }

        let targetPageIndex = pages.indices
            .sorted { pages[$0].sortIndex < pages[$1].sortIndex }
            .first { pages[$0].rootItems.count < LaunchPage.defaultCapacity }

        let pageIndex: Int
        if let targetPageIndex {
            pageIndex = targetPageIndex
        } else {
            let nextPageIndex = (pages.map(\.sortIndex).max() ?? -1) + 1
            pages.append(LaunchPage(sortIndex: nextPageIndex))
            pageIndex = pages.count - 1
        }

        var newItem = scannedItem
        newItem.parentID = nil
        newItem.sortIndex = pages[pageIndex].rootItems.count
        newItem.addedAt = Date()
        pages[pageIndex].items.append(newItem)
    }

    private func itemLocation(
        for lookupKey: String,
        in pages: [LaunchPage]
    ) -> (pageIndex: Int, itemIndex: Int)? {
        for pageIndex in pages.indices {
            if let itemIndex = pages[pageIndex].items.firstIndex(where: { stableKey(for: $0) == lookupKey }) {
                return (pageIndex, itemIndex)
            }
        }
        return nil
    }

    private func stableKey(for item: LaunchItem) -> String {
        switch item.kind {
        case .folder:
            return "folder:\(item.id.uuidString)"
        default:
            return item.bundleIdentifier ?? item.sourcePath
        }
    }

    private func installApplicationDirectoryMonitorIfNeeded() {
        guard applicationDirectoryMonitor == nil else { return }

        let roots = scanner.scanRoots.filter { url in
            url.path == "/Applications" || url.path.hasPrefix(NSHomeDirectory())
        }

        applicationDirectoryMonitor = ApplicationDirectoryMonitor(urls: roots) { [weak self] in
            self?.scheduleApplicationRefresh()
        }
    }

    private func scheduleApplicationRefresh() {
        pendingApplicationRefreshTask?.cancel()
        pendingApplicationRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.refreshApplications()
        }
    }

    private func refreshApplicationsInBackground() {
        guard initialApplicationRefreshTask == nil else { return }

        initialApplicationRefreshTask = Task { @MainActor [weak self] in
            await self?.refreshApplications()
            self?.initialApplicationRefreshTask = nil
        }
    }

    private func compactPageOrder(_ pages: inout [LaunchPage]) {
        let orderedIDs = pages
            .sorted { $0.sortIndex < $1.sortIndex }
            .map(\.id)

        for (sortIndex, pageID) in orderedIDs.enumerated() {
            if let pageIndex = pages.firstIndex(where: { $0.id == pageID }) {
                pages[pageIndex].sortIndex = sortIndex
            }
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
