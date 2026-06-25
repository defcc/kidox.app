import AppKit
import Observation
import SwiftUI

enum SearchDragLog {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/KidoX", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("search-drag.log")
    }()

    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    static func write(_ message: String) {
        let line = "[\(timestamp())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

private enum DropTargetEntryDirection {
    case fromLeft
    case fromRight
    case nonHorizontal
}

private struct DropTargetHit {
    let id: LaunchItem.ID
    let rect: CGRect
    let distance: CGFloat
}

enum KidoXBackgroundStyle: String, CaseIterable, Identifiable, Hashable {
    static let styleStorageKey = "KidoX.backgroundStyle"
    static let wallpaperBlurStorageKey = "KidoX.backgroundWallpaperBlur"
    static let wallpaperDarkenStorageKey = "KidoX.backgroundWallpaperDarken"
    static let imageBlurStorageKey = "KidoX.backgroundImageBlur"
    static let imageDarkenStorageKey = "KidoX.backgroundImageDarken"
    static let glassStrengthStorageKey = "KidoX.backgroundGlassStrength"
    static let solidPresetStorageKey = "KidoX.backgroundSolidPreset"
    static let solidCustomColorStorageKey = "KidoX.backgroundSolidCustomColor"
    static let customImagePathStorageKey = "KidoX.backgroundCustomImagePath"

    case wallpaper
    case image
    case glass
    case solid

    var id: String { rawValue }

    init(storageValue: String) {
        self = Self(rawValue: storageValue) ?? .wallpaper
    }

    var title: String {
        switch self {
        case .wallpaper: "Wallpaper"
        case .image:     "Image"
        case .glass:    "Glass"
        case .solid:    "Solid"
        }
    }

    func localizedTitle(languageRawValue: String? = nil) -> String {
        KidoXL10n.ui(title, languageRawValue: languageRawValue)
    }

    var description: String {
        switch self {
        case .wallpaper:
            "Use the current desktop wallpaper."
        case .image:
            "Use a custom image from this Mac."
        case .glass:
            "Use a live macOS material background."
        case .solid:
            "Use a fixed dark background."
        }
    }

    func localizedDescription(languageRawValue: String? = nil) -> String {
        KidoXL10n.ui(description, languageRawValue: languageRawValue)
    }

    var requiresPro: Bool {
        self == .image
    }
}

enum KidoXCustomWallpaperStore {
    static func copyImage(from sourceURL: URL) throws -> String {
        let fileManager = FileManager.default
        let directoryURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KidoX/CustomWallpaper", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        if let existingFiles = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) {
            for fileURL in existingFiles {
                try? fileManager.removeItem(at: fileURL)
            }
        }

        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let pathExtension = sourceURL.pathExtension.isEmpty ? "image" : sourceURL.pathExtension
        let filename = "Wallpaper-\(UUID().uuidString).\(pathExtension)"
        let destinationURL = directoryURL.appendingPathComponent(filename)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL.path
    }

    static func image(at path: String) async -> NSImage? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        return await Task.detached(priority: .utility) {
            NSImage(contentsOf: url)
        }.value
    }

    static func deleteImage(at path: String) {
        guard !path.isEmpty else { return }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
    }
}

enum KidoXSolidBackgroundPreset: String, CaseIterable, Identifiable, Hashable {
    case graphite
    case slate
    case navy
    case moss
    case plum
    case ember
    case custom

    var id: String { rawValue }

    init(storageValue: String) {
        self = Self(rawValue: storageValue) ?? .graphite
    }

    var title: String {
        switch self {
        case .graphite: "Graphite"
        case .slate:    "Slate"
        case .navy:     "Navy"
        case .moss:     "Moss"
        case .plum:     "Plum"
        case .ember:    "Ember"
        case .custom:   "Custom"
        }
    }

    var color: Color {
        switch self {
        case .graphite:
            Color(red: 0.140, green: 0.150, blue: 0.170)
        case .slate:
            Color(red: 0.120, green: 0.165, blue: 0.210)
        case .navy:
            Color(red: 0.090, green: 0.165, blue: 0.290)
        case .moss:
            Color(red: 0.095, green: 0.235, blue: 0.170)
        case .plum:
            Color(red: 0.210, green: 0.140, blue: 0.270)
        case .ember:
            Color(red: 0.290, green: 0.130, blue: 0.095)
        case .custom:
            Self.defaultCustomColor
        }
    }

    var requiresPro: Bool {
        switch self {
        case .graphite, .slate, .navy:
            false
        case .moss, .plum, .ember, .custom:
            true
        }
    }

    static var builtInCases: [Self] {
        [.graphite, .slate, .navy, .moss, .plum, .ember]
    }

    static let defaultCustomColorHex = "#171A22"
    static let defaultCustomColor = Color(red: 0.09, green: 0.10, blue: 0.13)
}

private struct RootDragStartRequest: Equatable {
    let id: UUID
    let itemID: LaunchItem.ID
    let startPoint: CGPoint
    let currentPoint: CGPoint
    let fingerOffset: CGSize
    let targetPage: Int
}

private struct PageTurnAnimationRequest: Equatable {
    let id: UUID
    let targetPage: Int
}

private struct GridCompactionAnimationRequest: Equatable {
    let id: UUID
    let removedItemID: LaunchItem.ID
}

struct KidoXBackgroundLayer: View {
    var body: some View {
        KidoXBackground()
    }
}

private func proMenuAttributedTitle(_ title: String, showsPro: Bool) -> NSAttributedString {
    let attributedTitle = NSMutableAttributedString(
        string: title,
        attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor
        ]
    )

    if showsPro {
        attributedTitle.append(NSAttributedString(
            string: "  Pro",
            attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.systemPurple
            ]
        ))
    }

    return attributedTitle
}

private struct SettingsMenuClickTarget: NSViewRepresentable {
    let selectedSort: KidoXLaunchSort
    let isPro: Bool
    let onOpenSettings: () -> Void
    let onPurchasePro: () -> Void
    let onActivateLicense: () -> Void
    let onSelectSort: (KidoXLaunchSort) -> Void
    let onQuit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.title = ""
        button.isBordered = false
        button.image = nil
        button.focusRingType = .none
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: SettingsMenuClickTarget

        init(_ parent: SettingsMenuClickTarget) {
            self.parent = parent
        }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false

            addItem(to: menu, title: KidoXL10n.ui("Open Settings"), action: #selector(openSettings(_:)))
            menu.addItem(.separator())

            let sectionItem = NSMenuItem(title: KidoXL10n.ui("Sort By"), action: nil, keyEquivalent: "")
            sectionItem.isEnabled = false
            menu.addItem(sectionItem)

            for sort in KidoXLaunchSort.allCases {
                let item = NSMenuItem(title: "", action: #selector(selectSort(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = sort.rawValue
                item.attributedTitle = attributedTitle(for: sort)
                item.state = parent.selectedSort == sort ? .on : .off
                menu.addItem(item)
            }

            menu.addItem(.separator())
            addItem(
                to: menu,
                title: KidoXL10n.ui(parent.isPro ? "Purchase More License" : "Purchase Pro"),
                action: #selector(purchasePro(_:))
            )
            if parent.isPro {
                addDisabledItem(to: menu, title: KidoXL10n.ui("License Activated"))
            } else {
                addItem(to: menu, title: KidoXL10n.ui("Activate License"), action: #selector(activateLicense(_:)))
            }
            menu.addItem(.separator())
            addItem(to: menu, title: KidoXL10n.ui("Quit"), action: #selector(quit(_:)))

            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        }

        private func addItem(to menu: NSMenu, title: String, action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        private func addDisabledItem(to menu: NSMenu, title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        private func attributedTitle(for sort: KidoXLaunchSort) -> NSAttributedString {
            proMenuAttributedTitle(KidoXL10n.ui(sort.title), showsPro: !parent.isPro && sort.requiresPro)
        }

        @objc private func openSettings(_ sender: NSMenuItem) {
            parent.onOpenSettings()
        }

        @objc private func purchasePro(_ sender: NSMenuItem) {
            parent.onPurchasePro()
        }

        @objc private func activateLicense(_ sender: NSMenuItem) {
            parent.onActivateLicense()
        }

        @objc private func selectSort(_ sender: NSMenuItem) {
            guard
                let rawValue = sender.representedObject as? String,
                let sort = KidoXLaunchSort(rawValue: rawValue)
            else { return }

            parent.onSelectSort(sort)
        }

        @objc private func quit(_ sender: NSMenuItem) {
            parent.onQuit()
        }
    }
}

struct KidoXForegroundLayer: View {
    @Bindable var store: KidoXStore
    let onDismiss: () -> Void
    let onLaunchApp: () -> Void
    let onOpenSettings: () -> Void
    let onOpenLicenseSettings: () -> Void
    let onModalInteractionChanged: (Bool) -> Void
    let onRestoreFocusAfterModalInteraction: () -> Void
    @AppStorage(KidoXLanguage.storageKey) private var appLanguageRaw = KidoXLanguage.system.rawValue
    @AppStorage(KidoXLaunchSort.storageKey) private var launchSortRaw = KidoXLaunchSort.default.rawValue
    @AppStorage("ClyAppLicense.status") private var licenseStatus = "Free"
    @State private var searchFocused = false
    @State private var searchTextIsComposing = false
    @State private var currentPage = 0
    @State private var pageTurnAnimationRequest: PageTurnAnimationRequest?
    @State private var pageBeforeSearch: Int?
    @State private var dragOffset: CGFloat = 0
    @State private var currentSize: CGSize = .zero
    @State private var pressedItemID: LaunchItem.ID?
    @State private var draggingItemID: LaunchItem.ID?
    @State private var draggedItem: LaunchItem?
    @State private var dragOriginPage: Int?
    @State private var dragTargetPage: Int?
    @State private var dragDropTargetID: LaunchItem.ID?
    @State private var dragEnteredDropTargetID: LaunchItem.ID?
    @State private var dragEnteredDropTargetDirection: DropTargetEntryDirection?
    @State private var dragLocation: CGPoint = .zero
    @State private var dragStartLocation: CGPoint?
    @State private var dragPreviousMouseLocation: CGPoint?
    @State private var dragFingerOffset: CGSize = .zero
    @State private var dragOriginSlot: Int?
    @State private var pageOrderOverride: [LaunchItem.ID]?
    @State private var folderPressedItemID: LaunchItem.ID?
    @State private var folderDraggingItemID: LaunchItem.ID?
    @State private var folderDraggedItem: LaunchItem?
    @State private var folderDragLocation: CGPoint = .zero
    @State private var folderDragStartLocation: CGPoint?
    @State private var folderDragFingerOffset: CGSize = .zero
    @State private var folderDragOriginSlot: Int?
    @State private var folderOrderOverride: [LaunchItem.ID]?
    @State private var folderDragHasExited = false
    @State private var folderDragExitPanelOrigin: CGPoint?
    @State private var rootDragStartRequest: RootDragStartRequest?
    @State private var folderOverlayIsExpanded = false
    @State private var folderOverlayProgress: CGFloat = 0
    @State private var isCompletingDrag = false
    @State private var lastDragPageTurnDate = Date.distantPast
    @State private var dragEdgeSide: Int = 0
    @State private var dragEdgeEnteredAt: Date?
    @State private var dragEdgeHasTurnedInCurrentRun = false
    @State private var keyboardSelectionID: LaunchItem.ID?
    @State private var uninstallSession: UninstallPanelSession?
    @State private var uninstallCompletionAnimation: UninstallCompletionAnimation?
    @State private var gridCompactionAnimationRequest: GridCompactionAnimationRequest?
    @State private var hasFullDiskAccess = Self.detectFullDiskAccess()

    private let dragActivationDistance: CGFloat = 6
    private let pageTurnReleaseThreshold: CGFloat = 64
    private let rowChangeHorizontalThreshold: CGFloat = 22
    private let rowCenterTolerance: CGFloat = 12
    private let dragPageTurnEdgeWidth: CGFloat = 56
    private let dragPageTurnDwell: TimeInterval = 0.4
    private let dragPageTurnRepeatDwell: TimeInterval = 1.0
    private let dragPageTurnCooldown: TimeInterval = 0.3
    private let dropTargetIconSize: CGFloat = 108

    private var isIconInteractionActive: Bool {
        pressedItemID != nil
            || draggingItemID != nil
            || folderPressedItemID != nil
            || folderDraggingItemID != nil
            || folderDragHasExited
    }

    private var launchSort: KidoXLaunchSort {
        let sort = KidoXLaunchSort(rawValue: launchSortRaw) ?? .default
        return isPro || !sort.requiresPro ? sort : .default
    }

    private var isPro: Bool {
        licenseStatus == "active"
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onDismiss()
                    }
                header
                    .position(x: proxy.size.width / 2, y: headerCenterY(for: proxy.size))
                    .opacity(appChromeOpacity)
                    .allowsHitTesting(store.openFolderID == nil && appChromeOpacity > 0.99)
                    .zIndex(2)

                Group {
                    if store.isLoading && store.items.isEmpty {
                        loadingView
                    } else if store.visibleItems.isEmpty {
                        emptyView
                    } else {
                        pagedGrid(size: proxy.size)
                    }
                }
                .frame(width: proxy.size.width, height: contentHeight(for: proxy.size))
                .position(x: proxy.size.width / 2, y: gridCenterY(for: proxy.size))
                .opacity(backgroundGridOpacity)
                .blur(radius: backgroundGridBlurRadius)
                .scaleEffect(backgroundGridScale)
                .allowsHitTesting(store.openFolderID == nil)

                pageFooter(size: proxy.size)
                    .opacity(store.openFolderID == nil ? 1 : 0)
                    .allowsHitTesting(store.openFolderID == nil)
                    .position(x: proxy.size.width / 2, y: footerCenterY(for: proxy.size))

                folderOverlay(size: proxy.size)
                    .zIndex(12)

                if let draggedItem, draggingItemID == draggedItem.id {
                    draggedTileOverlay(item: draggedItem)
                        .frame(width: proxy.size.width, height: contentHeight(for: proxy.size))
                        .position(x: proxy.size.width / 2, y: gridCenterY(for: proxy.size))
                        .zIndex(40)
                        .allowsHitTesting(false)
                }

                if let uninstallSession {
                    UninstallPanelRouteView(
                        session: uninstallSession,
                        hasFullDiskAccess: hasFullDiskAccess,
                        anchor: uninstallPopoverAnchor(for: uninstallSession.item, size: proxy.size),
                        onCancel: {
                            setUninstallSession(nil)
                            focusSearchField()
                        },
                        onConfirm: { item, plan in
                            await performInlineUninstall(item, plan: plan)
                        },
                        onRetryFailedItems: { result in
                            await retryFailedUninstallDataRemovals(result)
                        },
                        onOpenPrivacySettings: {
                            openAppDataPrivacySettings()
                        }
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    .zIndex(100)
                }

                if let uninstallCompletionAnimation {
                    UninstallPoofAnimation(
                        animation: uninstallCompletionAnimation,
                        onFinished: {
                            guard self.uninstallCompletionAnimation?.id == uninstallCompletionAnimation.id else { return }
                            let compactionRequest = GridCompactionAnimationRequest(
                                id: UUID(),
                                removedItemID: uninstallCompletionAnimation.item.id
                            )
                            gridCompactionAnimationRequest = compactionRequest
                            self.uninstallCompletionAnimation = nil
                            withAnimation(.snappy(duration: 0.22)) {
                                let pageMutationResult = store.removeUninstalledApplicationRecord(uninstallCompletionAnimation.item)
                                applyPageMutationResult(pageMutationResult)
                                reconcileOpenFolderAfterUninstall()
                                ensureKeyboardSelectionIsValid()
                            }
                            focusSearchField()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                if gridCompactionAnimationRequest?.id == compactionRequest.id {
                                    gridCompactionAnimationRequest = nil
                                }
                            }
                        }
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .allowsHitTesting(false)
                    .zIndex(110)
                }
            }
            .onAppear {
                currentSize = proxy.size
                ensureKeyboardSelectionIsValid()
            }
            .onChange(of: proxy.size) { _, newSize in
                currentSize = newSize
                currentPage = min(currentPage, maxPageIndex(for: newSize))
                ensureKeyboardSelectionIsValid()
            }
        }
        .ignoresSafeArea()
        .onChange(of: store.searchFocusRequestID) { _, _ in
            focusSearchField()
        }
        .onDisappear {
            onModalInteractionChanged(false)
        }
        .onChange(of: store.searchQuery) { oldValue, newValue in
            let wasSearching = !oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let isSearchingNow = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !wasSearching, isSearchingNow {
                // 进入搜索：记住当前页
                pageBeforeSearch = currentPage
                SearchDragLog.write("enterSearch: pageBeforeSearch=\(currentPage), totalPages=\(visiblePages(pageSize: max(columnCount(for: currentSize) * rowCount(for: currentSize), 1)).count)")
                currentPage = 0
            } else if wasSearching, !isSearchingNow {
                // 退出搜索：回到搜索前的页面
                if let prev = pageBeforeSearch {
                    currentPage = prev
                    pageBeforeSearch = nil
                }
                keyboardSelectionID = nil
            } else if isSearchingNow {
                // 仍在搜索：keep page 0
                currentPage = 0
            }
            // 每次输入都重置到第一个结果
            if isSearchingNow {
                keyboardSelectionID = nil
            }
            ensureKeyboardSelectionIsValid()
        }
        .onChange(of: visibleItemIDs) { _, _ in
            ensureKeyboardSelectionIsValid()
        }
        .onChange(of: launchSortRaw) { _, _ in
            handleLaunchSortChange()
            ensureKeyboardSelectionIsValid()
        }
        .onKeyPress(.escape) {
            handleEscape()
            return .handled
        }
        .onKeyPress(
            keys: [.leftArrow, .rightArrow, .upArrow, .downArrow],
            phases: [.down, .repeat]
        ) { keyPress in
            handleLaunchPanelKeyPress(keyPress)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            searchHeader
            settingsButton
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))

            ZStack(alignment: .leading) {
                if store.searchQuery.isEmpty && !searchTextIsComposing {
                    Text(KidoXL10n.string(.searchApplications, languageRawValue: appLanguageRaw))
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .allowsHitTesting(false)
                }

                SearchTextField(
                    text: $store.searchQuery,
                    isFocused: $searchFocused,
                    isComposing: $searchTextIsComposing,
                    onEscape: handleEscape,
                    onMoveSelection: { direction in
                        moveKeyboardSelection(direction)
                    },
                    onMovePage: { delta in
                        movePageBy(delta)
                    },
                    onCommit: {
                        commitKeyboardSelection()
                    }
                )
                .frame(height: 24)
            }

            if !store.searchQuery.isEmpty {
                Button {
                    clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .buttonStyle(.plain)
                .help(KidoXL10n.ui("Clear search", languageRawValue: appLanguageRaw))
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
        .frame(maxWidth: 280)
        .contentShape(Capsule(style: .continuous))
        .modifier(SearchFieldGlassBackground())
        .onTapGesture {
            focusSearchField()
        }
    }

    private var settingsButton: some View {
        ZStack {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
                .frame(width: 44, height: 44)
                .contentShape(Circle())

            SettingsMenuClickTarget(
                selectedSort: launchSort,
                isPro: isPro,
                onOpenSettings: onOpenSettings,
                onPurchasePro: {
                    NSWorkspace.shared.open(KidoXAppConfiguration.purchaseURL)
                },
                onActivateLicense: onOpenLicenseSettings,
                onSelectSort: selectLaunchSort,
                onQuit: {
                    NSApp.terminate(nil)
                }
            )
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .background(
            Circle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.040), location: 0.00),
                            .init(color: .black.opacity(0.024), location: 0.58),
                            .init(color: .black.opacity(0.055), location: 1.00)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            Circle()
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.70), location: 0.00),
                            .init(color: Color(red: 0.66, green: 0.91, blue: 1.00).opacity(0.50), location: 0.22),
                            .init(color: .white.opacity(0.24), location: 1.00)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
        )
        .shadow(color: .black.opacity(0.16), radius: 9, x: 0, y: 5)
        .help(KidoXL10n.string(.settings, languageRawValue: appLanguageRaw))
    }

    private func focusSearchField() {
        searchFocused = false
        DispatchQueue.main.async {
            searchFocused = true
        }
    }

    private func selectLaunchSort(_ sort: KidoXLaunchSort) {
        guard isPro || !sort.requiresPro else {
            onOpenLicenseSettings()
            return
        }
        launchSortRaw = sort.rawValue
    }

    private func visiblePages(pageSize: Int) -> [[LaunchItem]] {
        store.visiblePages(pageSize: pageSize, sort: launchSort)
    }

    private var visibleItemIDs: [LaunchItem.ID] {
        let pageSize = max(columnCount(for: currentSize) * rowCount(for: currentSize), 1)
        return visiblePages(pageSize: pageSize).flatMap { page in
            page.map(\.id)
        }
    }

    private func handleLaunchSortChange() {
        currentPage = 0
        pageBeforeSearch = nil
        keyboardSelectionID = nil
        store.openFolderID = nil
        folderOverlayIsExpanded = false
        folderOverlayProgress = 0
        resetDragState()
        resetFolderDragState()
        resetPageDragOffset()
    }

    private func pagedGrid(size: CGSize) -> some View {
        let columns = columnCount(for: size)
        let rows = rowCount(for: size)
        let pageSize = max(columns * rows, 1)
        let pages = visiblePages(pageSize: pageSize)
        let pageWidth = size.width
        let pageHeight = contentHeight(for: size)

        let folderIDs = pages.flatMap { page in
            page.compactMap { item in item.kind == .folder ? item.id : nil }
        }
        let childrenByFolderID = Dictionary(uniqueKeysWithValues: folderIDs.map { folderID in
            (folderID, store.children(of: folderID))
        })

        return AppKitPagedGridView(
            pages: pages,
            childrenByFolderID: childrenByFolderID,
            currentPage: $currentPage,
            columns: columns,
            rows: rows,
            pageWidth: pageWidth,
            pageHeight: pageHeight,
            horizontalMargin: horizontalPageMargin(for: size),
            gridTopY: gridTopY(for: size),
            gridBottomY: gridBottomY(for: size),
            isReorderingEnabled: launchSort.allowsReordering && store.searchQuery.isEmpty,
            isRenameEnabled: isPro,
            showsProBadges: !isPro,
            rootDragStartRequest: rootDragStartRequest,
            pageTurnAnimationRequest: pageTurnAnimationRequest,
            compactionAnimationRequest: gridCompactionAnimationRequest,
            visuallyHiddenItemID: store.openFolderID ?? uninstallCompletionAnimation?.item.id,
            onPageTurn: { page in
                moveKeyboardSelectionToFirstItem(on: page)
            },
            onCreateBoundaryPage: { edgeSide in
                guard launchSort.allowsReordering, store.searchQuery.isEmpty else { return nil }
                let insertionPosition = edgeSide < 0 ? 0 : pages.count
                return store.insertEmptyPage(atSortedPosition: insertionPosition)
            },
            onRootDragStarted: { requestID in
                DispatchQueue.main.async {
                    guard rootDragStartRequest?.id == requestID else { return }
                    rootDragStartRequest = nil
                }
            },
            onOpen: { item in
                open(item)
            },
            onReveal: { item in
                store.revealInFinder(item)
                onDismiss()
            },
            onUninstall: { item in
                confirmUninstall(item)
            },
            onRenameItem: { itemID, name in
                guard isPro else {
                    onOpenLicenseSettings()
                    return
                }
                store.renameItem(itemID, to: name)
            },
            onRenameUnavailable: onOpenLicenseSettings,
            onRenameEnded: {
                DispatchQueue.main.async {
                    focusSearchField()
                }
            },
            onUngroupFolder: { folderID in
                applyPageMutationResult(store.ungroupFolder(folderID))
            },
            onHide: { item in
                guard isPro else {
                    onOpenLicenseSettings()
                    return
                }
                store.hideItem(item)
            },
            onReorder: { itemID, slot in
                applyPageMutationResult(store.reorder(itemID: itemID, toSlot: slot))
            },
            onMoveRootItem: { itemID, page, slot in
                applyPageMutationResult(store.moveRootItem(itemID: itemID, toPage: page, toSlot: slot))
            },
            onDropRootItem: { itemID, targetID in
                applyPageMutationResult(store.dropRootItem(itemID: itemID, on: targetID))
            },
            onEmptyTap: {
                onDismiss()
            },
            selectedItemID: keyboardSelectionID,
            isInSearchMode: isSearching,
            onBeginSearchDrag: { itemID, slot in
                // 搜索态下用户开始拖拽：把 app 插到"进入搜索前的那一页"鼠标对应的 slot。
                // 如果目标页满了，store 的 insertItemGroup 会把溢出的最后一个 root 推到下一页。
                let targetPagePosition = pageBeforeSearch ?? currentPage
                SearchDragLog.write("onBeginSearchDrag: itemID=\(itemID), slot=\(slot), pageBeforeSearch=\(pageBeforeSearch.map(String.init) ?? "nil"), currentPage=\(currentPage), targetPagePosition=\(targetPagePosition)")
                applyPageMutationResult(
                    store.moveItemToRootPage(
                        itemID: itemID,
                        toPage: targetPagePosition,
                        toSlot: slot
                    )
                )
                clearSearch()
                return targetPagePosition
            }
        )
        .frame(width: pageWidth, height: pageHeight, alignment: .leading)
        .clipped()
    }

    private func pageBody(
        pageIndex: Int,
        pageItems: [LaunchItem],
        columns: Int,
        rows: Int,
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        size: CGSize
    ) -> some View {
        let displayItems = displayOrder(for: pageIndex, items: pageItems)
        return ZStack {
            ForEach(Array(displayItems.enumerated()), id: \.element.id) { itemIndex, item in
                tileBody(
                    item: item,
                    itemIndex: itemIndex,
                    pageIndex: pageIndex,
                    columns: columns,
                    rows: rows,
                    size: size
                )
            }
        }
        .frame(width: pageWidth, height: pageHeight)
        .offset(x: CGFloat(pageIndex - currentPage) * pageWidth + dragOffset)
    }

    private func tileBody(
        item: LaunchItem,
        itemIndex: Int,
        pageIndex: Int,
        columns: Int,
        rows: Int,
        size: CGSize
    ) -> some View {
        let isPlaceholder = draggingItemID == item.id
        let isOpenFolderSource = store.openFolderID == item.id
        let isPressed = pressedItemID == item.id && pageIndex == currentPage
        let x = tileX(index: itemIndex, columns: columns, size: size)
        let y = tileY(index: itemIndex, columns: columns, rows: rows, size: size)
        let previewItems = item.kind == .folder ? store.children(of: item.id) : []
        return AppTile(
            item: item,
            previewItems: previewItems,
            isPressed: isPressed && !isPlaceholder,
            isDragging: false,
            isDropTarget: shouldShowDropTarget(for: item),
            metrics: appTileMetrics(for: size),
            canRename: isPro,
            openAction: { open(item) },
            revealAction: { store.revealInFinder(item) },
            uninstallAction: canUninstall(item) ? {
                confirmUninstall(item)
            } : nil,
            renameAction: { name in
                guard isPro else {
                    onOpenLicenseSettings()
                    return
                }
                store.renameItem(item.id, to: name)
            },
            renameUnavailableAction: onOpenLicenseSettings,
            ungroupAction: item.kind == .folder ? {
                applyPageMutationResult(store.ungroupFolder(item.id))
            } : nil
        )
        .opacity(isPlaceholder || isOpenFolderSource ? 0 : 1)
        .allowsHitTesting(!isPlaceholder && !isOpenFolderSource)
        .zIndex(dragDropTargetID == item.id ? 8 : 0)
        .position(x: x, y: y)
        .highPriorityGesture(tileDragGesture(for: item, size: size))
    }

    private func draggedTileOverlay(item: LaunchItem) -> some View {
        let previewItems = item.kind == .folder ? store.children(of: item.id) : []
        return AppTile(
            item: item,
            previewItems: previewItems,
            isPressed: !isCompletingDrag,
            isDragging: !isCompletingDrag,
            isDropTarget: false,
            metrics: appTileMetrics(for: currentSize),
            openAction: { },
            revealAction: { },
            uninstallAction: nil,
            renameAction: nil,
            ungroupAction: nil
        )
        .position(x: dragLocation.x, y: dragLocation.y)
        .zIndex(20)
        .allowsHitTesting(false)
    }

    private func tileX(index: Int, columns: Int, size: CGSize) -> CGFloat {
        let margin = horizontalPageMargin(for: size)
        let slotWidth = contentWidth(for: size) / CGFloat(columns)
        return margin + slotWidth * (CGFloat(index % columns) + 0.5)
    }

    private func tileY(index: Int, columns: Int, rows: Int, size: CGSize) -> CGFloat {
        let row = CGFloat(index / columns)
        let top = gridTopY(for: size)
        let bottom = gridBottomY(for: size)
        guard rows > 1 else {
            return (top + bottom) / 2
        }

        return top + ((bottom - top) / CGFloat(rows - 1)) * row
    }

    private func displayOrder(for pageIndex: Int, items: [LaunchItem]) -> [LaunchItem] {
        guard let draggingItemID else { return items }
        guard pageIndex == dragTargetPage,
              let override = pageOrderOverride
        else {
            return items.filter { $0.id != draggingItemID }
        }

        var byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        if let draggedItem {
            byID[draggedItem.id] = draggedItem
        }
        let reordered = override.compactMap { byID[$0] }
        return reordered.count == override.count ? reordered : items.filter { $0.id != draggingItemID }
    }

    private func shouldShowDropTarget(for item: LaunchItem) -> Bool {
        guard dragDropTargetID == item.id else { return false }
        return draggedItem?.kind != .folder
    }

    private func tapHitsTile(at point: CGPoint, size: CGSize) -> Bool {
        let columns = columnCount(for: size)
        let rows = rowCount(for: size)
        let pageSize = max(columns * rows, 1)
        let pages = visiblePages(pageSize: pageSize)
        guard currentPage >= 0, currentPage < pages.count else { return false }

        let pageItems = displayOrder(for: currentPage, items: pages[currentPage])
        return pageItems.enumerated().contains { itemIndex, item in
            let center = CGPoint(
                x: tileX(index: itemIndex, columns: columns, size: size),
                y: tileY(index: itemIndex, columns: columns, rows: rows, size: size)
            )
            return appTileContentHit(at: point, center: center, item: item, size: size)
        }
    }

    private func appTileContentHit(at point: CGPoint, center: CGPoint, item: LaunchItem, size: CGSize) -> Bool {
        let metrics = appTileMetrics(for: size)
        let iconSize = metrics.iconSize
        let labelFont = appTileLabelFont(for: metrics)
        let labelHeight = appTileLabelHeight(for: metrics)
        let labelWidth = min(
            ceil((item.effectiveDisplayName as NSString).size(withAttributes: [.font: labelFont]).width),
            metrics.tileWidth
        )
        let contentHeight = iconSize + metrics.labelSpacing + labelHeight
        let iconRect = CGRect(
            x: center.x - iconSize / 2,
            y: center.y - contentHeight / 2,
            width: iconSize,
            height: iconSize
        )
        let labelRect = CGRect(
            x: center.x - labelWidth / 2,
            y: iconRect.maxY + metrics.labelSpacing,
            width: labelWidth,
            height: labelHeight
        )

        return iconRect.contains(point) || labelRect.contains(point)
    }

    private func slot(at point: CGPoint, columns: Int, rows: Int, size: CGSize, itemCount: Int) -> Int {
        let margin = horizontalPageMargin(for: size)
        let slotWidth = contentWidth(for: size) / CGFloat(columns)
        let rawCol = Int(((point.x - margin) / slotWidth).rounded(.down))
        let col = max(0, min(columns - 1, rawCol))

        let top = gridTopY(for: size)
        let bottom = gridBottomY(for: size)
        let step = rows > 1 ? max((bottom - top) / CGFloat(rows - 1), 1) : max(bottom - top, 1)
        let rawRow = Int(((point.y - top) / step).rounded())
        let row = max(0, min(rows - 1, rawRow))

        return min(row * columns + col, max(itemCount - 1, 0))
    }

    private func insertionSlot(
        at point: CGPoint,
        previousPoint: CGPoint,
        pageIndex: Int,
        pageItems: [LaunchItem],
        columns: Int,
        rows: Int,
        size: CGSize,
        pageSize: Int
    ) -> Int? {
        let top = gridTopY(for: size)
        let bottom = gridBottomY(for: size)
        let step = rows > 1 ? max((bottom - top) / CGFloat(rows - 1), 1) : max(bottom - top, 1)
        let rawRow = Int(((point.y - top) / step).rounded())
        let targetRow = max(0, min(rows - 1, rawRow))
        let originRow = (dragOriginSlot ?? 0) / columns
        guard shouldUpdateOrderForRowChange(
            from: originRow,
            to: targetRow,
            targetRowCenterY: top + step * CGFloat(targetRow),
            point: point,
            previousPoint: previousPoint,
            startPoint: dragStartLocation
        ) else {
            return nil
        }

        let displayItems = displayOrder(for: pageIndex, items: pageItems)
        let slot = displayItems.enumerated().reduce(0) { result, pair in
            let itemIndex = pair.offset
            let item = pair.element
            guard item.id != draggingItemID else { return result }

            let itemRow = itemIndex / columns
            guard itemRow <= targetRow else { return result }
            if itemRow < targetRow {
                return result + 1
            }

            let itemCenterX = tileX(index: itemIndex, columns: columns, size: size)
            return point.x > itemCenterX ? result + 1 : result
        }

        let candidateCount = displayItems.filter { $0.id != draggingItemID }.count
        let maxSlot = min(candidateCount, max(pageSize - 1, 0))
        return max(0, min(slot, maxSlot))
    }

    private func shouldUpdateOrderForRowChange(
        from originRow: Int,
        to targetRow: Int,
        targetRowCenterY: CGFloat,
        point: CGPoint,
        previousPoint: CGPoint,
        startPoint: CGPoint?
    ) -> Bool {
        guard targetRow != originRow else { return true }
        guard let startPoint,
              abs(point.x - startPoint.x) >= rowChangeHorizontalThreshold
        else {
            return false
        }

        if abs(point.y - targetRowCenterY) <= rowCenterTolerance {
            return true
        }

        if targetRow < originRow {
            return previousPoint.y >= targetRowCenterY && point.y <= targetRowCenterY
                || point.y < targetRowCenterY
        }

        return previousPoint.y <= targetRowCenterY && point.y >= targetRowCenterY
            || point.y > targetRowCenterY
    }

    private func tileDragGesture(for item: LaunchItem, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("grid"))
            .onChanged { value in
                handleTilePress(item: item, drag: value, size: size)
            }
            .onEnded { value in
                endTilePress(item: item, drag: value, size: size)
            }
    }

    private func activeTileDragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("grid"))
            .onChanged { value in
                guard let draggedItem,
                      draggingItemID == draggedItem.id
                else { return }

                updateTileDrag(item: draggedItem, drag: value, size: size)
            }
            .onEnded { value in
                guard let draggedItem,
                      draggingItemID == draggedItem.id
                else { return }

                endTilePress(item: draggedItem, drag: value, size: size)
            }
    }

    private func handleTilePress(item: LaunchItem, drag: DragGesture.Value, size: CGSize) {
        guard !isCompletingDrag else { return }

        if pressedItemID != item.id {
            pressedItemID = item.id
        }
        resetPageDragOffset()

        let distance = hypot(drag.translation.width, drag.translation.height)
        if draggingItemID == nil, distance > dragActivationDistance {
            beginTileDrag(item: item, drag: drag, size: size)
        }
        if draggingItemID == item.id {
            updateTileDrag(item: item, drag: drag, size: size)
        }
    }

    private func endTilePress(item: LaunchItem, drag: DragGesture.Value, size: CGSize) {
        guard !isCompletingDrag else { return }

        let wasDragging = draggingItemID == item.id
        pressedItemID = nil
        if wasDragging {
            completeTileDrag(size: size)
            return
        }

        let distance = hypot(drag.translation.width, drag.translation.height)
        if distance <= dragActivationDistance {
            open(item)
        }
    }

    private func open(_ item: LaunchItem) {
        if item.kind == .folder {
            openFolder(item.id)
        } else {
            // 打开 app 即完成搜索意图，退出搜索态再 dismiss，下次呼出回到正常网格
            if !store.searchQuery.isEmpty {
                clearSearch()
            }
            // 先同步收掉 panel + 让出 active app 状态，再启动目标 app，
            // 避免 Raycast 形态的目标 panel 因为我们仍然是 active app 而瞬间失焦自动隐藏。
            onLaunchApp()
            store.open(item)
        }
    }

    private func confirmUninstall(_ item: LaunchItem) {
        guard item.kind == .application else { return }
        hasFullDiskAccess = Self.detectFullDiskAccess()
        guard canUninstall(item) else {
            setUninstallSession(UninstallPanelSession(
                item: item,
                phase: .failed("\(item.effectiveDisplayName) is a protected macOS system app and cannot be moved to Trash by KidoX.")
            ))
            return
        }

        let session = UninstallPanelSession(item: item, phase: .planning)
        setUninstallSession(session)
        resetDragState()
        resetFolderDragState()

        Task { @MainActor in
            do {
                let plan = try await store.makeUninstallPlan(for: item)
                guard uninstallSession?.id == session.id else { return }
                uninstallSession?.phase = .confirming(plan)
            } catch {
                guard uninstallSession?.id == session.id else { return }
                uninstallSession?.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func canUninstall(_ item: LaunchItem) -> Bool {
        item.kind == .application && ApplicationUninstaller.canUninstallApplication(at: item.url)
    }

    @MainActor
    private func performInlineUninstall(_ item: LaunchItem, plan: ApplicationUninstallPlan) async -> Bool {
        uninstallSession?.phase = .uninstalling(plan)
        let completionAnimation = makeUninstallCompletionAnimation(for: item, size: currentSize)

        do {
            let uninstallResult = try await store.uninstallApplicationKeepingRecord(item, plan: plan)
            onRestoreFocusAfterModalInteraction()
            if uninstallResult.hasDataRemovalFailures {
                let pageMutationResult = store.removeUninstalledApplicationRecord(item)
                applyPageMutationResult(pageMutationResult)
                reconcileOpenFolderAfterUninstall()
                ensureKeyboardSelectionIsValid()
                setUninstallSession(UninstallPanelSession(item: item, phase: .completed(uninstallResult)))
            } else {
                setUninstallSession(nil)
                if let completionAnimation {
                    uninstallCompletionAnimation = completionAnimation
                } else {
                    let pageMutationResult = store.removeUninstalledApplicationRecord(item)
                    applyPageMutationResult(pageMutationResult)
                    reconcileOpenFolderAfterUninstall()
                    ensureKeyboardSelectionIsValid()
                }
            }
            return true
        } catch {
            onRestoreFocusAfterModalInteraction()
            uninstallSession?.phase = .failed(error.localizedDescription)
            return true
        }
    }

    @MainActor
    private func retryFailedUninstallDataRemovals(_ result: ApplicationUninstallResult) async -> Bool {
        let updatedResult = await store.retryFailedUninstallDataRemovals(from: result)
        onRestoreFocusAfterModalInteraction()
        uninstallSession?.phase = .completed(updatedResult)
        return true
    }

    private func openAppDataPrivacySettings() {
        let candidateURLs = [
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"),
            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
        ]

        if let url = candidateURLs.compactMap({ $0 }).first {
            NSWorkspace.shared.open(url)
        }
    }

    private func makeUninstallCompletionAnimation(for item: LaunchItem, size: CGSize) -> UninstallCompletionAnimation? {
        guard size.width > 0, size.height > 0 else { return nil }
        let metrics = appTileMetrics(for: size)
        let icon = NSWorkspace.shared.icon(forFile: item.sourcePath)
        icon.size = CGSize(width: metrics.iconSize, height: metrics.iconSize)

        let center = uninstallAnimationCenter(for: item, size: size)
        return UninstallCompletionAnimation(
            item: item,
            icon: icon,
            center: center,
            containerSize: size,
            iconSize: metrics.iconSize
        )
    }

    private func uninstallPopoverAnchor(for item: LaunchItem, size: CGSize) -> CGPoint {
        uninstallAnimationCenter(for: item, size: size)
    }

    private func uninstallAnimationCenter(for item: LaunchItem, size: CGSize) -> CGPoint {
        if let openFolderID = store.openFolderID,
           item.parentID == openFolderID {
            let children = store.children(of: openFolderID)
            let ordered = folderDisplayOrder(children)
            if let itemIndex = ordered.firstIndex(where: { $0.id == item.id }) {
                let layoutHeight = folderGridLayoutHeight(for: size, itemCount: children.count)
                let tileCenter = folderTilePosition(
                    index: itemIndex,
                    itemCount: children.count,
                    size: size,
                    layoutHeight: layoutHeight
                )
                let origin = folderPanelOrigin(folderID: openFolderID, size: size)
                return CGPoint(
                    x: origin.x + tileCenter.x,
                    y: origin.y + tileCenter.y - appTileIconLabelYOffset(for: size)
                )
            }
        }

        let columns = columnCount(for: size)
        let rows = rowCount(for: size)
        let pageSize = max(columns * rows, 1)
        let pages = visiblePages(pageSize: pageSize)
        let pageIndex = currentPage >= 0 && currentPage < pages.count ? currentPage : 0
        if pageIndex < pages.count {
            let pageItems = displayOrder(for: pageIndex, items: pages[pageIndex])
            if let itemIndex = pageItems.firstIndex(where: { $0.id == item.id }) {
                return CGPoint(
                    x: tileX(index: itemIndex, columns: columns, size: size),
                    y: tileY(index: itemIndex, columns: columns, rows: rows, size: size)
                        - appTileIconLabelYOffset(for: size)
                )
            }
        }

        return CGPoint(x: size.width / 2, y: size.height / 2)
    }

    private func reconcileOpenFolderAfterUninstall() {
        guard let openFolderID = store.openFolderID else { return }
        if store.items.contains(where: { $0.id == openFolderID }) {
            return
        }

        store.openFolderID = nil
        folderOverlayIsExpanded = false
        folderOverlayProgress = 0
    }

    private static func detectFullDiskAccess() -> Bool {
        let fileManager = FileManager.default
        let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
        let probeURLs = [
            libraryURL?.appendingPathComponent("Mail", isDirectory: true),
            libraryURL?.appendingPathComponent("Messages", isDirectory: true),
            libraryURL?.appendingPathComponent("Safari", isDirectory: true)
        ].compactMap { $0 }

        var testedProtectedLocation = false
        for url in probeURLs where fileManager.fileExists(atPath: url.path) {
            testedProtectedLocation = true
            if (try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) != nil {
                return true
            }
        }

        return !testedProtectedLocation
    }

    private func formattedByteCount(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private static let folderMorphAnimation: Animation = .spring(response: 0.42, dampingFraction: 0.92, blendDuration: 0.06)
    private static let folderMorphDuration: TimeInterval = 0.42

    private func openFolder(_ id: LaunchItem.ID) {
        guard draggingItemID == nil else { return }
        resetFolderDragState()
        store.openFolderID = id
        folderOverlayIsExpanded = false
        folderOverlayProgress = 0
        pressedItemID = nil

        DispatchQueue.main.async {
            withAnimation(Self.folderMorphAnimation) {
                folderOverlayIsExpanded = true
                folderOverlayProgress = 1
            }
        }
    }

    private func closeFolder(resetsFolderDragState: Bool = true) {
        withAnimation(Self.folderMorphAnimation) {
            if resetsFolderDragState {
                resetFolderDragState()
            }
            folderOverlayIsExpanded = false
            folderOverlayProgress = 0
            pressedItemID = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.folderMorphDuration + 0.02) {
            guard !folderOverlayIsExpanded else { return }
            store.openFolderID = nil
        }
    }

    // ESC 三层语义：folder 优先关 folder，其次清搜索，最后才 dismiss panel。
    // inline rename 在自己的 field editor key monitor 中优先处理 ESC。
    private func handleEscape() {
        if uninstallSession != nil {
            setUninstallSession(nil)
            focusSearchField()
            return
        }
        if store.openFolderID != nil {
            closeFolder()
            return
        }
        if isSearching {
            clearSearch()
            return
        }
        onDismiss()
    }

    private func setUninstallSession(_ session: UninstallPanelSession?) {
        uninstallSession = session
        onModalInteractionChanged(session != nil)
    }

    private func clearSearch() {
        store.searchQuery = ""
        keyboardSelectionID = nil
    }

    private func beginTileDrag(item: LaunchItem, drag: DragGesture.Value, size: CGSize) {
        guard store.searchQuery.isEmpty else { return }
        resetPageDragOffset()

        let columns = columnCount(for: size)
        let rows = rowCount(for: size)
        let pageSize = max(columns * rows, 1)
        let pages = visiblePages(pageSize: pageSize)
        guard currentPage < pages.count else { return }
        let pageItems = pages[currentPage]
        let initialOrder = pageItems.map(\.id)
        guard let slotIndex = initialOrder.firstIndex(of: item.id) else { return }

        let tileCenter = CGPoint(
            x: tileX(index: slotIndex, columns: columns, size: size),
            y: tileY(index: slotIndex, columns: columns, rows: rows, size: size)
        )
        dragFingerOffset = CGSize(
            width: drag.startLocation.x - tileCenter.x,
            height: drag.startLocation.y - tileCenter.y
        )
        draggedItem = item
        dragOriginPage = currentPage
        dragTargetPage = currentPage
        dragOriginSlot = slotIndex
        dragStartLocation = drag.startLocation
        dragEnteredDropTargetID = nil
        dragEnteredDropTargetDirection = nil
        dragPreviousMouseLocation = drag.location
        lastDragPageTurnDate = .distantPast
        dragEdgeSide = 0
        dragEdgeEnteredAt = nil
        dragEdgeHasTurnedInCurrentRun = false
        pageOrderOverride = initialOrder
        draggingItemID = item.id
    }

    private func updateTileDrag(item: LaunchItem, drag: DragGesture.Value, size: CGSize) {
        guard draggingItemID == item.id, !isCompletingDrag else { return }
        let previousMouseLocation = dragPreviousMouseLocation ?? drag.startLocation
        defer { dragPreviousMouseLocation = drag.location }

        updateActiveRootDrag(
            item: item,
            pointerLocation: drag.location,
            previousMouseLocation: previousMouseLocation,
            size: size,
            shouldUpdatePageForEdge: true
        )
    }

    private func updateActiveRootDrag(
        item: LaunchItem,
        pointerLocation: CGPoint,
        previousMouseLocation: CGPoint,
        size: CGSize,
        shouldUpdatePageForEdge: Bool
    ) {
        guard draggingItemID == item.id, !isCompletingDrag else { return }
        let columns = columnCount(for: size)
        let rows = rowCount(for: size)
        let pageSize = max(columns * rows, 1)
        var pages = visiblePages(pageSize: pageSize)
        guard !pages.isEmpty else { return }

        dragLocation = CGPoint(
            x: pointerLocation.x - dragFingerOffset.width,
            y: pointerLocation.y - dragFingerOffset.height
        )

        if shouldUpdatePageForEdge {
            updateDragTargetPageIfNeeded(location: dragLocation, size: size, pages: pages)
            pages = visiblePages(pageSize: pageSize)
            guard !pages.isEmpty else { return }
        }

        let targetPage = max(0, min(dragTargetPage ?? currentPage, pages.count - 1))
        dragTargetPage = targetPage
        let pageItems = pages[targetPage]
        let activeTarget = dropTargetHit(
            at: pointerLocation,
            pageIndex: targetPage,
            pageItems: pageItems,
            columns: columns,
            rows: rows,
            size: size,
            width: dropTargetIconSize,
            height: dropTargetIconSize
        )

        dragDropTargetID = activeTarget?.id
        if let activeTarget {
            if dragEnteredDropTargetID != activeTarget.id {
                dragEnteredDropTargetDirection = dropTargetEntryDirection(
                    from: previousMouseLocation,
                    to: pointerLocation,
                    in: activeTarget.rect
                )
            }
            dragEnteredDropTargetID = activeTarget.id
            return
        }

        guard let targetSlot = insertionSlot(
            at: pointerLocation,
            previousPoint: previousMouseLocation,
            pageIndex: targetPage,
            pageItems: pageItems,
            columns: columns,
            rows: rows,
            size: size,
            pageSize: pageSize
        ) else {
            return
        }

        if let approachingTarget = dropTargetHit(
            atSlot: targetSlot,
            pageIndex: targetPage,
            pageItems: pageItems,
            columns: columns,
            rows: rows,
            size: size
        ),
           approachingTarget.id == dragEnteredDropTargetID {
            guard shouldResumeSortingAfterLeavingDropTarget(
                at: pointerLocation,
                targetRect: approachingTarget.rect
            ) else {
                return
            }
        }

        dragEnteredDropTargetID = nil
        dragEnteredDropTargetDirection = nil
        updatePageOrderOverride(
            itemID: item.id,
            pageItems: pageItems,
            pageSize: pageSize,
            targetSlot: targetSlot
        )
    }

    private func updateDragTargetPageIfNeeded(
        drag: DragGesture.Value,
        size: CGSize,
        pages: [[LaunchItem]]
    ) {
        updateDragTargetPageIfNeeded(location: drag.location, size: size, pages: pages)
    }

    private func updateDragTargetPageIfNeeded(
        location: CGPoint,
        size: CGSize,
        pages: [[LaunchItem]]
    ) {
        let pageCount = pages.count
        guard pageCount > 0 else { return }

        let edgeSide: Int
        if location.x > size.width - dragPageTurnEdgeWidth {
            edgeSide = 1
        } else if location.x < dragPageTurnEdgeWidth {
            edgeSide = -1
        } else {
            edgeSide = 0
        }

        if edgeSide == 0 {
            dragEdgeSide = 0
            dragEdgeEnteredAt = nil
            dragEdgeHasTurnedInCurrentRun = false
            return
        }

        let now = Date()
        if dragEdgeSide != edgeSide {
            dragEdgeSide = edgeSide
            dragEdgeEnteredAt = now
            dragEdgeHasTurnedInCurrentRun = false
            return
        }

        guard let enteredAt = dragEdgeEnteredAt else {
            dragEdgeEnteredAt = now
            return
        }

        let requiredDwell = dragEdgeHasTurnedInCurrentRun ? dragPageTurnRepeatDwell : dragPageTurnDwell
        guard now.timeIntervalSince(enteredAt) >= requiredDwell,
              now.timeIntervalSince(lastDragPageTurnDate) >= dragPageTurnCooldown
        else { return }

        let proposedPage = currentPage + edgeSide
        let targetPage: Int
        if proposedPage < 0 {
            guard pages.first?.isEmpty == false else { return }
            targetPage = store.insertEmptyPage(atSortedPosition: 0)
            currentPage += 1
            dragOriginPage = dragOriginPage.map { $0 + 1 }
        } else if proposedPage >= pageCount {
            guard pages.last?.isEmpty == false else { return }
            targetPage = store.insertEmptyPage(atSortedPosition: pageCount)
        } else {
            targetPage = proposedPage
        }
        lastDragPageTurnDate = now
        dragTargetPage = targetPage
        dragEdgeEnteredAt = now
        dragEdgeHasTurnedInCurrentRun = true

        withAnimation(.spring(response: 0.45, dampingFraction: 0.84)) {
            currentPage = targetPage
            dragOffset = 0
        }
    }

    private func updatePageOrderOverride(
        itemID: LaunchItem.ID,
        pageItems: [LaunchItem],
        pageSize: Int,
        targetSlot: Int
    ) {
        var order = pageItems.map(\.id).filter { $0 != itemID }
        let bounded = max(0, min(targetSlot, min(order.count, pageSize - 1)))
        order.insert(itemID, at: bounded)
        if order.count > pageSize {
            order.removeLast()
        }

        guard pageOrderOverride != order else { return }
        withAnimation(.snappy(duration: 0.22)) {
            pageOrderOverride = order
        }
    }

    private func dropTargetHit(
        at point: CGPoint,
        pageIndex: Int,
        pageItems: [LaunchItem],
        columns: Int,
        rows: Int,
        size: CGSize,
        width: CGFloat,
        height: CGFloat
    ) -> DropTargetHit? {
        let displayItems = displayOrder(for: pageIndex, items: pageItems)
        let candidates = displayItems.enumerated().compactMap { itemIndex, item -> DropTargetHit? in
            guard item.id != draggingItemID else { return nil }

            let center = CGPoint(
                x: tileX(index: itemIndex, columns: columns, size: size),
                y: tileY(index: itemIndex, columns: columns, rows: rows, size: size)
            )
            let rect = CGRect(
                x: center.x - width / 2,
                y: center.y - height / 2,
                width: width,
                height: height
            )
            guard rect.contains(point) else { return nil }

            return DropTargetHit(
                id: item.id,
                rect: rect,
                distance: hypot(point.x - center.x, point.y - center.y)
            )
        }

        return candidates.min { $0.distance < $1.distance }
    }

    private func dropTargetHit(
        atSlot slot: Int,
        pageIndex: Int,
        pageItems: [LaunchItem],
        columns: Int,
        rows: Int,
        size: CGSize
    ) -> DropTargetHit? {
        let displayItems = displayOrder(for: pageIndex, items: pageItems)
        guard slot >= 0, slot < displayItems.count else { return nil }

        let candidate = displayItems[slot]
        guard candidate.id != draggingItemID else { return nil }

        let center = CGPoint(
            x: tileX(index: slot, columns: columns, size: size),
            y: tileY(index: slot, columns: columns, rows: rows, size: size)
        )
        let rect = CGRect(
            x: center.x - dropTargetIconSize / 2,
            y: center.y - dropTargetIconSize / 2,
            width: dropTargetIconSize,
            height: dropTargetIconSize
        )

        return DropTargetHit(
            id: candidate.id,
            rect: rect,
            distance: hypot(dragLocation.x - center.x, dragLocation.y - center.y)
        )
    }

    private func dropTargetEntryDirection(
        from previousPoint: CGPoint,
        to currentPoint: CGPoint,
        in rect: CGRect
    ) -> DropTargetEntryDirection {
        if previousPoint.x <= rect.minX && currentPoint.x > rect.minX {
            return .fromLeft
        }
        if previousPoint.x >= rect.maxX && currentPoint.x < rect.maxX {
            return .fromRight
        }
        return .nonHorizontal
    }

    private func shouldResumeSortingAfterLeavingDropTarget(
        at point: CGPoint,
        targetRect: CGRect
    ) -> Bool {
        guard let dragEnteredDropTargetDirection else { return false }

        switch dragEnteredDropTargetDirection {
        case .fromLeft:
            return point.x >= targetRect.maxX
        case .fromRight:
            return point.x <= targetRect.minX
        case .nonHorizontal:
            return point.x <= targetRect.minX || point.x >= targetRect.maxX
        }
    }

    private func completeTileDrag(size: CGSize) {
        guard let targetLocation = finalDragLocation(size: size) else {
            finishDragWithoutAnimation()
            return
        }

        isCompletingDrag = true
        withAnimation(.interpolatingSpring(stiffness: 520, damping: 38)) {
            dragLocation = targetLocation
        }

        let shouldAnimateLayoutCommit = dragDropTargetID != nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            finishDragWithoutAnimation(animateLayout: shouldAnimateLayoutCommit)
        }
    }

    private func finalDragLocation(size: CGSize) -> CGPoint? {
        let columns = columnCount(for: size)
        let rows = rowCount(for: size)
        let pageSize = max(columns * rows, 1)
        let pages = visiblePages(pageSize: pageSize)
        guard let targetPage = dragTargetPage,
              targetPage >= 0,
              targetPage < pages.count
        else { return nil }

        let pageItems = pages[targetPage]
        if let dragDropTargetID,
           let targetIndex = displayOrder(for: targetPage, items: pageItems).firstIndex(where: { $0.id == dragDropTargetID }) {
            return CGPoint(
                x: tileX(index: targetIndex, columns: columns, size: size),
                y: tileY(index: targetIndex, columns: columns, rows: rows, size: size)
            )
        }

        guard let draggingID = draggingItemID,
              let order = pageOrderOverride,
              let slotInPage = order.firstIndex(of: draggingID)
        else { return nil }

        return CGPoint(
            x: tileX(index: slotInPage, columns: columns, size: size),
            y: tileY(index: slotInPage, columns: columns, rows: rows, size: size)
        )
    }

    private func commitTileDrag() {
        guard let draggingID = draggingItemID,
              let order = pageOrderOverride,
              let slotInPage = order.firstIndex(of: draggingID),
              let targetPage = dragTargetPage
        else { return }

        if let dragDropTargetID {
            applyPageMutationResult(store.dropRootItem(itemID: draggingID, on: dragDropTargetID))
        } else if targetPage == dragOriginPage {
            applyPageMutationResult(store.reorder(itemID: draggingID, toSlot: slotInPage))
        } else {
            applyPageMutationResult(store.moveRootItem(itemID: draggingID, toPage: targetPage, toSlot: slotInPage))
        }
    }

    private func resetDragState() {
        draggingItemID = nil
        draggedItem = nil
        dragOriginPage = nil
        dragTargetPage = nil
        dragDropTargetID = nil
        dragEnteredDropTargetID = nil
        dragEnteredDropTargetDirection = nil
        pageOrderOverride = nil
        isCompletingDrag = false
        dragLocation = .zero
        dragStartLocation = nil
        dragPreviousMouseLocation = nil
        dragFingerOffset = .zero
        dragOriginSlot = nil
        lastDragPageTurnDate = .distantPast
        dragEdgeSide = 0
        dragEdgeEnteredAt = nil
        dragEdgeHasTurnedInCurrentRun = false
    }

    private func finishDragWithoutAnimation(animateLayout: Bool = false) {
        if animateLayout {
            withAnimation(.snappy(duration: 0.22)) {
                commitTileDrag()
                resetDragState()
            }
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            commitTileDrag()
            resetDragState()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(KidoXL10n.ui("Scanning Applications", languageRawValue: appLanguageRaw))
                .font(.headline)
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(.secondary)
            Text(KidoXL10n.ui(
                store.searchQuery.isEmpty ? "No applications found" : "No matching apps",
                languageRawValue: appLanguageRaw
            ))
                .font(.headline)
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func folderOverlay(size: CGSize) -> some View {
        if let folderID = store.openFolderID,
           let folder = store.items.first(where: { $0.id == folderID }) {
            let children = store.children(of: folderID)
            let panelHeight = folderPanelHeight(for: size, itemCount: children.count)
            let contentHeight = folderPanelContentHeight(for: size, itemCount: children.count)
            let isScrollable = contentHeight > panelHeight + 0.5
            let progress = folderOverlayProgress
            let easedProgress = smoothStep(progress)
            let panelWidth = folderPanelWidth(for: size)
            let metrics = appTileMetrics(for: size)

            let iconCenter = folderIconCenter(folderID: folderID, size: size)
                ?? CGPoint(
                    x: size.width / 2,
                    y: folderPanelCenterY(folderID: folderID, size: size, itemCount: children.count)
                )
            let panelCenter = CGPoint(
                x: size.width / 2,
                y: folderPanelCenterY(folderID: folderID, size: size, itemCount: children.count)
            )
            let posX = interpolate(from: iconCenter.x, to: panelCenter.x, progress: easedProgress)
            let posY = interpolate(from: iconCenter.y, to: panelCenter.y, progress: easedProgress)

            let visualWidth = interpolate(from: folderIconVisualSize(for: metrics), to: panelWidth, progress: easedProgress)
            let visualHeight = interpolate(from: folderIconVisualSize(for: metrics), to: panelHeight, progress: easedProgress)
            let uniformScale = visualWidth / panelWidth

            let contentOpacity = folderPanelContentOpacity(progress)
            let sourcePreviewOpacity = folderSourcePreviewOpacity(progress)
            let visualCornerRadius = interpolate(from: folderIconCornerRadius(for: metrics), to: 40, progress: easedProgress)
            let visualShape = RoundedRectangle(cornerRadius: visualCornerRadius, style: .continuous)

            ZStack {
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        closeFolder()
                    }

                Text(folder.effectiveDisplayName)
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: panelWidth - 80)
                    .position(
                        x: size.width / 2,
                        y: folderTitleCenterY(folderID: folderID, size: size, itemCount: children.count)
                    )
                    .opacity(contentOpacity)

                ZStack {
                    Group {
                        if #available(macOS 26.0, *) {
                            visualShape
                                .fill(.black.opacity(0.001))
                                .glassEffect(.clear.interactive(), in: visualShape)
                        } else {
                            visualShape
                                .fill(.ultraThinMaterial)
                        }
                    }
                    .frame(width: visualWidth, height: visualHeight)

                    ZStack(alignment: .top) {
                        if children.isEmpty {
                            Text(KidoXL10n.ui("No applications", languageRawValue: appLanguageRaw))
                                .font(.system(size: 15, weight: .regular))
                                .foregroundStyle(.white.opacity(0.72))
                                .padding(.top, 74)
                        } else if isScrollable {
                            ScrollView(.vertical, showsIndicators: true) {
                                folderDetailGrid(
                                    folderID: folderID,
                                    children: children,
                                    size: size,
                                    layoutHeight: contentHeight
                                )
                            }
                            .frame(width: panelWidth, height: panelHeight)
                        } else {
                            folderDetailGrid(
                                folderID: folderID,
                                children: children,
                                size: size,
                                layoutHeight: panelHeight
                            )
                        }
                    }
                    .frame(width: panelWidth, height: panelHeight)
                    .scaleEffect(
                        x: uniformScale,
                        y: uniformScale,
                        anchor: .center
                    )
                    .frame(width: visualWidth, height: visualHeight)
                    .clipShape(visualShape)
                    .opacity(contentOpacity)

                    visualShape
                        .stroke(
                            LinearGradient(
                                    stops: [
                                        .init(color: .white.opacity(0.60), location: 0.00),
                                        .init(color: .white.opacity(0.20), location: 0.24),
                                        .init(color: .white.opacity(0.06), location: 0.58),
                                        .init(color: .black.opacity(0.22), location: 1.00)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                            ),
                            lineWidth: 1.0
                        )
                        .frame(width: visualWidth, height: visualHeight)

                    visualShape
                        .inset(by: 1)
                        .stroke(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.18), location: 0.00),
                                    .init(color: .clear, location: 0.34),
                                    .init(color: .black.opacity(0.10), location: 1.00)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.6
                        )
                        .frame(width: visualWidth, height: visualHeight)

                    FolderPreviewIcon(
                        items: children,
                        isDropTarget: false,
                        size: metrics.iconSize,
                        showsBackground: false
                    )
                    .opacity(sourcePreviewOpacity)
                    .allowsHitTesting(false)
                }
                .shadow(
                    color: .black.opacity(0.26),
                    radius: interpolate(from: 10, to: 18, progress: easedProgress),
                    x: 0,
                    y: interpolate(from: 5, to: 10, progress: easedProgress)
                )
                .contentShape(visualShape)
                .onTapGesture { }
                .position(
                    x: posX,
                    y: posY
                )

                folderDraggedTileOverlay(folderID: folderID, size: size)
                    .zIndex(40)
            }
        }
    }

    private func folderDetailGrid(
        folderID: LaunchItem.ID,
        children: [LaunchItem],
        size: CGSize,
        layoutHeight: CGFloat
    ) -> some View {
        let displayItems = folderDisplayOrder(children)

        return ZStack(alignment: .topLeading) {
            ForEach(Array(displayItems.enumerated()), id: \.element.id) { itemIndex, item in
                let isPlaceholder = folderDraggingItemID == item.id
                AppTile(
                    item: item,
                    previewItems: item.kind == .folder ? store.children(of: item.id) : [],
                    isPressed: folderPressedItemID == item.id && !isPlaceholder,
                    isDragging: false,
                    isDropTarget: false,
                    metrics: folderTileMetrics(for: size),
                    openAction: { open(item) },
                    revealAction: { store.revealInFinder(item) },
                    uninstallAction: canUninstall(item) ? {
                        confirmUninstall(item)
                    } : nil,
                    renameAction: nil,
                    ungroupAction: nil
                )
                .opacity(isPlaceholder || item.id == uninstallCompletionAnimation?.item.id || item.id == gridCompactionAnimationRequest?.removedItemID ? 0 : 1)
                .allowsHitTesting(!isPlaceholder && item.id != uninstallCompletionAnimation?.item.id)
                .position(
                    folderTilePosition(
                        index: itemIndex,
                        itemCount: children.count,
                        size: size,
                        layoutHeight: layoutHeight
                    )
                )
                .highPriorityGesture(folderTileDragGesture(for: item, children: children, size: size))
            }
        }
        .frame(width: folderPanelWidth(for: size), height: layoutHeight)
        .coordinateSpace(name: "folderPanel")
    }

    @ViewBuilder
    private func folderDraggedTileOverlay(folderID: LaunchItem.ID, size: CGSize) -> some View {
        if !folderDragHasExited,
           let folderDraggedItem,
           folderDraggingItemID == folderDraggedItem.id,
           let globalLocation = folderDragGlobalLocation(folderID: folderID, size: size) {
            AppTile(
                item: folderDraggedItem,
                previewItems: folderDraggedItem.kind == .folder ? store.children(of: folderDraggedItem.id) : [],
                isPressed: true,
                isDragging: true,
                isDropTarget: false,
                metrics: folderTileMetrics(for: size),
                openAction: { },
                revealAction: { },
                uninstallAction: nil,
                renameAction: nil,
                ungroupAction: nil
            )
            .position(globalLocation)
            .allowsHitTesting(false)
        }
    }

    private func folderTileDragGesture(
        for item: LaunchItem,
        children: [LaunchItem],
        size: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("folderPanel"))
            .onChanged { value in
                handleFolderTilePress(item: item, children: children, drag: value, size: size)
            }
            .onEnded { value in
                endFolderTilePress(item: item, children: children, drag: value, size: size)
            }
    }

    private func handleFolderTilePress(
        item: LaunchItem,
        children: [LaunchItem],
        drag: DragGesture.Value,
        size: CGSize
    ) {
        guard !folderDragHasExited else { return }

        if folderPressedItemID != item.id {
            folderPressedItemID = item.id
        }
        resetPageDragOffset()

        let distance = hypot(drag.translation.width, drag.translation.height)
        if folderDraggingItemID == nil, distance > dragActivationDistance {
            beginFolderTileDrag(item: item, children: children, drag: drag, size: size)
        }
        if folderDraggingItemID == item.id {
            updateFolderTileDrag(item: item, children: children, drag: drag, size: size)
        }
    }

    private func endFolderTilePress(
        item: LaunchItem,
        children: [LaunchItem],
        drag: DragGesture.Value,
        size: CGSize
    ) {
        let wasDragging = folderDraggingItemID == item.id
        folderPressedItemID = nil

        guard wasDragging else {
            if folderDragHasExited {
                resetFolderDragState()
                return
            }
            let distance = hypot(drag.translation.width, drag.translation.height)
            if distance <= dragActivationDistance {
                open(item)
            }
            return
        }

        if folderDragHasExited {
            commitFolderDragExit(item, at: drag.location, size: size)
            return
        }

        if isFolderDragOutside(drag.location, size: size) {
            commitFolderDragExit(item, at: drag.location, size: size)
            return
        }

        if let override = folderOrderOverride,
           let targetSlot = override.firstIndex(of: item.id) {
            store.reorder(itemID: item.id, toSlot: targetSlot)
        }
        resetFolderDragState()
    }

    private func beginFolderTileDrag(
        item: LaunchItem,
        children: [LaunchItem],
        drag: DragGesture.Value,
        size: CGSize
    ) {
        resetPageDragOffset()

        let ordered = folderDisplayOrder(children)
        guard let itemIndex = ordered.firstIndex(where: { $0.id == item.id }) else { return }
        let tileCenter = folderTilePosition(
            index: itemIndex,
            itemCount: children.count,
            size: size,
            layoutHeight: folderGridLayoutHeight(for: size, itemCount: children.count)
        )

        folderDraggedItem = item
        folderDraggingItemID = item.id
        folderDragOriginSlot = itemIndex
        folderDragStartLocation = drag.startLocation
        let fingerOffset = CGSize(
            width: drag.startLocation.x - tileCenter.x,
            height: drag.startLocation.y - tileCenter.y
        )
        folderDragFingerOffset = fingerOffset
        folderDragLocation = CGPoint(
            x: drag.location.x - fingerOffset.width,
            y: drag.location.y - fingerOffset.height
        )
        folderOrderOverride = children.map(\.id)
        folderDragHasExited = false
    }

    private func updateFolderTileDrag(
        item: LaunchItem,
        children: [LaunchItem],
        drag: DragGesture.Value,
        size: CGSize
    ) {
        folderDragLocation = CGPoint(
            x: drag.location.x - folderDragFingerOffset.width,
            y: drag.location.y - folderDragFingerOffset.height
        )

        if folderDragHasExited {
            updateRootDragStartRequestCurrentPoint(pointerLocation: drag.location, size: size)
            return
        }

        if isFolderDragOutside(drag.location, size: size) {
            beginFolderDragExitIfNeeded(item: item, pointerLocation: drag.location, size: size)
            return
        }

        guard let targetSlot = folderInsertionSlot(
            at: drag.location,
            previousPoint: drag.startLocation,
            children: children,
            size: size,
            layoutHeight: folderGridLayoutHeight(for: size, itemCount: children.count)
        ) else {
            return
        }
        var order = children.map(\.id).filter { $0 != item.id }
        let bounded = max(0, min(targetSlot, order.count))
        order.insert(item.id, at: bounded)

        guard folderOrderOverride != order else { return }
        withAnimation(.snappy(duration: 0.18)) {
            folderOrderOverride = order
        }
    }

    private func resetFolderDragState() {
        folderPressedItemID = nil
        folderDraggingItemID = nil
        folderDraggedItem = nil
        folderDragLocation = .zero
        folderDragStartLocation = nil
        folderDragFingerOffset = .zero
        folderDragOriginSlot = nil
        folderOrderOverride = nil
        folderDragHasExited = false
        folderDragExitPanelOrigin = nil
    }

    private func beginFolderDragExitIfNeeded(
        item: LaunchItem,
        pointerLocation: CGPoint,
        size: CGSize
    ) {
        guard !folderDragHasExited else { return }
        folderDragHasExited = true

        let panelOrigin = folderPanelOrigin(size: size)
        folderDragExitPanelOrigin = panelOrigin
        let globalPointerLocation = CGPoint(
            x: panelOrigin.x + pointerLocation.x,
            y: panelOrigin.y + pointerLocation.y
        )
        let globalDragCenter = CGPoint(
            x: panelOrigin.x + folderDragLocation.x,
            y: panelOrigin.y + folderDragLocation.y
        )
        let targetPage = currentPage
        let targetSlot = rootSlotForGlobalPoint(globalPointerLocation, size: size)
        applyPageMutationResult(store.moveItemToRootPage(itemID: item.id, toPage: targetPage, toSlot: targetSlot))

        let columns = columnCount(for: size)
        let rows = rowCount(for: size)
        let pageSize = max(columns * rows, 1)
        let pages = visiblePages(pageSize: pageSize)
        let resolvedPage = pages.firstIndex { page in
            page.contains { $0.id == item.id }
        } ?? min(targetPage, max(pages.count - 1, 0))

        currentPage = resolvedPage
        resetPageDragOffset()
        rootDragStartRequest = RootDragStartRequest(
            id: UUID(),
            itemID: item.id,
            startPoint: globalPointerLocation,
            currentPoint: globalPointerLocation,
            fingerOffset: CGSize(
                width: globalPointerLocation.x - globalDragCenter.x,
                height: globalPointerLocation.y - globalDragCenter.y
            ),
            targetPage: resolvedPage
        )

        folderPressedItemID = nil
        folderDraggingItemID = nil
        folderDraggedItem = nil
        folderDragLocation = .zero
        folderDragStartLocation = nil
        folderDragFingerOffset = .zero
        folderDragOriginSlot = nil
        folderOrderOverride = nil

        closeFolder(resetsFolderDragState: false)
    }

    private func updateRootDragStartRequestCurrentPoint(pointerLocation: CGPoint, size: CGSize) {
        guard let request = rootDragStartRequest else { return }
        let panelOrigin = folderDragExitPanelOrigin ?? folderPanelOrigin(size: size)
        rootDragStartRequest = RootDragStartRequest(
            id: request.id,
            itemID: request.itemID,
            startPoint: request.startPoint,
            currentPoint: CGPoint(
                x: panelOrigin.x + pointerLocation.x,
                y: panelOrigin.y + pointerLocation.y
            ),
            fingerOffset: request.fingerOffset,
            targetPage: request.targetPage
        )
    }

    private func commitFolderDragExit(_ item: LaunchItem, at panelPoint: CGPoint, size: CGSize) {
        guard folderDraggingItemID == item.id else { return }
        let targetSlot = rootSlotForFolderExit(at: panelPoint, size: size)
        applyPageMutationResult(store.moveItemToRootPage(itemID: item.id, toPage: currentPage, toSlot: targetSlot))
        resetDragState()
        closeFolder()
    }

    private func folderDisplayOrder(_ children: [LaunchItem]) -> [LaunchItem] {
        guard let folderOrderOverride else { return children }
        let byID = Dictionary(uniqueKeysWithValues: children.map { ($0.id, $0) })
        let reordered = folderOrderOverride.compactMap { byID[$0] }
        return reordered.count == folderOrderOverride.count ? reordered : children
    }

    private func folderTilePosition(
        index: Int,
        itemCount: Int,
        size: CGSize,
        layoutHeight: CGFloat
    ) -> CGPoint {
        let columns = max(1, folderGridColumnCount(for: size))
        let column = index % columns
        let row = index / columns
        let margin = folderGridHorizontalPadding(for: size)
        let slotWidth = (folderPanelWidth(for: size) - margin * 2) / CGFloat(columns)
        let metrics = folderTileMetrics(for: size)
        let x = margin + slotWidth * (CGFloat(column) + 0.5)
        let y = folderGridTopPadding
            + metrics.tileHeight / 2
            + CGFloat(row) * (
                metrics.tileHeight
                    + effectiveFolderGridRowSpacing(
                        for: size,
                        itemCount: itemCount,
                        layoutHeight: layoutHeight
                    )
            )
        return CGPoint(x: x, y: y)
    }

    private func folderSlot(at point: CGPoint, size: CGSize, itemCount: Int, layoutHeight: CGFloat) -> Int {
        let columns = max(1, folderGridColumnCount(for: size))
        let margin = folderGridHorizontalPadding(for: size)
        let slotWidth = (folderPanelWidth(for: size) - margin * 2) / CGFloat(columns)
        let stepY = folderTileMetrics(for: size).tileHeight + effectiveFolderGridRowSpacing(
            for: size,
            itemCount: itemCount,
            layoutHeight: layoutHeight
        )
        let rawColumn = Int(((point.x - margin) / max(slotWidth, 1)).rounded(.down))
        let rawRow = Int(((point.y - folderGridTopPadding) / max(stepY, 1)).rounded(.down))
        let column = max(0, min(columns - 1, rawColumn))
        let row = max(0, rawRow)
        return min(row * columns + column, max(itemCount - 1, 0))
    }

    private func folderInsertionSlot(
        at point: CGPoint,
        previousPoint: CGPoint,
        children: [LaunchItem],
        size: CGSize,
        layoutHeight: CGFloat
    ) -> Int? {
        let columns = max(1, folderGridColumnCount(for: size))
        let margin = folderGridHorizontalPadding(for: size)
        let slotWidth = (folderPanelWidth(for: size) - margin * 2) / CGFloat(columns)
        let metrics = folderTileMetrics(for: size)
        let stepY = metrics.tileHeight + effectiveFolderGridRowSpacing(
            for: size,
            itemCount: children.count,
            layoutHeight: layoutHeight
        )
        let firstRowCenterY = folderGridTopPadding + metrics.tileHeight / 2
        let maxRow = max(0, (children.count - 1) / columns)
        let rawRow = Int(((point.y - firstRowCenterY) / max(stepY, 1)).rounded())
        let targetRow = max(0, min(maxRow, rawRow))
        let originRow = (folderDragOriginSlot ?? 0) / columns
        guard shouldUpdateOrderForRowChange(
            from: originRow,
            to: targetRow,
            targetRowCenterY: firstRowCenterY + stepY * CGFloat(targetRow),
            point: point,
            previousPoint: previousPoint,
            startPoint: folderDragStartLocation
        ) else {
            return nil
        }

        let displayItems = folderDisplayOrder(children)
        let slot = displayItems.enumerated().reduce(0) { result, pair in
            let itemIndex = pair.offset
            let item = pair.element
            guard item.id != folderDraggingItemID else { return result }

            let itemRow = itemIndex / columns
            guard itemRow <= targetRow else { return result }
            if itemRow < targetRow {
                return result + 1
            }

            let itemCenterX = margin + slotWidth * (CGFloat(itemIndex % columns) + 0.5)
            return point.x > itemCenterX ? result + 1 : result
        }

        let candidateCount = displayItems.filter { $0.id != folderDraggingItemID }.count
        return max(0, min(slot, candidateCount))
    }

    private func isFolderDragOutside(_ point: CGPoint, size: CGSize) -> Bool {
        let threshold: CGFloat = 22
        return point.x < -threshold
            || point.y < -threshold
            || point.x > folderPanelWidth(for: size) + threshold
            || point.y > folderGridLayoutHeight(for: size, itemCount: openFolderChildCount()) + threshold
    }

    private func rootSlotForFolderExit(at panelPoint: CGPoint, size: CGSize) -> Int {
        let panelOrigin = folderPanelOrigin(size: size)
        let globalPoint = CGPoint(
            x: panelOrigin.x + panelPoint.x,
            y: panelOrigin.y + panelPoint.y
        )
        let columns = columnCount(for: size)
        let rows = rowCount(for: size)
        let pageSize = max(columns * rows, 1)
        let pages = visiblePages(pageSize: pageSize)
        let itemCount = currentPage < pages.count ? min(pages[currentPage].count + 1, pageSize) : pageSize
        return slot(at: globalPoint, columns: columns, rows: rows, size: size, itemCount: max(itemCount, 1))
    }

    private func rootSlotForGlobalPoint(_ point: CGPoint, size: CGSize) -> Int {
        let columns = columnCount(for: size)
        let rows = rowCount(for: size)
        let pageSize = max(columns * rows, 1)
        let pages = visiblePages(pageSize: pageSize)
        let itemCount = currentPage < pages.count ? min(pages[currentPage].count + 1, pageSize) : pageSize
        return slot(at: point, columns: columns, rows: rows, size: size, itemCount: max(itemCount, 1))
    }

    private func folderDragGlobalLocation(folderID: LaunchItem.ID, size: CGSize) -> CGPoint? {
        guard folderDraggingItemID != nil else { return nil }
        let panelOrigin = folderPanelOrigin(folderID: folderID, size: size)
        return CGPoint(
            x: panelOrigin.x + folderDragLocation.x,
            y: panelOrigin.y + folderDragLocation.y
        )
    }

    private func folderPanelOrigin(folderID: LaunchItem.ID? = nil, size: CGSize) -> CGPoint {
        CGPoint(
            x: (size.width - folderPanelWidth(for: size)) / 2,
            y: folderPanelTopY(
                folderID: folderID ?? store.openFolderID ?? UUID(),
                size: size,
                itemCount: openFolderChildCount()
            )
        )
    }

    private func pageFooter(size: CGSize) -> some View {
        let pageSize = max(columnCount(for: size) * rowCount(for: size), 1)
        let pageCount = max(visiblePages(pageSize: pageSize).count, 1)

        return HStack {
            Spacer()

            HStack(spacing: 8) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Circle()
                        .fill(index == currentPage ? Color.white.opacity(0.78) : Color.white.opacity(0.30))
                        .frame(width: 7, height: 7)
                        .onTapGesture {
                            guard index != currentPage else { return }
                            moveToPage(index, animatedLikeScroll: true)
                            moveKeyboardSelectionToFirstItem(on: index)
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Spacer()
        }
    }

    private func columnCount(for size: CGSize) -> Int {
        7
    }

    private func rowCount(for size: CGSize) -> Int {
        5
    }

    private func maxPageIndex(for size: CGSize) -> Int {
        let pageSize = max(columnCount(for: size) * rowCount(for: size), 1)
        let pageCount = max(visiblePages(pageSize: pageSize).count, 1)
        return max(pageCount - 1, 0)
    }

    private func applyPageMutationResult(_ result: KidoXStore.PageMutationResult) {
        guard result.didRemovePages else { return }
        let removedPositions = result.removedPagePositions

        currentPage = adjustedPageIndex(currentPage, afterRemoving: removedPositions)
            ?? min(currentPage, maxPageIndex(for: currentSize))
        currentPage = max(0, min(currentPage, maxPageIndex(for: currentSize)))
        pageBeforeSearch = pageBeforeSearch.flatMap {
            adjustedPageIndex($0, afterRemoving: removedPositions)
        }
        dragOriginPage = dragOriginPage.flatMap {
            adjustedPageIndex($0, afterRemoving: removedPositions)
        }
        dragTargetPage = dragTargetPage.flatMap {
            adjustedPageIndex($0, afterRemoving: removedPositions)
        }
        ensureKeyboardSelectionIsValid()
    }

    private func adjustedPageIndex(_ page: Int, afterRemoving removedPositions: [Int]) -> Int? {
        var adjusted = page
        for removedPosition in removedPositions {
            if removedPosition < adjusted {
                adjusted -= 1
            } else if removedPosition == adjusted {
                return nil
            }
        }
        return max(0, adjusted)
    }

    private func handlePageDragChanged(translation: CGSize) {
        guard !isIconInteractionActive else {
            resetPageDragOffset()
            return
        }
        dragOffset = translation.width
    }

    private func handlePageDragEnded(translation: CGSize, size: CGSize, pageCount: Int? = nil) {
        guard !isIconInteractionActive else {
            resetPageDragOffset()
            return
        }

        guard abs(translation.width) > abs(translation.height) else {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { dragOffset = 0 }
            return
        }

        let threshold = pageTurnReleaseThreshold
        let maxIndex = max((pageCount ?? maxPageIndex(for: size) + 1) - 1, 0)
        var targetPage = currentPage
        if translation.width < -threshold {
            targetPage = min(currentPage + 1, maxIndex)
        } else if translation.width > threshold {
            targetPage = max(currentPage - 1, 0)
        }
        let didChangePage = targetPage != currentPage
        withAnimation(.spring(response: 0.45, dampingFraction: 0.84)) {
            currentPage = targetPage
            dragOffset = 0
        }
        if didChangePage {
            moveKeyboardSelectionToFirstItem(on: targetPage)
        }
    }

    private func resetPageDragOffset() {
        guard dragOffset != 0 else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dragOffset = 0
        }
    }

    private func moveToPage(_ page: Int, animatedLikeScroll: Bool = false) {
        guard animatedLikeScroll else {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.84)) {
                currentPage = page
                dragOffset = 0
            }
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pageTurnAnimationRequest = PageTurnAnimationRequest(id: UUID(), targetPage: page)
            currentPage = page
            dragOffset = 0
        }
    }

    // MARK: - Launch panel keyboard navigation

    private var isSearching: Bool {
        !store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func keyboardSelectionPages() -> [[LaunchItem]] {
        let columns = max(columnCount(for: currentSize), 1)
        let rows = max(rowCount(for: currentSize), 1)
        let pageSize = max(columns * rows, 1)
        return visiblePages(pageSize: pageSize).enumerated().map { pageIndex, page in
            displayOrder(for: pageIndex, items: page)
        }
    }

    private func ensureKeyboardSelectionIsValid() {
        let items = keyboardSelectionPages().flatMap { $0 }
        guard !items.isEmpty else {
            if keyboardSelectionID != nil { keyboardSelectionID = nil }
            return
        }

        if let id = keyboardSelectionID, items.contains(where: { $0.id == id }) {
            return
        }

        keyboardSelectionID = isSearching ? items.first?.id : nil
    }

    @discardableResult
    private func moveKeyboardSelection(_ direction: SearchSelectionMove) -> Bool {
        guard store.openFolderID == nil else { return false }
        let pages = keyboardSelectionPages()
        let items = pages.flatMap { $0 }
        guard !items.isEmpty else { return false }

        let columns = max(columnCount(for: currentSize), 1)
        let rows = max(rowCount(for: currentSize), 1)
        let pageSize = max(columns * rows, 1)

        guard let currentIndex = {
            if let id = keyboardSelectionID,
               let idx = items.firstIndex(where: { $0.id == id }) {
                return Optional(idx)
            }
            return nil
        }() else {
            if isSearching || direction == .right || direction == .down {
                let firstIndexOnCurrentPage = flatStartIndex(for: currentPage, in: pages) ?? 0
                let firstVisibleItem = firstIndexOnCurrentPage < items.count
                    ? items[firstIndexOnCurrentPage]
                    : items[0]
                keyboardSelectionID = firstVisibleItem.id
            }
            return true
        }

        let nextIndex: Int
        switch direction {
        case .left:
            nextIndex = max(0, currentIndex - 1)
        case .right:
            nextIndex = min(items.count - 1, currentIndex + 1)
        case .up:
            nextIndex = max(0, currentIndex - columns)
        case .down:
            // 不允许跨过末尾
            let candidate = currentIndex + columns
            if candidate < items.count {
                nextIndex = candidate
            } else {
                // 同页最后一行末尾
                nextIndex = items.count - 1
            }
        }

        guard nextIndex != currentIndex else { return true }

        let targetPage = pageIndex(containingFlatIndex: nextIndex, in: pages, fallbackPageSize: pageSize)
        if targetPage != currentPage {
            moveToPage(targetPage, animatedLikeScroll: true)
            moveKeyboardSelectionToFirstItem(on: targetPage)
        } else {
            keyboardSelectionID = items[nextIndex].id
        }
        return true
    }

    @discardableResult
    private func movePageBy(_ delta: Int) -> Bool {
        guard store.openFolderID == nil else { return false }
        let targetPage = max(0, min(currentPage + delta, maxPageIndex(for: currentSize)))
        guard targetPage != currentPage else { return true }
        moveToPage(targetPage, animatedLikeScroll: true)
        moveKeyboardSelectionToFirstItem(on: targetPage)
        return true
    }

    private func handleLaunchPanelKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        guard store.openFolderID == nil else { return .ignored }
        guard !isTextFieldEditing else { return .ignored }

        if keyPress.modifiers.contains(.command) {
            switch keyPress.key {
            case .leftArrow:
                return movePageBy(-1) ? .handled : .ignored
            case .rightArrow:
                return movePageBy(1) ? .handled : .ignored
            default:
                return .ignored
            }
        }

        let nonSelectionModifiers = keyPress.modifiers.intersection([.control, .option])
        guard nonSelectionModifiers.isEmpty else { return .ignored }

        switch keyPress.key {
        case .leftArrow:
            return moveKeyboardSelection(.left) ? .handled : .ignored
        case .rightArrow:
            return moveKeyboardSelection(.right) ? .handled : .ignored
        case .upArrow:
            return moveKeyboardSelection(.up) ? .handled : .ignored
        case .downArrow:
            return moveKeyboardSelection(.down) ? .handled : .ignored
        default:
            return .ignored
        }
    }

    private var isTextFieldEditing: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }

    @discardableResult
    private func commitKeyboardSelection() -> Bool {
        let items = keyboardSelectionPages().flatMap { $0 }
        guard !items.isEmpty else { return false }
        let target: LaunchItem
        if let id = keyboardSelectionID,
           let item = items.first(where: { $0.id == id }) {
            target = item
        } else if isSearching {
            target = items[0]
        } else {
            return false
        }
        open(target)
        return true
    }

    private func pageIndex(
        containingFlatIndex targetIndex: Int,
        in pages: [[LaunchItem]],
        fallbackPageSize: Int
    ) -> Int {
        var startIndex = 0
        for (pageIndex, page) in pages.enumerated() {
            let endIndex = startIndex + page.count
            if targetIndex >= startIndex && targetIndex < endIndex {
                return pageIndex
            }
            startIndex = endIndex
        }
        return max(0, min(targetIndex / max(fallbackPageSize, 1), max(pages.count - 1, 0)))
    }

    private func flatStartIndex(for targetPage: Int, in pages: [[LaunchItem]]) -> Int? {
        guard targetPage >= 0, targetPage < pages.count else { return nil }
        return pages.prefix(targetPage).reduce(0) { $0 + $1.count }
    }

    private func moveKeyboardSelectionToFirstItem(on targetPage: Int) {
        guard keyboardSelectionID != nil else { return }
        let pages = keyboardSelectionPages()
        guard targetPage >= 0, targetPage < pages.count else {
            keyboardSelectionID = nil
            return
        }
        keyboardSelectionID = pages[targetPage].first?.id
    }

    private func horizontalPageMargin(for size: CGSize) -> CGFloat {
        max(88, min(150, size.width * 0.08))
    }

    private func contentWidth(for size: CGSize) -> CGFloat {
        size.width - horizontalPageMargin(for: size) * 2
    }

    private func contentHeight(for size: CGSize) -> CGFloat {
        size.height
    }

    private var backgroundGridOpacity: CGFloat {
        appChromeOpacity
    }

    private var appChromeOpacity: CGFloat {
        guard !folderDragHasExited else { return 1 }
        guard store.openFolderID != nil else { return 1 }
        let delayed = clamped((folderOverlayProgress - 0.55) / 0.45)
        return interpolate(from: 1, to: 0, progress: delayed)
    }

    private var backgroundGridBlurRadius: CGFloat {
        guard !folderDragHasExited else { return 0 }
        guard store.openFolderID != nil else { return 0 }
        let delayed = clamped((folderOverlayProgress - 0.45) / 0.55)
        return interpolate(from: 0, to: 5, progress: delayed)
    }

    private var backgroundGridScale: CGFloat {
        guard !folderDragHasExited else { return 1 }
        guard store.openFolderID != nil else { return 1 }
        let delayed = clamped((folderOverlayProgress - 0.45) / 0.55)
        return interpolate(from: 1, to: 0.92, progress: delayed)
    }

    private func folderPanelWidth(for size: CGSize) -> CGFloat {
        max(520, size.width - max(96, size.width * 0.06))
    }

    private func folderPanelHeight(for size: CGSize, itemCount: Int) -> CGFloat {
        let contentHeight = folderPanelContentHeight(for: size, itemCount: itemCount)
        let maximumHeight = max(
            220,
            size.height - folderPanelMinimumTopY(for: size) - folderPanelBottomMargin
        )
        return max(220, min(contentHeight, maximumHeight))
    }

    private func folderPanelContentHeight(for size: CGSize, itemCount: Int) -> CGFloat {
        let rows = folderGridRowCount(for: size, itemCount: itemCount)
        let metrics = folderTileMetrics(for: size)
        return folderGridTopPadding
            + folderGridBottomPadding
            + CGFloat(rows) * metrics.tileHeight
            + CGFloat(max(rows - 1, 0)) * folderGridRowSpacing(for: size)
    }

    private func folderGridColumns(for size: CGSize) -> [GridItem] {
        let columnCount = folderGridColumnCount(for: size)
        return Array(
            repeating: GridItem(.fixed(folderTileMetrics(for: size).tileWidth), spacing: folderGridColumnSpacing(for: size), alignment: .top),
            count: columnCount
        )
    }

    private func folderGridColumnCount(for size: CGSize) -> Int {
        let minimumColumnWidth = max(178, folderTileMetrics(for: size).tileWidth + 46)
        return max(3, min(7, Int(folderPanelWidth(for: size) / minimumColumnWidth)))
    }

    private func folderGridColumnSpacing(for size: CGSize) -> CGFloat {
        let columnCount = folderGridColumnCount(for: size)
        let available = folderPanelWidth(for: size) - folderGridHorizontalPadding(for: size) * 2
        guard columnCount > 1 else { return 0 }
        return max(28, min(92, (available - CGFloat(columnCount) * folderTileMetrics(for: size).tileWidth) / CGFloat(columnCount - 1)))
    }

    private func folderGridRowSpacing(for size: CGSize) -> CGFloat {
        max(34, min(54, size.height * 0.055))
    }

    private func effectiveFolderGridRowSpacing(for size: CGSize, itemCount: Int, layoutHeight: CGFloat) -> CGFloat {
        let rows = folderGridRowCount(for: size, itemCount: itemCount)
        guard rows > 1 else { return 0 }

        let available = layoutHeight
            - folderGridTopPadding
            - folderGridBottomPadding
            - CGFloat(rows) * folderTileMetrics(for: size).tileHeight
        return max(0, min(folderGridRowSpacing(for: size), available / CGFloat(rows - 1)))
    }

    private func folderGridLayoutHeight(for size: CGSize, itemCount: Int) -> CGFloat {
        max(
            folderPanelHeight(for: size, itemCount: itemCount),
            folderPanelContentHeight(for: size, itemCount: itemCount)
        )
    }

    private func folderGridRowCount(for size: CGSize, itemCount: Int) -> Int {
        let columns = max(1, folderGridColumnCount(for: size))
        return max(1, Int(ceil(Double(max(itemCount, 1)) / Double(columns))))
    }

    private var folderGridTopPadding: CGFloat {
        42
    }

    private var folderGridBottomPadding: CGFloat {
        70
    }

    private func folderGridHorizontalPadding(for size: CGSize) -> CGFloat {
        max(42, min(84, size.width * 0.045))
    }

    private func folderPanelCenterY(folderID: LaunchItem.ID, size: CGSize, itemCount: Int) -> CGFloat {
        folderPanelTopY(folderID: folderID, size: size, itemCount: itemCount)
            + folderPanelHeight(for: size, itemCount: itemCount) / 2
    }

    private func folderTitleCenterY(folderID: LaunchItem.ID, size: CGSize, itemCount: Int) -> CGFloat {
        max(
            headerCenterY(for: size),
            folderPanelTopY(folderID: folderID, size: size, itemCount: itemCount) - folderTitlePanelGap
        )
    }

    private func folderPanelTopY(folderID: LaunchItem.ID, size: CGSize, itemCount: Int) -> CGFloat {
        max(
            folderPanelMinimumTopY(for: size),
            (size.height - folderPanelHeight(for: size, itemCount: itemCount)) / 2
        )
    }

    private var folderTitlePanelGap: CGFloat {
        66
    }

    private func folderPanelMinimumTopY(for size: CGSize) -> CGFloat {
        headerCenterY(for: size) + 44
    }

    private var folderPanelBottomMargin: CGFloat {
        36
    }

    private func folderTileMetrics(for size: CGSize) -> AppTileMetrics {
        appTileMetrics(for: size)
    }

    private func folderIconVisualSize(for metrics: AppTileMetrics) -> CGFloat {
        metrics.iconSize * 82 / 102
    }

    private func folderIconCornerRadius(for metrics: AppTileMetrics) -> CGFloat {
        folderIconVisualSize(for: metrics) * 0.30
    }

    private func folderPanelContentOpacity(_ progress: CGFloat) -> CGFloat {
        smoothStep((progress - 0.48) / 0.30)
    }

    private func folderSourcePreviewOpacity(_ progress: CGFloat) -> CGFloat {
        1 - smoothStep((progress - 0.08) / 0.24)
    }

    private func smoothStep(_ value: CGFloat) -> CGFloat {
        let t = clamped(value)
        return t * t * (3 - 2 * t)
    }

    private func interpolate(from start: CGFloat, to end: CGFloat, progress: CGFloat) -> CGFloat {
        start + (end - start) * clamped(progress)
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    private func folderIconCenter(folderID: LaunchItem.ID, size: CGSize) -> CGPoint? {
        guard var center = folderTileCenter(folderID: folderID, size: size) else { return nil }
        center.y -= appTileIconLabelYOffset(for: size)
        return center
    }

    private func appTileMetrics(for size: CGSize) -> AppTileMetrics {
        let columns = max(columnCount(for: size), 1)
        let rows = max(rowCount(for: size), 1)
        let columnWidth = max(contentWidth(for: size), 1) / CGFloat(columns)
        let rowStride: CGFloat
        if rows > 1 {
            rowStride = max((gridBottomY(for: size) - gridTopY(for: size)) / CGFloat(rows - 1), 1)
        } else {
            rowStride = max(gridBottomY(for: size) - gridTopY(for: size), 1)
        }

        let rawIconSize = min(columnWidth * 0.58, rowStride * 0.74)
        let iconSize = min(max(rawIconSize.rounded(.toNearestOrAwayFromZero), 82), 132)
        let labelSpacing: CGFloat = 5
        let labelFontSize: CGFloat = 13
        let labelHeight = appTileLabelHeight(for: labelFontSize)
        let tileWidth = max(132, min(columnWidth * 0.92, iconSize + 72))
        let tileHeight = iconSize + labelSpacing + labelHeight + 5

        return AppTileMetrics(
            tileWidth: tileWidth.rounded(.toNearestOrAwayFromZero),
            tileHeight: tileHeight.rounded(.toNearestOrAwayFromZero),
            iconSize: iconSize,
            labelSpacing: labelSpacing,
            labelFontSize: labelFontSize
        )
    }

    private func appTileIconLabelYOffset(for size: CGSize) -> CGFloat {
        let metrics = appTileMetrics(for: size)
        return (metrics.labelSpacing + appTileLabelHeight(for: metrics)) / 2
    }

    private func appTileLabelFont(for metrics: AppTileMetrics) -> NSFont {
        appTileLabelFont(size: metrics.labelFontSize)
    }

    private func appTileLabelFont(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .regular)
    }

    private func appTileLabelHeight(for metrics: AppTileMetrics) -> CGFloat {
        appTileLabelHeight(for: metrics.labelFontSize)
    }

    private func appTileLabelHeight(for fontSize: CGFloat) -> CGFloat {
        let font = appTileLabelFont(size: fontSize)
        return ceil(font.ascender - font.descender + font.leading)
    }

    private func folderTileCenter(folderID: LaunchItem.ID, size: CGSize) -> CGPoint? {
        let columns = columnCount(for: size)
        let rows = rowCount(for: size)
        let pageSize = max(columns * rows, 1)
        let pages = visiblePages(pageSize: pageSize)
        guard currentPage >= 0, currentPage < pages.count else { return nil }
        let pageItems = displayOrder(for: currentPage, items: pages[currentPage])
        guard let itemIndex = pageItems.firstIndex(where: { $0.id == folderID }) else { return nil }
        return CGPoint(
            x: tileX(index: itemIndex, columns: columns, size: size),
            y: tileY(index: itemIndex, columns: columns, rows: rows, size: size)
        )
    }

    private func folderTileCenterY(folderID: LaunchItem.ID, size: CGSize) -> CGFloat? {
        folderTileCenter(folderID: folderID, size: size)?.y
    }

    private func openFolderChildCount() -> Int {
        guard let openFolderID = store.openFolderID else { return 0 }
        return store.children(of: openFolderID).count
    }

    private func headerCenterY(for size: CGSize) -> CGFloat {
        max(100, size.height * 0.080)
    }

    private func gridCenterY(for size: CGSize) -> CGFloat {
        size.height * 0.50
    }

    private func footerCenterY(for size: CGSize) -> CGFloat {
        size.height - 30
    }

    private func gridTopY(for size: CGSize) -> CGFloat {
        headerCenterY(for: size) + 120
    }

    private func gridBottomY(for size: CGSize) -> CGFloat {
        footerCenterY(for: size) - 98
    }
}

enum SearchSelectionMove {
    case up, down, left, right
}

private struct SearchTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var isComposing: Bool
    let onEscape: () -> Void
    let onMoveSelection: (SearchSelectionMove) -> Bool
    let onMovePage: (Int) -> Bool
    let onCommit: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isFocused: $isFocused,
            isComposing: $isComposing,
            onEscape: onEscape,
            onMoveSelection: onMoveSelection,
            onMovePage: onMovePage,
            onCommit: onCommit
        )
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.cell = SearchFieldNSTextFieldCell(textCell: "")
        textField.isEditable = true
        textField.isSelectable = true
        textField.refusesFirstResponder = false
        textField.delegate = context.coordinator
        textField.isBezeled = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 18)
        textField.textColor = .white
        textField.placeholderString = nil
        textField.backgroundColor = .clear
        textField.stringValue = text
        textField.lineBreakMode = .byClipping
        textField.allowsEditingTextAttributes = false
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.cell?.usesSingleLineMode = true
        context.coordinator.attach(to: textField)
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused
        context.coordinator.isComposing = $isComposing
        context.coordinator.onEscape = onEscape
        context.coordinator.onMoveSelection = onMoveSelection
        context.coordinator.onMovePage = onMovePage
        context.coordinator.onCommit = onCommit

        let hasMarkedText = (textField.currentEditor() as? NSTextView)?.hasMarkedText() == true
        if !hasMarkedText, textField.stringValue != text {
            textField.stringValue = text
        }

        if isFocused {
            if context.coordinator.isEditing(textField) {
                context.coordinator.configureTextEditor(for: textField)
                context.coordinator.restartInsertionPoint(for: textField)
            } else {
                DispatchQueue.main.async {
                    context.coordinator.focus(textField)
                }
            }
        }
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>
        var isComposing: Binding<Bool>
        var onEscape: () -> Void
        var onMoveSelection: (SearchSelectionMove) -> Bool
        var onMovePage: (Int) -> Bool
        var onCommit: () -> Bool
        private weak var textField: NSTextField?
        private var keyDownMonitor: Any?

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            isComposing: Binding<Bool>,
            onEscape: @escaping () -> Void,
            onMoveSelection: @escaping (SearchSelectionMove) -> Bool,
            onMovePage: @escaping (Int) -> Bool,
            onCommit: @escaping () -> Bool
        ) {
            self.text = text
            self.isFocused = isFocused
            self.isComposing = isComposing
            self.onEscape = onEscape
            self.onMoveSelection = onMoveSelection
            self.onMovePage = onMovePage
            self.onCommit = onCommit
        }

        func detach() {
            if let keyDownMonitor {
                NSEvent.removeMonitor(keyDownMonitor)
                self.keyDownMonitor = nil
            }
        }

        func attach(to textField: NSTextField) {
            self.textField = textField
            guard keyDownMonitor == nil else { return }

            keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak textField] event in
                guard let self, let textField, self.isEditing(textField) else {
                    return event
                }

                if event.keyCode == 53 {
                    // 上层决定 ESC 行为（关 folder / 清搜索 / dismiss panel）
                    self.onEscape()
                    return nil
                }

                // 拦截方向键与回车，转发给上层做 launch panel 导航
                // 输入法 composing 期间不拦截，避免影响候选词导航
                let hasMarkedText = (textField.currentEditor() as? NSTextView)?.hasMarkedText() == true
                if !hasMarkedText {
                    if event.modifierFlags.contains(.command) {
                        switch event.keyCode {
                        case 123: // command + left arrow
                            if self.onMovePage(-1) { return nil }
                        case 124: // command + right arrow
                            if self.onMovePage(1) { return nil }
                        default:
                            break
                        }
                    }

                    let nonSelectionModifiers = event.modifierFlags.intersection([.command, .control, .option])
                    switch event.keyCode {
                    case 126: // up arrow
                        if nonSelectionModifiers.isEmpty, self.onMoveSelection(.up) { return nil }
                    case 125: // down arrow
                        if nonSelectionModifiers.isEmpty, self.onMoveSelection(.down) { return nil }
                    case 123: // left arrow
                        if nonSelectionModifiers.isEmpty, self.onMoveSelection(.left) { return nil }
                    case 124: // right arrow
                        if nonSelectionModifiers.isEmpty, self.onMoveSelection(.right) { return nil }
                    case 36, 76: // return / numpad enter
                        if self.onCommit() { return nil }
                    default:
                        break
                    }
                }

                if self.shouldHidePlaceholderBeforeHandling(event) {
                    self.isComposing.wrappedValue = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self, weak textField] in
                        guard let self, let textField else { return }
                        self.updateCompositionState(from: textField)
                    }
                }

                return event
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            isFocused.wrappedValue = true
            updateCompositionState(from: notification)
            if let textField = notification.object as? NSTextField {
                configureTextEditor(for: textField)
                restartInsertionPoint(for: textField)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text.wrappedValue = textField.stringValue
            updateCompositionState(from: notification)
            configureTextEditor(for: textField)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            isFocused.wrappedValue = false
            isComposing.wrappedValue = false
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onEscape()
                return true
            }

            return false
        }

        func configureTextEditor(for textField: NSTextField) {
            guard let textView = textField.currentEditor() as? NSTextView else { return }
            SearchFieldNSTextFieldCell.configureFieldEditor(textView)
        }

        func restartInsertionPoint(for textField: NSTextField) {
            guard let textView = textField.currentEditor() as? NSTextView else { return }
            textView.updateInsertionPointStateAndRestartTimer(true)
        }

        func focus(_ textField: NSTextField) {
            guard let window = textField.window else { return }
            guard window.isVisible, window.alphaValue >= 0.99 else { return }
            guard textField.bounds.width > 0, textField.bounds.height > 0 else { return }
            window.makeKey()

            if !isEditing(textField) {
                textField.selectText(nil)
            }

            configureTextEditor(for: textField)
            if let textView = textField.currentEditor() as? NSTextView {
                let insertionIndex = (textView.string as NSString).length
                textView.setSelectedRange(NSRange(location: insertionIndex, length: 0))
                textView.updateInsertionPointStateAndRestartTimer(true)

                DispatchQueue.main.async { [weak textField] in
                    guard let textField else { return }
                    self.restartInsertionPoint(for: textField)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak textField] in
                    guard let textField else { return }
                    self.restartInsertionPoint(for: textField)
                }
            }
        }

        private func updateCompositionState(from notification: Notification) {
            guard let textField = notification.object as? NSTextField else {
                isComposing.wrappedValue = false
                return
            }

            updateCompositionState(from: textField)
        }

        private func updateCompositionState(from textField: NSTextField) {
            isComposing.wrappedValue = (textField.currentEditor() as? NSTextView)?.hasMarkedText() == true
        }

        func isEditing(_ textField: NSTextField) -> Bool {
            guard let editor = textField.currentEditor() else { return false }
            return textField.window?.firstResponder === editor
        }

        private func shouldHidePlaceholderBeforeHandling(_ event: NSEvent) -> Bool {
            guard text.wrappedValue.isEmpty else { return false }

            let modifiers = event.modifierFlags.intersection([.command, .control])
            guard modifiers.isEmpty else { return false }

            switch event.keyCode {
            case 36, 48, 51, 53, 76, 123, 124, 125, 126:
                return false
            default:
                break
            }

            guard let characters = event.characters, !characters.isEmpty else { return false }
            return characters.unicodeScalars.contains(where: { !CharacterSet.controlCharacters.contains($0) })
        }
    }
}

final class SearchFieldNSTextFieldCell: NSTextFieldCell {
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        Self.configureFieldEditor(editor)
        return editor
    }

    static func configureFieldEditor(_ textObj: NSText) {
        guard let textView = textObj as? NSTextView else { return }
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        if let scrollView = textView.enclosingScrollView {
            scrollView.drawsBackground = false
            scrollView.backgroundColor = .clear
            scrollView.borderType = .noBorder
        }
        textView.insertionPointColor = .white
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = false
        textView.usesFindPanel = false
        textView.usesInspectorBar = false
        if #available(macOS 14.0, *) {
            textView.inlinePredictionType = .no
        }
        if #available(macOS 15.0, *) {
            textView.mathExpressionCompletionType = .no
        }
        if #available(macOS 15.2, *) {
            textView.writingToolsBehavior = .none
        }
    }
}

private struct AppTileMetrics: Hashable {
    static let standard = AppTileMetrics(tileWidth: 174, tileHeight: 128, iconSize: 102)

    let tileWidth: CGFloat
    let tileHeight: CGFloat
    let iconSize: CGFloat
    let labelSpacing: CGFloat
    let labelFontSize: CGFloat

    init(
        tileWidth: CGFloat,
        tileHeight: CGFloat,
        iconSize: CGFloat,
        labelSpacing: CGFloat = 5,
        labelFontSize: CGFloat = 13
    ) {
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.iconSize = iconSize
        self.labelSpacing = labelSpacing
        self.labelFontSize = labelFontSize
    }
}

private struct InlineRenameTextField: NSViewRepresentable {
    @Binding var text: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = FocusedRenameNSTextField(string: text)
        textField.cell = SearchFieldNSTextFieldCell(textCell: "")
        textField.isEditable = true
        textField.isSelectable = true
        textField.refusesFirstResponder = false
        textField.isBezeled = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.backgroundColor = .clear
        textField.focusRingType = .none
        textField.textColor = .white
        textField.font = .systemFont(ofSize: 13, weight: .regular)
        textField.alignment = .center
        textField.lineBreakMode = .byTruncatingMiddle
        textField.usesSingleLineMode = true
        textField.allowsEditingTextAttributes = false
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.cell?.usesSingleLineMode = true
        textField.delegate = context.coordinator
        context.coordinator.attach(to: textField)
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
        if let textField = textField as? FocusedRenameNSTextField {
            textField.configureFieldEditor = { field in
                context.coordinator.configureFieldEditor(for: field)
            }
        }

        if textField.stringValue != text {
            textField.stringValue = text
        }

        context.coordinator.configureFieldEditor(for: textField)
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onCommit: () -> Void
        var onCancel: () -> Void
        private weak var textField: NSTextField?
        private var keyDownMonitor: Any?
        private var didFinish = false

        init(text: Binding<String>, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func attach(to textField: NSTextField) {
            self.textField = textField
            guard keyDownMonitor == nil else { return }

            keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak textField] event in
                guard let self, let textField, self.isEditing(textField) else {
                    return event
                }

                if event.keyCode == 53 {
                    self.finish(commit: false)
                    return nil
                }

                return event
            }
        }

        func detach() {
            if let keyDownMonitor {
                NSEvent.removeMonitor(keyDownMonitor)
                self.keyDownMonitor = nil
            }
            textField = nil
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                finish(commit: true)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finish(commit: false)
                return true
            case #selector(NSResponder.moveLeft(_:)):
                textView.moveLeft(nil)
                return true
            case #selector(NSResponder.moveRight(_:)):
                textView.moveRight(nil)
                return true
            case #selector(NSResponder.moveUp(_:)):
                textView.moveUp(nil)
                return true
            case #selector(NSResponder.moveDown(_:)):
                textView.moveDown(nil)
                return true
            case #selector(NSResponder.moveLeftAndModifySelection(_:)):
                textView.moveLeftAndModifySelection(nil)
                return true
            case #selector(NSResponder.moveRightAndModifySelection(_:)):
                textView.moveRightAndModifySelection(nil)
                return true
            case #selector(NSResponder.moveUpAndModifySelection(_:)):
                textView.moveUpAndModifySelection(nil)
                return true
            case #selector(NSResponder.moveDownAndModifySelection(_:)):
                textView.moveDownAndModifySelection(nil)
                return true
            default:
                return false
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            didFinish = false
            guard let textField = notification.object as? NSTextField else { return }
            configureFieldEditor(for: textField)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text.wrappedValue = textField.stringValue
            configureFieldEditor(for: textField)
        }

        @MainActor
        func configureFieldEditor(for textField: NSTextField) {
            if let editor = textField.currentEditor() as? NSTextView {
                SearchFieldNSTextFieldCell.configureFieldEditor(editor)
                editor.textColor = .white
            }
        }

        private func finish(commit: Bool) {
            guard !didFinish else { return }
            didFinish = true
            if commit {
                onCommit()
            } else {
                onCancel()
            }
        }

        private func isEditing(_ textField: NSTextField) -> Bool {
            guard let editor = textField.currentEditor() else { return false }
            return textField.window?.firstResponder === editor
        }
    }

    final class FocusedRenameNSTextField: NSTextField {
        var configureFieldEditor: ((NSTextField) -> Void)?
        private var didFocus = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusWhenReady()
        }

        override func mouseDown(with event: NSEvent) {
            if currentEditor() == nil {
                window?.makeFirstResponder(self)
                configureFieldEditor?(self)
            }
            super.mouseDown(with: event)
            configureFieldEditor?(self)
        }

        private func focusWhenReady() {
            guard !didFocus, let targetWindow = window else { return }

            DispatchQueue.main.async { [weak self, weak targetWindow] in
                guard let self,
                      !self.didFocus,
                      let targetWindow,
                      self.window === targetWindow
                else { return }

                self.didFocus = true
                targetWindow.makeFirstResponder(self)
                if let editor = self.currentEditor() {
                    editor.selectedRange = NSRange(location: 0, length: self.stringValue.utf16.count)
                }
                self.configureFieldEditor?(self)
            }
        }
    }
}

private struct AppTile: View, Equatable {
    let item: LaunchItem
    let previewItems: [LaunchItem]
    let isPressed: Bool
    let isDragging: Bool
    let isDropTarget: Bool
    var showsLabel: Bool = true
    var metrics: AppTileMetrics = .standard
    var renderScale: CGFloat? = nil
    var isRenaming: Bool = false
    var renameCommitRequestID: Int = 0
    var canRename: Bool = true
    let openAction: () -> Void
    let revealAction: () -> Void
    var uninstallAction: (() -> Void)? = nil
    let renameAction: ((String) -> Void)?
    var renameUnavailableAction: (() -> Void)? = nil
    var renameCancelAction: (() -> Void)? = nil
    let ungroupAction: (() -> Void)?
    @State private var renameDraftName = ""
    @State private var isInternalRenaming = false

    nonisolated static func == (lhs: AppTile, rhs: AppTile) -> Bool {
        lhs.item == rhs.item
            && lhs.previewItems == rhs.previewItems
            && lhs.isPressed == rhs.isPressed
            && lhs.isDragging == rhs.isDragging
            && lhs.isDropTarget == rhs.isDropTarget
            && lhs.showsLabel == rhs.showsLabel
            && lhs.metrics == rhs.metrics
            && lhs.renderScale == rhs.renderScale
            && lhs.isRenaming == rhs.isRenaming
            && lhs.renameCommitRequestID == rhs.renameCommitRequestID
            && lhs.canRename == rhs.canRename
    }

    var body: some View {
        let pressVisual = isPressed && !isDropTarget
        let hitShape = AppTileHitShape(
            iconSize: iconSize,
            labelSpacing: labelSpacing,
            labelHeight: labelHeight,
            labelWidth: labelHitWidth
        )

        VStack(spacing: 5) {
            ZStack {
                tileIcon

                PressedIconOverlay(
                    item: item,
                    isVisible: pressVisual,
                    isFolderDropTarget: item.kind == .folder && isDropTarget,
                    iconSize: iconSize,
                    renderScale: iconRenderScale
                )
            }
            .frame(width: iconSize, height: iconSize)

            labelView
        }
        .frame(width: tileWidth, height: tileHeight)
        .animation(.snappy(duration: 0.10), value: pressVisual)
        .animation(.snappy(duration: 0.18), value: isDropTarget)
        .contentShape(hitShape)
        .contextMenu {
            contextMenuContent
        }
        .onChange(of: isRenaming) { _, newValue in
            if newValue {
                renameDraftName = item.effectiveDisplayName
            }
        }
        .onChange(of: renameCommitRequestID) { _, _ in
            guard isEditingName else { return }
            commitRename()
        }
    }

    @ViewBuilder
    private var labelView: some View {
        if isEditingName && !isDragging && showsLabel {
            ZStack {
                Color.clear
                    .frame(width: renameFieldWidth, height: labelHeight)

                InlineRenameTextField(
                    text: $renameDraftName,
                    onCommit: commitRename,
                    onCancel: cancelRename
                )
                .frame(width: renameFieldWidth - 14, height: labelHeight)
                .padding(.horizontal, 7)
                .frame(width: renameFieldWidth, height: labelHeight + 4)
                .modifier(SearchFieldGlassBackground())
            }
            .frame(width: renameFieldWidth, height: labelHeight)
            .onAppear {
                if renameDraftName.isEmpty {
                    renameDraftName = item.effectiveDisplayName
                }
            }
        } else {
            Text(item.effectiveDisplayName)
                .font(.system(size: labelFontSize, weight: .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 2, x: 0, y: 1)
                .opacity(isDragging || !showsLabel ? 0 : 1)
        }
    }

    @ViewBuilder
    private var tileIcon: some View {
        if item.kind == .folder {
            FolderPreviewIcon(
                items: previewItems,
                isDropTarget: isDropTarget,
                size: iconSize
            )
        } else {
            ZStack {
                if isDropTarget {
                    FolderGlassBackground(size: iconSize * 104 / 102)
                }

                Image(nsImage: IconCache.rasterizedIcon(for: item.sourcePath, pointSize: iconSize, scale: iconRenderScale))
                    .frame(width: iconSize, height: iconSize)
            }
            .frame(width: iconSize, height: iconSize)
        }
    }

    private var iconRenderScale: CGFloat {
        renderScale ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private var tileWidth: CGFloat { metrics.tileWidth }
    private var tileHeight: CGFloat { metrics.tileHeight }
    private var iconSize: CGFloat { metrics.iconSize }
    private var labelSpacing: CGFloat { metrics.labelSpacing }
    private var labelFontSize: CGFloat { metrics.labelFontSize }

    private var labelFont: NSFont {
        .systemFont(ofSize: labelFontSize, weight: .regular)
    }

    private var labelHeight: CGFloat {
        ceil(labelFont.ascender - labelFont.descender + labelFont.leading)
    }

    private var labelHitWidth: CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont]
        let measured = (item.effectiveDisplayName as NSString).size(withAttributes: attributes).width
        return min(ceil(measured), tileWidth)
    }

    private var renameFieldWidth: CGFloat {
        min(tileWidth - 18, max(labelHitWidth + 24, 92))
    }

    private var isEditingName: Bool {
        renameAction != nil && (isRenaming || isInternalRenaming)
    }

    private var trimmedRenameDraft: String {
        renameDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func beginRename() {
        guard renameAction != nil else { return }
        guard canRename else {
            renameUnavailableAction?()
            return
        }
        renameDraftName = item.effectiveDisplayName
        isInternalRenaming = true
    }

    private func commitRename() {
        let name = trimmedRenameDraft
        guard !name.isEmpty else {
            cancelRename()
            return
        }
        isInternalRenaming = false
        renameAction?(name)
    }

    private func cancelRename() {
        isInternalRenaming = false
        renameCancelAction?()
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button(KidoXL10n.string(.open)) {
            openAction()
        }
        if item.kind == .folder {
            if renameAction != nil {
                Button(canRename ? KidoXL10n.string(.rename) : "\(KidoXL10n.string(.rename))  Pro") {
                    beginRename()
                }
            }
            Divider()
            if let ungroupAction {
                Button(KidoXL10n.ui("Ungroup Folder")) {
                    ungroupAction()
                }
            }
        } else {
            if renameAction != nil {
                Button(canRename ? KidoXL10n.string(.rename) : "\(KidoXL10n.string(.rename))  Pro") {
                    beginRename()
                }
            }
            Button(KidoXL10n.string(.showInFinder)) {
                revealAction()
            }
            if let uninstallAction {
                Button(KidoXL10n.string(.uninstallAppEllipsis)) {
                    uninstallAction()
                }
            }
            Divider()
            Text(item.bundleIdentifier ?? item.sourcePath)
        }
    }
}

private struct FolderDetailAppTile: View, Equatable {
    let item: LaunchItem
    let previewItems: [LaunchItem]
    let isPressed: Bool
    let isDragging: Bool
    let openAction: () -> Void
    let revealAction: () -> Void
    var uninstallAction: (() -> Void)? = nil

    nonisolated static func == (lhs: FolderDetailAppTile, rhs: FolderDetailAppTile) -> Bool {
        lhs.item == rhs.item
            && lhs.previewItems == rhs.previewItems
            && lhs.isPressed == rhs.isPressed
            && lhs.isDragging == rhs.isDragging
    }

    var body: some View {
        Button(action: openAction) {
            VStack(spacing: 7) {
                icon
                    .frame(width: 96, height: 96)

                Text(item.effectiveDisplayName)
                    .font(.system(size: 13, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 2, x: 0, y: 1)
                    .frame(width: 174)
            }
            .frame(width: 174, height: 128)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isDragging ? 0.96 : 1)
        .contextMenu {
            Button(KidoXL10n.string(.open)) {
                openAction()
            }
            Button(KidoXL10n.string(.showInFinder)) {
                revealAction()
            }
            if let uninstallAction {
                Button(KidoXL10n.string(.uninstallAppEllipsis)) {
                    uninstallAction()
                }
            }
            Divider()
            Text(item.bundleIdentifier ?? item.sourcePath)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if item.kind == .folder {
            FolderPreviewIcon(items: previewItems, isDropTarget: false, size: 96)
        } else {
            Image(nsImage: IconCache.rasterizedIcon(for: item.sourcePath, pointSize: 96))
                .frame(width: 96, height: 96)
        }
    }
}

private struct PressedIconOverlay: View {
    let item: LaunchItem
    let isVisible: Bool
    let isFolderDropTarget: Bool
    let iconSize: CGFloat
    let renderScale: CGFloat

    @ViewBuilder
    var body: some View {
        if isVisible {
            if item.kind == .folder {
                RoundedRectangle(cornerRadius: iconSize * 0.30, style: .continuous)
                    .fill(.black.opacity(0.20))
                    .frame(width: folderVisibleSize, height: folderVisibleSize)
            } else {
                Rectangle()
                    .fill(.black.opacity(0.22))
                    .frame(width: iconSize, height: iconSize)
                    .mask {
                        Image(nsImage: IconCache.rasterizedIcon(for: item.sourcePath, pointSize: iconSize, scale: renderScale))
                            .frame(width: iconSize, height: iconSize)
                    }
            }
        } else {
            EmptyView()
        }
    }

    private var folderVisibleSize: CGFloat {
        iconSize * 82 / 102
    }
}

private struct DropTargetGlassOverlay: View {
    let item: LaunchItem
    let scale: CGFloat
    let metrics: AppTileMetrics

    var body: some View {
        VStack(spacing: metrics.labelSpacing) {
            if item.kind == .folder {
                FolderGlassBackground(size: metrics.iconSize * 108 / 102, showsStroke: false)
            } else {
                FolderGlassBackground(size: metrics.iconSize * 104 / 102)
            }

            Color.clear
                .frame(height: labelHeight)
        }
        .frame(width: metrics.tileWidth, height: metrics.tileHeight)
        .scaleEffect(scale, anchor: .center)
    }

    private var labelHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: metrics.labelFontSize, weight: .regular)
        return ceil(font.ascender - font.descender + font.leading)
    }
}

private struct AppDropTargetOverlay: View {
    let model: AppDropTargetOverlayModel

    var body: some View {
        VStack(spacing: model.metrics.labelSpacing) {
            ZStack {
                FolderGlassBackground(size: model.metrics.iconSize * 104 / 102)
                    .scaleEffect(0.68 + 0.32 * model.progress, anchor: .center)
                    .opacity(model.progress)

                Image(nsImage: IconCache.rasterizedIcon(for: model.item.sourcePath, pointSize: model.metrics.iconSize))
                    .frame(width: model.metrics.iconSize, height: model.metrics.iconSize)
            }
            .frame(width: model.metrics.iconSize, height: model.metrics.iconSize)

            Text(model.item.effectiveDisplayName)
                .font(.system(size: model.metrics.labelFontSize, weight: .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 2, x: 0, y: 1)
        }
        .frame(width: model.size.width, height: model.size.height)
        .allowsHitTesting(false)
    }
}

@Observable
@MainActor
private final class AppDropTargetOverlayModel {
    let item: LaunchItem
    var size: CGSize
    var metrics: AppTileMetrics
    var progress: CGFloat

    init(item: LaunchItem, size: CGSize, metrics: AppTileMetrics, progress: CGFloat = 0) {
        self.item = item
        self.size = size
        self.metrics = metrics
        self.progress = progress
    }
}

@MainActor
private final class AppDropTargetHostingView: NSView {
    private let model: AppDropTargetOverlayModel
    private let hostingView: NSHostingView<AppDropTargetOverlay>

    init(item: LaunchItem, size: CGSize, metrics: AppTileMetrics) {
        self.model = AppDropTargetOverlayModel(item: item, size: size, metrics: metrics)
        self.hostingView = NSHostingView(rootView: AppDropTargetOverlay(model: model))
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)
    }

    @MainActor
    required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateProgress(_ progress: CGFloat) {
        withAnimation(.snappy(duration: 0.22)) {
            model.progress = progress
        }
    }

    func updateLayout(size: CGSize, metrics: AppTileMetrics) {
        model.size = size
        model.metrics = metrics
    }
}

@MainActor
private final class DropTargetGlassHostingView: NSView {
    private let item: LaunchItem
    private let contentSize: CGSize
    private let metrics: AppTileMetrics
    private let hostingView: NSHostingView<AnyView>

    init(item: LaunchItem, size: CGSize, metrics: AppTileMetrics, scale: CGFloat) {
        self.item = item
        self.contentSize = size
        self.metrics = metrics
        self.hostingView = NSHostingView(rootView: Self.content(item: item, size: size, metrics: metrics, scale: scale))
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)
    }

    @MainActor
    required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateScale(_ scale: CGFloat) {
        withAnimation(.snappy(duration: 0.20)) {
            hostingView.rootView = Self.content(item: item, size: contentSize, metrics: metrics, scale: scale)
        }
    }

    private static func content(item: LaunchItem, size: CGSize, metrics: AppTileMetrics, scale: CGFloat) -> AnyView {
        AnyView(
            DropTargetGlassOverlay(item: item, scale: scale, metrics: metrics)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
        )
    }
}

@MainActor
private final class AppTileHostingView: NSView {
    private let model: AppTileHostingModel
    private let hostingView: NSHostingView<AppTileHostingRoot>

    init(
        item: LaunchItem,
        previewItems: [LaunchItem],
        size: CGSize,
        metrics: AppTileMetrics,
        isDropTarget: Bool,
        canRename: Bool = true,
        onRenameItem: ((LaunchItem.ID, String) -> Void)? = nil,
        onRenameUnavailable: (() -> Void)? = nil,
        onRenameEnded: (() -> Void)? = nil
    ) {
        self.model = AppTileHostingModel(
            item: item,
            previewItems: previewItems,
            size: size,
            metrics: metrics,
            isPressed: false,
            isDropTarget: isDropTarget,
            canRename: canRename,
            onRenameItem: onRenameItem,
            onRenameUnavailable: onRenameUnavailable,
            onRenameEnded: onRenameEnded
        )
        self.hostingView = NSHostingView(rootView: AppTileHostingRoot(model: model))
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)
    }

    @MainActor
    required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(isDropTarget: Bool) {
        withAnimation(.snappy(duration: 0.20)) {
            model.isDropTarget = isDropTarget
        }
    }

    func update(isPressed: Bool) {
        withAnimation(.snappy(duration: 0.10)) {
            model.isPressed = isPressed
        }
    }

    func update(canRename: Bool) {
        model.canRename = canRename
    }

    func updateLayout(size: CGSize, metrics: AppTileMetrics) {
        model.size = size
        model.metrics = metrics
    }

    func beginRename() {
        model.isRenaming = true
    }

    func commitRename() {
        model.renameCommitRequestID += 1
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if model.isRenaming,
           let textField = renameTextField() {
            let fieldPoint = convert(point, to: textField)
            if textField.bounds.insetBy(dx: -7, dy: -4).contains(fieldPoint) {
                return textField.hitTest(fieldPoint) ?? textField
            }
        }

        return super.hitTest(point)
    }

    func handleRenameInputMouseDown(_ event: NSEvent, from sourceView: NSView) -> Bool {
        guard model.isRenaming,
              let textField = renameTextField()
        else { return false }

        let sourcePoint = sourceView.convert(event.locationInWindow, from: nil)
        let localPoint = sourceView.convert(sourcePoint, to: self)
        let fieldPoint = convert(localPoint, to: textField)
        guard textField.bounds.insetBy(dx: -7, dy: -4).contains(fieldPoint) else {
            return false
        }

        textField.mouseDown(with: event)
        return true
    }

    func containsRenameInput(at point: CGPoint) -> Bool {
        guard model.isRenaming else { return false }

        if let textField = renameTextField() {
            let fieldPoint = convert(point, to: textField)
            if textField.bounds.insetBy(dx: -7, dy: -4).contains(fieldPoint) {
                return true
            }
        }

        let labelFont = NSFont.systemFont(ofSize: model.metrics.labelFontSize, weight: .regular)
        let labelHeight = ceil(labelFont.ascender - labelFont.descender + labelFont.leading)
        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont]
        let measured = (model.item.effectiveDisplayName as NSString).size(withAttributes: attributes).width
        let labelHitWidth = min(ceil(measured), model.metrics.tileWidth)
        let renameFieldWidth = min(model.metrics.tileWidth - 18, max(labelHitWidth + 24, 92))
        let contentHeight = model.metrics.iconSize + model.metrics.labelSpacing + labelHeight
        let contentTop = (model.size.height - contentHeight) / 2
        let labelY = contentTop + model.metrics.iconSize + model.metrics.labelSpacing
        let topOriginRect = CGRect(
            x: (model.size.width - renameFieldWidth) / 2,
            y: labelY - 3,
            width: renameFieldWidth,
            height: labelHeight + 6
        )
        let bottomOriginRect = topOriginRect.offsetBy(
            dx: 0,
            dy: model.size.height - topOriginRect.maxY - topOriginRect.minY
        )
        return topOriginRect.contains(point) || bottomOriginRect.contains(point)
    }

    func endRename() {
        model.isRenaming = false
    }

    private func renameTextField() -> NSTextField? {
        findRenameTextField(in: self)
    }

    private func findRenameTextField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField {
            return textField
        }

        for subview in view.subviews {
            if let textField = findRenameTextField(in: subview) {
                return textField
            }
        }

        return nil
    }
}

@Observable
@MainActor
private final class AppTileHostingModel {
    let item: LaunchItem
    let previewItems: [LaunchItem]
    var size: CGSize
    var metrics: AppTileMetrics
    var isPressed: Bool
    var isDropTarget: Bool
    var isRenaming: Bool
    var renameCommitRequestID: Int
    var canRename: Bool
    var onRenameItem: ((LaunchItem.ID, String) -> Void)?
    var onRenameUnavailable: (() -> Void)?
    var onRenameEnded: (() -> Void)?

    init(
        item: LaunchItem,
        previewItems: [LaunchItem],
        size: CGSize,
        metrics: AppTileMetrics,
        isPressed: Bool,
        isDropTarget: Bool,
        canRename: Bool,
        onRenameItem: ((LaunchItem.ID, String) -> Void)?,
        onRenameUnavailable: (() -> Void)?,
        onRenameEnded: (() -> Void)?
    ) {
        self.item = item
        self.previewItems = previewItems
        self.size = size
        self.metrics = metrics
        self.isPressed = isPressed
        self.isDropTarget = isDropTarget
        self.isRenaming = false
        self.renameCommitRequestID = 0
        self.canRename = canRename
        self.onRenameItem = onRenameItem
        self.onRenameUnavailable = onRenameUnavailable
        self.onRenameEnded = onRenameEnded
    }
}

private struct AppTileHostingRoot: View {
    let model: AppTileHostingModel

    var body: some View {
        AppTile(
            item: model.item,
            previewItems: model.previewItems,
            isPressed: model.isPressed,
            isDragging: false,
            isDropTarget: model.isDropTarget,
            metrics: model.metrics,
            isRenaming: model.isRenaming,
            renameCommitRequestID: model.renameCommitRequestID,
            canRename: model.canRename,
            openAction: { },
            revealAction: { },
            renameAction: model.onRenameItem.map { onRenameItem in
                { name in
                    model.isRenaming = false
                    model.onRenameEnded?()
                    onRenameItem(model.item.id, name)
                }
            },
            renameUnavailableAction: model.onRenameUnavailable,
            renameCancelAction: {
                model.isRenaming = false
                model.onRenameEnded?()
            },
            ungroupAction: nil
        )
        .frame(width: model.size.width, height: model.size.height)
        .allowsHitTesting(model.isRenaming)
    }
}

private struct FolderGlassBackground: View {
    let size: CGFloat
    var cornerRadius: CGFloat? = nil
    var showsStroke = true

    var body: some View {
        let resolvedCornerRadius = cornerRadius ?? size * 0.30
        let shape = RoundedRectangle(cornerRadius: resolvedCornerRadius, style: .continuous)

        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) {
                shape
                    .fill(.black.opacity(0.001))
                    .frame(width: size, height: size)
                    .glassEffect(.clear.interactive(), in: shape)
                    .overlay(
                        outerStroke(shape)
                    )
                    .overlay(
                        innerStroke(shape)
                    )
                    .contentShape(shape)
            }
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay(
                    shape
                        .fill(Color.white.opacity(0.045))
                )
                .overlay(
                    fallbackStroke(shape)
                )
                .frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private func outerStroke(_ shape: RoundedRectangle) -> some View {
        if showsStroke {
            shape
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.60), location: 0.00),
                            .init(color: .white.opacity(0.20), location: 0.24),
                            .init(color: .white.opacity(0.06), location: 0.58),
                            .init(color: .black.opacity(0.22), location: 1.00)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.9
                )
        }
    }

    @ViewBuilder
    private func innerStroke(_ shape: RoundedRectangle) -> some View {
        if showsStroke {
            shape
                .inset(by: 1)
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.18), location: 0.00),
                            .init(color: .clear, location: 0.34),
                            .init(color: .black.opacity(0.10), location: 1.00)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.6
                )
        }
    }

    @ViewBuilder
    private func fallbackStroke(_ shape: RoundedRectangle) -> some View {
        if showsStroke {
            shape
                .stroke(
                    Color(red: 0.75, green: 0.96, blue: 1.00).opacity(0.58),
                    lineWidth: 1.05
                )
        }
    }
}

private struct FolderPreviewIcon: View, Equatable {
    let items: [LaunchItem]
    let isDropTarget: Bool
    let size: CGFloat
    var showsBackground = true

    nonisolated static func == (lhs: FolderPreviewIcon, rhs: FolderPreviewIcon) -> Bool {
        lhs.items == rhs.items
            && lhs.isDropTarget == rhs.isDropTarget
            && lhs.size == rhs.size
            && lhs.showsBackground == rhs.showsBackground
    }

    var body: some View {
        ZStack {
            if showsBackground {
                FolderGlassBackground(size: isDropTarget ? dropTargetSize : visibleSize, showsStroke: !isDropTarget)
            }

            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(width: visibleSize, height: visibleSize)

                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(previewIconSize), spacing: previewIconSpacing, alignment: .topLeading),
                        count: 3
                    ),
                    alignment: .leading,
                    spacing: previewIconSpacing
                ) {
                    ForEach(previewItems, id: \.id) { item in
                        Image(nsImage: IconCache.rasterizedIcon(for: item.sourcePath, pointSize: previewIconSize))
                            .frame(width: previewIconSize, height: previewIconSize)
                    }
                }
                .frame(width: previewGridWidth, alignment: .topLeading)
                .padding(.top, gridInset)
                .padding(.leading, gridInset)
            }
        }
        .frame(width: size, height: size)
    }

    private var previewGridWidth: CGFloat {
        previewIconSize * 3 + previewIconSpacing * 2
    }

    private var previewItems: [LaunchItem] {
        Array(items.filter { !$0.isHidden && $0.kind != .folder }.prefix(9))
    }

    private var visibleSize: CGFloat { size * 82 / 102 }

    private var dropTargetSize: CGFloat { size * 104 / 102 }

    private var previewIconSize: CGFloat { max(10, size * 17 / 102) }

    private var previewIconSpacing: CGFloat { max(2, size * 4 / 102) }

    private var gridInset: CGFloat {
        max(0, (visibleSize - previewGridWidth) / 2)
    }
}

private struct AppTileHitShape: Shape {
    let iconSize: CGFloat
    let labelSpacing: CGFloat
    let labelHeight: CGFloat
    let labelWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let contentHeight = iconSize + labelSpacing + labelHeight
        let iconOriginY = rect.midY - contentHeight / 2
        let iconRect = CGRect(
            x: rect.midX - iconSize / 2,
            y: iconOriginY,
            width: iconSize,
            height: iconSize
        )
        let labelRect = CGRect(
            x: rect.midX - labelWidth / 2,
            y: iconRect.maxY + labelSpacing,
            width: labelWidth,
            height: labelHeight
        )

        var path = Path()
        path.addRoundedRect(in: iconRect, cornerSize: CGSize(width: 4, height: 4))
        path.addRoundedRect(in: labelRect, cornerSize: CGSize(width: 3, height: 3))
        return path
    }
}

private struct SearchFieldGlassBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.030), location: 0.00),
                                .init(color: .black.opacity(0.018), location: 0.55),
                                .init(color: .black.opacity(0.040), location: 1.00)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.82), location: 0.00),
                                .init(color: Color(red: 0.66, green: 0.91, blue: 1.00).opacity(0.62), location: 0.12),
                                .init(color: Color(red: 0.45, green: 0.78, blue: 0.95).opacity(0.46), location: 0.48),
                                .init(color: Color(red: 0.70, green: 0.93, blue: 1.00).opacity(0.58), location: 0.88),
                                .init(color: .white.opacity(0.66), location: 1.00)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.78
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .inset(by: 0.85)
                    .stroke(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.46), location: 0.00),
                                .init(color: Color(red: 0.78, green: 0.96, blue: 1.00).opacity(0.18), location: 0.18),
                                .init(color: .clear, location: 0.42),
                                .init(color: .clear, location: 0.62),
                                .init(color: Color(red: 0.80, green: 0.97, blue: 1.00).opacity(0.20), location: 0.82),
                                .init(color: .white.opacity(0.36), location: 1.00)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.48
                    )
                    .blendMode(.plusLighter)
            )
            .overlay(
                Capsule(style: .continuous)
                    .inset(by: 1.45)
                    .stroke(.black.opacity(0.08), lineWidth: 0.35)
            )
            .shadow(color: .black.opacity(0.055), radius: 1.2, x: 0, y: 1)
    }
}

private struct KidoXBackground: View {
    @AppStorage(KidoXBackgroundStyle.styleStorageKey)
    private var backgroundStyleRaw = KidoXBackgroundStyle.wallpaper.rawValue
    @AppStorage(KidoXBackgroundStyle.wallpaperBlurStorageKey)
    private var wallpaperBlurRadius = 24.0
    @AppStorage(KidoXBackgroundStyle.wallpaperDarkenStorageKey)
    private var wallpaperDarkenOpacity = 0.18
    @AppStorage(KidoXBackgroundStyle.imageBlurStorageKey)
    private var imageBlurRadius = 24.0
    @AppStorage(KidoXBackgroundStyle.imageDarkenStorageKey)
    private var imageDarkenOpacity = 0.18
    @AppStorage(KidoXBackgroundStyle.glassStrengthStorageKey)
    private var glassStrength = 0.5
    @AppStorage(KidoXBackgroundStyle.solidPresetStorageKey)
    private var solidPresetRaw = KidoXSolidBackgroundPreset.graphite.rawValue
    @AppStorage(KidoXBackgroundStyle.solidCustomColorStorageKey)
    private var solidCustomColorHex = KidoXSolidBackgroundPreset.defaultCustomColorHex
    @AppStorage(KidoXBackgroundStyle.customImagePathStorageKey)
    private var customImagePath = ""
    @AppStorage("ClyAppLicense.status")
    private var licenseStatus = "Free"

    @State private var wallpaper: NSImage?
    @State private var customImage: NSImage?

    init() {
        _wallpaper = State(initialValue: DesktopWallpaperProvider.cachedWallpaperImage())
    }

    private var backgroundStyle: KidoXBackgroundStyle {
        let style = KidoXBackgroundStyle(storageValue: backgroundStyleRaw)
        return licenseStatus == "active" || !style.requiresPro ? style : .wallpaper
    }

    private var solidPreset: KidoXSolidBackgroundPreset {
        let preset = KidoXSolidBackgroundPreset(storageValue: solidPresetRaw)
        return licenseStatus == "active" || !preset.requiresPro ? preset : .graphite
    }

    private var solidColor: Color {
        if solidPreset == .custom {
            return Color(hexRGB: solidCustomColorHex) ?? KidoXSolidBackgroundPreset.defaultCustomColor
        }

        return solidPreset.color
    }

    var body: some View {
        Group {
            switch backgroundStyle {
            case .wallpaper:
                wallpaperBackground
            case .image:
                customImageBackground
            case .glass:
                glassBackground
            case .solid:
                solidBackground
            }
        }
        .task(id: backgroundStyle) {
            await loadBackgroundImageIfNeeded()
        }
        .task(id: customImagePath) {
            await loadBackgroundImageIfNeeded()
        }
    }

    private func loadBackgroundImageIfNeeded() async {
        switch backgroundStyle {
        case .wallpaper:
            guard wallpaper == nil else { return }
            wallpaper = await DesktopWallpaperProvider.currentWallpaperImage()
        case .image:
            customImage = await KidoXCustomWallpaperStore.image(at: customImagePath)
        case .glass, .solid:
            break
        }
    }

    @ViewBuilder
    private var wallpaperBackground: some View {
        ZStack {
            if let wallpaper {
                Image(nsImage: wallpaper)
                    .resizable()
                    .scaledToFill()
                    .saturation(1.14)
                    .contrast(1.06)
                    .brightness(-0.035)
                    .blur(radius: clampedWallpaperBlurRadius, opaque: true)
                    .scaleEffect(wallpaperScale)
                    .ignoresSafeArea()
            } else {
                solidBaseGradient
            }

            Rectangle()
                .fill(wallpaperBrightnessOverlayColor)
                .ignoresSafeArea()

            sharedLightAndVignetteOverlay
        }
    }

    @ViewBuilder
    private var customImageBackground: some View {
        ZStack {
            if let customImage {
                Image(nsImage: customImage)
                    .resizable()
                    .scaledToFill()
                    .saturation(1.08)
                    .contrast(1.04)
                    .brightness(-0.02)
                    .blur(radius: clampedImageBlurRadius, opaque: true)
                    .scaleEffect(imageScale)
                    .ignoresSafeArea()
            } else {
                solidBaseGradient
            }

            Rectangle()
                .fill(imageBrightnessOverlayColor)
                .ignoresSafeArea()

            sharedLightAndVignetteOverlay
        }
    }

    private var glassBackground: some View {
        ZStack {
            glassMaterialLayer

            Rectangle()
                .fill(Color.black.opacity(glassOverlayOpacity))
                .ignoresSafeArea()

            LinearGradient(
                stops: [
                    .init(color: Color.white.opacity(0.06), location: 0.00),
                    .init(color: Color.clear, location: 0.22),
                    .init(color: Color.black.opacity(0.16), location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            sharedLightAndVignetteOverlay
        }
    }

    private var solidBackground: some View {
        ZStack {
            solidColor.ignoresSafeArea()
            sharedLightAndVignetteOverlay
        }
    }

    @ViewBuilder
    private var glassMaterialLayer: some View {
        switch clampedGlassStrength {
        case ..<0.34:
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
        case ..<0.67:
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
        default:
            Rectangle().fill(.thickMaterial).ignoresSafeArea()
        }
    }

    private var solidBaseGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 0.12, green: 0.13, blue: 0.15),
                Color(red: 0.055, green: 0.06, blue: 0.075)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var sharedLightAndVignetteOverlay: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.10), location: 0.00),
                    .init(color: .clear, location: 0.24),
                    .init(color: .black.opacity(0.14), location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            GeometryReader { proxy in
                RadialGradient(
                    colors: [
                        .clear,
                        .black.opacity(0.24)
                    ],
                    center: .center,
                    startRadius: max(proxy.size.width, proxy.size.height) * 0.22,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.78
                )
                .ignoresSafeArea()
            }
        }
    }

    private var clampedWallpaperBlurRadius: CGFloat {
        CGFloat(min(max(wallpaperBlurRadius, 0), 48))
    }

    private var clampedWallpaperBrightnessAdjustment: Double {
        min(max(wallpaperDarkenOpacity, -0.32), 0.45)
    }

    private var wallpaperBrightnessOverlayColor: Color {
        let adjustment = clampedWallpaperBrightnessAdjustment
        return adjustment < 0
            ? Color.white.opacity(abs(adjustment))
            : Color.black.opacity(adjustment)
    }

    private var clampedImageBlurRadius: CGFloat {
        CGFloat(min(max(imageBlurRadius, 0), 48))
    }

    private var clampedImageBrightnessAdjustment: Double {
        min(max(imageDarkenOpacity, -0.32), 0.45)
    }

    private var imageBrightnessOverlayColor: Color {
        let adjustment = clampedImageBrightnessAdjustment
        return adjustment < 0
            ? Color.white.opacity(abs(adjustment))
            : Color.black.opacity(adjustment)
    }

    private var glassOverlayOpacity: Double {
        0.16 + clampedGlassStrength * 0.16
    }

    private var clampedGlassStrength: Double {
        min(max(glassStrength, 0), 1)
    }

    private var wallpaperScale: CGFloat {
        1 + min(clampedWallpaperBlurRadius / 240, 0.16)
    }

    private var imageScale: CGFloat {
        1 + min(clampedImageBlurRadius / 240, 0.16)
    }
}

extension Color {
    init?(hexRGB: String) {
        let hex = hexRGB.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6,
              let value = Int(hex, radix: 16) else {
            return nil
        }

        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }

    var hexRGBString: String? {
        guard let color = NSColor(self)
            .usingColorSpace(.deviceRGB) else {
            return nil
        }

        let red = Int((color.redComponent * 255).rounded())
        let green = Int((color.greenComponent * 255).rounded())
        let blue = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

private struct AppKitPagedGridView: NSViewRepresentable {
    let pages: [[LaunchItem]]
    let childrenByFolderID: [LaunchItem.ID: [LaunchItem]]
    @Binding var currentPage: Int
    let columns: Int
    let rows: Int
    let pageWidth: CGFloat
    let pageHeight: CGFloat
    let horizontalMargin: CGFloat
    let gridTopY: CGFloat
    let gridBottomY: CGFloat
    let isReorderingEnabled: Bool
    let isRenameEnabled: Bool
    let showsProBadges: Bool
    let rootDragStartRequest: RootDragStartRequest?
    let pageTurnAnimationRequest: PageTurnAnimationRequest?
    let compactionAnimationRequest: GridCompactionAnimationRequest?
    let visuallyHiddenItemID: LaunchItem.ID?
    let onPageTurn: (Int) -> Void
    let onCreateBoundaryPage: (Int) -> Int?
    let onRootDragStarted: (UUID) -> Void
    let onOpen: (LaunchItem) -> Void
    let onReveal: (LaunchItem) -> Void
    let onUninstall: (LaunchItem) -> Void
    let onRenameItem: (LaunchItem.ID, String) -> Void
    let onRenameUnavailable: () -> Void
    let onRenameEnded: () -> Void
    let onUngroupFolder: (LaunchItem.ID) -> Void
    let onHide: (LaunchItem) -> Void
    let onReorder: (LaunchItem.ID, Int) -> Void
    let onMoveRootItem: (LaunchItem.ID, Int, Int) -> Void
    let onDropRootItem: (LaunchItem.ID, LaunchItem.ID) -> Void
    let onEmptyTap: () -> Void
    let selectedItemID: LaunchItem.ID?
    let isInSearchMode: Bool
    let onBeginSearchDrag: (LaunchItem.ID, Int) -> Int?

    func makeNSView(context: Context) -> AppKitPagedGridNSView {
        context.coordinator.onPageTurn = onPageTurn
        let view = AppKitPagedGridNSView()
        view.onPageChanged = { page in
            let didChangePage = page != currentPage
            currentPage = page
            if didChangePage, selectedItemID != nil {
                context.coordinator.onPageTurn?(page)
            }
        }
        view.onOpen = onOpen
        view.onReveal = onReveal
        view.onUninstall = onUninstall
        view.onRenameItem = onRenameItem
        view.onRenameUnavailable = onRenameUnavailable
        view.onRenameEnded = onRenameEnded
        view.onUngroupFolder = onUngroupFolder
        view.onHide = onHide
        view.onReorder = onReorder
        view.onMoveRootItem = onMoveRootItem
        view.onDropRootItem = onDropRootItem
        view.onEmptyTap = onEmptyTap
        view.onBeginSearchDrag = onBeginSearchDrag
        view.onRootDragStarted = onRootDragStarted
        view.onCreateBoundaryPage = onCreateBoundaryPage
        view.isRenameEnabled = isRenameEnabled
        view.showsProBadges = showsProBadges
        view.visuallyHiddenItemID = visuallyHiddenItemID
        return view
    }

    func updateNSView(_ nsView: AppKitPagedGridNSView, context: Context) {
        context.coordinator.onPageTurn = onPageTurn
        nsView.onPageChanged = { page in
            let didChangePage = page != currentPage
            currentPage = page
            if didChangePage, selectedItemID != nil {
                context.coordinator.onPageTurn?(page)
            }
        }
        nsView.onOpen = onOpen
        nsView.onReveal = onReveal
        nsView.onUninstall = onUninstall
        nsView.onRenameItem = onRenameItem
        nsView.onRenameUnavailable = onRenameUnavailable
        nsView.onRenameEnded = onRenameEnded
        nsView.onUngroupFolder = onUngroupFolder
        nsView.onHide = onHide
        nsView.onReorder = onReorder
        nsView.onMoveRootItem = onMoveRootItem
        nsView.onDropRootItem = onDropRootItem
        nsView.onEmptyTap = onEmptyTap
        nsView.onBeginSearchDrag = onBeginSearchDrag
        nsView.onRootDragStarted = onRootDragStarted
        nsView.onCreateBoundaryPage = onCreateBoundaryPage
        nsView.isRenameEnabled = isRenameEnabled
        nsView.showsProBadges = showsProBadges
        nsView.isInSearchMode = isInSearchMode
        nsView.rootDragStartRequest = rootDragStartRequest
        nsView.visuallyHiddenItemID = visuallyHiddenItemID
        nsView.configure(
            pages: pages,
            childrenByFolderID: childrenByFolderID,
            currentPage: currentPage,
            columns: columns,
            rows: rows,
            pageWidth: pageWidth,
            pageHeight: pageHeight,
            horizontalMargin: horizontalMargin,
            gridTopY: gridTopY,
            gridBottomY: gridBottomY,
            isReorderingEnabled: isReorderingEnabled,
            pageTurnAnimationRequest: pageTurnAnimationRequest,
            compactionAnimationRequest: compactionAnimationRequest
        )
        nsView.updateSelection(itemID: selectedItemID)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var onPageTurn: ((Int) -> Void)?
    }
}

@MainActor
private final class AppKitPagedGridNSView: NSView, NSDraggingSource {
    var onPageChanged: ((Int) -> Void)?
    var onOpen: ((LaunchItem) -> Void)?
    var onReveal: ((LaunchItem) -> Void)?
    var onUninstall: ((LaunchItem) -> Void)?
    var onRenameItem: ((LaunchItem.ID, String) -> Void)?
    var onRenameUnavailable: (() -> Void)?
    var onRenameEnded: (() -> Void)?
    var onUngroupFolder: ((LaunchItem.ID) -> Void)?
    var onHide: ((LaunchItem) -> Void)?
    var onReorder: ((LaunchItem.ID, Int) -> Void)?
    var onMoveRootItem: ((LaunchItem.ID, Int, Int) -> Void)?
    var onDropRootItem: ((LaunchItem.ID, LaunchItem.ID) -> Void)?
    var onEmptyTap: (() -> Void)?
    var onBeginSearchDrag: ((LaunchItem.ID, Int) -> Int?)?
    var onRootDragStarted: ((UUID) -> Void)?
    var onCreateBoundaryPage: ((Int) -> Int?)?
    var isInSearchMode: Bool = false
    var isRenameEnabled: Bool = true {
        didSet {
            guard oldValue != isRenameEnabled else { return }
            if !isRenameEnabled {
                finishInlineRename()
            }
            updateRenameAvailability()
        }
    }
    var showsProBadges: Bool = true
    var rootDragStartRequest: RootDragStartRequest?
    var visuallyHiddenItemID: LaunchItem.ID?
    private var handledPageTurnAnimationRequestID: UUID?
    private var handledCompactionAnimationRequestID: UUID?

    // 当搜索态触发拖拽时记下来，等下一次 configure (退出搜索后) 再实际开始拖拽
    private var pendingSearchDragItem: LaunchItem?
    private var pendingSearchDragMouseDownPoint: CGPoint?
    private var pendingSearchDragCurrentPoint: CGPoint?
    private var pendingSearchDragTargetPage: Int?

    private var pages: [[LaunchItem]] = []
    private var childrenByFolderID: [LaunchItem.ID: [LaunchItem]] = [:]
    private var isReorderingEnabled = true
    private var currentPage = 0
    private var columns = 7
    private var rows = 5
    private var pageWidth: CGFloat = 0
    private var pageHeight: CGFloat = 0
    private var horizontalMargin: CGFloat = 0
    private var gridTopY: CGFloat = 0
    private var gridBottomY: CGFloat = 0

    private let containerView = FlippedLayerBackedView()
    private let glassOverlayContainerView = FlippedLayerBackedView()
    private let appLayerContainerView = FlippedLayerBackedView()
    private var pageLayers: [CALayer] = []
    private var folderTileViews: [NSView] = []
    private var tileRecords: [TileRecord] = []
    private var mouseDownPoint: CGPoint?
    private var mouseDownItem: LaunchItem?
    private var isPageDragging = false
    private var isTileDragging = false
    private var isFinishingTileDrag = false
    private var dragStartOffsetX: CGFloat = 0
    private var tileDragFingerOffset: CGSize = .zero
    private var tileDraggedItem: LaunchItem?
    private var tileDragOriginPage: Int?
    private var tileDragTargetPage: Int?
    private var tileDragOriginSlot: Int?
    private var tileDragPreviousPoint: CGPoint?
    private var tileDragLastPoint: CGPoint?
    private var tileDragOverlayView: NSView?
    private var tileDragOverlayItem: LaunchItem?
    private var isTrackingTrackpadPageGesture = false
    private var isTrackpadPageDragging = false
    private var trackpadAccumulatedTranslation: CGSize = .zero
    private var trackpadDragStartOffsetX: CGFloat = 0
    private var lastMouseWheelPageTurnDate = Date.distantPast
    private var handledRootDragStartRequestID: UUID?
    private var rootDragMonitor: Any?
    private var pendingDropDraggingID: LaunchItem.ID?
    private var pendingDropFinalFrame: CGRect?
    private var pendingDropFinalPageIndex: Int?
    private var pendingDropCompactionSourceFrames: [LaunchItem.ID: PendingDropCompactionSourceFrame] = [:]
    private var dropTargetOverlayView: NSView?
    private var highlightedDropTargetID: LaunchItem.ID?
    private var nearbyPageRenderWorkItem: DispatchWorkItem?
    private var renderedPageIndexes = Set<Int>()
    private var renderedBackingScale: CGFloat?
    private var tileDragEdgeTimer: Timer?
    private var pageOrderOverride: [LaunchItem.ID]?
    private var selectedItemID: LaunchItem.ID?
    private var selectionHighlightView: NSView?
    private var selectionHighlightItemID: LaunchItem.ID?
    private var pressedVisualItemID: LaunchItem.ID?
    private var dragDropTargetID: LaunchItem.ID?
    private var dragEnteredDropTargetID: LaunchItem.ID?
    private var dragEnteredDropTargetDirection: DropTargetEntryDirection?
    private var dragEdgeSide = 0
    private var dragEdgeEnteredAt: Date?
    private var dragEdgeHasTurnedInCurrentRun = false
    private var lastDragPageTurnDate = Date.distantPast
    private var appSystemDragSession: NSDraggingSession?
    private var tileDragUsesSystemDrag = false
    private var tileDragDockEdgeSnapshot: DockEdge?
    private var appSystemDragMouseUpTimer: Timer?
    private var inlineRenameView: AppTileHostingView?
    private var inlineRenameHiddenVisual: TileVisual?
    private var inlineRenameIsTemporaryOverlay = false
    private var renameWindowNotificationTokens: [NSObjectProtocol] = []
    private var renameWindowMouseDownMonitor: Any?
    private let dragActivationDistance: CGFloat = 6
    private let pageTurnReleaseThreshold: CGFloat = 64
    private let rowChangeHorizontalThreshold: CGFloat = 22
    private let rowCenterTolerance: CGFloat = 12
    private let dragPageTurnEdgeWidth: CGFloat = 56
    private let dragPageTurnDwell: TimeInterval = 0.4
    private let dragPageTurnRepeatDwell: TimeInterval = 1.0
    private let dragPageTurnCooldown: TimeInterval = 0.3
    private let mouseWheelPageTurnCooldown: TimeInterval = 0.22
    private let tileReorderAnimationDuration: TimeInterval = 0.52
    private let tileDropTargetFinishAnimationDuration: TimeInterval = 0.18
    private let dropTargetIconSize: CGFloat = 108
    private let enablesAppSystemDragBridge = true
    private let appSystemDragBridgeDockPadding: CGFloat = 24
    private let minimumDockInsetForSystemDragBridge: CGFloat = 1

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.isGeometryFlipped = true
        containerView.wantsLayer = true
        containerView.layer?.masksToBounds = false
        containerView.layer?.isGeometryFlipped = true
        containerView.layer?.actions = disabledActions
        addSubview(containerView)

        glassOverlayContainerView.wantsLayer = true
        glassOverlayContainerView.layer?.masksToBounds = false
        glassOverlayContainerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.addSubview(glassOverlayContainerView)

        appLayerContainerView.wantsLayer = true
        appLayerContainerView.layer?.masksToBounds = false
        appLayerContainerView.layer?.backgroundColor = NSColor.clear.cgColor
        appLayerContainerView.layer?.isGeometryFlipped = true
        appLayerContainerView.layer?.actions = disabledActions
        containerView.addSubview(appLayerContainerView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeRenameWindowObservers()
        removeRenameMouseDownMonitor()
        if window == nil {
            tearDownForWindowRemoval()
            clearCallbacks()
        } else {
            installRenameWindowObservers()
            installRenameMouseDownMonitor()
            ensurePageRendered(currentPage)
            scheduleNearbyPageRendering()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rerenderRenderedLayerContents()
    }

    override func layout() {
        super.layout()
        layer?.masksToBounds = true
        containerView.frame.size = CGSize(
            width: pageWidth * CGFloat(max(pages.count, 1)),
            height: pageHeight
        )
        glassOverlayContainerView.frame = containerView.bounds
        appLayerContainerView.frame = containerView.bounds
        positionContainer(animated: false)
    }

    private func tearDownForWindowRemoval() {
        finishInlineRename()
        removeRenameWindowObservers()
        removeRenameMouseDownMonitor()
        removeRootDragMonitor()
        stopAppSystemDragMouseUpWatchdog()
        nearbyPageRenderWorkItem?.cancel()
        nearbyPageRenderWorkItem = nil
        tileDragEdgeTimer?.invalidate()
        tileDragEdgeTimer = nil

        tileDragOverlayView?.removeFromSuperview()
        tileDragOverlayView = nil
        tileDragOverlayItem = nil
        dropTargetOverlayView?.removeFromSuperview()
        dropTargetOverlayView = nil
        highlightedDropTargetID = nil
        removeSelectionHighlight()

        pageLayers.forEach { $0.removeFromSuperlayer() }
        pageLayers.removeAll()
        folderTileViews.forEach { $0.removeFromSuperview() }
        folderTileViews.removeAll()
        tileRecords.removeAll()
        renderedPageIndexes.removeAll()
        renderedBackingScale = nil
        pendingDropCompactionSourceFrames.removeAll()

        pages.removeAll()
        childrenByFolderID.removeAll()
        pendingSearchDragItem = nil
        pendingSearchDragMouseDownPoint = nil
        pendingSearchDragCurrentPoint = nil
        pendingSearchDragTargetPage = nil
        mouseDownPoint = nil
        mouseDownItem = nil
        isPageDragging = false
        isTileDragging = false
        isFinishingTileDrag = false
        appSystemDragSession = nil
        tileDragUsesSystemDrag = false
        tileDragDockEdgeSnapshot = nil
        tileDraggedItem = nil
        tileDragOriginPage = nil
        tileDragTargetPage = nil
        tileDragOriginSlot = nil
        tileDragPreviousPoint = nil
        tileDragLastPoint = nil
        pageOrderOverride = nil
        selectedItemID = nil
        selectionHighlightItemID = nil
        pressedVisualItemID = nil
        dragDropTargetID = nil
        dragEnteredDropTargetID = nil
        dragEnteredDropTargetDirection = nil
        dragEdgeSide = 0
        dragEdgeEnteredAt = nil
        dragEdgeHasTurnedInCurrentRun = false
    }

    private func clearCallbacks() {
        onPageChanged = nil
        onOpen = nil
        onReveal = nil
        onRenameItem = nil
        onRenameUnavailable = nil
        onRenameEnded = nil
        onUngroupFolder = nil
        onHide = nil
        onReorder = nil
        onMoveRootItem = nil
        onDropRootItem = nil
        onEmptyTap = nil
        onBeginSearchDrag = nil
        onRootDragStarted = nil
        onCreateBoundaryPage = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let inlineRenameView,
           !inlineRenameView.isHidden {
            let localPoint = convert(point, to: inlineRenameView)
            if inlineRenameView.containsRenameInput(at: localPoint),
               let hitView = inlineRenameView.hitTest(localPoint) {
                return hitView
            }
        }
        return bounds.contains(point) ? self : nil
    }

    private func installRenameMouseDownMonitor() {
        guard renameWindowMouseDownMonitor == nil else { return }
        renameWindowMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self,
                  let inlineRenameView = self.inlineRenameView,
                  !inlineRenameView.isHidden,
                  event.window === self.window
            else {
                return event
            }

            let point = self.convert(event.locationInWindow, from: nil)
            let renamePoint = self.convert(point, to: inlineRenameView)
            if inlineRenameView.containsRenameInput(at: renamePoint) {
                return event
            }

            self.commitInlineRename()
            return event
        }
    }

    private func removeRenameMouseDownMonitor() {
        if let renameWindowMouseDownMonitor {
            NSEvent.removeMonitor(renameWindowMouseDownMonitor)
            self.renameWindowMouseDownMonitor = nil
        }
    }

    private func installRenameWindowObservers() {
        guard let window else { return }

        let notificationCenter = NotificationCenter.default
        renameWindowNotificationTokens = [
            notificationCenter.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.finishInlineRename()
                }
            },
            notificationCenter.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.finishInlineRename()
                }
            },
            notificationCenter.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.finishInlineRename()
                }
            }
        ]
    }

    private func removeRenameWindowObservers() {
        let notificationCenter = NotificationCenter.default
        renameWindowNotificationTokens.forEach { notificationCenter.removeObserver($0) }
        renameWindowNotificationTokens.removeAll()
    }

    private func updateRenameAvailability() {
        for case let view as AppTileHostingView in folderTileViews {
            view.update(canRename: isRenameEnabled)
        }
        if inlineRenameIsTemporaryOverlay {
            inlineRenameView?.update(canRename: isRenameEnabled)
        }
    }

    func configure(
        pages: [[LaunchItem]],
        childrenByFolderID: [LaunchItem.ID: [LaunchItem]],
        currentPage: Int,
        columns: Int,
        rows: Int,
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        horizontalMargin: CGFloat,
        gridTopY: CGFloat,
        gridBottomY: CGFloat,
        isReorderingEnabled: Bool,
        pageTurnAnimationRequest: PageTurnAnimationRequest?,
        compactionAnimationRequest: GridCompactionAnimationRequest?
    ) {
        let previousTileMetrics = tileMetrics
        let shouldRebuild = self.pages != pages
            || self.childrenByFolderID != childrenByFolderID
            || self.isReorderingEnabled != isReorderingEnabled

        let shouldRelayout = self.columns != columns
            || self.rows != rows
            || self.pageWidth != pageWidth
            || self.pageHeight != pageHeight
            || self.horizontalMargin != horizontalMargin
            || self.gridTopY != gridTopY
            || self.gridBottomY != gridBottomY

        let boundedCurrentPage = max(0, min(currentPage, max(pages.count - 1, 0)))
        let shouldAnimatePageTurn = pageTurnAnimationRequest != nil
            && pageTurnAnimationRequest?.id != handledPageTurnAnimationRequestID
            && pageTurnAnimationRequest?.targetPage == boundedCurrentPage
            && boundedCurrentPage != self.currentPage
        let willAnimatePageTurn = shouldAnimatePageTurn && !shouldRebuild && !shouldRelayout

        if willAnimatePageTurn {
            handledPageTurnAnimationRequestID = pageTurnAnimationRequest?.id
        }
        let shouldPrepareCompactionAnimation = compactionAnimationRequest != nil
            && compactionAnimationRequest?.id != handledCompactionAnimationRequestID
            && compactionAnimationRequest.map { request in
                tileRecords.contains(where: { $0.item.id == request.removedItemID })
                    && !pages.contains { page in
                        page.contains { $0.id == request.removedItemID }
                    }
            } == true
        if let compactionAnimationRequest, shouldPrepareCompactionAnimation {
            handledCompactionAnimationRequestID = compactionAnimationRequest.id
            pendingDropCompactionSourceFrames = Dictionary(
                uniqueKeysWithValues: tileRecords
                    .filter { $0.item.id != compactionAnimationRequest.removedItemID }
                    .map {
                        (
                            $0.item.id,
                            PendingDropCompactionSourceFrame(
                                frame: $0.frame,
                                pageIndex: $0.pageIndex
                            )
                        )
                    }
            )
        }

        self.pages = pages
        self.childrenByFolderID = childrenByFolderID
        self.isReorderingEnabled = isReorderingEnabled
        self.currentPage = boundedCurrentPage
        self.columns = columns
        self.rows = rows
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
        self.horizontalMargin = horizontalMargin
        self.gridTopY = gridTopY
        self.gridBottomY = gridBottomY
        let backingScaleChanged = renderedBackingScale.map { $0 != backingScale } ?? false
        let shouldRefreshRenderedContents = previousTileMetrics != tileMetrics
            || backingScaleChanged

        if shouldRebuild {
            rebuildLayers()
        } else if shouldRelayout {
            relayoutLayersPreservingContents(refreshRenderedContents: shouldRefreshRenderedContents)
        } else {
            ensurePageRendered(self.currentPage)
        }
        if !isPageDragging {
            positionContainer(animated: willAnimatePageTurn)
        }
        if isTileDragging {
            applyDragLayout()
        }
        let pendingDropCompactionAnimations = preparePendingDropCompactionAnimationIfNeeded()
        finishPendingDrop()
        runPendingDropCompactionAnimations(pendingDropCompactionAnimations)
        applyVisualHiddenState()
        applySelectionHighlight()
        flushPendingSearchDragIfNeeded()
        startRootDragIfNeeded()
        scheduleNearbyPageRendering()
    }

    private func relayoutLayersPreservingContents(refreshRenderedContents: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        containerView.frame = CGRect(
            x: containerView.frame.origin.x,
            y: 0,
            width: pageWidth * CGFloat(max(pages.count, 1)),
            height: pageHeight
        )
        glassOverlayContainerView.frame = containerView.bounds
        appLayerContainerView.frame = containerView.bounds

        for (pageIndex, pageLayer) in pageLayers.enumerated() {
            pageLayer.frame = CGRect(
                x: CGFloat(pageIndex) * pageWidth,
                y: 0,
                width: pageWidth,
                height: pageHeight
            )
        }

        let metrics = refreshRenderedContents ? tileMetrics : nil
        let scale = backingScale
        for pageIndex in pages.indices {
            let displayItems = displayOrder(for: pageIndex, items: pages[pageIndex])
            for (slot, item) in displayItems.enumerated() {
                guard let recordIndex = tileRecords.firstIndex(where: {
                    $0.pageIndex == pageIndex && $0.item.id == item.id
                }) else {
                    continue
                }

                let recordMetrics = metrics ?? tileRecords[recordIndex].metrics
                let frame = tileFrameForItem(index: slot, metrics: recordMetrics)
                tileRecords[recordIndex].frame = frame
                tileRecords[recordIndex].metrics = recordMetrics

                let visual = tileRecords[recordIndex].visual
                if case .view(let view) = visual,
                   let view = view as? AppTileHostingView {
                    view.updateLayout(size: frame.size, metrics: recordMetrics)
                } else if refreshRenderedContents,
                          case .layer(let layer) = visual {
                    layer.contentsScale = scale
                    layer.contents = AppKitTileImageRenderer.image(
                        item: item,
                        previewItems: [],
                        size: frame.size,
                        scale: scale,
                        metrics: recordMetrics
                    )
                }
                setVisual(visual, frame: frame, pageIndex: pageIndex)
            }
        }
        if refreshRenderedContents {
            renderedBackingScale = scale
        }
    }

    private func flushPendingSearchDragIfNeeded() {
        guard !isFinishingTileDrag else { return }

        guard let item = pendingSearchDragItem,
              let mouseDown = pendingSearchDragMouseDownPoint,
              let current = pendingSearchDragCurrentPoint,
              !isInSearchMode
        else {
            if pendingSearchDragItem != nil {
                SearchDragLog.write("flush: skipped (isInSearchMode=\(isInSearchMode), hasMouse=\(pendingSearchDragMouseDownPoint != nil))")
            }
            return
        }

        // 找到 item 实际所在的真实 page：
        // 优先用上层指定的 targetPage（进入搜索前的页面），
        // 但 store 可能因为 item 已经在那或目标页不存在而没移动；
        // 兜底找 item 在 root 实际所在的 page。
        let preferred = pendingSearchDragTargetPage
        let preferredHit: Bool
        if let preferred,
           preferred >= 0,
           preferred < pages.count {
            preferredHit = pages[preferred].contains(where: { $0.id == item.id })
        } else {
            preferredHit = false
        }
        let foundPage = pages.firstIndex(where: { $0.contains(where: { $0.id == item.id }) })

        SearchDragLog.write("flush: itemID=\(item.id), pendingTarget=\(preferred.map(String.init) ?? "nil"), preferredHit=\(preferredHit), foundPage=\(foundPage.map(String.init) ?? "nil"), pages.count=\(pages.count), currentPage=\(currentPage)")

        let resolvedPage: Int
        if preferredHit, let preferred {
            resolvedPage = preferred
        } else if let found = foundPage {
            resolvedPage = found
        } else {
            // store 还没把 item 放进任何真实页面（pages 还是搜索切片或还没刷新），等下次 configure
            SearchDragLog.write("flush: waiting (item not in any page yet)")
            return
        }

        SearchDragLog.write("flush: starting drag at resolvedPage=\(resolvedPage)")

        pendingSearchDragItem = nil
        pendingSearchDragMouseDownPoint = nil
        pendingSearchDragCurrentPoint = nil
        pendingSearchDragTargetPage = nil

        if currentPage != resolvedPage {
            currentPage = resolvedPage
            onPageChanged?(resolvedPage)
            positionContainer(animated: false)
        }

        mouseDownItem = item
        mouseDownPoint = mouseDown
        beginTileDrag(
            item: item,
            startPoint: mouseDown,
            currentPoint: current,
            centerOverlayOnPointer: true
        )
    }

    private func startRootDragIfNeeded() {
        guard let request = rootDragStartRequest,
              handledRootDragStartRequestID != request.id,
              !isTileDragging,
              !isCompletingExternalDrop
        else { return }

        guard request.targetPage >= 0,
              request.targetPage < pages.count,
              let item = pages[request.targetPage].first(where: { $0.id == request.itemID })
        else { return }

        handledRootDragStartRequestID = request.id
        onRootDragStarted?(request.id)
        if currentPage != request.targetPage {
            currentPage = request.targetPage
            onPageChanged?(request.targetPage)
            positionContainer(animated: false)
        }

        mouseDownItem = item
        mouseDownPoint = request.startPoint
        beginTileDrag(
            item: item,
            startPoint: request.startPoint,
            currentPoint: request.currentPoint,
            fingerOffsetOverride: request.fingerOffset
        )
        installRootDragMonitor()
    }

    private var isCompletingExternalDrop: Bool {
        pendingDropDraggingID != nil || isFinishingTileDrag
    }

    func updateSelection(itemID: LaunchItem.ID?) {
        guard selectedItemID != itemID else {
            applySelectionHighlight()
            return
        }
        selectedItemID = itemID
        applySelectionHighlight()
    }

    private func applySelectionHighlight() {
        guard let itemID = selectedItemID,
              let record = tileRecords.first(where: { $0.item.id == itemID })
        else {
            removeSelectionHighlight()
            return
        }

        let frame = record.frame.offsetBy(dx: CGFloat(record.pageIndex) * pageWidth, dy: 0)

        if let existing = selectionHighlightView,
           selectionHighlightItemID == itemID {
            // 同一项：直接平滑挪到新位置（page 切换 / 布局变化）
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                context.allowsImplicitAnimation = true
                existing.animator().frame = frame
            }
            return
        }

        // 选中项改变：旧高亮淡出，新高亮淡入（复用 drop target 的玻璃外观）
        removeSelectionHighlight(animated: true)

        let hostingView = DropTargetGlassHostingView(item: record.item, size: frame.size, metrics: record.metrics, scale: 0.68)
        hostingView.frame = frame
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.alphaValue = 0
        glassOverlayContainerView.addSubview(hostingView)
        selectionHighlightView = hostingView
        selectionHighlightItemID = itemID

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hostingView.animator().alphaValue = 1
        }
        hostingView.updateScale(1)
    }

    private func removeSelectionHighlight(animated: Bool = false) {
        guard let view = selectionHighlightView else {
            selectionHighlightItemID = nil
            return
        }
        selectionHighlightView = nil
        selectionHighlightItemID = nil
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in
                    view.removeFromSuperview()
                }
            })
        } else {
            view.removeFromSuperview()
        }
    }

    private func finishPendingDrop() {
        guard let draggingID = pendingDropDraggingID else { return }
        pendingDropDraggingID = nil
        let finalFrame = pendingDropFinalFrame
        let finalPageIndex = pendingDropFinalPageIndex
        pendingDropFinalFrame = nil
        pendingDropFinalPageIndex = nil
        pendingDropCompactionSourceFrames.removeAll()
        isFinishingTileDrag = false
        // 撤 overlay 之前，先把原 tile 摆到落点并 unhide。
        // configure → rebuildLayers 已经把 tile 放到新位置时是 no-op；
        // store 没触发重建时这一步保证撤掉 overlay 不会露出空位。
        for record in tileRecords where record.item.id == draggingID {
            if let finalFrame, let finalPageIndex {
                setVisual(record.visual, frame: finalFrame, pageIndex: finalPageIndex)
            }
            setVisual(record.visual, hidden: false)
        }
        tileDragOverlayView?.removeFromSuperview()
        tileDragOverlayView = nil
        tileDragOverlayItem = nil
    }

    private func preparePendingDropCompactionAnimationIfNeeded() -> [PendingDropCompactionAnimation] {
        guard !pendingDropCompactionSourceFrames.isEmpty else { return [] }

        let sourceFrames = pendingDropCompactionSourceFrames
        pendingDropCompactionSourceFrames.removeAll()

        var animations: [PendingDropCompactionAnimation] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for record in tileRecords {
            guard let source = sourceFrames[record.item.id],
                  source.pageIndex == record.pageIndex,
                  source.frame != record.frame
            else {
                continue
            }

            setVisual(record.visual, frame: source.frame, pageIndex: source.pageIndex)
            animations.append(
                PendingDropCompactionAnimation(
                    visual: record.visual,
                    frame: record.frame,
                    pageIndex: record.pageIndex
                )
            )
        }
        CATransaction.commit()

        return animations
    }

    private func runPendingDropCompactionAnimations(_ animations: [PendingDropCompactionAnimation]) {
        guard !animations.isEmpty else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = tileReorderAnimationDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            context.allowsImplicitAnimation = true
            for animation in animations {
                setVisual(
                    animation.visual,
                    frame: animation.frame,
                    pageIndex: animation.pageIndex,
                    animated: true
                )
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !isFinishingTileDrag else {
            mouseDownPoint = nil
            mouseDownItem = nil
            setPressedVisual(itemID: nil)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        if let inlineRenameView {
            if inlineRenameView.handleRenameInputMouseDown(event, from: self) {
                return
            }
            commitInlineRename()
            return
        }
        mouseDownPoint = point
        mouseDownItem = item(at: point)
        setPressedVisual(itemID: mouseDownItem?.id)
        isPageDragging = false
        dragStartOffsetX = containerView.layer?.presentation()?.frame.origin.x ?? containerView.frame.origin.x
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let inlineRenameView {
            let localPoint = convert(point, to: inlineRenameView)
            if !inlineRenameView.containsRenameInput(at: localPoint) {
                commitInlineRename()
                return nil
            }
        }
        guard let item = item(at: point) else { return nil }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let openItem = NSMenuItem(title: KidoXL10n.string(.open), action: #selector(handleContextOpen(_:)), keyEquivalent: "")
        openItem.target = self
        openItem.representedObject = item
        menu.addItem(openItem)

        if item.kind == .folder {
            let renameItem = NSMenuItem(title: KidoXL10n.string(.rename), action: #selector(handleContextRenameItem(_:)), keyEquivalent: "")
            renameItem.target = self
            renameItem.representedObject = item
            renameItem.attributedTitle = proMenuAttributedTitle(KidoXL10n.string(.rename), showsPro: !isRenameEnabled)
            menu.addItem(renameItem)

            menu.addItem(.separator())

            let ungroupItem = NSMenuItem(title: KidoXL10n.ui("Ungroup Folder"), action: #selector(handleContextUngroupFolder(_:)), keyEquivalent: "")
            ungroupItem.target = self
            ungroupItem.representedObject = item
            menu.addItem(ungroupItem)
        } else {
            let renameItem = NSMenuItem(title: KidoXL10n.string(.rename), action: #selector(handleContextRenameItem(_:)), keyEquivalent: "")
            renameItem.target = self
            renameItem.representedObject = item
            renameItem.attributedTitle = proMenuAttributedTitle(KidoXL10n.string(.rename), showsPro: !isRenameEnabled)
            menu.addItem(renameItem)

            let revealItem = NSMenuItem(title: KidoXL10n.string(.showInFinder), action: #selector(handleContextReveal(_:)), keyEquivalent: "")
            revealItem.target = self
            revealItem.representedObject = item
            menu.addItem(revealItem)

            let hideItem = NSMenuItem(title: KidoXL10n.string(.hideApp), action: #selector(handleContextHide(_:)), keyEquivalent: "")
            hideItem.target = self
            hideItem.representedObject = item
            hideItem.attributedTitle = proMenuAttributedTitle(KidoXL10n.string(.hideApp), showsPro: showsProBadges)
            menu.addItem(hideItem)

            if ApplicationUninstaller.canUninstallApplication(at: item.url) {
                let uninstallItem = NSMenuItem(title: KidoXL10n.string(.uninstallAppEllipsis), action: #selector(handleContextUninstall(_:)), keyEquivalent: "")
                uninstallItem.target = self
                uninstallItem.representedObject = item
                menu.addItem(uninstallItem)
            }

            menu.addItem(.separator())

            let info = NSMenuItem(title: item.bundleIdentifier ?? item.sourcePath, action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }

        return menu
    }

    @objc private func handleContextOpen(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? LaunchItem else { return }
        onOpen?(item)
    }

    @objc private func handleContextReveal(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? LaunchItem else { return }
        onReveal?(item)
    }

    @objc private func handleContextRenameItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? LaunchItem else { return }
        guard isRenameEnabled else {
            onRenameUnavailable?()
            return
        }
        beginInlineRename(for: item)
    }

    @objc private func handleContextUngroupFolder(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? LaunchItem else { return }
        onUngroupFolder?(item.id)
    }

    @objc private func handleContextHide(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? LaunchItem else { return }
        onHide?(item)
    }

    @objc private func handleContextUninstall(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? LaunchItem else { return }
        onUninstall?(item)
    }

    private func beginInlineRename(for item: LaunchItem) {
        guard isRenameEnabled else {
            onRenameUnavailable?()
            return
        }
        guard let record = tileRecords.first(where: { $0.item.id == item.id }) else { return }

        finishInlineRename()
        switch record.visual {
        case .view(let view):
            guard let hostingView = view as? AppTileHostingView else { return }
            inlineRenameView = hostingView
            inlineRenameHiddenVisual = nil
            inlineRenameIsTemporaryOverlay = false
            hostingView.beginRename()

        case .layer:
            let hostingView = AppTileHostingView(
                item: item,
                previewItems: [],
                size: record.frame.size,
                metrics: record.metrics,
                isDropTarget: false,
                canRename: isRenameEnabled,
                onRenameItem: { [weak self] itemID, name in
                    self?.finishInlineRename()
                    self?.onRenameItem?(itemID, name)
                },
                onRenameUnavailable: { [weak self] in
                    self?.onRenameUnavailable?()
                },
                onRenameEnded: { [weak self] in
                    self?.finishInlineRename()
                    self?.onRenameEnded?()
                }
            )
            hostingView.frame = record.frame.offsetBy(dx: CGFloat(record.pageIndex) * pageWidth, dy: 0)
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            setVisual(record.visual, hidden: true)
            containerView.addSubview(hostingView)
            inlineRenameView = hostingView
            inlineRenameHiddenVisual = record.visual
            inlineRenameIsTemporaryOverlay = true
            hostingView.beginRename()
        }
    }

    private func finishInlineRename() {
        inlineRenameView?.endRename()
        if let inlineRenameHiddenVisual {
            setVisual(inlineRenameHiddenVisual, hidden: false)
        }
        if inlineRenameIsTemporaryOverlay {
            inlineRenameView?.removeFromSuperview()
        }
        inlineRenameView = nil
        inlineRenameHiddenVisual = nil
        inlineRenameIsTemporaryOverlay = false
    }

    private func commitInlineRename() {
        guard let inlineRenameView else { return }
        inlineRenameView.commitRename()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isFinishingTileDrag else { return }

        guard let mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        let translation = CGSize(width: point.x - mouseDownPoint.x, height: point.y - mouseDownPoint.y)

        if isTileDragging {
            if tileDragUsesSystemDrag {
                return
            }
            if beginAppSystemDragIfNeeded(event: event, point: point) {
                return
            }
            updateTileDrag(at: point)
            return
        }

        // 搜索拖拽等待中：继续记录鼠标位置，等 configure 完成时 begin drag 用
        if pendingSearchDragItem != nil {
            pendingSearchDragCurrentPoint = point
            return
        }

        if !isPageDragging {
            if let mouseDownItem, isReorderingEnabled {
                setPressedVisual(itemID: nil)
                beginTileDrag(
                    item: mouseDownItem,
                    startPoint: mouseDownPoint,
                    currentPoint: point
                )
                return
            }

            // 搜索态：AppKit 已经判定为拖拽，通知上层退出搜索，等下次 configure 完成再继续拖
            if let mouseDownItem, isInSearchMode, pendingSearchDragItem == nil {
                setPressedVisual(itemID: nil)
                pendingSearchDragItem = mouseDownItem
                pendingSearchDragMouseDownPoint = mouseDownPoint
                pendingSearchDragCurrentPoint = point
                let slot = slotFromGridPoint(point)
                pendingSearchDragTargetPage = onBeginSearchDrag?(mouseDownItem.id, slot)
                SearchDragLog.write("mouseDragged: triggered search drag, itemID=\(mouseDownItem.id), slot=\(slot), returnedTargetPage=\(pendingSearchDragTargetPage.map(String.init) ?? "nil")")
                return
            }

            guard mouseDownItem == nil else { return }
            let distance = hypot(translation.width, translation.height)
            guard distance >= dragActivationDistance else { return }
            guard abs(translation.width) >= abs(translation.height) else { return }
            setPressedVisual(itemID: nil)
            isPageDragging = true
        }

        setContainerOffset(dragStartOffsetX + translation.width)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            setPressedVisual(itemID: nil)
            mouseDownPoint = nil
            mouseDownItem = nil
            isPageDragging = false
            pendingSearchDragItem = nil
            pendingSearchDragMouseDownPoint = nil
            pendingSearchDragCurrentPoint = nil
        }

        let point = convert(event.locationInWindow, from: nil)
        if isTileDragging {
            if tileDragUsesSystemDrag {
                appSystemDragSession = nil
                finishAppSystemDrag(at: point)
                return
            }
            finishTileDrag(at: point)
            return
        }

        if isPageDragging, let mouseDownPoint {
            finishPageDrag(translationX: point.x - mouseDownPoint.x)
            return
        }

        if let mouseDownItem,
           let mouseDownPoint,
           hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) < dragActivationDistance {
            onOpen?(mouseDownItem)
            return
        }

        // 点击空隙（没击中任何 tile，且不是拖拽）→ 通知关闭
        if mouseDownItem == nil,
           let mouseDownPoint,
           hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) < dragActivationDistance {
            onEmptyTap?()
        }
    }

    private func installRootDragMonitor() {
        removeRootDragMonitor()
        rootDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  self.isTileDragging
            else { return event }

            let point = self.convert(event.locationInWindow, from: nil)
            switch event.type {
            case .leftMouseDragged:
                if self.tileDragUsesSystemDrag {
                    return nil
                }
                if self.beginAppSystemDragIfNeeded(event: event, point: point) {
                    return nil
                }
                self.updateTileDrag(at: point)
            case .leftMouseUp:
                if self.tileDragUsesSystemDrag {
                    return nil
                }
                self.removeRootDragMonitor()
                self.finishTileDrag(at: point)
            default:
                break
            }
            return nil
        }
    }

    private func removeRootDragMonitor() {
        if let rootDragMonitor {
            NSEvent.removeMonitor(rootDragMonitor)
            self.rootDragMonitor = nil
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if handleScrollWheel(event) {
            return
        }
        super.scrollWheel(with: event)
    }

    private func handleScrollWheel(_ event: NSEvent) -> Bool {
        guard pages.count > 1, !isTileDragging, pendingSearchDragItem == nil else {
            cancelTrackpadPageGesture()
            return false
        }

        if event.hasPreciseScrollingDeltas {
            return handleTrackpadScroll(event)
        }

        return handleMouseWheelScroll(event)
    }

    private func handleTrackpadScroll(_ event: NSEvent) -> Bool {
        let horizontalDelta = event.scrollingDeltaX
        let verticalDelta = event.scrollingDeltaY
        let isHorizontal = abs(horizontalDelta) > abs(verticalDelta)

        if !event.momentumPhase.isEmpty {
            if isTrackingTrackpadPageGesture {
                cancelTrackpadPageGesture()
            }
            return isHorizontal
        }

        if event.phase.contains(.began) || !isTrackingTrackpadPageGesture {
            beginTrackpadPageGesture()
        }

        if !isHorizontal && !isTrackpadPageDragging {
            cancelTrackpadPageGesture()
            return false
        }

        if event.phase.contains(.cancelled) {
            cancelTrackpadPageGesture()
            return true
        }

        trackpadAccumulatedTranslation.width += horizontalDelta
        trackpadAccumulatedTranslation.height += verticalDelta

        if !isTrackpadPageDragging {
            let distance = hypot(trackpadAccumulatedTranslation.width, trackpadAccumulatedTranslation.height)
            guard distance >= dragActivationDistance else { return true }
            guard abs(trackpadAccumulatedTranslation.width) >= abs(trackpadAccumulatedTranslation.height) else {
                cancelTrackpadPageGesture()
                return false
            }
            isTrackpadPageDragging = true
        }

        setContainerOffset(trackpadDragStartOffsetX + trackpadAccumulatedTranslation.width)

        if event.phase.contains(.ended) {
            finishPageDrag(translationX: trackpadAccumulatedTranslation.width)
            resetTrackpadPageGesture()
        }

        return true
    }

    private func handleMouseWheelScroll(_ event: NSEvent) -> Bool {
        let dominant = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY

        guard abs(dominant) > 0 else { return false }

        let now = Date()
        guard now.timeIntervalSince(lastMouseWheelPageTurnDate) >= mouseWheelPageTurnCooldown else {
            return true
        }
        lastMouseWheelPageTurnDate = now

        if dominant < 0 {
            currentPage = min(currentPage + 1, max(pages.count - 1, 0))
        } else {
            currentPage = max(currentPage - 1, 0)
        }
        onPageChanged?(currentPage)
        positionContainer(animated: true)
        return true
    }

    private func beginTrackpadPageGesture() {
        isTrackingTrackpadPageGesture = true
        isTrackpadPageDragging = false
        trackpadAccumulatedTranslation = .zero
        trackpadDragStartOffsetX = containerView.layer?.presentation()?.frame.origin.x ?? containerView.frame.origin.x
    }

    private func cancelTrackpadPageGesture() {
        if isTrackpadPageDragging {
            positionContainer(animated: true)
        }
        resetTrackpadPageGesture()
    }

    private func resetTrackpadPageGesture() {
        isTrackingTrackpadPageGesture = false
        isTrackpadPageDragging = false
        trackpadAccumulatedTranslation = .zero
        trackpadDragStartOffsetX = 0
    }

    private func finishPageDrag(translationX: CGFloat) {
        let threshold = pageTurnReleaseThreshold
        var targetPage = currentPage
        if translationX < -threshold {
            targetPage = min(currentPage + 1, max(pages.count - 1, 0))
        } else if translationX > threshold {
            targetPage = max(currentPage - 1, 0)
        }
        currentPage = targetPage
        onPageChanged?(targetPage)
        positionContainer(animated: true)
    }

    private func beginTileDrag(
        item: LaunchItem,
        startPoint: CGPoint,
        currentPoint: CGPoint,
        centerOverlayOnPointer: Bool = false,
        fingerOffsetOverride: CGSize? = nil
    ) {
        guard !isFinishingTileDrag else { return }

        guard let record = tileRecords.first(where: { $0.pageIndex == currentPage && $0.item.id == item.id }),
              currentPage < pages.count,
              let originSlot = pages[currentPage].firstIndex(where: { $0.id == item.id })
        else { return }

        isTileDragging = true
        tileDraggedItem = item
        tileDragOriginPage = currentPage
        tileDragTargetPage = currentPage
        tileDragOriginSlot = originSlot
        tileDragPreviousPoint = startPoint
        pageOrderOverride = pages[currentPage].map(\.id)
        dragDropTargetID = nil
        dragEnteredDropTargetID = nil
        dragEnteredDropTargetDirection = nil
        dragEdgeSide = 0
        dragEdgeEnteredAt = nil
        dragEdgeHasTurnedInCurrentRun = false
        lastDragPageTurnDate = .distantPast
        appSystemDragSession = nil
        tileDragUsesSystemDrag = false
        tileDragDockEdgeSnapshot = item.kind == .application ? currentDockEdgeSnapshot() : nil

        if let fingerOffsetOverride {
            tileDragFingerOffset = fingerOffsetOverride
        } else if centerOverlayOnPointer {
            // 搜索拖拽：原来的鼠标位置和新槽位中心毫无关系，让 overlay 跟着鼠标
            tileDragFingerOffset = .zero
        } else {
            let center = CGPoint(x: record.frame.midX, y: record.frame.midY)
            tileDragFingerOffset = CGSize(
                width: startPoint.x - center.x,
                height: startPoint.y - center.y
            )
        }

        let initialDragCenter = CGPoint(
            x: currentPoint.x - tileDragFingerOffset.width,
            y: currentPoint.y - tileDragFingerOffset.height
        )

        setVisual(record.visual, hidden: true)
        createTileDragOverlay(for: item, size: record.frame.size, center: initialDragCenter)
        startTileDragEdgeTimer()
        updateTileDrag(at: currentPoint)
    }

    private func beginAppSystemDragIfNeeded(event: NSEvent, point: CGPoint) -> Bool {
        guard enablesAppSystemDragBridge,
              !tileDragUsesSystemDrag,
              let item = tileDraggedItem,
              item.kind == .application,
              isPointInDockSystemDragZone(point),
              let record = tileRecords.first(where: { $0.item.id == item.id })
        else { return false }

        guard beginAppSystemDrag(
            item: item,
            event: event,
            localPoint: point,
            size: record.frame.size,
            metrics: record.metrics
        ) else { return false }

        tileDragUsesSystemDrag = true
        updateTileDrag(at: point, updatesOverlay: false)
        scheduleSystemDragBridgeOverlayRemoval(for: item.id)
        return true
    }

    private func isPointInDockSystemDragZone(_ point: CGPoint) -> Bool {
        guard let windowPoint = window?.convertPoint(toScreen: convert(point, to: nil)) else {
            return false
        }

        let screen = NSScreen.screens.first(where: { $0.frame.contains(windowPoint) }) ?? window?.screen
        guard let screen else { return false }

        let frame = screen.frame
        let dockEdge = tileDragDockEdgeSnapshot ?? visibleFrameDockEdge(for: screen)
        guard let dockEdge else { return false }

        switch dockEdge {
        case .left:
            return windowPoint.x <= frame.minX + appSystemDragBridgeDockPadding
        case .right:
            return windowPoint.x >= frame.maxX - appSystemDragBridgeDockPadding
        case .bottom:
            return windowPoint.y <= frame.minY + appSystemDragBridgeDockPadding
        }
    }

    private func currentDockEdgeSnapshot() -> DockEdge? {
        guard let orientation = CFPreferencesCopyAppValue(
            "orientation" as CFString,
            "com.apple.dock" as CFString
        ) as? String else {
            return visibleFrameDockEdge(for: window?.screen)
        }

        return DockEdge(dockOrientation: orientation)
            ?? visibleFrameDockEdge(for: window?.screen)
    }

    private func visibleFrameDockEdge(for screen: NSScreen?) -> DockEdge? {
        guard let screen else { return nil }
        return visibleFrameDockEdge(for: screen)
    }

    private func visibleFrameDockEdge(for screen: NSScreen) -> DockEdge? {
        let frame = screen.frame
        let visibleFrame = screen.visibleFrame
        let leftInset = max(0, visibleFrame.minX - frame.minX)
        let rightInset = max(0, frame.maxX - visibleFrame.maxX)
        let bottomInset = max(0, visibleFrame.minY - frame.minY)
        let insets: [(DockEdge, CGFloat)] = [
            (.left, leftInset),
            (.right, rightInset),
            (.bottom, bottomInset)
        ]
        guard let dock = insets.max(by: { $0.1 < $1.1 }),
              dock.1 >= minimumDockInsetForSystemDragBridge
        else { return nil }

        return dock.0
    }

    private func updateTileDrag(at point: CGPoint, updatesOverlay: Bool = true) {
        guard let draggedItem = tileDraggedItem,
              let draggingID = tileDraggedItem?.id
        else { return }

        let previousPoint = tileDragPreviousPoint ?? point
        tileDragLastPoint = point
        defer { tileDragPreviousPoint = point }

        let dragCenter = CGPoint(
            x: point.x - tileDragFingerOffset.width,
            y: point.y - tileDragFingerOffset.height
        )
        if updatesOverlay {
            updateTileDragOverlay(center: dragCenter)
        }
        updateDragTargetPageIfNeeded(location: dragCenter)

        let targetPage = max(0, min(tileDragTargetPage ?? currentPage, max(pages.count - 1, 0)))
        tileDragTargetPage = targetPage
        guard targetPage < pages.count else { return }

        let pageItems = pages[targetPage]
        // 拖拽 folder 时不显示任何 drop target（folder 不能放入 folder）
        let activeTarget: DropTargetHit?
        if draggedItem.kind == .folder {
            activeTarget = nil
        } else {
            activeTarget = dropTargetHit(
                at: point,
                pageIndex: targetPage,
                pageItems: pageItems,
                excluding: draggingID,
                width: dropTargetIconSize,
                height: dropTargetIconSize
            )
        }

        dragDropTargetID = activeTarget?.id
        updateDropTargetHighlight(activeTarget)
        if let activeTarget {
            if dragEnteredDropTargetID != activeTarget.id {
                dragEnteredDropTargetDirection = dropTargetEntryDirection(
                    from: previousPoint,
                    to: point,
                    in: activeTarget.rect
                )
            }
            dragEnteredDropTargetID = activeTarget.id
            return
        }

        guard let targetSlot = insertionSlot(
            at: point,
            previousPoint: previousPoint,
            pageIndex: targetPage,
            pageItems: pageItems
        ) else {
            return
        }

        if let approachingTarget = dropTargetHit(
            atSlot: targetSlot,
            pageIndex: targetPage,
            pageItems: pageItems,
            excluding: draggingID
        ),
           approachingTarget.id == dragEnteredDropTargetID,
           !shouldResumeSortingAfterLeavingDropTarget(at: point, targetRect: approachingTarget.rect) {
            return
        }

        dragEnteredDropTargetID = nil
        dragEnteredDropTargetDirection = nil
        let previousOrder = pageOrderOverride
        updatePageOrderOverride(item: draggedItem, pageItems: pageItems, targetSlot: targetSlot)
        applyDragLayout(animated: pageOrderOverride != previousOrder)
    }

    private func finishTileDrag(at point: CGPoint) {
        guard let draggingID = tileDraggedItem?.id else {
            resetTileDragState()
            return
        }

        isFinishingTileDrag = true
        updateTileDrag(at: point)

        let dropTargetID = dragDropTargetID
        let isDroppingIntoTarget = dropTargetID != nil
        let targetPage = tileDragTargetPage
        let originPage = tileDragOriginPage
        let order = pageOrderOverride

        // 算出原 tile 最终落在哪个 page 的哪个 slot 的 tile frame
        var finalSlotFrame: CGRect?
        var finalSlotPage: Int?
        if let targetPage, targetPage >= 0, targetPage < pages.count {
            let pageItems = pages[targetPage]
            let displayItems = displayOrder(for: targetPage, items: pageItems)
            if let dropTargetID,
               let idx = displayItems.firstIndex(where: { $0.id == dropTargetID }) {
                finalSlotFrame = tileFrameForItem(index: idx)
                finalSlotPage = targetPage
            } else if let order, let idx = order.firstIndex(of: draggingID) {
                finalSlotFrame = tileFrameForItem(index: idx)
                finalSlotPage = targetPage
            }
        }

        let commit: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            // 在通知 store 之前清掉拖拽状态，但保留 overlay 和原 tile 的隐藏
            // 直到下一次 configure() 用新顺序 rebuild 完成
            self.pendingDropDraggingID = draggingID
            self.pendingDropFinalFrame = finalSlotFrame
            self.pendingDropFinalPageIndex = finalSlotPage
            if dropTargetID != nil {
                self.pendingDropCompactionSourceFrames = Dictionary(
                    uniqueKeysWithValues: self.tileRecords
                        .filter { $0.item.id != draggingID }
                        .map {
                            (
                                $0.item.id,
                                PendingDropCompactionSourceFrame(
                                    frame: $0.frame,
                                    pageIndex: $0.pageIndex
                                )
                            )
                        }
                )
            } else {
                self.pendingDropCompactionSourceFrames.removeAll()
            }
            self.tileDraggedItem = nil
            self.tileDragOriginPage = nil
            self.tileDragTargetPage = nil
            self.tileDragOriginSlot = nil
            self.tileDragPreviousPoint = nil
            self.tileDragLastPoint = nil
            self.tileDragFingerOffset = .zero
            self.appSystemDragSession = nil
            self.tileDragUsesSystemDrag = false
            self.tileDragDockEdgeSnapshot = nil
            self.pageOrderOverride = nil
            self.dragDropTargetID = nil
            self.dragEnteredDropTargetID = nil
            self.dragEnteredDropTargetDirection = nil
            self.dragEdgeSide = 0
            self.dragEdgeEnteredAt = nil
            self.dragEdgeHasTurnedInCurrentRun = false
            self.lastDragPageTurnDate = .distantPast
            self.removeDropTargetOverlay()
            self.removeRootDragMonitor()
            self.tileDragEdgeTimer?.invalidate()
            self.tileDragEdgeTimer = nil

            var didNotifyStore = false
            if let dropTargetID {
                self.onDropRootItem?(draggingID, dropTargetID)
                didNotifyStore = true
            } else if let targetPage,
                      let order,
                      let slot = order.firstIndex(of: draggingID) {
                if targetPage == originPage {
                    self.onReorder?(draggingID, slot)
                } else {
                    self.onMoveRootItem?(draggingID, targetPage, slot)
                }
                didNotifyStore = true
            }

            if !didNotifyStore {
                // 没有通知 store，不会有 configure 回调，立即撤 overlay
                self.finishPendingDrop()
                return
            }
            // 通知了 store —— 正常情况下 configure() 会触发 finishPendingDrop。
            // 但如果 store 决定 pages 不变（顺序未变 / drop 被忽略），不会重建，
            // 这里下一 runloop 兜底：finishPendingDrop 会先 unhide 原 tile 再撤 overlay，
            // 真实 tile 已经在原位置，所以不会闪空白。
            DispatchQueue.main.async { [weak self] in
                self?.finishPendingDrop()
            }
        }

        guard let overlay = tileDragOverlayView,
              let finalFrameInGrid = finalTileDragOverlayFrame(
                draggingID: draggingID,
                dropTargetID: dropTargetID,
                targetPage: targetPage,
                order: order,
                overlaySize: overlay.frame.size
              )
        else {
            commit()
            return
        }

        // 锁住后续拖拽事件，但保留 overlay 用于归位动画
        isTileDragging = false
        tileDragEdgeTimer?.invalidate()
        tileDragEdgeTimer = nil

        // 普通排序回位时切回正常外观；drop 到 folder/target 时保持无 label，
        // 否则系统 drag image 消失后会马上露出 app name。
        relaxTileDragOverlay(showsLabel: !isDroppingIntoTarget)

        let host = overlay.superview ?? overlayHostView()
        let finalFrame = convertGridRectToOverlayHost(finalFrameInGrid, in: host)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = isDroppingIntoTarget
                ? tileDropTargetFinishAnimationDuration
                : tileReorderAnimationDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            context.allowsImplicitAnimation = true
            overlay.animator().frame = finalFrame
            if isDroppingIntoTarget {
                overlay.animator().alphaValue = 0
            }
        }, completionHandler: {
            Task { @MainActor in
                commit()
            }
        })
    }

    private func beginAppSystemDrag(
        item: LaunchItem,
        event: NSEvent,
        localPoint: CGPoint,
        size: CGSize,
        metrics: AppTileMetrics
    ) -> Bool {
        guard appSystemDragSession == nil,
              let appURL = dockDraggableApplicationURL(for: item)
        else { return false }

        let dragImage = AppKitTileImageRenderer.image(
            item: item,
            previewItems: [],
            size: size,
            scale: backingScale,
            metrics: metrics,
            isPressed: true,
            isDragging: true
        )
        let dragCenter = CGPoint(
            x: localPoint.x - tileDragFingerOffset.width,
            y: localPoint.y - tileDragFingerOffset.height
        )
        let dragFrame = tileDragFrame(center: dragCenter, size: size)
        let draggingItem = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        draggingItem.setDraggingFrame(
            dragFrame,
            contents: dragImage
        )

        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.draggingFormation = .none
        session.animatesToStartingPositionsOnCancelOrFail = false
        appSystemDragSession = session
        startAppSystemDragMouseUpWatchdog()
        return true
    }

    private func dockDraggableApplicationURL(for item: LaunchItem) -> URL? {
        guard item.kind == .application else { return nil }
        let url = item.sourcePath.isEmpty
            ? item.url
            : URL(fileURLWithPath: item.sourcePath)
        let appURL = url.standardizedFileURL
        guard appURL.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame,
              FileManager.default.fileExists(atPath: appURL.path)
        else { return nil }

        return appURL
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard appSystemDragSession === session else { return }
        appSystemDragSession = nil

        guard let point = gridPoint(forScreenPoint: screenPoint) else {
            resetTileDragState()
            return
        }

        finishAppSystemDrag(at: point)
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard appSystemDragSession === session,
              let point = gridPoint(forScreenPoint: screenPoint)
        else { return }

        updateTileDrag(at: point, updatesOverlay: false)
    }

    private func finishAppSystemDrag(at point: CGPoint) {
        guard isTileDragging, tileDragUsesSystemDrag else { return }
        stopAppSystemDragMouseUpWatchdog()
        appSystemDragSession = nil
        tileDragUsesSystemDrag = false

        if bounds.contains(point) {
            createTileDragOverlayForSystemDragIfNeeded(at: point)
            finishTileDrag(at: point)
        } else {
            finishAppSystemDragReturningToOrigin(from: point)
        }
    }

    private func gridPoint(forScreenPoint screenPoint: NSPoint) -> CGPoint? {
        guard let window else { return nil }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        return convert(windowPoint, from: nil)
    }

    private func startAppSystemDragMouseUpWatchdog() {
        stopAppSystemDragMouseUpWatchdog()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkAppSystemDragMouseButton()
            }
        }
        timer.tolerance = 1.0 / 120.0
        RunLoop.main.add(timer, forMode: .common)
        appSystemDragMouseUpTimer = timer
    }

    private func stopAppSystemDragMouseUpWatchdog() {
        appSystemDragMouseUpTimer?.invalidate()
        appSystemDragMouseUpTimer = nil
    }

    private func checkAppSystemDragMouseButton() {
        guard isTileDragging, tileDragUsesSystemDrag else {
            stopAppSystemDragMouseUpWatchdog()
            return
        }

        guard !CGEventSource.buttonState(.hidSystemState, button: .left) else { return }

        let point = gridPoint(forScreenPoint: NSEvent.mouseLocation)
            ?? tileDragLastPoint
            ?? CGPoint(x: bounds.midX, y: bounds.midY)
        finishAppSystemDrag(at: point)
    }

    private func createTileDragOverlayForSystemDragIfNeeded(at point: CGPoint) {
        guard tileDragOverlayView == nil,
              let item = tileDraggedItem,
              let record = tileRecords.first(where: { $0.item.id == item.id })
        else { return }

        let center = CGPoint(
            x: point.x - tileDragFingerOffset.width,
            y: point.y - tileDragFingerOffset.height
        )
        createTileDragOverlay(for: item, size: record.frame.size, center: center)
    }

    private func finishAppSystemDragReturningToOrigin(from point: CGPoint) {
        createTileDragOverlayForSystemDragIfNeeded(at: point)

        guard let draggingID = tileDraggedItem?.id,
              let overlay = tileDragOverlayView,
              let originPage = tileDragOriginPage,
              originPage >= 0,
              originPage < pages.count
        else {
            resetTileDragState()
            return
        }

        let originSlot = tileDragOriginSlot
            ?? pages[originPage].firstIndex(where: { $0.id == draggingID })
        guard let originSlot else {
            resetTileDragState()
            return
        }

        let originFrame = tileFrameForItem(index: originSlot)
        let pageOffset = CGFloat(originPage - currentPage) * pageWidth
        let finalFrameInGrid = CGRect(
            x: originFrame.midX + pageOffset - overlay.frame.width / 2,
            y: originFrame.midY - overlay.frame.height / 2,
            width: overlay.frame.width,
            height: overlay.frame.height
        )

        isTileDragging = false
        isFinishingTileDrag = true
        dragDropTargetID = nil
        dragEnteredDropTargetID = nil
        dragEnteredDropTargetDirection = nil
        pageOrderOverride = pages[originPage].map(\.id)
        removeDropTargetOverlay()
        removeRootDragMonitor()
        tileDragEdgeTimer?.invalidate()
        tileDragEdgeTimer = nil
        relaxTileDragOverlay()
        overlay.alphaValue = 1

        let host = overlay.superview ?? overlayHostView()
        let finalFrame = convertGridRectToOverlayHost(finalFrameInGrid, in: host)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.52
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            context.allowsImplicitAnimation = true
            overlay.animator().frame = finalFrame
        }, completionHandler: {
            Task { @MainActor in
                self.resetTileDragState()
            }
        })
    }

    private func finalTileDragOverlayFrame(
        draggingID: LaunchItem.ID,
        dropTargetID: LaunchItem.ID?,
        targetPage: Int?,
        order: [LaunchItem.ID]?,
        overlaySize: CGSize
    ) -> CGRect? {
        guard let targetPage, targetPage >= 0, targetPage < pages.count else { return nil }

        let pageItems = pages[targetPage]
        let displayItems = displayOrder(for: targetPage, items: pageItems)
        let pageOffset = CGFloat(targetPage - currentPage) * pageWidth

        let slotIndex: Int
        if let dropTargetID,
           let idx = displayItems.firstIndex(where: { $0.id == dropTargetID }) {
            slotIndex = idx
        } else if let order, let idx = order.firstIndex(of: draggingID) {
            slotIndex = idx
        } else {
            return nil
        }

        let local = tileFrameForItem(index: slotIndex)
        return CGRect(
            x: local.midX + pageOffset - overlaySize.width / 2,
            y: local.midY - overlaySize.height / 2,
            width: overlaySize.width,
            height: overlaySize.height
        )
    }

    private func resetTileDragState() {
        removeRootDragMonitor()
        stopAppSystemDragMouseUpWatchdog()
        isTileDragging = false
        isFinishingTileDrag = false
        appSystemDragSession = nil
        tileDragUsesSystemDrag = false
        tileDragDockEdgeSnapshot = nil
        tileDraggedItem = nil
        tileDragOriginPage = nil
        tileDragTargetPage = nil
        tileDragOriginSlot = nil
        tileDragPreviousPoint = nil
        tileDragLastPoint = nil
        tileDragFingerOffset = .zero
        pageOrderOverride = nil
        dragDropTargetID = nil
        dragEnteredDropTargetID = nil
        dragEnteredDropTargetDirection = nil
        dragEdgeSide = 0
        dragEdgeEnteredAt = nil
        dragEdgeHasTurnedInCurrentRun = false
        lastDragPageTurnDate = .distantPast
        tileDragOverlayView?.removeFromSuperview()
        tileDragOverlayView = nil
        tileDragOverlayItem = nil
        removeDropTargetOverlay()
        tileDragEdgeTimer?.invalidate()
        tileDragEdgeTimer = nil
        applyDragLayout()
    }

    private func startTileDragEdgeTimer() {
        tileDragEdgeTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isTileDragging, let point = self.tileDragLastPoint else { return }
                self.updateTileDrag(at: point)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tileDragEdgeTimer = timer
    }

    private func rebuildLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        finishInlineRename()
        nearbyPageRenderWorkItem?.cancel()
        nearbyPageRenderWorkItem = nil
        pageLayers.forEach { $0.removeFromSuperlayer() }
        pageLayers.removeAll()
        folderTileViews.forEach { $0.removeFromSuperview() }
        folderTileViews.removeAll()
        tileRecords.removeAll()
        renderedPageIndexes.removeAll()
        removeSelectionHighlight()

        containerView.frame = CGRect(
            x: containerView.frame.origin.x,
            y: 0,
            width: pageWidth * CGFloat(max(pages.count, 1)),
            height: pageHeight
        )
        glassOverlayContainerView.frame = containerView.bounds
        appLayerContainerView.frame = containerView.bounds

        for pageIndex in pages.indices {
            let pageLayer = CALayer()
            pageLayer.frame = CGRect(
                x: CGFloat(pageIndex) * pageWidth,
                y: 0,
                width: pageWidth,
                height: pageHeight
            )
            pageLayer.masksToBounds = true
            pageLayer.actions = disabledActions
            pageLayer.isGeometryFlipped = true
            appLayerContainerView.layer?.addSublayer(pageLayer)
            pageLayers.append(pageLayer)
        }

        ensurePageRendered(currentPage)
        renderedBackingScale = backingScale
        scheduleNearbyPageRendering()
    }

    private func ensurePageRendered(_ pageIndex: Int) {
        guard pageIndex >= 0, pageIndex < pages.count else { return }
        guard !renderedPageIndexes.contains(pageIndex) else { return }
        guard pageIndex < pageLayers.count else { return }

        renderPage(pageIndex)
    }

    private func renderPage(_ pageIndex: Int) {
        let metrics = tileMetrics
        let pageLayer = pageLayers[pageIndex]
        let items = pages[pageIndex]

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for (itemIndex, item) in items.enumerated() {
            let tileFrame = tileFrameForItem(index: itemIndex, metrics: metrics)
            if item.kind == .folder {
                let folderFrame = tileFrame.offsetBy(dx: CGFloat(pageIndex) * pageWidth, dy: 0)
                let hostingView = AppTileHostingView(
                    item: item,
                    previewItems: childrenByFolderID[item.id] ?? [],
                    size: tileFrame.size,
                    metrics: metrics,
                    isDropTarget: false,
                    canRename: isRenameEnabled,
                    onRenameItem: { [weak self] itemID, name in
                        self?.finishInlineRename()
                        self?.onRenameItem?(itemID, name)
                    },
                    onRenameUnavailable: { [weak self] in
                        self?.onRenameUnavailable?()
                    },
                    onRenameEnded: { [weak self] in
                        self?.finishInlineRename()
                        self?.onRenameEnded?()
                    }
                )
                hostingView.frame = folderFrame
                hostingView.wantsLayer = true
                hostingView.layer?.backgroundColor = NSColor.clear.cgColor
                hostingView.isHidden = isVisualHidden(item)
                containerView.addSubview(hostingView)
                folderTileViews.append(hostingView)
                tileRecords.append(
                    TileRecord(
                        item: item,
                        pageIndex: pageIndex,
                        frame: tileFrame,
                        metrics: metrics,
                        visual: .view(hostingView)
                    )
                )
            } else {
                let tileLayer = CALayer()
                tileLayer.frame = layerFrameForTileFrame(tileFrame)
                let scale = backingScale
                tileLayer.contentsScale = scale
                tileLayer.contents = AppKitTileImageRenderer.image(
                    item: item,
                    previewItems: [],
                    size: tileFrame.size,
                    scale: scale,
                    metrics: metrics
                )
                tileLayer.actions = disabledActions
                tileLayer.isHidden = isVisualHidden(item)
                pageLayer.addSublayer(tileLayer)
                tileRecords.append(
                    TileRecord(
                        item: item,
                        pageIndex: pageIndex,
                        frame: tileFrame,
                        metrics: metrics,
                        visual: .layer(tileLayer)
                    )
                )
            }
        }

        renderedPageIndexes.insert(pageIndex)
    }

    private func scheduleNearbyPageRendering() {
        nearbyPageRenderWorkItem?.cancel()
        guard window != nil, pages.count > 1 else { return }

        let pageIndexes = [currentPage - 1, currentPage + 1]
            .filter { $0 >= 0 && $0 < pages.count && !renderedPageIndexes.contains($0) }
        guard !pageIndexes.isEmpty else { return }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.isTileDragging, self.pendingDropDraggingID == nil else { return }
                for pageIndex in pageIndexes {
                    self.ensurePageRendered(pageIndex)
                }
            }
        }
        nearbyPageRenderWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    private func rerenderRenderedLayerContents() {
        guard !isTileDragging, pendingDropDraggingID == nil else { return }
        let scale = backingScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for record in tileRecords {
            guard case .layer(let layer) = record.visual else { continue }
            layer.contentsScale = scale
            layer.contents = AppKitTileImageRenderer.image(
                item: record.item,
                previewItems: [],
                size: record.frame.size,
                scale: scale,
                metrics: record.metrics
            )
        }
        CATransaction.commit()
        renderedBackingScale = scale
    }

    private func createTileDragOverlay(for item: LaunchItem, size: CGSize, center: CGPoint) {
        tileDragOverlayView?.removeFromSuperview()
        let hostingView = NSHostingView(rootView: tileDragOverlayContent(
            item: item,
            size: size,
            pressed: true
        ))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        // 添加到 window 顶层，覆盖搜索框和 page indicator，
        // 让拖拽 overlay 的玻璃效果作用到所有 UI 上
        let host = overlayHostView()
        let frame = tileDragFrame(center: center, size: size)
        hostingView.frame = pixelAlignedRect(convertGridRectToOverlayHost(frame, in: host))
        host.addSubview(hostingView)
        tileDragOverlayView = hostingView
        tileDragOverlayItem = item
    }

    private func scheduleSystemDragBridgeOverlayRemoval(for itemID: LaunchItem.ID) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isTileDragging,
                  self.tileDragUsesSystemDrag,
                  self.tileDragOverlayItem?.id == itemID
            else { return }

            self.tileDragOverlayView?.removeFromSuperview()
            self.tileDragOverlayView = nil
            self.tileDragOverlayItem = nil
        }
    }

    private func overlayHostView() -> NSView {
        window?.contentView ?? self
    }

    private func tileDragFrame(center: CGPoint, size: CGSize) -> CGRect {
        pixelAlignedRect(CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        ))
    }

    private func pixelAlignedRect(_ rect: CGRect) -> CGRect {
        let scale = max(backingScale, 1)
        return CGRect(
            x: (rect.origin.x * scale).rounded() / scale,
            y: (rect.origin.y * scale).rounded() / scale,
            width: (rect.width * scale).rounded() / scale,
            height: (rect.height * scale).rounded() / scale
        )
    }

    private func convertGridRectToOverlayHost(_ rect: CGRect, in host: NSView) -> CGRect {
        guard host !== self else { return rect }
        return convert(rect, to: host)
    }

    private func convertOverlayHostRectToGrid(_ rect: CGRect, from host: NSView) -> CGRect {
        guard host !== self else { return rect }
        return host.convert(rect, to: self)
    }

    private func tileDragOverlayContent(
        item: LaunchItem,
        size: CGSize,
        pressed: Bool,
        showsLabel: Bool = true
    ) -> AnyView {
        AnyView(
            AppTile(
                item: item,
                previewItems: item.kind == .folder ? childrenByFolderID[item.id] ?? [] : [],
                isPressed: pressed,
                isDragging: pressed,
                isDropTarget: false,
                showsLabel: showsLabel,
                metrics: tileMetrics,
                renderScale: backingScale,
                openAction: { },
                revealAction: { },
                renameAction: nil,
                ungroupAction: nil
            )
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
        )
    }

    private func relaxTileDragOverlay(showsLabel: Bool = true) {
        guard let hostingView = tileDragOverlayView as? NSHostingView<AnyView>,
              let item = tileDragOverlayItem
        else { return }
        hostingView.rootView = tileDragOverlayContent(
            item: item,
            size: hostingView.frame.size,
            pressed: false,
            showsLabel: showsLabel
        )
    }

    private func updateTileDragOverlay(center: CGPoint) {
        guard let tileDragOverlayView else { return }
        let size = tileDragOverlayView.frame.size
        let gridFrame = tileDragFrame(center: center, size: size)
        let host = tileDragOverlayView.superview ?? overlayHostView()
        tileDragOverlayView.frame = pixelAlignedRect(convertGridRectToOverlayHost(gridFrame, in: host))
    }

    private func applyDragLayout(animated: Bool = false) {
        let draggingID = tileDraggedItem?.id

        for record in tileRecords {
            setVisual(record.visual, hidden: record.item.id == draggingID)
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = tileReorderAnimationDuration
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                context.allowsImplicitAnimation = true

                CATransaction.begin()
                CATransaction.setAnimationDuration(tileReorderAnimationDuration)
                CATransaction.setAnimationTimingFunction(
                    CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                )

                for pageIndex in pages.indices {
                    let displayItems = displayOrder(for: pageIndex, items: pages[pageIndex])
                    for (slot, item) in displayItems.enumerated() where item.id != draggingID {
                        guard let record = tileRecords.first(where: { $0.pageIndex == pageIndex && $0.item.id == item.id }) else {
                            continue
                        }
                        let frame = tileFrameForItem(index: slot)
                        setVisual(record.visual, frame: frame, pageIndex: pageIndex, animated: true)
                    }
                }

                CATransaction.commit()
            }
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for pageIndex in pages.indices {
            let displayItems = displayOrder(for: pageIndex, items: pages[pageIndex])
            for (slot, item) in displayItems.enumerated() where item.id != draggingID {
                guard let record = tileRecords.first(where: { $0.pageIndex == pageIndex && $0.item.id == item.id }) else {
                    continue
                }
                let frame = tileFrameForItem(index: slot)
                setVisual(record.visual, frame: frame, pageIndex: pageIndex)
            }
        }
        CATransaction.commit()
    }

    private func applyVisualHiddenState() {
        for record in tileRecords {
            setVisual(record.visual, hidden: isVisualHidden(record.item))
        }
    }

    private func isVisualHidden(_ item: LaunchItem) -> Bool {
        item.id == tileDraggedItem?.id || item.id == visuallyHiddenItemID
    }

    private func setVisual(_ visual: TileVisual, hidden: Bool) {
        switch visual {
        case .layer(let layer):
            layer.isHidden = hidden
        case .view(let view):
            view.isHidden = hidden
        }
    }

    private func setVisual(_ visual: TileVisual, frame: CGRect, pageIndex: Int, animated: Bool = false) {
        switch visual {
        case .layer(let layer):
            let target = layerFrameForTileFrame(frame)
            if animated {
                let fromPosition = layer.presentation()?.position ?? layer.position
                layer.actions = nil
                layer.frame = target
                let toPosition = layer.position
                if fromPosition != toPosition {
                    let anim = CABasicAnimation(keyPath: "position")
                    anim.fromValue = NSValue(point: NSPoint(x: fromPosition.x, y: fromPosition.y))
                    anim.toValue = NSValue(point: NSPoint(x: toPosition.x, y: toPosition.y))
                    anim.duration = tileReorderAnimationDuration
                    anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                    layer.add(anim, forKey: "tileReorderPosition")
                }
                layer.actions = disabledActions
            } else {
                layer.frame = target
            }
        case .view(let view):
            let target = frame.offsetBy(dx: CGFloat(pageIndex) * pageWidth, dy: 0)
            if animated, view.frame != target {
                view.animator().frame = target
            } else {
                view.frame = target
            }
        }
    }

    private func setPressedVisual(itemID: LaunchItem.ID?) {
        guard pressedVisualItemID != itemID else { return }

        if let pressedVisualItemID {
            updatePressedVisual(itemID: pressedVisualItemID, isPressed: false)
        }

        pressedVisualItemID = itemID

        if let itemID {
            updatePressedVisual(itemID: itemID, isPressed: true)
        }
    }

    private func updatePressedVisual(itemID: LaunchItem.ID, isPressed: Bool) {
        guard let record = tileRecords.first(where: { $0.item.id == itemID }) else { return }

        switch record.visual {
        case .layer(let layer):
            let scale = backingScale
            layer.contentsScale = scale
            layer.contents = AppKitTileImageRenderer.image(
                item: record.item,
                previewItems: [],
                size: record.frame.size,
                scale: scale,
                metrics: record.metrics,
                isPressed: isPressed
            )
        case .view(let view):
            if let view = view as? AppTileHostingView {
                view.update(isPressed: isPressed)
            }
        }
    }

    private func displayOrder(for pageIndex: Int, items: [LaunchItem]) -> [LaunchItem] {
        guard let draggedItem = tileDraggedItem else { return items }
        guard pageIndex == tileDragTargetPage,
              let pageOrderOverride
        else {
            return items.filter { $0.id != draggedItem.id }
        }

        var byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        byID[draggedItem.id] = draggedItem
        let reordered = pageOrderOverride.compactMap { byID[$0] }
        return reordered.count == pageOrderOverride.count ? reordered : items.filter { $0.id != draggedItem.id }
    }

    private func insertionSlot(
        at point: CGPoint,
        previousPoint: CGPoint,
        pageIndex: Int,
        pageItems: [LaunchItem]
    ) -> Int? {
        let top = gridTopY
        let bottom = gridBottomY
        let step = rows > 1 ? max((bottom - top) / CGFloat(rows - 1), 1) : max(bottom - top, 1)
        let rawRow = Int(((point.y - top) / step).rounded())
        let targetRow = max(0, min(rows - 1, rawRow))
        let originRow = (tileDragOriginSlot ?? 0) / max(columns, 1)
        guard shouldUpdateOrderForRowChange(
            from: originRow,
            to: targetRow,
            targetRowCenterY: top + step * CGFloat(targetRow),
            point: point,
            previousPoint: previousPoint
        ) else {
            return nil
        }

        let displayItems = displayOrder(for: pageIndex, items: pageItems)
        let slot = displayItems.enumerated().reduce(0) { result, pair in
            let itemIndex = pair.offset
            let item = pair.element
            guard item.id != tileDraggedItem?.id else { return result }

            let itemRow = itemIndex / max(columns, 1)
            guard itemRow <= targetRow else { return result }
            if itemRow < targetRow {
                return result + 1
            }

            let itemCenterX = tileX(index: itemIndex)
            return point.x > itemCenterX ? result + 1 : result
        }

        let pageSize = max(columns * rows, 1)
        let candidateCount = displayItems.filter { $0.id != tileDraggedItem?.id }.count
        let maxSlot = min(candidateCount, max(pageSize - 1, 0))
        return max(0, min(slot, maxSlot))
    }

    private func shouldUpdateOrderForRowChange(
        from originRow: Int,
        to targetRow: Int,
        targetRowCenterY: CGFloat,
        point: CGPoint,
        previousPoint: CGPoint
    ) -> Bool {
        guard targetRow != originRow else { return true }
        guard let mouseDownPoint,
              abs(point.x - mouseDownPoint.x) >= rowChangeHorizontalThreshold
        else {
            return false
        }

        if abs(point.y - targetRowCenterY) <= rowCenterTolerance {
            return true
        }

        if targetRow < originRow {
            return previousPoint.y >= targetRowCenterY && point.y <= targetRowCenterY
                || point.y < targetRowCenterY
        }

        return previousPoint.y <= targetRowCenterY && point.y >= targetRowCenterY
            || point.y > targetRowCenterY
    }

    private func updatePageOrderOverride(item: LaunchItem, pageItems: [LaunchItem], targetSlot: Int) {
        let pageSize = max(columns * rows, 1)
        var order = pageItems.map(\.id).filter { $0 != item.id }
        let bounded = max(0, min(targetSlot, min(order.count, pageSize - 1)))
        order.insert(item.id, at: bounded)
        if order.count > pageSize {
            order.removeLast()
        }

        pageOrderOverride = order
    }

    private func dropTargetHit(
        at point: CGPoint,
        pageIndex: Int,
        pageItems: [LaunchItem],
        excluding draggingID: LaunchItem.ID,
        width: CGFloat,
        height: CGFloat
    ) -> DropTargetHit? {
        let displayItems = displayOrder(for: pageIndex, items: pageItems)
        let candidates = displayItems.enumerated().compactMap { itemIndex, item -> DropTargetHit? in
            guard item.id != draggingID else { return nil }

            let center = CGPoint(x: tileX(index: itemIndex), y: tileY(index: itemIndex))
            let rect = CGRect(
                x: center.x - width / 2,
                y: center.y - height / 2,
                width: width,
                height: height
            )
            guard rect.contains(point) else { return nil }

            return DropTargetHit(
                id: item.id,
                rect: rect,
                distance: hypot(point.x - center.x, point.y - center.y)
            )
        }

        return candidates.min { $0.distance < $1.distance }
    }

    private func dropTargetHit(
        atSlot slot: Int,
        pageIndex: Int,
        pageItems: [LaunchItem],
        excluding draggingID: LaunchItem.ID
    ) -> DropTargetHit? {
        let displayItems = displayOrder(for: pageIndex, items: pageItems)
        guard slot >= 0, slot < displayItems.count else { return nil }

        let candidate = displayItems[slot]
        guard candidate.id != draggingID else { return nil }

        let center = CGPoint(x: tileX(index: slot), y: tileY(index: slot))
        let rect = CGRect(
            x: center.x - dropTargetIconSize / 2,
            y: center.y - dropTargetIconSize / 2,
            width: dropTargetIconSize,
            height: dropTargetIconSize
        )
        return DropTargetHit(
            id: candidate.id,
            rect: rect,
            distance: hypot(center.x - rect.midX, center.y - rect.midY)
        )
    }

    private func updateDropTargetHighlight(_ target: DropTargetHit?) {
        guard let target else {
            removeDropTargetOverlay()
            return
        }

        if highlightedDropTargetID == target.id {
            if let targetRecord = tileRecords.first(where: { $0.pageIndex == currentPage && $0.item.id == target.id }) {
                switch targetRecord.visual {
                case .layer:
                    setVisual(targetRecord.visual, hidden: true)
                    if let dropTargetOverlayView {
                        animateDropTargetOverlay(dropTargetOverlayView, to: targetFrame(for: target.id).offsetBy(dx: CGFloat(currentPage) * pageWidth, dy: 0))
                    }
                case .view(let targetView):
                    if let targetView = targetView as? AppTileHostingView {
                        targetView.update(isDropTarget: true)
                    }
                }
            }
            return
        }

        removeDropTargetOverlay()
        guard let targetRecord = tileRecords.first(where: { $0.pageIndex == currentPage && $0.item.id == target.id }),
              let targetIndex = displayOrder(for: currentPage, items: pages[currentPage]).firstIndex(where: { $0.id == target.id })
        else { return }

        let targetItem = targetRecord.item
        let targetFrame = tileFrameForItem(index: targetIndex)

        switch targetRecord.visual {
        case .layer:
            setVisual(targetRecord.visual, hidden: true)
            let hostingView = makeDropTargetOverlayView(
                item: targetItem,
                frame: targetFrame.offsetBy(dx: CGFloat(currentPage) * pageWidth, dy: 0)
            )
            glassOverlayContainerView.addSubview(hostingView)
            dropTargetOverlayView = hostingView
            animateDropTargetOverlayIn(hostingView)

        case .view(let targetView):
            if let targetView = targetView as? AppTileHostingView {
                targetView.update(isDropTarget: true)
            }
        }

        highlightedDropTargetID = target.id
    }

    private func removeDropTargetOverlay() {
        if let highlightedDropTargetID,
           let record = tileRecords.first(where: { $0.pageIndex == currentPage && $0.item.id == highlightedDropTargetID }) {
            switch record.visual {
            case .layer:
                setVisual(record.visual, hidden: false)
            case .view(let view):
                if let view = view as? AppTileHostingView {
                    view.update(isDropTarget: false)
                } else {
                    setVisual(record.visual, hidden: false)
                }
            }
        }
        if let dropTargetOverlayView {
            animateDropTargetOverlayOut(dropTargetOverlayView)
        }
        dropTargetOverlayView = nil
        highlightedDropTargetID = nil
    }

    private func makeDropTargetOverlayView(item: LaunchItem, frame: CGRect) -> NSView {
        if item.kind == .application {
            let hostingView = AppDropTargetHostingView(
                item: item,
                size: frame.size,
                metrics: tileMetrics
            )
            hostingView.frame = frame
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            return hostingView
        }

        let hostingView = DropTargetGlassHostingView(item: item, size: frame.size, metrics: tileMetrics, scale: 0.68)
        hostingView.frame = frame
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.alphaValue = 0
        return hostingView
    }

    private func targetFrame(for targetID: LaunchItem.ID) -> CGRect {
        guard let targetPage = tileDragTargetPage,
              targetPage < pages.count,
              let index = displayOrder(for: targetPage, items: pages[targetPage]).firstIndex(where: { $0.id == targetID })
        else {
            return .zero
        }
        return tileFrameForItem(index: index)
    }

    private func animateDropTargetOverlay(_ view: NSView, to frame: CGRect) {
        guard frame != .zero else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().frame = frame
        }
    }

    private func animateDropTargetOverlayIn(_ view: NSView) {
        view.layer?.removeAllAnimations()
        if let hostingView = view as? AppDropTargetHostingView {
            DispatchQueue.main.async { [weak hostingView] in
                hostingView?.updateProgress(1)
            }
            return
        } else if let hostingView = view as? DropTargetGlassHostingView {
            hostingView.updateScale(1)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 1
        }
    }

    private func animateDropTargetOverlayOut(_ view: NSView) {
        if let hostingView = view as? AppDropTargetHostingView {
            hostingView.updateProgress(0)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                view.removeFromSuperview()
            }
        }
    }

    private func dropTargetEntryDirection(
        from previousPoint: CGPoint,
        to currentPoint: CGPoint,
        in rect: CGRect
    ) -> DropTargetEntryDirection {
        if previousPoint.x <= rect.minX && currentPoint.x > rect.minX {
            return .fromLeft
        }
        if previousPoint.x >= rect.maxX && currentPoint.x < rect.maxX {
            return .fromRight
        }
        return .nonHorizontal
    }

    private func shouldResumeSortingAfterLeavingDropTarget(at point: CGPoint, targetRect: CGRect) -> Bool {
        guard let dragEnteredDropTargetDirection else { return false }

        switch dragEnteredDropTargetDirection {
        case .fromLeft:
            return point.x >= targetRect.maxX
        case .fromRight:
            return point.x <= targetRect.minX
        case .nonHorizontal:
            return point.x <= targetRect.minX || point.x >= targetRect.maxX
        }
    }

    private func updateDragTargetPageIfNeeded(location: CGPoint) {
        guard !pages.isEmpty else { return }

        let edgeSide: Int
        if location.x > pageWidth - dragPageTurnEdgeWidth {
            edgeSide = 1
        } else if location.x < dragPageTurnEdgeWidth {
            edgeSide = -1
        } else {
            edgeSide = 0
        }

        if edgeSide == 0 {
            dragEdgeSide = 0
            dragEdgeEnteredAt = nil
            dragEdgeHasTurnedInCurrentRun = false
            return
        }

        let now = Date()
        if dragEdgeSide != edgeSide {
            dragEdgeSide = edgeSide
            dragEdgeEnteredAt = now
            dragEdgeHasTurnedInCurrentRun = false
            return
        }

        guard let enteredAt = dragEdgeEnteredAt else {
            dragEdgeEnteredAt = now
            return
        }
        let requiredDwell = dragEdgeHasTurnedInCurrentRun ? dragPageTurnRepeatDwell : dragPageTurnDwell
        guard now.timeIntervalSince(enteredAt) >= requiredDwell,
              now.timeIntervalSince(lastDragPageTurnDate) >= dragPageTurnCooldown
        else { return }

        let proposedPage = currentPage + edgeSide
        let targetPage: Int
        if proposedPage < 0 || proposedPage >= pages.count {
            guard let createdPage = createBoundaryDragPage(edgeSide: edgeSide) else { return }
            targetPage = createdPage
        } else {
            targetPage = proposedPage
        }
        lastDragPageTurnDate = now
        tileDragTargetPage = targetPage
        dragEdgeEnteredAt = now
        dragEdgeHasTurnedInCurrentRun = true
        currentPage = targetPage
        onPageChanged?(targetPage)
        positionContainer(animated: true)
    }

    private func createBoundaryDragPage(edgeSide: Int) -> Int? {
        let insertionPosition = edgeSide < 0 ? 0 : pages.count
        if edgeSide < 0 {
            guard pages.first?.isEmpty == false else { return nil }
        } else {
            guard pages.last?.isEmpty == false else { return nil }
        }
        guard let createdPage = onCreateBoundaryPage?(edgeSide) else { return nil }

        if edgeSide < 0 {
            pages.insert([], at: 0)
            tileDragOriginPage = tileDragOriginPage.map { $0 + 1 }
            currentPage += 1
        } else {
            pages.append([])
        }

        rebuildLayers()
        positionContainer(animated: false)
        return createdPage == insertionPosition ? createdPage : insertionPosition
    }

    private func item(at point: CGPoint) -> LaunchItem? {
        return tileRecords.first { record in
            record.pageIndex == currentPage && tileContentContains(point, in: record)
        }?.item
    }

    private func tileContentContains(_ point: CGPoint, in record: TileRecord) -> Bool {
        guard record.frame.contains(point) else { return false }

        let metrics = record.metrics
        let iconSize = metrics.iconSize
        let labelSpacing = metrics.labelSpacing
        let labelFont = NSFont.systemFont(ofSize: metrics.labelFontSize, weight: .regular)
        let labelHeight = ceil(labelFont.ascender - labelFont.descender + labelFont.leading)
        let labelWidth = min(
            ceil((record.item.effectiveDisplayName as NSString).size(withAttributes: [.font: labelFont]).width),
            record.frame.width
        )
        let contentHeight = iconSize + labelSpacing + labelHeight
        let localPoint = CGPoint(
            x: point.x - record.frame.minX,
            y: point.y - record.frame.minY
        )
        let iconRect = CGRect(
            x: (record.frame.width - iconSize) / 2,
            y: (record.frame.height - contentHeight) / 2,
            width: iconSize,
            height: iconSize
        )
        let labelRect = CGRect(
            x: (record.frame.width - labelWidth) / 2,
            y: iconRect.maxY + labelSpacing,
            width: labelWidth,
            height: labelHeight
        )

        return iconRect.contains(localPoint) || labelRect.contains(localPoint)
    }

    private func tileFrameForItem(index: Int, metrics: AppTileMetrics? = nil) -> CGRect {
        let metrics = metrics ?? tileMetrics
        let tileSize = CGSize(width: metrics.tileWidth, height: metrics.tileHeight)
        let center = CGPoint(
            x: tileX(index: index),
            y: tileY(index: index)
        )
        return CGRect(
            x: center.x - tileSize.width / 2,
            y: center.y - tileSize.height / 2,
            width: tileSize.width,
            height: tileSize.height
        )
    }

    private func layerFrameForTileFrame(_ tileFrame: CGRect) -> CGRect {
        CGRect(
            x: tileFrame.minX,
            y: pageHeight - tileFrame.maxY,
            width: tileFrame.width,
            height: tileFrame.height
        )
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private var tileMetrics: AppTileMetrics {
        let columnWidth = max(pageWidth - horizontalMargin * 2, 1) / CGFloat(max(columns, 1))
        let rowStride: CGFloat
        if rows > 1 {
            rowStride = max((gridBottomY - gridTopY) / CGFloat(rows - 1), 1)
        } else {
            rowStride = max(gridBottomY - gridTopY, 1)
        }

        let rawIconSize = min(columnWidth * 0.58, rowStride * 0.74)
        let iconSize = min(max(rawIconSize.rounded(.toNearestOrAwayFromZero), 82), 132)
        let labelSpacing: CGFloat = 5
        let labelFontSize: CGFloat = 13
        let labelFont = NSFont.systemFont(ofSize: labelFontSize, weight: .regular)
        let labelHeight = ceil(labelFont.ascender - labelFont.descender + labelFont.leading)
        let tileWidth = max(132, min(columnWidth * 0.92, iconSize + 72))
        let tileHeight = iconSize + labelSpacing + labelHeight + 5

        return AppTileMetrics(
            tileWidth: tileWidth.rounded(.toNearestOrAwayFromZero),
            tileHeight: tileHeight.rounded(.toNearestOrAwayFromZero),
            iconSize: iconSize,
            labelSpacing: labelSpacing,
            labelFontSize: labelFontSize
        )
    }

    private func slotFromGridPoint(_ point: CGPoint) -> Int {
        let cols = max(columns, 1)
        let rws = max(rows, 1)
        let slotWidth = max(pageWidth - horizontalMargin * 2, 1) / CGFloat(cols)
        let rawCol = Int(((point.x - horizontalMargin) / slotWidth).rounded(.down))
        let col = max(0, min(cols - 1, rawCol))
        let step = rws > 1 ? max((gridBottomY - gridTopY) / CGFloat(rws - 1), 1) : max(gridBottomY - gridTopY, 1)
        let rawRow = Int(((point.y - gridTopY) / step).rounded())
        let row = max(0, min(rws - 1, rawRow))
        return row * cols + col
    }

    private func tileX(index: Int) -> CGFloat {
        let slotWidth = max(pageWidth - horizontalMargin * 2, 1) / CGFloat(max(columns, 1))
        return horizontalMargin + slotWidth * (CGFloat(index % max(columns, 1)) + 0.5)
    }

    private func tileY(index: Int) -> CGFloat {
        let row = CGFloat(index / max(columns, 1))
        guard rows > 1 else { return (gridTopY + gridBottomY) / 2 }
        return gridTopY + ((gridBottomY - gridTopY) / CGFloat(rows - 1)) * row
    }

    private func positionContainer(animated: Bool) {
        ensurePageRendered(currentPage)
        scheduleNearbyPageRendering()
        setContainerOffset(-CGFloat(currentPage) * pageWidth, animated: animated)
    }

    private func setContainerOffset(_ offsetX: CGFloat, animated: Bool = false) {
        var targetFrame = containerView.frame
        targetFrame.origin.x = offsetX

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.34
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                containerView.animator().frame = targetFrame
            }
        } else {
            containerView.frame = targetFrame
        }
    }

    private var disabledActions: [String: CAAction] {
        [
            "position": NSNull() as CAAction,
            "bounds": NSNull() as CAAction,
            "contents": NSNull() as CAAction,
            "frame": NSNull() as CAAction,
            "opacity": NSNull() as CAAction,
            "hidden": NSNull() as CAAction,
            "onOrderIn": NSNull() as CAAction,
            "onOrderOut": NSNull() as CAAction,
            "sublayers": NSNull() as CAAction,
            "transform": NSNull() as CAAction
        ]
    }

    private struct TileRecord {
        let item: LaunchItem
        let pageIndex: Int
        var frame: CGRect
        var metrics: AppTileMetrics
        let visual: TileVisual
    }

    private struct PendingDropCompactionSourceFrame {
        let frame: CGRect
        let pageIndex: Int
    }

    private struct PendingDropCompactionAnimation {
        let visual: TileVisual
        let frame: CGRect
        let pageIndex: Int
    }

    private enum DockEdge {
        case left
        case right
        case bottom

        init?(dockOrientation: String) {
            switch dockOrientation {
            case "left":
                self = .left
            case "right":
                self = .right
            case "bottom":
                self = .bottom
            default:
                return nil
            }
        }
    }

    private enum TileVisual {
        case layer(CALayer)
        case view(NSView)
    }
}

@MainActor
private enum AppKitTileImageRenderer {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 384
        cache.totalCostLimit = 192 * 1_024 * 1_024
        return cache
    }()

    static func image(
        item: LaunchItem,
        previewItems: [LaunchItem],
        size: CGSize,
        scale: CGFloat,
        metrics: AppTileMetrics,
        isPressed: Bool = false,
        isDragging: Bool = false
    ) -> NSImage {
        let renderScale = normalizedRenderScale(for: scale)
        let previewKey = previewItems.map(\.id.uuidString).joined(separator: ",")
        let key = [
            item.id.uuidString,
            item.effectiveDisplayName,
            item.sourcePath,
            item.kind.rawValue,
            previewKey,
            "\(size.width)",
            "\(size.height)",
            "\(metrics.iconSize)",
            "\(metrics.labelFontSize)",
            "\(isPressed)",
            "\(isDragging)",
            "\(renderScale)"
        ].joined(separator: "|") as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let tile = AppTile(
            item: item,
            previewItems: previewItems,
            isPressed: isPressed,
            isDragging: isDragging,
            isDropTarget: false,
            metrics: metrics,
            renderScale: renderScale,
            openAction: { },
            revealAction: { },
            renameAction: nil,
            ungroupAction: nil
        )
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: tile)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = renderScale

        let image = renderer.nsImage ?? NSImage(size: size)
        let pixelWidth = max(1, Int((size.width * renderScale).rounded(.up)))
        let pixelHeight = max(1, Int((size.height * renderScale).rounded(.up)))
        cache.setObject(image, forKey: key, cost: pixelWidth * pixelHeight * 4)
        return image
    }

    static func clearCache() {
        cache.removeAllObjects()
    }

    private static func normalizedRenderScale(for scale: CGFloat) -> CGFloat {
        max(2, (scale * 100).rounded() / 100)
    }
}

@MainActor
func KidoXReleaseTransientImageCaches() {
    AppKitTileImageRenderer.clearCache()
}

@MainActor
private final class FlippedLayerBackedView: NSView {
    override var isFlipped: Bool { true }
}

private struct PageDragBridge: NSViewRepresentable {
    let isEnabled: Bool
    let shouldBegin: (CGPoint) -> Bool
    let onChanged: (CGSize) -> Void
    let onEnded: (CGSize) -> Void
    let onCancelled: () -> Void

    func makeNSView(context: Context) -> PageDragMonitorView {
        let view = PageDragMonitorView()
        view.isEnabled = isEnabled
        view.shouldBegin = shouldBegin
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.onCancelled = onCancelled
        return view
    }

    func updateNSView(_ nsView: PageDragMonitorView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.shouldBegin = shouldBegin
        nsView.onChanged = onChanged
        nsView.onEnded = onEnded
        nsView.onCancelled = onCancelled
    }
}

@MainActor
private final class PageDragMonitorView: NSView {
    var isEnabled = true
    var shouldBegin: ((CGPoint) -> Bool)?
    var onChanged: ((CGSize) -> Void)?
    var onEnded: ((CGSize) -> Void)?
    var onCancelled: (() -> Void)?

    private var monitor: Any?
    private var startPoint: CGPoint?
    private var isDraggingPage = false
    private let activationDistance: CGFloat = 6

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            resetTracking(cancel: true)
        } else {
            installMonitorIfNeeded()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleMouseEvent(event) ? nil : event
        }
    }

    private func handleMouseEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            guard isEnabled else {
                resetTracking(cancel: true)
                return false
            }

            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point),
                  shouldBegin?(point) ?? true
            else {
                resetTracking(cancel: true)
                return false
            }

            startPoint = point
            isDraggingPage = false
            return false

        case .leftMouseDragged:
            guard isEnabled,
                  let startPoint
            else { return false }

            let point = convert(event.locationInWindow, from: nil)
            let translation = CGSize(
                width: point.x - startPoint.x,
                height: point.y - startPoint.y
            )

            if !isDraggingPage {
                let distance = hypot(translation.width, translation.height)
                guard distance >= activationDistance else { return false }
                if abs(translation.height) > abs(translation.width) {
                    resetTracking(cancel: true)
                    return false
                }
                isDraggingPage = true
            }

            onChanged?(translation)
            return true

        case .leftMouseUp:
            defer { resetTracking(cancel: false) }
            guard isDraggingPage,
                  let startPoint
            else { return false }

            let point = convert(event.locationInWindow, from: nil)
            onEnded?(
                CGSize(
                    width: point.x - startPoint.x,
                    height: point.y - startPoint.y
                )
            )
            return true

        default:
            return false
        }
    }

    private func resetTracking(cancel: Bool) {
        if cancel, isDraggingPage {
            onCancelled?()
        }
        startPoint = nil
        isDraggingPage = false
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
