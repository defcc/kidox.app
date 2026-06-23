import AppKit
import KidoXIPC
import LaunchAtLogin

@MainActor
final class KidoXAppDelegate: NSObject, NSApplicationDelegate {
    private let updaterController = KidoXUpdaterController.shared
    private lazy var settingsWindowController = SettingsWindowController()
    private lazy var panelController = KidoXPanelController { [weak self] pane in
        self?.openSettings(pane: pane)
    }
    private lazy var activationController = KidoXActivationController { [weak self] in
        self?.panelController.show()
    }
    private var statusItemController: StatusItemController?
    private var licenseValidationTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ClyAppLicenseService.shared.restoreLocalLicenseState()
        startLicenseValidation()
        installMainMenu()
        NSApp.setActivationPolicy(.accessory)
        KidoXDockIconPreference.applyCurrentIcon()
        updaterController.start()
        statusItemController = StatusItemController(
            onOpen: { [weak self] in
                self?.panelController.show()
            },
            onSettings: { [weak self] in
                self?.openSettings()
            },
            onLicenseSettings: { [weak self] in
                self?.openSettings(pane: .license)
            }
        )
        activationController.start()
        if LaunchAtLogin.wasLaunchedAtLogin {
            panelController.prepareForBackgroundLaunch()
        } else {
            panelController.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        licenseValidationTimer?.invalidate()
        activationController.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController.show()
        return true
    }

    func refreshApplications() {
        panelController.refreshApplications()
    }

    func openSettings(pane: SettingsPane? = nil) {
        settingsWindowController.show(pane: pane)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)

        let appMenu = NSMenu(title: "KidoX")
        appItem.submenu = appMenu
        addMenuItem(
            to: appMenu,
            title: KidoXL10n.ui("Settings..."),
            action: #selector(openSettingsMenuItem(_:)),
            keyEquivalent: ",",
            target: self
        )
        appMenu.addItem(.separator())
        addMenuItem(
            to: appMenu,
            title: KidoXL10n.ui("Quit KidoX"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q",
            target: NSApp
        )

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)

        let editMenu = NSMenu(title: KidoXL10n.ui("Edit"))
        editItem.submenu = editMenu
        addMenuItem(to: editMenu, title: KidoXL10n.ui("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        addMenuItem(
            to: editMenu,
            title: KidoXL10n.ui("Redo"),
            action: Selector(("redo:")),
            keyEquivalent: "Z",
            modifierMask: [.command, .shift]
        )
        editMenu.addItem(.separator())
        addMenuItem(to: editMenu, title: KidoXL10n.ui("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        addMenuItem(to: editMenu, title: KidoXL10n.ui("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        addMenuItem(to: editMenu, title: KidoXL10n.ui("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        addMenuItem(to: editMenu, title: KidoXL10n.ui("Delete"), action: #selector(NSText.delete(_:)))
        editMenu.addItem(.separator())
        addMenuItem(to: editMenu, title: KidoXL10n.ui("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    private func addMenuItem(
        to menu: NSMenu,
        title: String,
        action: Selector,
        keyEquivalent: String = "",
        modifierMask: NSEvent.ModifierFlags = [.command],
        target: AnyObject? = nil
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = keyEquivalent.isEmpty ? [] : modifierMask
        item.target = target
        menu.addItem(item)
    }

    @objc private func openSettingsMenuItem(_ sender: Any?) {
        openSettings()
    }

    @objc private func refreshApplicationsMenuItem(_ sender: Any?) {
        refreshApplications()
    }

    @objc private func checkForUpdatesMenuItem(_ sender: Any?) {
        updaterController.checkForUpdates()
    }

    private func startLicenseValidation() {
        licenseValidationTimer?.invalidate()
        runLicenseValidation(force: false)
    }

    private func runLicenseValidation(force: Bool) {
        Task {
            await ClyAppLicenseService.shared.validateStoredLicenseIfNeeded(force: force)
            await MainActor.run {
                scheduleNextLicenseValidation()
            }
        }
    }

    private func scheduleNextLicenseValidation() {
        licenseValidationTimer?.invalidate()
        let delay = max(1, ClyAppLicenseService.shared.nextValidationDelay())
        licenseValidationTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.runLicenseValidation(force: true)
            }
        }
    }
}

let delegate = KidoXAppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
