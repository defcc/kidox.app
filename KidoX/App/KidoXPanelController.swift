import AppKit
import Carbon
import QuartzCore
import SwiftUI

extension Notification.Name {
    static let kidoXPanelEscapeRequested = Notification.Name("KidoXPanelEscapeRequested")
}

@MainActor
final class KidoXPanelController {
    static let showMenuBarStorageKey = "KidoX.showMenuBarInLaunchPanel"
    static let hideLaunchPanelForModalPresentationNotification = Notification.Name("KidoXHideLaunchPanelForModalPresentation")

    private let store = KidoXStore()
    private let onOpenSettings: (SettingsPane?) -> Void
    private var panel: KidoXPanel?
    private weak var foregroundHostingView: NSView?
    private weak var fieldEditorWarmupTextField: NSTextField?
    private var interactiveGestureTransition: InteractiveGestureTransition?
    private var lastInteractiveGestureProgress: CGFloat?
    private var interactiveGestureStartOpenness: CGFloat?
    private var previousSystemUIMode: SystemUIMode?
    private var previousSystemUIOptions: SystemUIOptions?
    private var previousActivationPolicy: NSApplication.ActivationPolicy?
    private var mouseDownMonitor: Any?
    private var hideWorkItem: DispatchWorkItem?
    private var focusWorkItem: DispatchWorkItem?
    private var keepsPanelOpenForModalInteraction = false
    nonisolated(unsafe) private var defaultsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var updateCheckObserver: NSObjectProtocol?
    nonisolated(unsafe) private var modalPresentationObserver: NSObjectProtocol?
    private var observedAppLanguageRaw: String
    private static let scaleAnimationKey = "kidoXScaleAnimation"

    private enum InteractiveGestureTransition {
        case presentation
        case dismissal
    }

    init(onOpenSettings: @escaping (SettingsPane?) -> Void = { _ in }) {
        self.onOpenSettings = onOpenSettings
        self.observedAppLanguageRaw = UserDefaults.standard.string(forKey: KidoXLanguage.storageKey) ?? KidoXLanguage.system.rawValue
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDefaultsChanged()
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
        interactiveGestureTransition = nil
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
        prewarmForGestureActivation()
        Task { @MainActor [weak self] in
            await self?.store.loadApplications()
        }
    }

    func prewarmForGestureActivation() {
        guard panel == nil else { return }

        store.prepareCachedApplicationsForPresentation()

        let targetScreen = screenForPresentation()
        let panel = makePanel(for: targetScreen)
        self.panel = panel
        resizePanel(panel, to: targetScreen)
        configurePanelLevel(panel)
        prepareForPresentationAnimation(panel)
        prepareFirstVisibleFrame(panel)
        prewarmSearchFieldEditor(panel)
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
        interactiveGestureTransition = nil
        guard let panel, panel.isVisible else { return }
        keepsPanelOpenForModalInteraction = false
        resetTransientPresentationState()
        focusWorkItem?.cancel()
        focusWorkItem = nil
        panel.makeFirstResponder(nil)
        removeOutsideClickMonitor()
        animateDismissal(panel)
    }

    func beginInteractiveGesturePresentation() {
        if interactiveGestureTransition == .presentation {
            return
        }

        if interactiveGestureTransition == .dismissal {
            switchInteractiveGestureTransition(to: .presentation)
            return
        }

        guard !(panel?.isVisible ?? false) else { return }

        store.prepareCachedApplicationsForPresentation()
        store.markPreparingForInitialPresentation()

        let targetScreen = screenForPresentation()
        let panel = panel ?? makePanel(for: targetScreen)
        self.panel = panel
        hideWorkItem?.cancel()
        focusWorkItem?.cancel()
        focusWorkItem = nil

        resizePanel(panel, to: targetScreen)
        configurePanelLevel(panel)
        prepareForPresentationAnimation(panel)
        prewarmSearchFieldEditor(panel)
        applySystemMenuBarVisibilityPreference()
        panel.makeKeyAndOrderFront(nil)
        prepareFirstVisibleFrame(panel)
        installOutsideClickMonitor()

        interactiveGestureTransition = .presentation
        lastInteractiveGestureProgress = nil
        removeForegroundScaleAnimation()
        applyInteractiveGestureProgress(0, transition: .presentation)

        Task { @MainActor [weak self] in
            guard let self else { return }
            await store.prepareForPresentation()
        }
    }

    func updateInteractiveGesturePresentation(progress: CGFloat) {
        if interactiveGestureTransition == .dismissal {
            switchInteractiveGestureTransition(to: .presentation)
        }
        guard interactiveGestureTransition == .presentation else { return }
        applyInteractiveGestureProgress(progress, transition: .presentation)
    }

    func finishInteractiveGesturePresentation() {
        guard interactiveGestureTransition == .presentation, let panel else { return }
        interactiveGestureTransition = nil
        lastInteractiveGestureProgress = nil
        animateInteractiveGestureProgress(to: 1, transition: .presentation) { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.resetForegroundAnimation()
            panel.alphaValue = 1
            self.scheduleSearchFocusRequest(for: panel)
        }
    }

    func cancelInteractiveGesturePresentation() {
        guard interactiveGestureTransition == .presentation, let panel else { return }
        interactiveGestureTransition = nil
        lastInteractiveGestureProgress = nil
        animateInteractiveGestureProgress(to: 0, transition: .presentation) { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.removeOutsideClickMonitor()
            panel.orderOut(nil)
            self.restoreSystemMenuBarVisibility()
            self.hideAppIfNoOtherWindowIsVisible()
            self.parkPanelAfterDismissal(matching: panel)
        }
    }

    func beginInteractiveGestureDismissal() {
        if interactiveGestureTransition == .dismissal {
            return
        }

        if interactiveGestureTransition == .presentation {
            switchInteractiveGestureTransition(to: .dismissal)
            return
        }

        guard let panel, panel.isVisible else { return }

        keepsPanelOpenForModalInteraction = false
        resetTransientPresentationState()
        focusWorkItem?.cancel()
        focusWorkItem = nil
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel.makeFirstResponder(nil)
        removeOutsideClickMonitor()

        interactiveGestureTransition = .dismissal
        lastInteractiveGestureProgress = nil
        removeForegroundScaleAnimation()
        applyInteractiveGestureProgress(0, transition: .dismissal)
    }

    func updateInteractiveGestureDismissal(progress: CGFloat) {
        if interactiveGestureTransition == .presentation {
            switchInteractiveGestureTransition(to: .dismissal)
        }
        guard interactiveGestureTransition == .dismissal else { return }
        applyInteractiveGestureProgress(progress, transition: .dismissal)
    }

    func finishInteractiveGestureDismissal() {
        guard interactiveGestureTransition == .dismissal, let panel else { return }
        interactiveGestureTransition = nil
        lastInteractiveGestureProgress = nil
        animateInteractiveGestureProgress(to: 1, transition: .dismissal) { [weak self, weak panel] in
            guard let self, let panel else { return }
            panel.orderOut(nil)
            self.restoreSystemMenuBarVisibility()
            self.hideAppIfNoOtherWindowIsVisible()
            panel.alphaValue = 1
            self.resetForegroundAnimation()
            self.parkPanelAfterDismissal(matching: panel)
        }
    }

    func cancelInteractiveGestureDismissal() {
        guard interactiveGestureTransition == .dismissal, let panel else { return }
        interactiveGestureTransition = nil
        lastInteractiveGestureProgress = nil
        animateInteractiveGestureProgress(to: 0, transition: .dismissal) { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.resetForegroundAnimation()
            panel.alphaValue = 1
            self.installOutsideClickMonitor()
            self.scheduleSearchFocusRequest(for: panel)
        }
    }

    func beginInteractiveTrackpadGesture(direction: KidoXGlobalTrackpadGestureDirection) {
        guard interactiveGestureStartOpenness == nil else { return }

        let isVisible = panel?.isVisible ?? false
        if !isVisible {
            guard direction == .pinchIn else { return }
            prepareHiddenPanelForInteractiveGesturePresentation()
        } else {
            prepareVisiblePanelForInteractiveGesture()
        }

        let startOpenness = currentPanelOpennessEstimate()
        interactiveGestureStartOpenness = startOpenness
        interactiveGestureTransition = startOpenness < 0.5 ? .presentation : .dismissal
        lastInteractiveGestureProgress = nil
        removeForegroundScaleAnimation()
        applyInteractiveGestureOpenness(startOpenness)
    }

    func updateInteractiveTrackpadGesture(opennessDelta: CGFloat) {
        guard let startOpenness = interactiveGestureStartOpenness else { return }
        applyInteractiveGestureOpenness(startOpenness + opennessDelta)
    }

    func finishInteractiveTrackpadGesture(direction: KidoXGlobalTrackpadGestureDirection) {
        guard interactiveGestureStartOpenness != nil else { return }
        let currentOpenness = currentPanelOpennessEstimate()
        let targetOpenness = targetOpennessAfterTrackpadRelease(
            currentOpenness: currentOpenness,
            direction: direction
        )
        animateInteractiveGestureOpenness(to: targetOpenness) { [weak self] in
            self?.completeInteractiveTrackpadGesture(at: targetOpenness)
        }
    }

    func cancelInteractiveTrackpadGesture() {
        guard let startOpenness = interactiveGestureStartOpenness else { return }
        animateInteractiveGestureOpenness(to: startOpenness) { [weak self] in
            self?.completeInteractiveTrackpadGesture(at: startOpenness)
        }
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
        keepsPanelOpenForModalInteraction = false
        resetTransientPresentationState()
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

    private func resetTransientPresentationState() {
        store.openFolderID = nil
    }

    private func handleDefaultsChanged() {
        applyPanelPresentationPreference()

        let languageRaw = UserDefaults.standard.string(forKey: KidoXLanguage.storageKey) ?? KidoXLanguage.system.rawValue
        guard languageRaw != observedAppLanguageRaw else { return }
        observedAppLanguageRaw = languageRaw
        refreshApplications()
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
            },
            onOpenUninstallerSettings: { [weak self] in
                self?.hideImmediatelyForSettings()
                self?.onOpenSettings(.uninstaller)
            },
            onModalInteractionChanged: { [weak self] isActive in
                self?.keepsPanelOpenForModalInteraction = isActive
            },
            onRestoreFocusAfterModalInteraction: { [weak self] in
                self?.restoreFocusAfterModalInteraction()
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
                guard !self.keepsPanelOpenForModalInteraction else { return }
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
    private static let interactiveReleaseDuration: TimeInterval = 0.10

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

    private func restoreFocusAfterModalInteraction() {
        guard let panel, panel.isVisible else { return }

        hideWorkItem?.cancel()
        hideWorkItem = nil

        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)

        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, panel.isVisible else { return }
            panel.makeKeyAndOrderFront(nil)
            self.requestSearchFocusIfVisible(panel)
        }
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
                self?.parkPanelAfterDismissal(matching: panel)
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
        keepsPanelOpenForModalInteraction = false
        hideWorkItem = nil
        focusWorkItem = nil

        IconCache.clearMemoryCaches()
        KidoXReleaseTransientImageCaches()
    }

    private func parkPanelAfterDismissal(matching dismissedPanel: NSPanel?) {
        guard let dismissedPanel else { return }
        guard panel === dismissedPanel else { return }

        keepsPanelOpenForModalInteraction = false
        hideWorkItem = nil
        focusWorkItem = nil
        dismissedPanel.alphaValue = 1
        resetForegroundAnimation()

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

    private func applyInteractiveGestureProgress(
        _ rawProgress: CGFloat,
        transition: InteractiveGestureTransition
    ) {
        let progress = min(max(rawProgress, 0), 1)
        guard let panel else { return }
        if let lastInteractiveGestureProgress,
           abs(lastInteractiveGestureProgress - progress) < 0.003 {
            return
        }
        lastInteractiveGestureProgress = progress

        let state = interactiveGestureVisualState(progress: progress, transition: transition)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.alphaValue = state.alpha
        if let foreground = foregroundHostingView,
           let layer = foreground.layer {
            layer.transform = CATransform3DMakeAffineTransform(
                centeredScaleTransform(scale: state.scale, in: foreground.bounds.size)
            )
        }
        CATransaction.commit()
    }

    private func applyInteractiveGestureOpenness(_ rawOpenness: CGFloat) {
        let openness = min(max(rawOpenness, 0), 1)
        guard let panel else { return }
        if let lastInteractiveGestureProgress,
           abs(lastInteractiveGestureProgress - openness) < 0.003 {
            return
        }
        lastInteractiveGestureProgress = openness

        let state = interactiveGestureVisualState(openness: openness)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.alphaValue = state.alpha
        if let foreground = foregroundHostingView,
           let layer = foreground.layer {
            layer.transform = CATransform3DMakeAffineTransform(
                centeredScaleTransform(scale: state.scale, in: foreground.bounds.size)
            )
        }
        CATransaction.commit()
    }

    private func switchInteractiveGestureTransition(to transition: InteractiveGestureTransition) {
        guard interactiveGestureTransition != transition else { return }
        guard let previousTransition = interactiveGestureTransition else { return }

        hideWorkItem?.cancel()
        hideWorkItem = nil
        focusWorkItem?.cancel()
        focusWorkItem = nil
        removeForegroundScaleAnimation()

        let currentProgress = lastInteractiveGestureProgress ?? currentProgressEstimate(for: previousTransition)
        let mappedProgress = 1 - currentProgress
        interactiveGestureTransition = transition
        lastInteractiveGestureProgress = nil

        if transition == .presentation {
            installOutsideClickMonitor()
        } else {
            removeOutsideClickMonitor()
        }

        applyInteractiveGestureProgress(mappedProgress, transition: transition)
    }

    private func currentProgressEstimate(for transition: InteractiveGestureTransition) -> CGFloat {
        guard let panel else { return 0 }
        switch transition {
        case .presentation:
            return min(max(panel.alphaValue, 0), 1)
        case .dismissal:
            return min(max(1 - panel.alphaValue, 0), 1)
        }
    }

    private func currentPanelOpennessEstimate() -> CGFloat {
        guard let panel, panel.isVisible else { return 0 }
        return min(max(panel.alphaValue, 0), 1)
    }

    private func targetOpennessAfterTrackpadRelease(
        currentOpenness: CGFloat,
        direction: KidoXGlobalTrackpadGestureDirection
    ) -> CGFloat {
        switch direction {
        case .pinchIn:
            return currentOpenness >= 0.38 ? 1 : 0
        case .spreadOut:
            return currentOpenness <= 0.62 ? 0 : 1
        }
    }

    private func prepareHiddenPanelForInteractiveGesturePresentation() {
        store.prepareCachedApplicationsForPresentation()
        store.markPreparingForInitialPresentation()

        let targetScreen = screenForPresentation()
        let panel = panel ?? makePanel(for: targetScreen)
        self.panel = panel
        hideWorkItem?.cancel()
        focusWorkItem?.cancel()
        focusWorkItem = nil

        resizePanel(panel, to: targetScreen)
        configurePanelLevel(panel)
        prepareForPresentationAnimation(panel)
        prewarmSearchFieldEditor(panel)
        applySystemMenuBarVisibilityPreference()
        panel.makeKeyAndOrderFront(nil)
        prepareFirstVisibleFrame(panel)
        installOutsideClickMonitor()

        Task { @MainActor [weak self] in
            guard let self else { return }
            await store.prepareForPresentation()
        }
    }

    private func prepareVisiblePanelForInteractiveGesture() {
        guard let panel, panel.isVisible else { return }
        keepsPanelOpenForModalInteraction = false
        resetTransientPresentationState()
        focusWorkItem?.cancel()
        focusWorkItem = nil
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel.makeFirstResponder(nil)
    }

    private func animateInteractiveGestureOpenness(
        to targetOpenness: CGFloat,
        completion: @escaping @MainActor () -> Void
    ) {
        let openness = min(max(targetOpenness, 0), 1)
        guard let panel else {
            completion()
            return
        }

        let state = interactiveGestureVisualState(openness: openness)
        lastInteractiveGestureProgress = openness

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.interactiveReleaseDuration
            context.timingFunction = Self.presentationTimingFunction()
            panel.animator().alphaValue = state.alpha
        }

        if let foreground = foregroundHostingView,
           let layer = foreground.layer {
            let targetTransform = CATransform3DMakeAffineTransform(
                centeredScaleTransform(scale: state.scale, in: foreground.bounds.size)
            )
            let currentTransform = layer.presentation()?.transform ?? layer.transform

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = targetTransform
            CATransaction.commit()

            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = NSValue(caTransform3D: currentTransform)
            animation.toValue = NSValue(caTransform3D: targetTransform)
            animation.duration = Self.interactiveReleaseDuration
            animation.timingFunction = Self.presentationTimingFunction()
            animation.fillMode = .both
            animation.isRemovedOnCompletion = true
            layer.add(animation, forKey: Self.scaleAnimationKey)
        }

        let workItem = DispatchWorkItem {
            Task { @MainActor in
                completion()
            }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.interactiveReleaseDuration + 0.01, execute: workItem)
    }

    private func completeInteractiveTrackpadGesture(at openness: CGFloat) {
        let shouldRemainVisible = openness >= 0.5
        interactiveGestureTransition = nil
        interactiveGestureStartOpenness = nil
        lastInteractiveGestureProgress = nil

        if shouldRemainVisible, let panel {
            resetForegroundAnimation()
            panel.alphaValue = 1
            installOutsideClickMonitor()
            scheduleSearchFocusRequest(for: panel)
        } else if let panel {
            removeOutsideClickMonitor()
            panel.orderOut(nil)
            restoreSystemMenuBarVisibility()
            hideAppIfNoOtherWindowIsVisible()
            panel.alphaValue = 1
            resetForegroundAnimation()
            parkPanelAfterDismissal(matching: panel)
        }
    }

    private func animateInteractiveGestureProgress(
        to targetProgress: CGFloat,
        transition: InteractiveGestureTransition,
        completion: @escaping @MainActor () -> Void
    ) {
        let progress = min(max(targetProgress, 0), 1)
        guard let panel else {
            completion()
            return
        }

        let state = interactiveGestureVisualState(progress: progress, transition: transition)
        lastInteractiveGestureProgress = progress

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.interactiveReleaseDuration
            context.timingFunction = Self.presentationTimingFunction()
            panel.animator().alphaValue = state.alpha
        }

        if let foreground = foregroundHostingView,
           let layer = foreground.layer {
            let targetTransform = CATransform3DMakeAffineTransform(
                centeredScaleTransform(scale: state.scale, in: foreground.bounds.size)
            )
            let currentTransform = layer.presentation()?.transform ?? layer.transform

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = targetTransform
            CATransaction.commit()

            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = NSValue(caTransform3D: currentTransform)
            animation.toValue = NSValue(caTransform3D: targetTransform)
            animation.duration = Self.interactiveReleaseDuration
            animation.timingFunction = Self.presentationTimingFunction()
            animation.fillMode = .both
            animation.isRemovedOnCompletion = true
            layer.add(animation, forKey: Self.scaleAnimationKey)
        }

        let workItem = DispatchWorkItem {
            Task { @MainActor in
                completion()
            }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.interactiveReleaseDuration + 0.01, execute: workItem)
    }

    private func interactiveGestureVisualState(
        progress: CGFloat,
        transition: InteractiveGestureTransition
    ) -> (alpha: CGFloat, scale: CGFloat) {
        switch transition {
        case .presentation:
            return (
                alpha: progress,
                scale: Self.presentationInitialScale - ((Self.presentationInitialScale - 1) * progress)
            )
        case .dismissal:
            return (
                alpha: 1 - progress,
                scale: 1 + ((Self.dismissalTargetScale - 1) * progress)
            )
        }
    }

    private func interactiveGestureVisualState(openness: CGFloat) -> (alpha: CGFloat, scale: CGFloat) {
        let startOpenness = interactiveGestureStartOpenness ?? openness
        if startOpenness < 0.5 {
            return (
                alpha: openness,
                scale: Self.presentationInitialScale - ((Self.presentationInitialScale - 1) * openness)
            )
        }
        return (
            alpha: openness,
            scale: 1 + ((Self.dismissalTargetScale - 1) * (1 - openness))
        )
    }

    private func removeForegroundScaleAnimation() {
        guard let layer = foregroundHostingView?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.scaleAnimationKey)
        CATransaction.commit()
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

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, !isEditingText {
            NotificationCenter.default.post(name: .kidoXPanelEscapeRequested, object: self)
            return
        }

        super.sendEvent(event)
    }

    private var isEditingText: Bool {
        guard let textView = firstResponder as? NSTextView else { return false }
        return textView.delegate != nil
    }

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
