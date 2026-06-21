import AppKit
import CryptoKit
import Foundation
import IOKit

struct ClyAppLicenseService {
    static let shared = ClyAppLicenseService()
    static let validationInterval: TimeInterval = 24 * 60 * 60

    private let endpoint = KidoXAppConfiguration.licenseEndpointURL
    private let urlSession = URLSession.shared
    private let maxConsecutiveTransientValidationFailures = 7
    private let requestTimeout: TimeInterval = 10
    private let transientRetryDelays: [Duration] = [
        .seconds(5 * 60),
        .seconds(10 * 60),
        .seconds(30 * 60),
        .seconds(60 * 60),
        .seconds(2 * 60 * 60)
    ]

    func activate(licenseKey: String) async throws -> LicenseActivationResult {
        let bundleID = licensedBundleIdentifier
        let serialNumber = hardwareSerialNumber()
        let request = LicenseActivationRequest(
            bundleID: bundleID,
            licenseKey: licenseKey,
            deviceHash: deviceHash(for: bundleID, serialNumber: serialNumber),
            serialNumber: serialNumber,
            deviceName: Host.current().localizedName ?? "Mac",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        )

        var urlRequest = URLRequest(url: endpoint.appending(path: "/api/licenses/activate"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = requestTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await urlSession.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LicenseActivationError.invalidResponse
        }

        let decoder = JSONDecoder()
        if (200..<300).contains(httpResponse.statusCode) {
            let payload = try decoder.decode(LicenseActivationResponse.self, from: data)
            guard payload.ok else {
                throw LicenseActivationError.serverMessage(payload.error?.message ?? "Activation failed.")
            }
            guard let receipt = payload.receipt else {
                throw LicenseActivationError.invalidReceipt
            }
            let verifiedReceipt = try ClyLicenseReceiptVerifier.verify(
                receipt,
                expectedBundleID: bundleID,
                expectedDeviceHash: request.deviceHash
            )
            guard let receiptLicenseKey = verifiedReceipt.licenseKey,
                  receiptLicenseKey == canonicalLicenseKey(licenseKey) else {
                throw LicenseActivationError.invalidReceipt
            }
            ClyLicenseLocalStore.save(licenseKey: receiptLicenseKey, receipt: receipt)
            ClyLicenseLocalStore.markSuccessfulValidation()
            ClyLicenseLocalStore.resetTransientValidationFailures()
            applyLocalLicenseState(verifiedReceipt, defaults: UserDefaults.standard)
            return LicenseActivationResult(
                bundleID: verifiedReceipt.bundleID,
                status: verifiedReceipt.status,
                plan: verifiedReceipt.plan,
                activationID: verifiedReceipt.activationID ?? "",
                licensePrefix: licenseKeyPrefix(receiptLicenseKey)
            )
        }

        if let errorPayload = try? decoder.decode(LicenseActivationResponse.self, from: data),
           let message = errorPayload.error?.message {
            throw LicenseActivationError.serverMessage(message)
        }

        throw LicenseActivationError.serverMessage("Activation failed with HTTP \(httpResponse.statusCode).")
    }

    func deactivateStoredLicense() async throws {
        guard let receipt = ClyLicenseLocalStore.receipt() else {
            ClyLicenseLocalStore.delete()
            await startTrialIfNeeded()
            return
        }

        let request = LicenseDeactivationRequest(receipt: receipt)
        var urlRequest = URLRequest(url: endpoint.appending(path: "/api/licenses/deactivate"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = requestTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await urlSession.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LicenseActivationError.invalidResponse
        }

        if (200..<300).contains(httpResponse.statusCode) {
            ClyLicenseLocalStore.delete()
            await startTrialIfNeeded()
            return
        }

        if httpResponse.statusCode == 404 {
            ClyLicenseLocalStore.delete()
            await startTrialIfNeeded()
            return
        }

        if let errorPayload = try? JSONDecoder().decode(LicenseDeactivationResponse.self, from: data),
           let message = errorPayload.error?.message {
            throw LicenseActivationError.serverMessage(message)
        }

        throw LicenseActivationError.serverMessage("Deactivation failed with HTTP \(httpResponse.statusCode).")
    }

    func restoreLocalLicenseState() {
        let defaults = UserDefaults.standard
        guard let receipt = ClyLicenseLocalStore.receipt() else {
            clearLocalLicenseState(defaults: defaults)
            return
        }

        do {
            let bundleID = licensedBundleIdentifier
            let verifiedReceipt = try ClyLicenseReceiptVerifier.verify(
                receipt,
                expectedBundleID: bundleID,
                expectedDeviceHash: currentDeviceHash(for: bundleID),
                allowExpired: true
            )
            restoreTrustedReceiptState(verifiedReceipt, defaults: defaults, now: Date())
        } catch {
            clearLocalLicenseState(defaults: defaults)
        }
    }

    func validateStoredLicenseIfNeeded(force: Bool = false) async {
        guard let receipt = ClyLicenseLocalStore.receipt() else {
            await startTrialIfNeeded()
            return
        }

        let bundleID = licensedBundleIdentifier
        let currentReceipt: ClyLicenseReceiptPayload
        do {
            currentReceipt = try ClyLicenseReceiptVerifier.verify(
                receipt,
                expectedBundleID: bundleID,
                expectedDeviceHash: currentDeviceHash(for: bundleID),
                allowExpired: true
            )
        } catch {
            clearLocalLicenseState(defaults: UserDefaults.standard)
            await startTrialIfNeeded()
            return
        }

        let now = Date()
        guard force || shouldAttemptValidation(now: now) else {
            restoreTrustedReceiptState(currentReceipt, defaults: UserDefaults.standard, now: now)
            return
        }
        ClyLicenseLocalStore.markValidationAttempt()

        do {
            let refreshedReceipt = try await validateStoredLicenseWithRetry(receipt: receipt, currentReceipt: currentReceipt)
            let verifiedReceipt = try ClyLicenseReceiptVerifier.verify(
                refreshedReceipt,
                expectedBundleID: bundleID,
                expectedDeviceHash: currentDeviceHash(for: bundleID)
            )
            ClyLicenseLocalStore.save(licenseKey: verifiedReceipt.licenseKey, receipt: refreshedReceipt)
            ClyLicenseLocalStore.markSuccessfulValidation()
            ClyLicenseLocalStore.resetTransientValidationFailures()
            applyLocalLicenseState(verifiedReceipt, defaults: UserDefaults.standard)
        } catch let error as LicenseValidationFailure {
            switch error {
            case .permanent:
                clearLocalLicenseState(defaults: UserDefaults.standard)
                if !currentReceipt.isTrial {
                    await startTrialIfNeeded()
                }
            case .transient:
                let failures = ClyLicenseLocalStore.incrementTransientValidationFailures()
                restoreTrustedReceiptState(currentReceipt, defaults: UserDefaults.standard, now: now, transientFailureCount: failures)
            }
        } catch {
            let failures = ClyLicenseLocalStore.incrementTransientValidationFailures()
            restoreTrustedReceiptState(currentReceipt, defaults: UserDefaults.standard, now: now, transientFailureCount: failures)
        }
    }

    func nextValidationDelay(now: Date = Date()) -> TimeInterval {
        guard let receipt = ClyLicenseLocalStore.receipt() else {
            return Self.validationInterval
        }

        let bundleID = licensedBundleIdentifier
        guard let currentReceipt = try? ClyLicenseReceiptVerifier.verify(
            receipt,
            expectedBundleID: bundleID,
            expectedDeviceHash: currentDeviceHash(for: bundleID),
            allowExpired: true
        ) else {
            return 0
        }

        guard currentReceipt.isTrial,
              let expiryDate = ClyLicenseReceiptVerifier.date(from: currentReceipt.expiresAt) else {
            return Self.validationInterval
        }

        let secondsUntilExpiry = expiryDate.timeIntervalSince(now)
        if secondsUntilExpiry <= 0 {
            return 0
        }

        return min(Self.validationInterval, secondsUntilExpiry + 1)
    }

    var licensedBundleIdentifier: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.clyapps.KidoX"
        if bundleID.hasSuffix(".Agent") {
            return String(bundleID.dropLast(".Agent".count))
        }
        return bundleID
    }

    private func currentDeviceHash(for bundleID: String) -> String {
        deviceHash(for: bundleID, serialNumber: hardwareSerialNumber())
    }

    private func deviceHash(for bundleID: String, serialNumber: String?) -> String {
        let defaultsKey = "ClyAppLicenseManager.deviceID"
        let defaults = UserDefaults.standard
        let deviceID: String
        if let existing = defaults.string(forKey: defaultsKey) {
            deviceID = existing
        } else if let serialNumber {
            deviceID = "serial:\(serialNumber)"
            defaults.set(deviceID, forKey: defaultsKey)
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: defaultsKey)
        }

        let digest = SHA256.hash(data: Data("\(bundleID):\(deviceID)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func hardwareSerialNumber() -> String? {
        let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard platformExpert != 0 else { return nil }
        defer { IOObjectRelease(platformExpert) }

        let serialValue = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformSerialNumberKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String

        let serialNumber = serialValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return serialNumber?.isEmpty == false ? serialNumber : nil
    }

    private func licenseKeyPrefix(_ licenseKey: String) -> String {
        let filtered = licenseKey
            .uppercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(filtered).prefix(8))
    }

    private func canonicalLicenseKey(_ licenseKey: String) -> String {
        licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func shouldAttemptValidation(now: Date) -> Bool {
        guard let lastAttemptAt = ClyLicenseLocalStore.lastValidationAttemptAt() else { return true }
        return now.timeIntervalSince(lastAttemptAt) >= Self.validationInterval
    }

    private func startTrialIfNeeded() async {
        guard ClyLicenseLocalStore.receipt() == nil else { return }

        do {
            let receipt = try await startTrial()
            let bundleID = licensedBundleIdentifier
            let verifiedReceipt = try ClyLicenseReceiptVerifier.verify(
                receipt,
                expectedBundleID: bundleID,
                expectedDeviceHash: currentDeviceHash(for: bundleID)
            )
            guard verifiedReceipt.isTrial else {
                throw LicenseActivationError.invalidReceipt
            }
            ClyLicenseLocalStore.save(licenseKey: nil, receipt: receipt)
            ClyLicenseLocalStore.markSuccessfulValidation()
            ClyLicenseLocalStore.resetTransientValidationFailures()
            applyLocalLicenseState(verifiedReceipt, defaults: UserDefaults.standard)
        } catch {
            clearLocalLicenseState(defaults: UserDefaults.standard)
        }
    }

    private func startTrial() async throws -> String {
        let bundleID = licensedBundleIdentifier
        let serialNumber = hardwareSerialNumber()
        let request = TrialStartRequest(
            bundleID: bundleID,
            deviceHash: deviceHash(for: bundleID, serialNumber: serialNumber),
            serialNumber: serialNumber,
            deviceName: Host.current().localizedName ?? "Mac",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        )

        var urlRequest = URLRequest(url: endpoint.appending(path: "/api/trials/start"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = requestTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await urlSession.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LicenseActivationError.invalidResponse
        }

        let decoder = JSONDecoder()
        if (200..<300).contains(httpResponse.statusCode) {
            let payload = try decoder.decode(TrialStartResponse.self, from: data)
            guard payload.ok else {
                throw LicenseActivationError.serverMessage(payload.error?.message ?? "Trial activation failed.")
            }
            guard let receipt = payload.receipt else {
                throw LicenseActivationError.serverMessage("Trial has expired.")
            }
            return receipt
        }

        if let errorPayload = try? decoder.decode(TrialStartResponse.self, from: data),
           let message = errorPayload.error?.message {
            throw LicenseActivationError.serverMessage(message)
        }

        throw LicenseActivationError.serverMessage("Trial activation failed with HTTP \(httpResponse.statusCode).")
    }

    private func validateStoredLicense(receipt: String, currentReceipt: ClyLicenseReceiptPayload) async throws -> String {
        let request = LicenseValidationRequest(
            receipt: receipt,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        )

        let validationPath = currentReceipt.isTrial ? "/api/trials/validate" : "/api/licenses/validate"
        var urlRequest = URLRequest(url: endpoint.appending(path: validationPath))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = requestTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await urlSession.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LicenseValidationFailure.transient
        }

        let decoder = JSONDecoder()
        if (200..<300).contains(httpResponse.statusCode) {
            let payload = try decoder.decode(LicenseActivationResponse.self, from: data)
            guard payload.ok, let receipt = payload.receipt else {
                throw LicenseValidationFailure.transient
            }
            return receipt
        }

        if [400, 401, 403, 404, 409].contains(httpResponse.statusCode) {
            throw LicenseValidationFailure.permanent
        }

        throw LicenseValidationFailure.transient
    }

    private func validateStoredLicenseWithRetry(receipt: String, currentReceipt: ClyLicenseReceiptPayload) async throws -> String {
        do {
            return try await validateStoredLicense(receipt: receipt, currentReceipt: currentReceipt)
        } catch LicenseValidationFailure.permanent {
            throw LicenseValidationFailure.permanent
        } catch {
            for delay in transientRetryDelays {
                do {
                    try await Task.sleep(for: delay)
                    return try await validateStoredLicense(receipt: receipt, currentReceipt: currentReceipt)
                } catch LicenseValidationFailure.permanent {
                    throw LicenseValidationFailure.permanent
                } catch is CancellationError {
                    throw LicenseValidationFailure.transient
                } catch {
                    continue
                }
            }

            throw LicenseValidationFailure.transient
        }
    }

    private func restoreTrustedReceiptState(
        _ receipt: ClyLicenseReceiptPayload,
        defaults: UserDefaults,
        now: Date,
        transientFailureCount: Int? = nil
    ) {
        guard let expiresAt = ClyLicenseReceiptVerifier.date(from: receipt.expiresAt) else {
            clearLocalLicenseState(defaults: defaults)
            return
        }

        if expiresAt > now {
            ClyLicenseLocalStore.resetTransientValidationFailures()
            applyLocalLicenseState(receipt, defaults: defaults)
            return
        }

        if receipt.isTrial {
            clearLocalLicenseState(defaults: defaults)
            return
        }

        let failures = transientFailureCount ?? ClyLicenseLocalStore.transientValidationFailureCount()
        if failures <= maxConsecutiveTransientValidationFailures {
            applyLocalLicenseState(receipt, defaults: defaults)
        } else {
            clearLocalLicenseState(defaults: defaults)
        }
    }

    private func applyLocalLicenseState(_ receipt: ClyLicenseReceiptPayload, defaults: UserDefaults) {
        defaults.set(receipt.status, forKey: "ClyAppLicense.status")
        defaults.set(receipt.plan, forKey: "ClyAppLicense.plan")
        defaults.set(receipt.entitlementType, forKey: "ClyAppLicense.entitlementType")
        defaults.set(receipt.activationID ?? "", forKey: "ClyAppLicense.activationID")
        defaults.set(receipt.licenseKey.map(licenseKeyPrefix) ?? "", forKey: "ClyAppLicense.licensePrefix")
        defaults.set(receipt.licenseKey ?? "", forKey: "ClyAppLicense.licenseKey")
        defaults.set(receipt.trialStartedAt ?? "", forKey: "ClyAppLicense.trialStartedAt")
        defaults.set(receipt.trialEndsAt ?? "", forKey: "ClyAppLicense.trialEndsAt")
    }

    private func clearLocalLicenseState(defaults: UserDefaults) {
        defaults.set("Free", forKey: "ClyAppLicense.status")
        defaults.set("Free", forKey: "ClyAppLicense.plan")
        defaults.set("", forKey: "ClyAppLicense.activationID")
        defaults.set("", forKey: "ClyAppLicense.licensePrefix")
        defaults.set("", forKey: "ClyAppLicense.licenseKey")
        defaults.set("", forKey: "ClyAppLicense.entitlementType")
        defaults.set("", forKey: "ClyAppLicense.trialStartedAt")
        defaults.set("", forKey: "ClyAppLicense.trialEndsAt")
        ClyLicenseLocalStore.delete()
    }
}

struct LicenseActivationResult {
    let bundleID: String
    let status: String
    let plan: String
    let activationID: String
    let licensePrefix: String
}

enum LicenseActivationError: LocalizedError {
    case invalidResponse
    case invalidReceipt
    case serverMessage(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The license server returned an invalid response."
        case .invalidReceipt:
            "The license server returned an invalid license receipt."
        case .serverMessage(let message):
            message
        }
    }
}

private struct LicenseActivationRequest: Encodable {
    let bundleID: String
    let licenseKey: String
    let deviceHash: String
    let serialNumber: String?
    let deviceName: String
    let appVersion: String

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case licenseKey = "license_key"
        case deviceHash = "device_hash"
        case serialNumber = "serial_number"
        case deviceName = "device_name"
        case appVersion = "app_version"
    }
}

private struct TrialStartRequest: Encodable {
    let bundleID: String
    let deviceHash: String
    let serialNumber: String?
    let deviceName: String
    let appVersion: String

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case deviceHash = "device_hash"
        case serialNumber = "serial_number"
        case deviceName = "device_name"
        case appVersion = "app_version"
    }
}

private struct LicenseValidationRequest: Encodable {
    let receipt: String
    let appVersion: String

    enum CodingKeys: String, CodingKey {
        case receipt
        case appVersion = "app_version"
    }
}

private struct LicenseDeactivationRequest: Encodable {
    let receipt: String
}

private struct LicenseActivationResponse: Decodable {
    let ok: Bool
    let receipt: String?
    let error: ErrorPayload?

    struct ErrorPayload: Decodable {
        let message: String
    }
}

private struct TrialStartResponse: Decodable {
    let ok: Bool
    let receipt: String?
    let error: ErrorPayload?

    struct ErrorPayload: Decodable {
        let message: String
    }
}

private struct LicenseDeactivationResponse: Decodable {
    let ok: Bool
    let error: ErrorPayload?

    struct ErrorPayload: Decodable {
        let message: String
    }
}

private enum LicenseValidationFailure: Error {
    case permanent
    case transient
}

private enum ClyLicenseLocalStore {
    private static let licenseKeyDefaultsKey = "ClyAppLicense.licenseKey"
    private static let receiptDefaultsKey = "ClyAppLicense.receipt"
    private static let lastSuccessfulValidationAtDefaultsKey = "ClyAppLicense.lastSuccessfulValidationAt"
    private static let lastValidationAttemptAtDefaultsKey = "ClyAppLicense.lastValidationAttemptAt"
    private static let transientValidationFailureCountDefaultsKey = "ClyAppLicense.transientValidationFailureCount"

    static func save(licenseKey: String?, receipt: String) {
        if let licenseKey, !licenseKey.isEmpty {
            UserDefaults.standard.set(licenseKey, forKey: licenseKeyDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: licenseKeyDefaultsKey)
        }
        UserDefaults.standard.set(receipt, forKey: receiptDefaultsKey)
    }

    static func receipt() -> String? {
        let value = UserDefaults.standard.string(forKey: receiptDefaultsKey) ?? ""
        return value.isEmpty ? nil : value
    }

    static func delete() {
        UserDefaults.standard.removeObject(forKey: licenseKeyDefaultsKey)
        UserDefaults.standard.removeObject(forKey: receiptDefaultsKey)
        UserDefaults.standard.removeObject(forKey: lastSuccessfulValidationAtDefaultsKey)
        UserDefaults.standard.removeObject(forKey: lastValidationAttemptAtDefaultsKey)
        UserDefaults.standard.removeObject(forKey: transientValidationFailureCountDefaultsKey)
    }

    static func markSuccessfulValidation() {
        UserDefaults.standard.set(Date(), forKey: lastSuccessfulValidationAtDefaultsKey)
    }

    static func lastValidationAttemptAt() -> Date? {
        UserDefaults.standard.object(forKey: lastValidationAttemptAtDefaultsKey) as? Date
    }

    static func markValidationAttempt() {
        UserDefaults.standard.set(Date(), forKey: lastValidationAttemptAtDefaultsKey)
    }

    static func transientValidationFailureCount() -> Int {
        UserDefaults.standard.integer(forKey: transientValidationFailureCountDefaultsKey)
    }

    static func incrementTransientValidationFailures() -> Int {
        let next = transientValidationFailureCount() + 1
        UserDefaults.standard.set(next, forKey: transientValidationFailureCountDefaultsKey)
        return next
    }

    static func resetTransientValidationFailures() {
        UserDefaults.standard.removeObject(forKey: transientValidationFailureCountDefaultsKey)
    }
}

private struct ClyLicenseReceiptPayload: Decodable {
    let version: Int
    let entitlementTypeValue: String?
    let licenseID: String?
    let licenseKey: String?
    let bundleID: String
    let activationID: String?
    let trialID: String?
    let deviceHash: String
    let status: String
    let plan: String
    let issuedAt: String
    let expiresAt: String
    let trialStartedAt: String?
    let trialEndsAt: String?

    var entitlementType: String {
        entitlementTypeValue ?? "license"
    }

    var isTrial: Bool {
        entitlementType == "trial"
    }

    enum CodingKeys: String, CodingKey {
        case version
        case entitlementTypeValue = "entitlement_type"
        case licenseID = "license_id"
        case licenseKey = "license_key"
        case bundleID = "bundle_id"
        case activationID = "activation_id"
        case trialID = "trial_id"
        case deviceHash = "device_hash"
        case status
        case plan
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
        case trialStartedAt = "trial_started_at"
        case trialEndsAt = "trial_ends_at"
    }
}

private enum ClyLicenseReceiptVerifier {
    static func verify(
        _ receipt: String,
        expectedBundleID: String,
        expectedDeviceHash: String,
        allowExpired: Bool = false
    ) throws -> ClyLicenseReceiptPayload {
        let parts = receipt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "v1",
              let payloadData = Data(base64URLEncoded: parts[1]),
              let signatureData = Data(base64URLEncoded: parts[2]),
              let publicKeyData = Data(base64Encoded: KidoXAppConfiguration.licenseReceiptPublicKey) else {
            throw LicenseActivationError.invalidReceipt
        }

        let publicKey = try P256.Signing.PublicKey(x963Representation: publicKeyData)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard publicKey.isValidSignature(signature, for: signingInput) else {
            throw LicenseActivationError.invalidReceipt
        }

        let payload = try JSONDecoder().decode(ClyLicenseReceiptPayload.self, from: payloadData)
        guard payload.version == 1,
              payload.bundleID == expectedBundleID,
              payload.deviceHash == expectedDeviceHash,
              payload.status == "active",
              (payload.isTrial ? payload.trialID != nil : (payload.licenseID != nil && payload.licenseKey != nil && payload.activationID != nil)),
              let expiryDate = date(from: payload.expiresAt),
              allowExpired || expiryDate > Date() else {
            throw LicenseActivationError.invalidReceipt
        }

        return payload
    }

    static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: 4 - padding)
        }
        self.init(base64Encoded: base64)
    }
}
