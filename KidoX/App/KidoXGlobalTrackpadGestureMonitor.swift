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

enum KidoXGlobalTrackpadGestureAction {
    case pinchIn
    case spreadOut
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
        var pinchInTriggerScaleRatio: CGFloat = 0.88
        var spreadOutTriggerScaleRatio: CGFloat = 1.12
        var minimumParticipatingFingerCount = 3
        var requiredStableDuration: TimeInterval = 0.025
        var requiredConsecutiveMatches = 2
        var cooldownDuration: TimeInterval = 0.65
        var minimumBaselineScale: CGFloat = 0.10
        var maximumCentroidDriftRatio: CGFloat = 0.56
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

    private let onTrigger: @MainActor (KidoXGlobalTrackpadGestureAction) -> Void
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
        onTrigger: @escaping @MainActor (KidoXGlobalTrackpadGestureAction) -> Void
    ) {
        self.configuration = configuration
        self.onTrigger = onTrigger
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
        var triggeredAction: KidoXGlobalTrackpadGestureAction?

        lock.lock()
        if isListening {
            let deviceID = deviceIDsByPointer[UInt(bitPattern: device)] ?? UInt64(UInt(bitPattern: device))
            var recognizer = recognizers[deviceID] ?? KidoXFourFingerPinchRecognizer(configuration: configuration)
            triggeredAction = recognizer.consume(samples: samples, at: now)
            recognizers[deviceID] = recognizer
        }
        lock.unlock()

        guard let triggeredAction else { return }
        Task { @MainActor [onTrigger] in
            onTrigger(triggeredAction)
        }
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
    private var cooldownUntil: TimeInterval = 0
    private var baselineScale: CGFloat = 0
    private var baselineCentroid: CGPoint = .zero
    private var baselineRadii: [CInt: CGFloat] = [:]
    private var filteredScale: CGFloat = 0
    private var consecutiveMatches = 0
    private var pendingAction: KidoXGlobalTrackpadGestureAction?
    private var didTriggerCurrentContact = false

    init(configuration: KidoXGlobalTrackpadGestureMonitor.Configuration) {
        self.configuration = configuration
    }

    mutating func consume(samples: [KidoXTrackpadSample], at time: TimeInterval) -> KidoXGlobalTrackpadGestureAction? {
        guard time >= cooldownUntil else { return nil }
        guard samples.count == configuration.fingerCount else {
            resetContact()
            return nil
        }

        let sortedSamples = samples.sorted { $0.id < $1.id }
        let ids = Set(sortedSamples.map(\.id))
        if ids != trackedIDs {
            beginContact(with: sortedSamples, at: time)
            return nil
        }

        guard !didTriggerCurrentContact else { return nil }

        let currentScale = scale(for: sortedSamples)
        guard currentScale >= configuration.minimumBaselineScale else {
            resetContact()
            return nil
        }

        let currentCentroid = centroid(for: sortedSamples)
        guard time - startedAt >= configuration.requiredStableDuration else {
            return nil
        }

        filteredScale = (filteredScale * 0.45) + (currentScale * 0.55)
        let scaleRatio = filteredScale / max(baselineScale, 0.0001)
        let drift = distance(from: baselineCentroid, to: currentCentroid)
        let maximumDrift = max(baselineScale * configuration.maximumCentroidDriftRatio, 0.035)
        let currentRadii = radii(for: sortedSamples, around: currentCentroid)
        let inwardCount = currentRadii.reduce(0) { partial, entry in
            guard let baselineRadius = baselineRadii[entry.key] else { return partial }
            return partial + (entry.value / max(baselineRadius, 0.0001) <= 0.985 ? 1 : 0)
        }
        let outwardCount = currentRadii.reduce(0) { partial, entry in
            guard let baselineRadius = baselineRadii[entry.key] else { return partial }
            return partial + (entry.value / max(baselineRadius, 0.0001) >= 1.015 ? 1 : 0)
        }

        let action: KidoXGlobalTrackpadGestureAction?
        if scaleRatio <= configuration.pinchInTriggerScaleRatio,
           drift <= maximumDrift,
           inwardCount >= configuration.minimumParticipatingFingerCount {
            action = .pinchIn
        } else if scaleRatio >= configuration.spreadOutTriggerScaleRatio,
                  drift <= maximumDrift,
                  outwardCount >= configuration.minimumParticipatingFingerCount {
            action = .spreadOut
        } else {
            action = nil
        }

        updateConsecutiveMatches(for: action)

        guard let pendingAction,
              consecutiveMatches >= configuration.requiredConsecutiveMatches
        else { return nil }

        didTriggerCurrentContact = true
        cooldownUntil = time + configuration.cooldownDuration
        return pendingAction
    }

    private mutating func beginContact(with samples: [KidoXTrackpadSample], at time: TimeInterval) {
        trackedIDs = Set(samples.map(\.id))
        startedAt = time
        let initialScale = scale(for: samples)
        let initialCentroid = centroid(for: samples)
        baselineScale = initialScale
        baselineCentroid = initialCentroid
        baselineRadii = radii(for: samples, around: initialCentroid)
        filteredScale = initialScale
        consecutiveMatches = 0
        pendingAction = nil
        didTriggerCurrentContact = false
    }

    private mutating func resetContact() {
        trackedIDs = []
        startedAt = 0
        baselineScale = 0
        baselineCentroid = .zero
        baselineRadii = [:]
        filteredScale = 0
        consecutiveMatches = 0
        pendingAction = nil
        didTriggerCurrentContact = false
    }

    private mutating func updateConsecutiveMatches(for action: KidoXGlobalTrackpadGestureAction?) {
        guard let action else {
            pendingAction = nil
            consecutiveMatches = 0
            return
        }

        if pendingAction == action {
            consecutiveMatches += 1
        } else {
            pendingAction = action
            consecutiveMatches = 1
        }
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
