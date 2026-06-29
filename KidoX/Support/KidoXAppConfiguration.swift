import Foundation

enum KidoXAppConfiguration {
    static let licenseEndpointURL = url("https://cly-app-license-manager.chengchao1.workers.dev")

    static let websiteURL = url("https://kidox.app")

    static let helpURL = url("https://kidox.app/help")

    static let supportURL = url("https://kidox.app/support")

    static let purchaseURL = url("https://kidox.app/pricing")

    static let licenseReceiptPublicKey = "BKimVREphpT5adxHB2MD4ye1kaCOcwFltnw2KFgFxpUStXtoZEKMR75Tnvz2r4oKrXnAMgzuGeifFsqIlUxW0Rw="

    private static func url(_ value: String) -> URL {
        guard let url = URL(string: value), url.scheme != nil else {
            fatalError("Invalid KidoX app configuration URL: \(value)")
        }
        return url
    }
}
