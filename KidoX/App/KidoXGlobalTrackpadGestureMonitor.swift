import CoreGraphics
import Darwin
import Foundation
import OSLog

private typealias KidoXMTDeviceRef = UnsafeMutableRawPointer

private struct KidoXMTPoint {
    var x: Float
    var y: Float
}

private struct KidoXMTVector {
    var position: KidoXMTPoint
    var velocity: KidoXMTPoint
}

private struct KidoXMTTouch {
    var frame: CInt
    var timestamp: Double
    var identifier: CInt
    var state: CInt
    var fingerID: CInt
    var handID: CInt
    var normalizedPosition: KidoXMTVector
    var total: Float
    var pressure: Float
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absolutePosition: KidoXMTVector
    var field14: CInt
    var field15: CInt
    var density: Float
}

private struct KidoXTrackpadSample {
    let id: CInt
    let point: CGPoint
}

enum KidoXGlobalTrackpadGestureDirection: Equatable {
    case pinchIn
    case spreadOut
}

enum KidoXGlobalTrackpadGestureEvent {
    case began(KidoXGlobalTrackpadGestureDirection)
    case changed(direction: KidoXGlobalTrackpadGestureDirection, progress: CGFloat, opennessDelta: CGFloat)
    case committed(KidoXGlobalTrackpadGestureDirection)
    case cancelled(KidoXGlobalTrackpadGestureDirection)
}

private typealias KidoXMTFrameCallback = @convention(c) (
    KidoXMTDeviceRef?,
    UnsafeRawPointer?,
    CInt,
    Double,
    CInt
) -> Void

private let kidoXMTFrameCallback: KidoXMTFrameCallback = { device, touches, count, _, _ in
    KidoXGlobalTrackpadGestureMonitor.handleFrame(device: device, touches: touches, count: count)
}

final class KidoXGlobalTrackpadGestureMonitor: @unchecked Sendable {
    struct Configuration: Equatable {
        var isEnabled = true
        var fingerCount = 4
        var pinchInTriggerScaleRatio: CGFloat = 0.80
        var spreadOutTriggerScaleRatio: CGFloat = 1.20
        var minimumTrackingFingerCount = 2
        var minimumParticipatingFingerCount = 3
        var requiredStableDuration: TimeInterval = 0.008
        var minimumBaselineScale: CGFloat = 0.10
        var maximumCentroidDriftRatio: CGFloat = 0.26
        var movementDeadZone: CGFloat = 0.014
        var activationProgressThreshold: CGFloat = 0.055
        var maximumActivationTranslationRatio: CGFloat = 1.65
        var minimumActivationRadialMotionRatio: CGFloat = 0.028
        var maximumActivationTangentialRatio: CGFloat = 1.35
        var swipeLockoutTranslationRatio: CGFloat = 0.070
        var swipeLockoutTranslationDominanceRatio: CGFloat = 2.25
        var scaleSmoothingFactor: CGFloat = 0.88
    }

    private struct RegisteredDevice {
        let ref: KidoXMTDeviceRef
        let id: UInt64
        let ownsReference: Bool
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.clyapps.KidoX",
        category: "TrackpadGesture"
    )

    nonisolated(unsafe) private static var activeMonitor: KidoXGlobalTrackpadGestureMonitor?

    private let onGestureEvent: @MainActor (KidoXGlobalTrackpadGestureEvent) -> Void
    private let gestureEventDispatcher: KidoXTrackpadGestureEventDispatcher
    private let lock = NSLock()
    private var configuration: Configuration
    private var support: KidoXMultitouchSupport?
    private var retainedDeviceList: CFArray?
    private var registeredDevices: [RegisteredDevice] = []
    private var deviceIDsByPointer: [UInt: UInt64] = [:]
    private var recognizers: [UInt64: KidoXFourFingerPinchRecognizer] = [:]
    private var isListening = false

    init(
        configuration: Configuration = Configuration(),
        onGestureEvent: @escaping @MainActor (KidoXGlobalTrackpadGestureEvent) -> Void
    ) {
        self.configuration = configuration
        self.onGestureEvent = onGestureEvent
        self.gestureEventDispatcher = KidoXTrackpadGestureEventDispatcher(onGestureEvent: onGestureEvent)
    }

    deinit {
        stop()
    }

    func update(configuration: Configuration) {
        let shouldRestart = self.configuration != configuration && isListening
        self.configuration = configuration

        if !configuration.isEnabled {
            stop()
            return
        }

        if shouldRestart {
            stop()
        }

        if !isListening {
            start()
        }
    }

    func start() {
        guard configuration.isEnabled, !isListening else { return }
        guard let support = KidoXMultitouchSupport() else {
            Self.logger.info("MultitouchSupport is unavailable")
            return
        }

        self.support = support
        Self.activeMonitor = self

        let devices = enumerateTrackpadDevices(using: support)
        guard !devices.isEmpty else {
            Self.logger.info("No usable trackpad devices found for global gesture")
            Self.activeMonitor = nil
            self.support = nil
            retainedDeviceList = nil
            return
        }

        var startedDevices: [RegisteredDevice] = []
        for device in devices {
            support.registerContactFrameCallback(device.ref, kidoXMTFrameCallback)
            let status = support.startDevice(device.ref)
            guard status == 0 else {
                support.unregisterContactFrameCallback(device.ref, kidoXMTFrameCallback)
                if device.ownsReference {
                    support.releaseDevice(device.ref)
                }
                Self.logger.error("Failed to start multitouch device: id=\(device.id, privacy: .public), status=\(status, privacy: .public)")
                continue
            }
            startedDevices.append(device)
        }

        guard !startedDevices.isEmpty else {
            Self.activeMonitor = nil
            self.support = nil
            retainedDeviceList = nil
            return
        }

        lock.lock()
        registeredDevices = startedDevices
        deviceIDsByPointer = Dictionary(uniqueKeysWithValues: startedDevices.map {
            (UInt(bitPattern: $0.ref), $0.id)
        })
        recognizers.removeAll()
        isListening = true
        lock.unlock()

        Self.logger.info("Started global trackpad gesture monitor: devices=\(startedDevices.count, privacy: .public)")
    }

    func stop() {
        lock.lock()
        let devices = registeredDevices
        registeredDevices = []
        deviceIDsByPointer = [:]
        recognizers.removeAll()
        isListening = false
        lock.unlock()

        guard let support else {
            Self.activeMonitor = nil
            return
        }

        for device in devices {
            if support.isDeviceRunning(device.ref) {
                support.unregisterContactFrameCallback(device.ref, kidoXMTFrameCallback)
                _ = support.stopDevice(device.ref)
            }
            if device.ownsReference {
                support.releaseDevice(device.ref)
            }
        }

        retainedDeviceList = nil
        self.support = nil
        Self.activeMonitor = nil

        if !devices.isEmpty {
            Self.logger.info("Stopped global trackpad gesture monitor")
        }
    }

    fileprivate static func handleFrame(
        device: KidoXMTDeviceRef?,
        touches: UnsafeRawPointer?,
        count: CInt
    ) {
        guard let activeMonitor else { return }
        activeMonitor.consumeFrame(device: device, touches: touches, count: count)
    }

    private func consumeFrame(
        device: KidoXMTDeviceRef?,
        touches: UnsafeRawPointer?,
        count: CInt
    ) {
        guard let device, let touches, count >= 0 else { return }
        let touchBuffer = touches.bindMemory(to: KidoXMTTouch.self, capacity: Int(count))

        var samples: [KidoXTrackpadSample] = []
        samples.reserveCapacity(Int(count))

        for index in 0..<Int(count) {
            let touch = touchBuffer[index]
            guard Self.activeTouchStates.contains(touch.state) else { continue }
            samples.append(
                KidoXTrackpadSample(
                    id: touch.identifier,
                    point: CGPoint(
                        x: CGFloat(touch.normalizedPosition.position.x),
                        y: CGFloat(touch.normalizedPosition.position.y)
                    )
                )
            )
        }

        let now = ProcessInfo.processInfo.systemUptime
        var event: KidoXGlobalTrackpadGestureEvent?

        lock.lock()
        if isListening {
            let deviceID = deviceIDsByPointer[UInt(bitPattern: device)] ?? UInt64(UInt(bitPattern: device))
            var recognizer = recognizers[deviceID] ?? KidoXFourFingerPinchRecognizer(configuration: configuration)
            event = recognizer.consume(samples: samples, at: now)
            recognizers[deviceID] = recognizer
        }
        lock.unlock()

        guard let event else { return }
        gestureEventDispatcher.enqueue(event)
    }

    private func enumerateTrackpadDevices(using support: KidoXMultitouchSupport) -> [RegisteredDevice] {
        var result: [RegisteredDevice] = []

        if let list = support.createDeviceList() {
            retainedDeviceList = list
            let count = CFArrayGetCount(list)

            for index in 0..<count {
                guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
                let device = KidoXMTDeviceRef(mutating: raw)
                guard isLikelyTrackpad(device, using: support) else { continue }
                result.append(
                    RegisteredDevice(
                        ref: device,
                        id: deviceID(for: device, using: support),
                        ownsReference: false
                    )
                )
            }
        }

        if result.isEmpty, let device = support.createDefaultDevice() {
            result.append(
                RegisteredDevice(
                    ref: device,
                    id: deviceID(for: device, using: support),
                    ownsReference: true
                )
            )
        }

        return result
    }

    private func isLikelyTrackpad(_ device: KidoXMTDeviceRef, using support: KidoXMultitouchSupport) -> Bool {
        var familyID: CInt = 0
        let hasFamilyID = support.getFamilyID(device, &familyID) == 0
        if hasFamilyID {
            switch familyID {
            case 98...109, 128...130:
                return true
            case 112...113:
                return false
            default:
                break
            }
        }

        var width: CInt = 0
        var height: CInt = 0
        guard support.getSensorSurfaceDimensions(device, &width, &height) == 0 else {
            return support.isBuiltIn(device) ?? true
        }

        let looksLikeTouchBar = width > 1000 && height < 100
        return width > height && width > 50 && height > 20 && !looksLikeTouchBar
    }

    private func deviceID(for device: KidoXMTDeviceRef, using support: KidoXMultitouchSupport) -> UInt64 {
        var id: UInt64 = 0
        if support.getDeviceID(device, &id) == 0 {
            return id
        }
        return UInt64(UInt(bitPattern: device))
    }

    private static let activeTouchStates: Set<CInt> = [
        3, // make touch
        4  // touching
    ]
}

private final class KidoXTrackpadGestureEventDispatcher: @unchecked Sendable {
    private let onGestureEvent: @MainActor (KidoXGlobalTrackpadGestureEvent) -> Void
    private let lock = NSLock()
    private var queuedEvents: [KidoXGlobalTrackpadGestureEvent] = []
    private var pendingChangedEvent: KidoXGlobalTrackpadGestureEvent?
    private var isFlushScheduled = false

    init(onGestureEvent: @escaping @MainActor (KidoXGlobalTrackpadGestureEvent) -> Void) {
        self.onGestureEvent = onGestureEvent
    }

    func enqueue(_ event: KidoXGlobalTrackpadGestureEvent) {
        var shouldScheduleFlush = false

        lock.lock()
        switch event {
        case .changed:
            pendingChangedEvent = event
        case .began:
            pendingChangedEvent = nil
            queuedEvents.append(event)
        case .committed, .cancelled:
            if let pendingChangedEvent,
               Self.direction(of: pendingChangedEvent) == Self.direction(of: event) {
                queuedEvents.append(pendingChangedEvent)
            }
            self.pendingChangedEvent = nil
            queuedEvents.append(event)
        }

        if !isFlushScheduled {
            isFlushScheduled = true
            shouldScheduleFlush = true
        }
        lock.unlock()

        if shouldScheduleFlush {
            DispatchQueue.main.async { [weak self] in
                self?.flush()
            }
        }
    }

    private func flush() {
        let events: [KidoXGlobalTrackpadGestureEvent]

        lock.lock()
        var coalescedEvents = queuedEvents
        queuedEvents.removeAll(keepingCapacity: true)
        if let pendingChangedEvent {
            coalescedEvents.append(pendingChangedEvent)
            self.pendingChangedEvent = nil
        }
        isFlushScheduled = false
        events = coalescedEvents
        lock.unlock()

        guard !events.isEmpty else { return }
        Task { @MainActor [onGestureEvent, events] in
            for event in events {
                onGestureEvent(event)
            }
        }
    }

    private static func direction(of event: KidoXGlobalTrackpadGestureEvent) -> KidoXGlobalTrackpadGestureDirection {
        switch event {
        case let .began(direction),
             let .committed(direction),
             let .cancelled(direction):
            return direction
        case let .changed(direction, _, _):
            return direction
        }
    }
}

private final class KidoXMultitouchSupport {
    private typealias MTDeviceIsAvailable = @convention(c) () -> Bool
    private typealias MTDeviceCreateDefault = @convention(c) () -> KidoXMTDeviceRef?
    private typealias MTDeviceCreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias MTDeviceRelease = @convention(c) (KidoXMTDeviceRef?) -> Void
    private typealias MTDeviceStart = @convention(c) (KidoXMTDeviceRef?, CInt) -> OSStatus
    private typealias MTDeviceStop = @convention(c) (KidoXMTDeviceRef?) -> OSStatus
    private typealias MTDeviceIsRunning = @convention(c) (KidoXMTDeviceRef?) -> Bool
    private typealias MTRegisterContactFrameCallback = @convention(c) (KidoXMTDeviceRef?, KidoXMTFrameCallback?) -> Void
    private typealias MTUnregisterContactFrameCallback = @convention(c) (KidoXMTDeviceRef?, KidoXMTFrameCallback?) -> Void
    private typealias MTDeviceGetDeviceID = @convention(c) (KidoXMTDeviceRef?, UnsafeMutablePointer<UInt64>?) -> OSStatus
    private typealias MTDeviceGetFamilyID = @convention(c) (KidoXMTDeviceRef?, UnsafeMutablePointer<CInt>?) -> OSStatus
    private typealias MTDeviceGetSensorSurfaceDimensions = @convention(c) (
        KidoXMTDeviceRef?,
        UnsafeMutablePointer<CInt>?,
        UnsafeMutablePointer<CInt>?
    ) -> OSStatus
    private typealias MTDeviceIsBuiltIn = @convention(c) (KidoXMTDeviceRef?) -> Bool

    private let handle: UnsafeMutableRawPointer
    private let createDefault: MTDeviceCreateDefault
    private let createList: MTDeviceCreateList?
    private let release: MTDeviceRelease
    private let start: MTDeviceStart
    private let stop: MTDeviceStop
    private let isRunning: MTDeviceIsRunning
    private let registerCallback: MTRegisterContactFrameCallback
    private let unregisterCallback: MTUnregisterContactFrameCallback
    private let rawGetDeviceID: MTDeviceGetDeviceID?
    private let rawGetFamilyID: MTDeviceGetFamilyID
    private let rawGetSensorSurfaceDimensions: MTDeviceGetSensorSurfaceDimensions
    private let rawIsBuiltIn: MTDeviceIsBuiltIn?

    init?() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return nil }

        guard let isAvailable = Self.loadSymbol(handle, "MTDeviceIsAvailable", as: MTDeviceIsAvailable.self),
              isAvailable(),
              let createDefault = Self.loadSymbol(handle, "MTDeviceCreateDefault", as: MTDeviceCreateDefault.self),
              let release = Self.loadSymbol(handle, "MTDeviceRelease", as: MTDeviceRelease.self),
              let start = Self.loadSymbol(handle, "MTDeviceStart", as: MTDeviceStart.self),
              let stop = Self.loadSymbol(handle, "MTDeviceStop", as: MTDeviceStop.self),
              let isRunning = Self.loadSymbol(handle, "MTDeviceIsRunning", as: MTDeviceIsRunning.self),
              let registerCallback = Self.loadSymbol(handle, "MTRegisterContactFrameCallback", as: MTRegisterContactFrameCallback.self),
              let unregisterCallback = Self.loadSymbol(handle, "MTUnregisterContactFrameCallback", as: MTUnregisterContactFrameCallback.self),
              let getFamilyID = Self.loadSymbol(handle, "MTDeviceGetFamilyID", as: MTDeviceGetFamilyID.self),
              let getSensorSurfaceDimensions = Self.loadSymbol(handle, "MTDeviceGetSensorSurfaceDimensions", as: MTDeviceGetSensorSurfaceDimensions.self)
        else {
            dlclose(handle)
            return nil
        }

        self.handle = handle
        self.createDefault = createDefault
        self.createList = Self.loadSymbol(handle, "MTDeviceCreateList", as: MTDeviceCreateList.self)
        self.release = release
        self.start = start
        self.stop = stop
        self.isRunning = isRunning
        self.registerCallback = registerCallback
        self.unregisterCallback = unregisterCallback
        self.rawGetDeviceID = Self.loadSymbol(handle, "MTDeviceGetDeviceID", as: MTDeviceGetDeviceID.self)
        self.rawGetFamilyID = getFamilyID
        self.rawGetSensorSurfaceDimensions = getSensorSurfaceDimensions
        self.rawIsBuiltIn = Self.loadSymbol(handle, "MTDeviceIsBuiltIn", as: MTDeviceIsBuiltIn.self)
    }

    deinit {
        dlclose(handle)
    }

    func createDeviceList() -> CFArray? {
        createList?()?.takeRetainedValue()
    }

    func createDefaultDevice() -> KidoXMTDeviceRef? {
        createDefault()
    }

    func releaseDevice(_ device: KidoXMTDeviceRef?) {
        release(device)
    }

    func startDevice(_ device: KidoXMTDeviceRef?) -> OSStatus {
        start(device, 0)
    }

    func stopDevice(_ device: KidoXMTDeviceRef?) -> OSStatus {
        stop(device)
    }

    func isDeviceRunning(_ device: KidoXMTDeviceRef?) -> Bool {
        isRunning(device)
    }

    func registerContactFrameCallback(_ device: KidoXMTDeviceRef?, _ callback: KidoXMTFrameCallback?) {
        registerCallback(device, callback)
    }

    func unregisterContactFrameCallback(_ device: KidoXMTDeviceRef?, _ callback: KidoXMTFrameCallback?) {
        unregisterCallback(device, callback)
    }

    func getDeviceID(_ device: KidoXMTDeviceRef?, _ id: UnsafeMutablePointer<UInt64>?) -> OSStatus {
        rawGetDeviceID?(device, id) ?? -1
    }

    func getFamilyID(_ device: KidoXMTDeviceRef?, _ familyID: UnsafeMutablePointer<CInt>?) -> OSStatus {
        rawGetFamilyID(device, familyID)
    }

    func getSensorSurfaceDimensions(
        _ device: KidoXMTDeviceRef?,
        _ width: UnsafeMutablePointer<CInt>?,
        _ height: UnsafeMutablePointer<CInt>?
    ) -> OSStatus {
        rawGetSensorSurfaceDimensions(device, width, height)
    }

    func isBuiltIn(_ device: KidoXMTDeviceRef?) -> Bool? {
        rawIsBuiltIn?(device)
    }

    private static func loadSymbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) -> T? {
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
}

private struct KidoXFourFingerPinchRecognizer {
    private let configuration: KidoXGlobalTrackpadGestureMonitor.Configuration
    private var trackedIDs: Set<CInt> = []
    private var startedAt: TimeInterval = 0
    private var baselineScale: CGFloat = 0
    private var baselineCentroid: CGPoint = .zero
    private var baselineRadii: [CInt: CGFloat] = [:]
    private var baselinePoints: [CInt: CGPoint] = [:]
    private var filteredScale: CGFloat = 0
    private var activeDirection: KidoXGlobalTrackpadGestureDirection?
    private var isSwipeLockedOut = false
    private var lastProgress: CGFloat = 0

    init(configuration: KidoXGlobalTrackpadGestureMonitor.Configuration) {
        self.configuration = configuration
    }

    mutating func consume(samples: [KidoXTrackpadSample], at time: TimeInterval) -> KidoXGlobalTrackpadGestureEvent? {
        guard samples.count == configuration.fingerCount else {
            let event = endEventIfNeeded()
            resetContact()
            return event
        }

        let sortedSamples = samples.sorted { $0.id < $1.id }
        let ids = Set(sortedSamples.map(\.id))
        if ids != trackedIDs {
            let event = endEventIfNeeded()
            beginContact(with: sortedSamples, at: time)
            return event
        }

        let currentScale = scale(for: sortedSamples)
        guard currentScale >= configuration.minimumBaselineScale else {
            resetContact()
            return nil
        }

        let currentCentroid = centroid(for: sortedSamples)
        guard time - startedAt >= configuration.requiredStableDuration else {
            return nil
        }

        let radialEvidence = radialEvidence(for: sortedSamples, currentCentroid: currentCentroid)
        let smoothing = min(max(configuration.scaleSmoothingFactor, 0), 1)
        filteredScale = (filteredScale * (1 - smoothing)) + (currentScale * smoothing)
        let scaleRatio = filteredScale / max(baselineScale, 0.0001)
        let drift = distance(from: baselineCentroid, to: currentCentroid)
        let maximumDrift = max(baselineScale * configuration.maximumCentroidDriftRatio, 0.020)
        let currentRadii = radii(for: sortedSamples, around: currentCentroid)
        let inwardCount = currentRadii.reduce(0) { partial, entry in
            guard let baselineRadius = baselineRadii[entry.key] else { return partial }
            return partial + (entry.value / max(baselineRadius, 0.0001) <= 0.985 ? 1 : 0)
        }
        let outwardCount = currentRadii.reduce(0) { partial, entry in
            guard let baselineRadius = baselineRadii[entry.key] else { return partial }
            return partial + (entry.value / max(baselineRadius, 0.0001) >= 1.015 ? 1 : 0)
        }

        let pinchInProgress = clampedProgress(
            (1 - scaleRatio) / max(1 - configuration.pinchInTriggerScaleRatio, 0.0001)
        )
        let spreadOutProgress = clampedProgress(
            (scaleRatio - 1) / max(configuration.spreadOutTriggerScaleRatio - 1, 0.0001)
        )
        let opennessDelta = scaleRatio <= 1 ? pinchInProgress : -spreadOutProgress

        guard !isSwipeLockedOut else { return nil }

        if activeDirection == nil,
           shouldLockOutAsSwipe(
               drift: drift,
               radialEvidence: radialEvidence
           ) {
            isSwipeLockedOut = true
            return nil
        }

        let candidate: (
            direction: KidoXGlobalTrackpadGestureDirection,
            progress: CGFloat,
            opennessDelta: CGFloat,
            participatingFingerCount: Int
        )?
        if pinchInProgress >= spreadOutProgress,
           isPinchLikeMotion(
               direction: .pinchIn,
               progress: pinchInProgress,
               drift: drift,
               maximumDrift: maximumDrift,
               radialProjection: radialEvidence.inwardProjection,
               tangentialMotion: radialEvidence.tangentialMotion
           ),
           radialEvidence.inwardCount >= requiredTrackingFingerCount(for: .pinchIn),
           inwardCount >= requiredTrackingFingerCount(for: .pinchIn),
           pinchInProgress > requiredProgressThreshold(for: .pinchIn) {
            candidate = (.pinchIn, pinchInProgress, opennessDelta, inwardCount)
        } else if spreadOutProgress > pinchInProgress,
                  isPinchLikeMotion(
                      direction: .spreadOut,
                      progress: spreadOutProgress,
                      drift: drift,
                      maximumDrift: maximumDrift,
                      radialProjection: radialEvidence.outwardProjection,
                      tangentialMotion: radialEvidence.tangentialMotion
                  ),
                  radialEvidence.outwardCount >= requiredTrackingFingerCount(for: .spreadOut),
                  outwardCount >= requiredTrackingFingerCount(for: .spreadOut),
                  spreadOutProgress > requiredProgressThreshold(for: .spreadOut) {
            candidate = (.spreadOut, spreadOutProgress, opennessDelta, outwardCount)
        } else {
            candidate = nil
        }

        guard let candidate else {
            if let activeDirection {
                lastProgress = max(0, abs(opennessDelta))
                return .changed(direction: activeDirection, progress: lastProgress, opennessDelta: opennessDelta)
            }
            return nil
        }

        if activeDirection != candidate.direction {
            activeDirection = candidate.direction
            lastProgress = candidate.progress
            return .began(candidate.direction)
        }

        lastProgress = candidate.progress

        return .changed(
            direction: candidate.direction,
            progress: candidate.progress,
            opennessDelta: candidate.opennessDelta
        )
    }

    private mutating func beginContact(with samples: [KidoXTrackpadSample], at time: TimeInterval) {
        trackedIDs = Set(samples.map(\.id))
        startedAt = time
        let initialScale = scale(for: samples)
        let initialCentroid = centroid(for: samples)
        baselineScale = initialScale
        baselineCentroid = initialCentroid
        baselineRadii = radii(for: samples, around: initialCentroid)
        baselinePoints = Dictionary(uniqueKeysWithValues: samples.map { ($0.id, $0.point) })
        filteredScale = initialScale
        activeDirection = nil
        isSwipeLockedOut = false
        lastProgress = 0
    }

    private mutating func resetContact() {
        trackedIDs = []
        startedAt = 0
        baselineScale = 0
        baselineCentroid = .zero
        baselineRadii = [:]
        baselinePoints = [:]
        filteredScale = 0
        activeDirection = nil
        isSwipeLockedOut = false
        lastProgress = 0
    }

    private func endEventIfNeeded() -> KidoXGlobalTrackpadGestureEvent? {
        guard let activeDirection else { return nil }
        return .committed(activeDirection)
    }

    private func clampedProgress(_ progress: CGFloat) -> CGFloat {
        min(max(progress, 0), 1)
    }

    private func requiredTrackingFingerCount(for direction: KidoXGlobalTrackpadGestureDirection) -> Int {
        if activeDirection == direction {
            return max(1, min(configuration.minimumTrackingFingerCount, configuration.fingerCount))
        }
        return max(1, min(configuration.minimumTrackingFingerCount, configuration.minimumParticipatingFingerCount))
    }

    private func requiredProgressThreshold(for direction: KidoXGlobalTrackpadGestureDirection) -> CGFloat {
        activeDirection == direction
            ? configuration.movementDeadZone
            : configuration.activationProgressThreshold
    }

    private func isPinchLikeMotion(
        direction: KidoXGlobalTrackpadGestureDirection,
        progress: CGFloat,
        drift: CGFloat,
        maximumDrift: CGFloat,
        radialProjection: CGFloat,
        tangentialMotion: CGFloat
    ) -> Bool {
        guard drift <= maximumDrift else { return false }
        guard activeDirection != nil else {
            let translationLimit = max(0.014, radialProjection * configuration.maximumActivationTranslationRatio)
            let minimumRadialProjection = baselineScale * configuration.minimumActivationRadialMotionRatio
            let maximumTangentialMotion = max(minimumRadialProjection, radialProjection * configuration.maximumActivationTangentialRatio)
            return progress >= configuration.activationProgressThreshold &&
                drift <= translationLimit &&
                radialProjection >= minimumRadialProjection &&
                tangentialMotion <= maximumTangentialMotion
        }
        return activeDirection == direction || progress >= configuration.activationProgressThreshold
    }

    private func shouldLockOutAsSwipe(
        drift: CGFloat,
        radialEvidence: (
            inwardCount: Int,
            outwardCount: Int,
            inwardProjection: CGFloat,
            outwardProjection: CGFloat,
            tangentialMotion: CGFloat
        )
    ) -> Bool {
        let minimumSwipeTranslation = max(0.018, baselineScale * configuration.swipeLockoutTranslationRatio)
        guard drift >= minimumSwipeTranslation else { return false }

        let strongestRadialProjection = max(radialEvidence.inwardProjection, radialEvidence.outwardProjection)
        let radialFloor = max(strongestRadialProjection, baselineScale * 0.006)
        return drift >= radialFloor * configuration.swipeLockoutTranslationDominanceRatio
    }

    private func radialEvidence(
        for samples: [KidoXTrackpadSample],
        currentCentroid: CGPoint
    ) -> (
        inwardCount: Int,
        outwardCount: Int,
        inwardProjection: CGFloat,
        outwardProjection: CGFloat,
        tangentialMotion: CGFloat
    ) {
        let translation = CGPoint(
            x: currentCentroid.x - baselineCentroid.x,
            y: currentCentroid.y - baselineCentroid.y
        )
        let minimumProjection = baselineScale * 0.010

        var inwardCount = 0
        var outwardCount = 0
        var inwardProjectionTotal: CGFloat = 0
        var outwardProjectionTotal: CGFloat = 0
        var tangentialTotal: CGFloat = 0

        for sample in samples {
            guard let baselinePoint = baselinePoints[sample.id] else { continue }
            let radialVector = CGPoint(
                x: baselinePoint.x - baselineCentroid.x,
                y: baselinePoint.y - baselineCentroid.y
            )
            let radialLength = max(hypot(radialVector.x, radialVector.y), 0.0001)
            let radialUnit = CGPoint(x: radialVector.x / radialLength, y: radialVector.y / radialLength)
            let residual = CGPoint(
                x: sample.point.x - baselinePoint.x - translation.x,
                y: sample.point.y - baselinePoint.y - translation.y
            )
            let projection = (residual.x * radialUnit.x) + (residual.y * radialUnit.y)
            let tangential = abs((residual.x * -radialUnit.y) + (residual.y * radialUnit.x))
            tangentialTotal += tangential

            if projection <= -minimumProjection {
                inwardCount += 1
                inwardProjectionTotal += -projection
            } else if projection >= minimumProjection {
                outwardCount += 1
                outwardProjectionTotal += projection
            }
        }

        let divisor = CGFloat(max(samples.count, 1))
        return (
            inwardCount,
            outwardCount,
            inwardProjectionTotal / divisor,
            outwardProjectionTotal / divisor,
            tangentialTotal / divisor
        )
    }

    private func scale(for samples: [KidoXTrackpadSample]) -> CGFloat {
        guard samples.count > 1 else { return 0 }
        var distances: [CGFloat] = []
        distances.reserveCapacity((samples.count * (samples.count - 1)) / 2)

        for index in samples.indices {
            for otherIndex in samples.indices where otherIndex > index {
                distances.append(distance(from: samples[index].point, to: samples[otherIndex].point))
            }
        }
        return median(distances)
    }

    private func centroid(for samples: [KidoXTrackpadSample]) -> CGPoint {
        let total = samples.reduce(CGPoint.zero) { partial, sample in
            CGPoint(x: partial.x + sample.point.x, y: partial.y + sample.point.y)
        }
        let divisor = CGFloat(max(samples.count, 1))
        return CGPoint(x: total.x / divisor, y: total.y / divisor)
    }

    private func radii(for samples: [KidoXTrackpadSample], around centroid: CGPoint) -> [CInt: CGFloat] {
        Dictionary(uniqueKeysWithValues: samples.map { sample in
            (sample.id, distance(from: sample.point, to: centroid))
        })
    }

    private func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func distance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}
