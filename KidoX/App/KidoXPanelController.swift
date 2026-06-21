import AppKit
import Carbon
import QuartzCore
import SwiftUI

@MainActor
final class KidoXPanelController {
    static let showMenuBarStorageKey = "KidoX.showMenuBarInLaunchPanel"
    static let hideLaunchPanelForModalPresentationNotification = Notification.Name("KidoXHideLaunchPanelForModalPresentation")

    private let store = KidoXStore()
    private let onOpenSettings: (SettingsPane?) -> Void
    private var panel: KidoXPanel?
    private weak var foregroundHostingView: NSView?
    private weak var fieldEditorWarmupTextField: NSTextField?
    private var previousSystemUIMode: SystemUIMode?
    private var previousSystemUIOptions: SystemUIOptions?
    private var previousActivationPolicy: NSApplication.ActivationPolicy?
    private var mouseDownMonitor: Any?
    private var hideWorkItem: DispatchWorkItem?
    private var focusWorkItem: DispatchWorkItem?
    nonisolated(unsafe) private var defaultsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var updateCheckObserver: NSObjectProtocol?
    nonisolated(unsafe) private var modalPresentationObserver: NSObjectProtocol?
    private static let scaleAnimationKey = "kidoXScaleAnimation"

    init(onOpenSettings: @escaping (SettingsPane?) -> Void = { _ in }) {
        self.onOpenSettings = onOpenSettings
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyPanelPresentationPreference()
            }
        }

        updateCheckObserver = NotificationCenter.default.addObserver(
            forName: KidoXUpdaterController.hideLaunchPanelForUpdateCheckNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hideImmediatelyForLaunch()
            }
        }

        modalPresentationObserver = NotificationCenter.default.addObserver(
            forName: Self.hideLaunchPanelForModalPresentationNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.hideImmediatelyForSettings()
            }
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        if let updateCheckObserver {
            NotificationCenter.default.removeObserver(updateCheckObserver)
        }
        if let modalPresentationObserver {
            NotificationCenter.default.removeObserver(modalPresentationObserver)
        }
        if let mode = previousSystemUIMode,
           let options = previousSystemUIOptions {
            MainActor.assumeIsolated {
                SetSystemUIMode(mode, options)
            }
        }
        if let activationPolicy = previousActivationPolicy {
            MainActor.assumeIsolated {
                NSApp.setActivationPolicy(activationPolicy)
            }
        }
    }

    func show() {
        if let panel, panel.isVisible {
            hide()
            return
        }

        store.prepareCachedApplicationsForPresentation()
        store.markPreparingForInitialPresentation()
        present()

        Task { @MainActor [weak self] in
            guard let self else { return }
            await store.prepareForPresentation()
        }
    }

    func prepareForBackgroundLaunch() {
        Task { @MainActor [weak self] in
            await self?.store.loadApplications()
        }
    }

    private func present() {
        let targetScreen = screenForPresentation()
        let panel = panel ?? makePanel(for: targetScreen)
        self.panel = panel
        hideWorkItem?.cancel()

        resizePanel(panel, to: targetScreen)
        configurePanelLevel(panel)
        prepareForPresentationAnimation(panel)
        prepareFirstVisibleFrame(panel)
        prewarmSearchFieldEditor(panel)
//        NSApp.activate(ignoringOtherApps: true)
        applySystemMenuBarVisibilityPreference()
        panel.makeKeyAndOrderFront(nil)
        scheduleSearchFocusRequest(for: panel)
        installOutsideClickMonitor()
        animatePresentation(panel)
    }

    private func applyPanelPresentationPreference() {
        guard let panel else { return }
        configurePanelLevel(panel)
        if panel.isVisible {
            applySystemMenuBarVisibilityPreference()
        }
    }

    // 用鼠标当前位置定位屏幕：Dock 点击的瞬间，光标一定在那块屏幕上。
    // NSScreen.main 是 key window 所在屏幕（accessory app 时常不准）。
    private func screenForPresentation() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        focusWorkItem?.cancel()
        focusWorkItem = nil
        panel.makeFirstResponder(nil)
        removeOutsideClickMonitor()
        animateDismissal(panel)
    }

    /// 启动 app 时使用：同步关闭 panel 并让出 active app 状态，避免与目标 panel 形态 app 抢焦点。
    func hideImmediatelyForLaunch() {
        hideImmediately(shouldHideAppIfNoOtherWindowIsVisible: true)
    }

    /// 打开设置时使用：先同步关闭 launch panel，避免高层级 panel 盖住普通 settings window。
    func hideImmediatelyForSettings() {
        hideImmediately(shouldHideAppIfNoOtherWindowIsVisible: false)
    }

    private func hideImmediately(shouldHideAppIfNoOtherWindowIsVisible: Bool) {
        focusWorkItem?.cancel()
        focusWorkItem = nil
        hideWorkItem?.cancel()
        hideWorkItem = nil
        removeOutsideClickMonitor()
        restoreSystemMenuBarVisibility()

        if let panel {
            panel.makeFirstResponder(nil)
            panel.orderOut(nil)
            panel.alphaValue = 1
        }

        if let layer = foregroundHostingView?.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: Self.scaleAnimationKey)
            layer.transform = CATransform3DIdentity
            layer.shouldRasterize = false
            CATransaction.commit()
        }

        if shouldHideAppIfNoOtherWindowIsVisible {
            hideAppIfNoOtherWindowIsVisible()
        }

        releasePanelResources(matching: panel)
    }

    func refreshApplications() {
        Task {
            await store.refreshApplications()
        }
    }

    private func makePanel(for screen: NSScreen?) -> KidoXPanel {
        let panelFrame = targetPanelFrame(for: screen)
        let panel = KidoXPanel(
            contentRect: panelFrame,
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )

        // 让 panel 浮在普通窗口之上，但低于 Dock，让 Dock 仍然可见
        panel.level = .modalPanel
        panel.backgroundColor = NSColor.clear
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false

        let containerFrame = NSRect(origin: .zero, size: panelFrame.size)
        let containerView = NSView(frame: containerFrame)
        containerView.wantsLayer = true
        containerView.autoresizingMask = [.width, .height]

        let backgroundHosting = NSHostingView(rootView: KidoXBackgroundLayer())
        backgroundHosting.frame = containerFrame
        backgroundHosting.autoresizingMask = [.width, .height]
        backgroundHosting.wantsLayer = true

        let foregroundHosting = NSHostingView(rootView: KidoXForegroundLayer(
            store: store,
            onDismiss: { [weak self] in
                self?.hide()
            },
            onLaunchApp: { [weak self] in
                self?.hideImmediatelyForLaunch()
            },
            onOpenSettings: { [weak self] in
                self?.hideImmediatelyForSettings()
                self?.onOpenSettings(nil)
            },
            onOpenLicenseSettings: { [weak self] in
                self?.hideImmediatelyForSettings()
                self?.onOpenSettings(.license)
            }
        ))
        foregroundHosting.frame = containerFrame
        foregroundHosting.autoresizingMask = [.width, .height]
        foregroundHosting.wantsLayer = true

        let fieldEditorWarmupTextField = NSTextField(frame: NSRect(x: -10_000, y: -10_000, width: 1, height: 1))
        fieldEditorWarmupTextField.cell = SearchFieldNSTextFieldCell(textCell: "")
        fieldEditorWarmupTextField.isEditable = true
        fieldEditorWarmupTextField.isSelectable = true
        fieldEditorWarmupTextField.isBezeled = false
        fieldEditorWarmupTextField.isBordered = false
        fieldEditorWarmupTextField.drawsBackground = false
        fieldEditorWarmupTextField.focusRingType = .none
        fieldEditorWarmupTextField.alphaValue = 0

        containerView.addSubview(backgroundHosting)
        containerView.addSubview(foregroundHosting)
        containerView.addSubview(fieldEditorWarmupTextField)

        panel.contentView = containerView
        self.foregroundHostingView = foregroundHosting
        self.fieldEditorWarmupTextField = fieldEditorWarmupTextField

        return panel
    }

    private var shouldShowMenuBar: Bool {
        UserDefaults.standard.object(forKey: Self.showMenuBarStorageKey) as? Bool ?? false
    }

    private func configurePanelLevel(_ panel: NSPanel) {
        panel.level = shouldShowMenuBar
            ? .floating
            : NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
    }

    private func applySystemMenuBarVisibilityPreference() {
//        if shouldShowMenuBar {
//            restoreSystemMenuBarVisibility()
//        } else {
//            hideSystemMenuBar()
//        }
    }

    private func hideSystemMenuBar() {
        guard previousSystemUIMode == nil else { return }
        previousActivationPolicy = NSApp.activationPolicy()
        var mode = SystemUIMode(kUIModeNormal)
        var options = SystemUIOptions(0)
        GetSystemUIMode(&mode, &options)
        previousSystemUIMode = mode
        previousSystemUIOptions = options

        if previousActivationPolicy != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        SetSystemUIMode(
            SystemUIMode(kUIModeNormal),
            SystemUIOptions(kUIOptionAutoShowMenuBar)
        )
    }

    private func restoreSystemMenuBarVisibility() {
        guard previousSystemUIMode != nil || previousActivationPolicy != nil else { return }
        if let previousSystemUIMode,
           let previousSystemUIOptions {
            SetSystemUIMode(previousSystemUIMode, previousSystemUIOptions)
        } else {
            SetSystemUIMode(SystemUIMode(kUIModeNormal), SystemUIOptions(0))
        }
        if let previousActivationPolicy {
            NSApp.setActivationPolicy(previousActivationPolicy)
        }
        self.previousSystemUIMode = nil
        self.previousSystemUIOptions = nil
        self.previousActivationPolicy = nil
    }

    private func resizePanel(_ panel: NSPanel, to screen: NSScreen?) {
        guard let screen else { return }
        let panelFrame = targetPanelFrame(for: screen)

        panel.setFrameOrigin(panelFrame.origin)
        panel.setContentSize(panelFrame.size)
        panel.contentView?.frame = NSRect(origin: .zero, size: panelFrame.size)

        store.screenMetrics = ScreenMetrics(
            topInset: 0,
            panelFrame: panel.frame,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
    }

    private func targetPanelFrame(for screen: NSScreen?) -> NSRect {
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.origin.y,
            width: screenFrame.width,
            height: screenFrame.height + 20
        )
    }

    private func installOutsideClickMonitor() {
        guard mouseDownMonitor == nil else { return }
        // global monitor 只会收到其他进程的事件（dock、其他 app、桌面等），
        // 任何外部点击都关掉面板。
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.hide()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
            self.mouseDownMonitor = nil
        }
    }

    private static let presentationAlphaDuration: TimeInterval = 0.20
    private static let presentationScaleDelay: TimeInterval = 0
    private static let presentationScaleDuration: TimeInterval = 0.34
    private static let dismissalDuration: TimeInterval = 0.20
    private static let dismissalAlphaDuration: TimeInterval = 0.16
    private static let presentationInitialScale: CGFloat = 1.10
    private static let dismissalTargetScale: CGFloat = 1.035

    private static func presentationTimingFunction() -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.22, 0.00, 0.20, 1.00)
    }

    private static func dismissalTimingFunction() -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.36, 0.00, 1.00, 1.00)
    }

    private func scheduleSearchFocusRequest(for panel: NSPanel) {
        focusWorkItem?.cancel()

        let presentationDuration = Self.presentationScaleDelay + Self.presentationScaleDuration
        let workItem = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.requestSearchFocusIfVisible(panel)
        }
        focusWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + presentationDuration + 0.04, execute: workItem)
    }

    private func requestSearchFocusIfVisible(_ panel: NSPanel) {
        guard panel.isVisible else { return }
        store.searchFocusRequestID += 1
    }

    private func prewarmSearchFieldEditor(_ panel: NSPanel) {
        guard let textField = fieldEditorWarmupTextField,
              textField.window === panel
        else { return }

        let previousFirstResponder = panel.firstResponder
        textField.stringValue = ""
        guard panel.makeFirstResponder(textField) else { return }

        if let textView = textField.currentEditor() as? NSTextView {
            SearchFieldNSTextFieldCell.configureFieldEditor(textView)
            textView.string = ""
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }

        if let previousFirstResponder,
           previousFirstResponder !== textField,
           previousFirstResponder !== textField.currentEditor() {
            panel.makeFirstResponder(previousFirstResponder)
        } else {
            panel.makeFirstResponder(nil)
        }
    }

    private func prepareForPresentationAnimation(_ panel: NSPanel) {
        panel.alphaValue = 0
        guard let foreground = foregroundHostingView, let layer = foreground.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.scaleAnimationKey)
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    private func prepareFirstVisibleFrame(_ panel: NSPanel) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.contentView?.layoutSubtreeIfNeeded()
        foregroundHostingView?.layoutSubtreeIfNeeded()
        panel.contentView?.displayIfNeeded()
        CATransaction.commit()
    }

    private func animatePresentation(_ panel: NSPanel) {
        guard let foreground = foregroundHostingView, let layer = foreground.layer else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.presentationAlphaDuration
            context.timingFunction = Self.presentationTimingFunction()
            panel.animator().alphaValue = 1
        }

        let from3D = CATransform3DMakeAffineTransform(
            centeredScaleTransform(scale: Self.presentationInitialScale, in: foreground.bounds.size)
        )

        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = NSValue(caTransform3D: from3D)
        anim.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        anim.duration = Self.presentationScaleDuration
        anim.beginTime = CACurrentMediaTime() + Self.presentationScaleDelay
        anim.timingFunction = Self.presentationTimingFunction()
        anim.fillMode = .backwards
        anim.isRemovedOnCompletion = true

        layer.add(anim, forKey: Self.scaleAnimationKey)
    }

    private func animateDismissal(_ panel: NSPanel) {
        hideWorkItem?.cancel()

        guard let foreground = foregroundHostingView, let layer = foreground.layer else {
            panel.orderOut(nil)
            restoreSystemMenuBarVisibility()
            hideAppIfNoOtherWindowIsVisible()
            releasePanelResources(matching: panel)
            return
        }

        let currentTransform = layer.presentation()?.transform ?? layer.transform
        layer.removeAnimation(forKey: Self.scaleAnimationKey)

        let to3D = CATransform3DMakeAffineTransform(
            centeredScaleTransform(scale: Self.dismissalTargetScale, in: foreground.bounds.size)
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = to3D
        CATransaction.commit()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.dismissalAlphaDuration
            context.timingFunction = Self.dismissalTimingFunction()
            panel.animator().alphaValue = 0
        }

        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = NSValue(caTransform3D: currentTransform)
        anim.toValue = NSValue(caTransform3D: to3D)
        anim.duration = Self.dismissalDuration
        anim.timingFunction = Self.dismissalTimingFunction()
        anim.fillMode = .both
        anim.isRemovedOnCompletion = true
        layer.add(anim, forKey: Self.scaleAnimationKey)

        let workItem = DispatchWorkItem { [weak self, weak panel] in
            Task { @MainActor in
                guard let panel else { return }
                panel.orderOut(nil)
                self?.restoreSystemMenuBarVisibility()
                self?.hideAppIfNoOtherWindowIsVisible()
                panel.alphaValue = 1
                if let layer = self?.foregroundHostingView?.layer {
                    self?.resetForegroundAnimation(layer)
                }
                self?.releasePanelResources(matching: panel)
            }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dismissalDuration + 0.01, execute: workItem)
    }

    private func releasePanelResources(matching releasedPanel: NSPanel?) {
        guard let releasedPanel else { return }
        guard panel === releasedPanel else { return }

        releasedPanel.contentView = nil
        panel = nil
        foregroundHostingView = nil
        fieldEditorWarmupTextField = nil
        hideWorkItem = nil
        focusWorkItem = nil

        IconCache.clearMemoryCaches()
        KidoXReleaseTransientImageCaches()
    }

    private func hideAppIfNoOtherWindowIsVisible() {
        let hasOtherVisibleWindow = NSApp.windows.contains { window in
            guard window.isVisible else { return false }
            guard window !== panel else { return false }
            return true
        }

        if !hasOtherVisibleWindow {
            NSApp.hide(nil)
        }
    }

    private func centeredScaleTransform(scale: CGFloat, in size: CGSize) -> CGAffineTransform {
        guard size.width > 0, size.height > 0 else {
            return CGAffineTransform(scaleX: scale, y: scale)
        }
        let tx = (1 - scale) * size.width / 2
        let ty = (1 - scale) * size.height / 2
        return CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
    }

    private func resetForegroundAnimation(_ layer: CALayer? = nil) {
        guard let layer = layer ?? foregroundHostingView?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.scaleAnimationKey)
        layer.transform = CATransform3DIdentity
        layer.shouldRasterize = false
        CATransaction.commit()
    }
}

final class KidoXPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Pre-configure the shared field editor so its first use never flashes the
    // default opaque NSTextView background at the search input. The cell's
    // setUpFieldEditorAttributes runs on the same editor, but eagerly applying
    // the transparent settings here closes the window between editor insertion
    // and the cell's configuration.
    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        let editor = super.fieldEditor(createFlag, for: object)
        if let editor {
            SearchFieldNSTextFieldCell.configureFieldEditor(editor)
        }
        return editor
    }
}
