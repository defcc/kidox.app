import Foundation
import OSLog
import Security
import ServiceManagement

struct KidoXPrivilegedHelperClient: Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.clyapps.KidoX",
        category: "PrivilegedHelper"
    )

    func installHelper() throws {
        Self.logger.notice("Starting privileged helper install or update.")
        var authorizationRef: AuthorizationRef?
        let authorizationStatus = AuthorizationCreate(
            nil,
            nil,
            [.interactionAllowed, .extendRights, .preAuthorize],
            &authorizationRef
        )
        guard authorizationStatus == errAuthorizationSuccess, let authorizationRef else {
            Self.logger.error("Privileged helper authorization failed. status=\(authorizationStatus, privacy: .public)")
            throw KidoXPrivilegedHelperClientError.authorizationFailed(authorizationStatus)
        }
        defer {
            AuthorizationFree(authorizationRef, [])
        }

        var unmanagedError: Unmanaged<CFError>?
        let didBless = SMJobBless(
            kSMDomainSystemLaunchd,
            KidoXPrivilegedHelper.label as CFString,
            authorizationRef,
            &unmanagedError
        )

        if didBless {
            Self.logger.notice("Privileged helper installed or updated successfully.")
            return
        }

        let error = unmanagedError?.takeRetainedValue()
        if let error {
            Self.logger.error("Privileged helper install failed. \(CFErrorCopyDescription(error) as String, privacy: .public)")
        } else {
            Self.logger.error("Privileged helper install failed without CFError.")
        }
        throw KidoXPrivilegedHelperClientError.blessFailed(error)
    }

    func installedHelperVersion() async throws -> String {
        Self.logger.debug("Querying privileged helper version. label=\(KidoXPrivilegedHelper.label, privacy: .public)")
        let connection = makeConnection()
        defer {
            connection.invalidate()
        }

        return try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                Self.logger.error("Privileged helper version query XPC error. \(Self.errorSummary(error), privacy: .public)")
                continuation.resume(throwing: error)
            } as? KidoXPrivilegedHelperProtocol

            guard let proxy else {
                Self.logger.error("Privileged helper version query failed because the XPC proxy is invalid.")
                continuation.resume(throwing: KidoXPrivilegedHelperClientError.invalidProxy)
                return
            }

            proxy.getVersion { version in
                Self.logger.notice("Privileged helper version query succeeded. installedVersion=\(version, privacy: .public) bundledVersion=\(KidoXPrivilegedHelper.version, privacy: .public)")
                continuation.resume(returning: version)
            }
        }
    }

    func moveApplicationToTrash(_ appURL: URL) async throws -> URL {
        Self.logger.notice("Requesting privileged helper app move. source='\(appURL.path, privacy: .public)'")
        let connection = makeConnection()
        defer {
            connection.invalidate()
        }

        return try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                Self.logger.error("Privileged helper app move XPC error. source='\(appURL.path, privacy: .public)' \(Self.errorSummary(error), privacy: .public)")
                continuation.resume(throwing: error)
            } as? KidoXPrivilegedHelperProtocol

            guard let proxy else {
                Self.logger.error("Privileged helper app move failed because the XPC proxy is invalid.")
                continuation.resume(throwing: KidoXPrivilegedHelperClientError.invalidProxy)
                return
            }

            proxy.moveApplicationToTrash(appURL.path) { didMove, destinationPath, errorDescription in
                if didMove, let destinationPath {
                    Self.logger.notice("Privileged helper app move succeeded. source='\(appURL.path, privacy: .public)' destination='\(destinationPath, privacy: .public)'")
                    continuation.resume(returning: URL(fileURLWithPath: destinationPath))
                    return
                }

                Self.logger.error("Privileged helper app move failed. source='\(appURL.path, privacy: .public)' reason=\(errorDescription ?? "<missing>", privacy: .public)")
                continuation.resume(throwing: KidoXPrivilegedHelperClientError.moveFailed(
                    errorDescription ?? "Privileged helper did not move the app."
                ))
            }
        }
    }

    func removeItems(at urls: [URL]) async throws -> (removed: [URL], failed: [URL: String]) {
        let paths = urls.map(\.path)
        Self.logger.notice("Requesting privileged helper data removal. itemCount=\(paths.count, privacy: .public)")

        let connection = makeConnection()
        defer {
            connection.invalidate()
        }

        return try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                Self.logger.error("Privileged helper data removal XPC error. \(Self.errorSummary(error), privacy: .public)")
                continuation.resume(throwing: error)
            } as? KidoXPrivilegedHelperProtocol

            guard let proxy else {
                Self.logger.error("Privileged helper data removal failed because the XPC proxy is invalid.")
                continuation.resume(throwing: KidoXPrivilegedHelperClientError.invalidProxy)
                return
            }

            proxy.removeItems(paths) { removedPaths, failedPaths in
                Self.logger.notice(
                    "Privileged helper data removal finished. removed=\(removedPaths.count, privacy: .public) failed=\(failedPaths.count, privacy: .public)"
                )
                continuation.resume(returning: (
                    removed: removedPaths.map { URL(fileURLWithPath: $0) },
                    failed: Dictionary(uniqueKeysWithValues: failedPaths.map {
                        (URL(fileURLWithPath: $0.key), $0.value)
                    })
                ))
            }
        }
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: KidoXPrivilegedHelper.label,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: KidoXPrivilegedHelperProtocol.self)
        connection.resume()
        return connection
    }

    private static func errorSummary(_ error: Error) -> String {
        let nsError = error as NSError
        return "domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)"
    }
}

enum KidoXPrivilegedHelperClientError: LocalizedError {
    case authorizationFailed(OSStatus)
    case blessFailed(CFError?)
    case invalidProxy
    case moveFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationFailed(let status):
            "Administrator authorization failed with status \(status)."
        case .blessFailed(let error):
            error.map { CFErrorCopyDescription($0) as String } ?? "Could not install the privileged helper."
        case .invalidProxy:
            "Could not connect to the privileged helper."
        case .moveFailed(let reason):
            reason
        }
    }
}
