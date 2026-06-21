import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let state = SettingsState()

    init() {
        let splitVC = NSSplitViewController()

        // ── Sidebar ──────────────────────────────────────────────────
        // Using NSSplitViewItem(sidebarWithViewController:) is what makes
        // the traffic lights appear *inside* the sidebar and extends the
        // sidebar background under the title-bar area automatically.
        let sidebarVC = NSHostingController(rootView: SidebarView(state: state))
        sidebarVC.safeAreaRegions = []
        sidebarVC.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 260
        sidebarItem.allowsFullHeightLayout = true
        splitVC.addSplitViewItem(sidebarItem)

        // ── Detail ───────────────────────────────────────────────────
        let detailVC = NSHostingController(rootView: DetailView(state: state))
        detailVC.safeAreaRegions = []
        detailVC.sizingOptions = []
        let detailItem = NSSplitViewItem(viewController: detailVC)
        detailItem.minimumThickness = 400
        detailItem.allowsFullHeightLayout = true
        splitVC.addSplitViewItem(detailItem)

        // ── Window ───────────────────────────────────────────────────
        let window = NSWindow(contentViewController: splitVC)
        window.title = "KidoX Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        // Use an empty toolbar and unified style to position traffic lights correctly
        let toolbar = NSToolbar(identifier: "KidoX.Settings.Toolbar")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 680, height: 500))
        window.contentMinSize = NSSize(width: 600, height: 400)
        window.center()

        super.init(window: window)
        shouldCascadeWindows = false
        windowFrameAutosaveName = "KidoX.Settings"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(pane: SettingsPane? = nil) {
        guard let window else { return }
        if let pane {
            state.selection = pane
        }
        if !window.isVisible { window.center() }
        window.level = .normal
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
