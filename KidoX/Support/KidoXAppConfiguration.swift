import Foundation

enum KidoXAppConfiguration {
    static let licenseEndpointURL = url(
        forInfoDictionaryKey: "KidoXLicenseEndpointURL",
        fallback: "https://cly-app-license-manager.chengchao1.workers.dev"
    )

    static let websiteURL = url(
        forInfoDictionaryKey: "KidoXWebsiteURL",
        fallback: "https://kidox.app"
    )

    static let helpURL = url(
        forInfoDictionaryKey: "KidoXHelpURL",
        fallback: "https://kidox.app/help"
    )

    static let supportURL = url(
        forInfoDictionaryKey: "KidoXSupportURL",
        fallback: "https://kidox.app/support"
    )

    static let purchaseURL = url(
        forInfoDictionaryKey: "KidoXPurchaseURL",
        fallback: "https://kidox.app"
    )

    static let appcastURL = url(
        forInfoDictionaryKey: "SUFeedURL",
        fallback: "https://kidox.app/appcast.xml"
    )

    static let licenseReceiptPublicKey = string(
        forInfoDictionaryKey: "KidoXLicenseReceiptPublicKey",
        fallback: ""
    )

    private static func url(forInfoDictionaryKey key: String, fallback: String) -> URL {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
        return URL(string: value ?? fallback) ?? URL(string: fallback)!
    }

    private static func string(forInfoDictionaryKey key: String, fallback: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? fallback
    }
}
