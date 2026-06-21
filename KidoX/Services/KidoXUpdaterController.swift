import AppKit
import Sparkle

@MainActor
final class KidoXUpdaterController: NSObject, SPUUpdaterDelegate {
    static let shared = KidoXUpdaterController()
    static let updateAvailabilityDidChangeNotification = Notification.Name("KidoXUpdaterAvailabilityDidChange")
    static let hideLaunchPanelForUpdateCheckNotification = Notification.Name("KidoXHideLaunchPanelForUpdateCheck")

    private lazy var standardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    private(set) var availableVersion: String?
    private(set) var availableBuild: String?

    var updaterController: SPUStandardUpdaterController {
        standardUpdaterController
    }

    var updater: SPUUpdater {
        updaterController.updater
    }

    private override init() {
        super.init()
    }

    func start() {
        _ = updaterController
    }

    func checkForUpdates(orderOutSettingsWindow: Bool = false) {
        if orderOutSettingsWindow {
            prepareKidoXWindowsForUpdateCheck()
        }
        updaterController.checkForUpdates(nil)
    }

    func showAvailableUpdate(orderOutSettingsWindow: Bool = false) {
        clearAvailableUpdate()
        if orderOutSettingsWindow {
            prepareKidoXWindowsForUpdateCheck()
        }
        updaterController.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        availableBuild = item.versionString
        notifyAvailabilityChanged()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        clearAvailableUpdate()
    }

    private func clearAvailableUpdate() {
        guard availableVersion != nil || availableBuild != nil else { return }
        availableVersion = nil
        availableBuild = nil
        notifyAvailabilityChanged()
    }

    private func notifyAvailabilityChanged() {
        NotificationCenter.default.post(name: Self.updateAvailabilityDidChangeNotification, object: self)
    }

    private func prepareKidoXWindowsForUpdateCheck() {
        NotificationCenter.default.post(name: Self.hideLaunchPanelForUpdateCheckNotification, object: self)
        orderOutSettingsWindows()
    }

    private func orderOutSettingsWindows() {
        for window in NSApp.windows where window.title == "KidoX Settings" {
            window.orderOut(nil)
        }
    }
}
