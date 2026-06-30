import AppKit
import ApplicationServices
import Carbon.HIToolbox
import KeyboardShortcuts
import OSLog

enum KidoXActivationPreferenceKeys {
    static let f4HotKeyEnabled = "KidoX.f4HotKey.enabled"
    static let globalTrackpadGestureEnabled = "KidoX.globalTrackpadGesture.enabled"
    static let debugLoggingEnabled = "KidoX.debugLogging.enabled"
    static let hotCorner = "KidoX.hotCorner"
}

private func kidoXF4EventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userData: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    KidoXActivationController.handleF4EventTap(
        proxy: proxy,
        type: type,
        event: event,
        userData: userData
    )
}

extension KeyboardShortcuts.Name {
    static let showLaunchPanel = Self(
        "showLaunchPanel",
        default: .init(.space, modifiers: [.option])
    )
}

enum KidoXHotCorner: String, CaseIterable, Identifiable {
    case none
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }

    func localizedTitle(languageRawValue: String? = nil) -> String {
        KidoXL10n.ui(title, languageRawValue: languageRawValue)
    }
}

final class KidoXActivationController: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.clyapps.KidoX",
        category: "Activation"
    )

    private static let f4HotKeySignature: OSType = 0x4B584634 // "KXF4"
    private static let standardF4KeyCode = Int64(kVK_F4)
    // Built-in Mac keyboards send the F4/Spotlight key as virtual key code 177.
    private static let builtInSpotlightF4KeyCode: Int64 = 177
    private static let systemDefinedEventType = CGEventType(rawValue: 14)!
    private static let systemDefinedAuxControlButtonsSubtype = 8
    private static let legacyF4SpecialKeyTypes: Set<Int> = [
        13,   // NX_KEYTYPE_LAUNCH_PANEL on older Launchpad-key layouts.
        0x81  // Apple vendor Spotlight special key.
    ]
    private static let systemDefinedKeyDownState = 0xA

    private let onShow: @MainActor () -> Void
    private let onHide: @MainActor () -> Void
    private let onTrackpadGestureEvent: @MainActor (KidoXGlobalTrackpadGestureEvent) -> Void
    private var defaultsObserver: NSObjectProtocol?
    private var applicationDidBecomeActiveObserver: NSObjectProtocol?
    private var f4HotKey: EventHotKeyRef?
    private var f4EventHandler: EventHandlerRef?
    private var f4EventTap: CFMachPort?
    private var f4EventTapRunLoopSource: CFRunLoopSource?
    private var globalTrackpadGestureMonitor: KidoXGlobalTrackpadGestureMonitor?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var activeHotCorner: KidoXHotCorner = .none
    private var pointerIsInsideHotCorner = false
    private var lastActivationDate = Date.distantPast

    init(
        onShow: @escaping @MainActor () -> Void,
        onHide: @escaping @MainActor () -> Void = {},
        onTrackpadGestureEvent: @escaping @MainActor (KidoXGlobalTrackpadGestureEvent) -> Void = { _ in }
    ) {
        self.onShow = onShow
        self.onHide = onHide
        self.onTrackpadGestureEvent = onTrackpadGestureEvent
        registerDefaultPreferences()
    }

    deinit {
        stop()
    }

    func start() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.configureF4HotKeyFromDefaults()
            self?.configureGlobalTrackpadGestureFromDefaults()
            self?.configureHotCornerFromDefaults()
        }

        applicationDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.configureF4HotKeyFromDefaults()
        }

        KeyboardShortcuts.onKeyUp(for: .showLaunchPanel) { [weak self] in
            self?.triggerFromInput()
        }

        configureF4HotKeyFromDefaults()
        configureGlobalTrackpadGestureFromDefaults()
        configureHotCornerFromDefaults()
    }

    func stop() {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
        if let applicationDidBecomeActiveObserver {
            NotificationCenter.default.removeObserver(applicationDidBecomeActiveObserver)
            self.applicationDidBecomeActiveObserver = nil
        }
        uninstallF4HotKey()
        uninstallF4EventTap()
        uninstallGlobalTrackpadGestureMonitor()
        uninstallHotCornerMonitor()
    }

    private func registerDefaultPreferences() {
        UserDefaults.standard.register(defaults: [
            KidoXActivationPreferenceKeys.f4HotKeyEnabled: true,
            KidoXActivationPreferenceKeys.globalTrackpadGestureEnabled: true,
            KidoXActivationPreferenceKeys.debugLoggingEnabled: false,
            KidoXActivationPreferenceKeys.hotCorner: KidoXHotCorner.none.rawValue
        ])
    }

    private func configureF4HotKeyFromDefaults() {
        let enabled = UserDefaults.standard.bool(forKey: KidoXActivationPreferenceKeys.f4HotKeyEnabled)
        Self.logger.info("Configure F4 activation: enabled=\(enabled, privacy: .public), accessibility=\(Self.isAccessibilityAccessGranted, privacy: .public)")

        if enabled {
            installF4HotKey()
            installF4EventTapIfTrusted()
        } else {
            uninstallF4HotKey()
            uninstallF4EventTap()
        }
    }

    private func installF4HotKey() {
        guard f4HotKey == nil, f4EventHandler == nil else {
            Self.logger.debug("F4 Carbon hotkey already installed")
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let controller = Unmanaged<KidoXActivationController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                controller.triggerFromInput()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &f4EventHandler
        )

        guard handlerStatus == noErr else {
            Self.logger.error("Failed to install F4 Carbon hotkey handler: status=\(handlerStatus, privacy: .public)")
            return
        }

        var hotKey: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_F4),
            0,
            EventHotKeyID(signature: Self.f4HotKeySignature, id: 1),
            GetEventDispatcherTarget(),
            0,
            &hotKey
        )

        guard registerStatus == noErr, let hotKey else {
            Self.logger.error("Failed to register F4 Carbon hotkey: status=\(registerStatus, privacy: .public)")
            if let f4EventHandler {
                RemoveEventHandler(f4EventHandler)
                self.f4EventHandler = nil
            }
            return
        }

        f4HotKey = hotKey
        Self.logger.info("Installed F4 Carbon hotkey")
    }

    private func installF4EventTapIfTrusted() {
        guard f4EventTap == nil else {
            Self.logger.debug("F4 event tap already installed")
            return
        }

        guard Self.isAccessibilityAccessGranted else {
            Self.logger.info("F4 event tap not installed because Accessibility is not granted")
            return
        }

        let keyDownMask = 1 << CGEventType.keyDown.rawValue
        let systemDefinedMask = 1 << Self.systemDefinedEventType.rawValue
        let eventMask = CGEventMask(keyDownMask | systemDefinedMask)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: kidoXF4EventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Self.logger.error("Failed to create F4 event tap despite Accessibility being granted")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        f4EventTap = tap
        f4EventTapRunLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
        Self.logger.info("Installed F4 event tap: mask=\(eventMask, privacy: .public)")
    }

    private func uninstallF4HotKey() {
        if let f4HotKey {
            UnregisterEventHotKey(f4HotKey)
            self.f4HotKey = nil
            Self.logger.info("Uninstalled F4 Carbon hotkey")
        }

        if let f4EventHandler {
            RemoveEventHandler(f4EventHandler)
            self.f4EventHandler = nil
        }
    }

    private func uninstallF4EventTap() {
        if let source = f4EventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            f4EventTapRunLoopSource = nil
        }

        if let tap = f4EventTap {
            CFMachPortInvalidate(tap)
            f4EventTap = nil
            Self.logger.info("Uninstalled F4 event tap")
        }
    }

    private func configureGlobalTrackpadGestureFromDefaults() {
        let enabled = UserDefaults.standard.bool(forKey: KidoXActivationPreferenceKeys.globalTrackpadGestureEnabled)
        let configuration = KidoXGlobalTrackpadGestureMonitor.Configuration(isEnabled: enabled)

        if globalTrackpadGestureMonitor == nil {
            globalTrackpadGestureMonitor = KidoXGlobalTrackpadGestureMonitor(configuration: configuration) { [weak self] event in
                self?.handleGlobalTrackpadGestureEvent(event)
            }
        }

        globalTrackpadGestureMonitor?.update(configuration: configuration)
    }

    private func uninstallGlobalTrackpadGestureMonitor() {
        globalTrackpadGestureMonitor?.stop()
        globalTrackpadGestureMonitor = nil
    }

    static var isAccessibilityAccessGranted: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityAccess() {
        logger.info("Requesting Accessibility access")
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private static var isDebugLoggingEnabled: Bool {
        UserDefaults.standard.bool(forKey: KidoXActivationPreferenceKeys.debugLoggingEnabled)
    }

    private static func logF4Debug(_ message: @autoclosure () -> String) {
        guard isDebugLoggingEnabled else { return }
        let text = message()
        logger.info("\(text, privacy: .public)")
    }

    fileprivate static func handleF4EventTap(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent,
        userData: UnsafeMutableRawPointer?
    ) -> Unmanaged<CGEvent>? {
        guard let userData else {
            return Unmanaged.passUnretained(event)
        }

        let controller = Unmanaged<KidoXActivationController>
            .fromOpaque(userData)
            .takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Self.logger.warning("F4 event tap disabled by system: type=\(type.rawValue, privacy: .public); re-enabling")
            if let tap = controller.f4EventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard UserDefaults.standard.bool(forKey: KidoXActivationPreferenceKeys.f4HotKeyEnabled) else {
            return Unmanaged.passUnretained(event)
        }

        if controller.shouldCaptureF4Event(event, type: type) {
            Self.logF4Debug("Captured F4 activation event: type=\(type.rawValue)")
            controller.triggerFromInput()
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func shouldCaptureF4Event(_ event: CGEvent, type: CGEventType) -> Bool {
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            Self.logF4Debug("Entered F4 event matcher: type=keyDown, keyCode=\(keyCode), carbonHotkeyInstalled=\(self.f4HotKey != nil)")
            let isStandardF4 = keyCode == Self.standardF4KeyCode
            let isBuiltInSpotlightF4 = keyCode == Self.builtInSpotlightF4KeyCode
            if isStandardF4 || isBuiltInSpotlightF4 {
                Self.logF4Debug("Observed keyDown F4: carbonHotkeyInstalled=\(self.f4HotKey != nil)")
            }
            return (isStandardF4 && f4HotKey == nil) || isBuiltInSpotlightF4
        }

        guard type == Self.systemDefinedEventType else {
            Self.logF4Debug("Entered F4 event matcher: type=\(type.rawValue), unsupported event type")
            return false
        }

        guard let nsEvent = NSEvent(cgEvent: event) else {
            Self.logF4Debug("Entered F4 event matcher: type=systemDefined, unable to bridge CGEvent to NSEvent")
            return false
        }

        Self.logF4Debug("Entered F4 event matcher: type=systemDefined, subtype=\(nsEvent.subtype.rawValue), data1=\(nsEvent.data1), data2=\(nsEvent.data2)")

        guard nsEvent.subtype.rawValue == Self.systemDefinedAuxControlButtonsSubtype else {
            return false
        }

        let keyType = (nsEvent.data1 & 0xFFFF0000) >> 16
        let keyState = (nsEvent.data1 & 0x0000FF00) >> 8
        let isLegacyF4SpecialKey = Self.legacyF4SpecialKeyTypes.contains(keyType)
        if isLegacyF4SpecialKey {
            Self.logF4Debug("Observed F4 special-key system event: subtype=\(nsEvent.subtype.rawValue), data1=\(nsEvent.data1), keyType=\(keyType), keyState=\(keyState)")
        } else {
            Self.logF4Debug("Observed other system-defined aux event: subtype=\(nsEvent.subtype.rawValue), data1=\(nsEvent.data1), keyType=\(keyType), keyState=\(keyState)")
        }
        return isLegacyF4SpecialKey && keyState == Self.systemDefinedKeyDownState
    }

    private func configureHotCornerFromDefaults() {
        let rawValue = UserDefaults.standard.string(forKey: KidoXActivationPreferenceKeys.hotCorner)
        activeHotCorner = rawValue.flatMap(KidoXHotCorner.init(rawValue:)) ?? .none
        pointerIsInsideHotCorner = false

        if activeHotCorner == .none {
            uninstallHotCornerMonitor()
        } else {
            installHotCornerMonitor()
        }
    }

    private func installHotCornerMonitor() {
        guard globalMouseMonitor == nil, localMouseMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.handleMouseLocation(NSEvent.mouseLocation)
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMouseLocation(NSEvent.mouseLocation)
            return event
        }
    }

    private func uninstallHotCornerMonitor() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }

        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }

    private func handleMouseLocation(_ location: CGPoint) {
        guard activeHotCorner != .none else { return }

        let isInside = isLocation(location, inside: activeHotCorner)
        defer { pointerIsInsideHotCorner = isInside }

        guard isInside, !pointerIsInsideHotCorner else { return }
        triggerFromInput()
    }

    private func isLocation(_ location: CGPoint, inside corner: KidoXHotCorner) -> Bool {
        let threshold: CGFloat = 8
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.insetBy(dx: -threshold, dy: -threshold).contains(location)
        }) else { return false }

        let frame = screen.frame
        switch corner {
        case .none:
            return false
        case .topLeft:
            return location.x <= frame.minX + threshold && location.y >= frame.maxY - threshold
        case .topRight:
            return location.x >= frame.maxX - threshold && location.y >= frame.maxY - threshold
        case .bottomLeft:
            return location.x <= frame.minX + threshold && location.y <= frame.minY + threshold
        case .bottomRight:
            return location.x >= frame.maxX - threshold && location.y <= frame.minY + threshold
        }
    }

    private func triggerFromInput() {
        DispatchQueue.main.async { [weak self] in
            self?.showLaunchPanelIfNeeded()
        }
    }

    @MainActor
    private func showLaunchPanelIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastActivationDate) > 0.35 else { return }
        lastActivationDate = now
        onShow()
    }

    @MainActor
    private func hideLaunchPanelIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastActivationDate) > 0.35 else { return }
        lastActivationDate = now
        onHide()
    }

    @MainActor
    private func handleGlobalTrackpadGestureEvent(_ event: KidoXGlobalTrackpadGestureEvent) {
        onTrackpadGestureEvent(event)
    }
}
