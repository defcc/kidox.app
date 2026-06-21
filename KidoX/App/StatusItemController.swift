import AppKit
@MainActor
final class StatusItemController: NSObject {
    static let showMenuBarIconStorageKey = "KidoX.showMenuBarIcon"

    private var statusItem: NSStatusItem?
    private let onOpen: () -> Void
    private let onSettings: () -> Void
    private let onLicenseSettings: () -> Void
    private var defaultsObserver: NSObjectProtocol?

    init(
        onOpen: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onLicenseSettings: @escaping () -> Void
    ) {
        self.onOpen = onOpen
        self.onSettings = onSettings
        self.onLicenseSettings = onLicenseSettings
        super.init()
        applyMenuBarIconPreference()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyMenuBarIconPreference()
            }
        }
    }

    func invalidate() {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
        hideStatusItemIfNeeded()
    }

    private func applyMenuBarIconPreference() {
        if shouldShowMenuBarIcon {
            showStatusItemIfNeeded()
        } else {
            hideStatusItemIfNeeded()
        }
    }

    private var shouldShowMenuBarIcon: Bool {
        UserDefaults.standard.object(forKey: Self.showMenuBarIconStorageKey) as? Bool ?? true
    }

    private func showStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = statusItem
        configureStatusItem(statusItem)
    }

    private func hideStatusItemIfNeeded() {
        guard let statusItem else { return }
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func configureStatusItem(_ statusItem: NSStatusItem) {
        guard let button = statusItem.button else { return }

        button.image = makeStatusItemImage()
        button.imagePosition = .imageOnly
        button.toolTip = "KidoX"
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func makeStatusItemImage() -> NSImage? {
        let image = Bundle.main.url(
            forResource: "MenuBarIcon",
            withExtension: "pdf",
            subdirectory: "Icons"
        ).flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "KidoX")

        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        image?.accessibilityDescription = "KidoX"
        return image
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard NSApp.currentEvent?.type == .rightMouseUp else {
            onOpen()
            return
        }

        let menu = makeMenu()
        guard let statusItem else { return }
        statusItem.menu = menu
        sender.performClick(nil)
        statusItem.menu = nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let settingsItem = makeMenuItem(title: "Settings", symbolName: "gearshape", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let versionItem = makeMenuItem(title: versionInfoTitle, symbolName: "number.circle", action: nil)
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let updatesItem = makeMenuItem(title: "Check for Updates...", symbolName: "arrow.down.circle", action: #selector(checkForUpdates))
        updatesItem.target = self
        menu.addItem(updatesItem)

        let helpItem = makeMenuItem(title: "Help", symbolName: "questionmark.circle", action: #selector(openHelp))
        helpItem.target = self
        menu.addItem(helpItem)
        menu.addItem(.separator())



        let purchaseItem = makeMenuItem(
            title: isPro ? "Purchase More License" : "Purchase Pro",
            symbolName: "cart",
            action: #selector(purchasePro)
        )
        purchaseItem.target = self
        menu.addItem(purchaseItem)

        if isPro {
            let licenseActivatedItem = makeMenuItem(title: "License Activated", symbolName: "checkmark.seal", action: nil)
            licenseActivatedItem.isEnabled = false
            menu.addItem(licenseActivatedItem)
        } else {
            let activateLicenseItem = makeMenuItem(title: "Activate License", symbolName: "key", action: #selector(activateLicense))
            activateLicenseItem.target = self
            menu.addItem(activateLicenseItem)
        }

        menu.addItem(.separator())

        let quitItem = makeMenuItem(title: "Quit", symbolName: "power", action: #selector(quitKidoX), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func makeMenuItem(
        title: String,
        symbolName: String,
        action: Selector?,
        keyEquivalent: String = "",
        keyEquivalentModifierMask: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = keyEquivalentModifierMask
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        item.image?.isTemplate = true
        return item
    }

    private var versionInfoTitle: String {
        let infoDictionary = Bundle.main.infoDictionary
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String

        if let build, !build.isEmpty {
            return "KidoX Version \(version) (\(build))"
        }
        return "KidoX Version \(version)"
    }

    private var isPro: Bool {
        UserDefaults.standard.string(forKey: "ClyAppLicense.status") == "active"
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func openSettings() {
        onSettings()
    }

    @objc private func purchasePro() {
        NSWorkspace.shared.open(KidoXAppConfiguration.purchaseURL)
    }

    @objc private func activateLicense() {
        onLicenseSettings()
    }

    @objc private func openHelp() {
        NSWorkspace.shared.open(KidoXAppConfiguration.helpURL)
    }

    @objc private func checkForUpdates() {
        KidoXUpdaterController.shared.checkForUpdates()
    }

    @objc private func quitKidoX() {
        NSApp.terminate(nil)
    }
}
