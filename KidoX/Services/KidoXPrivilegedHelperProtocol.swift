import Foundation

enum KidoXPrivilegedHelper {
    static let label = "com.clyapps.KidoX.PrivilegedHelper"
    static let version = "1.1"
}

@objc(KidoXPrivilegedHelperProtocol)
protocol KidoXPrivilegedHelperProtocol {
    func getVersion(reply: @escaping (String) -> Void)
    func moveApplicationToTrash(_ appPath: String, withReply reply: @escaping (Bool, String?, String?) -> Void)
    func removeItems(_ paths: [String], withReply reply: @escaping ([String], [String: String]) -> Void)
}
