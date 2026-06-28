import Foundation
import Security
import SystemConfiguration
import os.log

private let logger = Logger(
    subsystem: KidoXPrivilegedHelper.label,
    category: "Helper"
)

final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard ClientCodeRequirementValidator.isValidClient(pid: newConnection.processIdentifier) else {
            logger.error("Rejected XPC connection from pid \(newConnection.processIdentifier, privacy: .public)")
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: KidoXPrivilegedHelperProtocol.self)
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        logger.info("Accepted XPC connection from pid \(newConnection.processIdentifier, privacy: .public)")
        return true
    }
}

final class HelperService: NSObject, KidoXPrivilegedHelperProtocol {
    func getVersion(reply: @escaping (String) -> Void) {
        reply(KidoXPrivilegedHelper.version)
    }

    func moveApplicationToTrash(_ appPath: String, withReply reply: @escaping (Bool, String?, String?) -> Void) {
        do {
            let destinationURL = try ApplicationMover.moveApplicationToTrash(appPath: appPath)
            logger.notice("Moved app to Trash: source='\(appPath, privacy: .public)' destination='\(destinationURL.path, privacy: .public)'")
            reply(true, destinationURL.path, nil)
        } catch {
            let nsError = error as NSError
            logger.error("Failed to move app to Trash: source='\(appPath, privacy: .public)' domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .public)")
            reply(false, nil, nsError.localizedDescription)
        }
    }

    func removeItems(_ paths: [String], withReply reply: @escaping ([String], [String: String]) -> Void) {
        var removedPaths: [String] = []
        var failedPaths: [String: String] = [:]

        for path in paths {
            do {
                try ApplicationMover.removeUserDataItem(path: path)
                removedPaths.append(path)
                logger.notice("Removed user data item: path='\(path, privacy: .public)'")
            } catch {
                let nsError = error as NSError
                failedPaths[path] = nsError.localizedDescription
                logger.error("Failed to remove user data item: path='\(path, privacy: .public)' domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .public)")
            }
        }

        logger.notice("Finished user data removal. removed=\(removedPaths.count, privacy: .public) failed=\(failedPaths.count, privacy: .public)")
        reply(removedPaths, failedPaths)
    }
}

enum ClientCodeRequirementValidator {
    private static let requirementString = "identifier \"com.clyapps.KidoX\" and anchor apple generic and certificate leaf[subject.OU] = \"LCR49HJMTK\""

    static func isValidClient(pid: pid_t) -> Bool {
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(requirementString as CFString, [], &requirement)
        guard requirementStatus == errSecSuccess, let requirement else {
            logger.error("Could not create client code requirement. status=\(statusSummary(requirementStatus), privacy: .public) requirement='\(requirementString, privacy: .public)'")
            return false
        }

        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: pid)
        ] as CFDictionary

        var code: SecCode?
        let copyStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard copyStatus == errSecSuccess, let code else {
            logger.error("Could not copy SecCode for pid \(pid, privacy: .public). status=\(statusSummary(copyStatus), privacy: .public)")
            return false
        }

        let checkStatus = SecCodeCheckValidity(code, [], requirement)
        if checkStatus != errSecSuccess {
            logger.error("Client code requirement failed for pid \(pid, privacy: .public). status=\(statusSummary(checkStatus), privacy: .public) requirement='\(requirementString, privacy: .public)' client=\(signingSummary(for: code), privacy: .public)")
        }
        return checkStatus == errSecSuccess
    }

    private static func statusSummary(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "\(status) (\(message))"
        }
        return "\(status)"
    }

    private static func signingSummary(for code: SecCode) -> String {
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            return "staticCodeStatus=\(statusSummary(staticStatus))"
        }

        var signingInfo: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        )
        guard infoStatus == errSecSuccess, let signingInfo else {
            return "signingInfoStatus=\(statusSummary(infoStatus))"
        }

        let info = signingInfo as NSDictionary
        let identifier = info[kSecCodeInfoIdentifier as String] as? String ?? "<unknown>"
        let teamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String ?? "<unknown>"
        return "identifier='\(identifier)' teamID='\(teamIdentifier)'"
    }
}

enum ApplicationMover {
    static func moveApplicationToTrash(appPath: String) throws -> URL {
        let sourceURL = URL(fileURLWithPath: appPath).standardizedFileURL
        try validateApplicationSourceURL(sourceURL)

        let trashURL = try consoleUser().trashURL
        try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)

        let destinationURL = uniqueDestinationURL(for: sourceURL, in: trashURL)
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    static func removeUserDataItem(path: String) throws {
        let sourceURL = URL(fileURLWithPath: path).standardizedFileURL
        try validateUserDataURL(sourceURL)

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return
        }

        try FileManager.default.removeItem(at: sourceURL)
    }

    private static func validateApplicationSourceURL(_ url: URL) throws {
        let path = url.path
        guard path.hasPrefix("/Applications/") else {
            throw HelperError.rejectedPath("Only apps inside /Applications can be moved by the helper.")
        }
        guard url.pathExtension == "app" else {
            throw HelperError.rejectedPath("Only .app bundles can be moved by the helper.")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw HelperError.rejectedPath("The requested app bundle does not exist.")
        }
    }

    private static func validateUserDataURL(_ url: URL) throws {
        let user = try consoleUser()
        let path = url.path
        let homePath = user.homeURL.standardizedFileURL.path
        guard path.hasPrefix("\(homePath)/") else {
            throw HelperError.rejectedPath("Only data inside the active user's home directory can be removed by the helper.")
        }

        let allowedPrefixes = [
            "\(homePath)/Library/Application Scripts/",
            "\(homePath)/Library/Application Support/",
            "\(homePath)/Library/Autosave Information/",
            "\(homePath)/Library/Caches/",
            "\(homePath)/Library/Containers/",
            "\(homePath)/Library/Cookies/",
            "\(homePath)/Library/Group Containers/",
            "\(homePath)/Library/HTTPStorages/",
            "\(homePath)/Library/LaunchAgents/",
            "\(homePath)/Library/Logs/",
            "\(homePath)/Library/Preferences/",
            "\(homePath)/Library/Saved Application State/",
            "\(homePath)/Library/SyncedPreferences/",
            "\(homePath)/Library/WebKit/",
            "\(homePath)/.cache/",
            "\(homePath)/.config/",
            "\(homePath)/.local/share/"
        ]

        if allowedPrefixes.contains(where: { path.hasPrefix($0) }) {
            return
        }

        let parentPath = url.deletingLastPathComponent().standardizedFileURL.path
        if parentPath == homePath, url.lastPathComponent.hasPrefix(".") {
            return
        }

        throw HelperError.rejectedPath("The requested data path is outside KidoX's uninstall cleanup scope.")
    }

    private static func consoleUser() throws -> ConsoleUser {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let unmanagedUser = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) else {
            throw HelperError.consoleUserUnavailable
        }

        let username = unmanagedUser as String
        guard username != "loginwindow", let passwd = getpwnam(username) else {
            throw HelperError.consoleUserUnavailable
        }

        let homeDirectory = String(cString: passwd.pointee.pw_dir)
        let homeURL = URL(fileURLWithPath: homeDirectory, isDirectory: true)
        let trashURL = homeURL.appendingPathComponent(".Trash", isDirectory: true)

        if !FileManager.default.fileExists(atPath: trashURL.path) {
            try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
            chown(trashURL.path, uid, gid)
            chmod(trashURL.path, 0o700)
        }

        return ConsoleUser(uid: uid, gid: gid, homeURL: homeURL, trashURL: trashURL)
    }

    private static func uniqueDestinationURL(for sourceURL: URL, in trashURL: URL) -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let pathExtension = sourceURL.pathExtension

        var candidate = trashURL.appendingPathComponent(sourceURL.lastPathComponent)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let filename = pathExtension.isEmpty ? "\(baseName) \(index)" : "\(baseName) \(index).\(pathExtension)"
            candidate = trashURL.appendingPathComponent(filename)
            index += 1
        }

        return candidate
    }
}

private struct ConsoleUser {
    let uid: uid_t
    let gid: gid_t
    let homeURL: URL
    let trashURL: URL
}

enum HelperError: LocalizedError {
    case rejectedPath(String)
    case consoleUserUnavailable

    var errorDescription: String? {
        switch self {
        case .rejectedPath(let reason):
            reason
        case .consoleUserUnavailable:
            "Could not determine the active user Trash location."
        }
    }
}

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: KidoXPrivilegedHelper.label)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
