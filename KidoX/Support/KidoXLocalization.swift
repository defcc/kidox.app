import Foundation

enum KidoXLanguage: String, CaseIterable, Identifiable {
    static let storageKey = "KidoX.appLanguage"

    case system
    case english
    case simplifiedChinese
    case japanese

    var id: String { rawValue }

    var lprojIdentifier: String? {
        switch self {
        case .system: nil
        case .english: nil
        case .simplifiedChinese: "zh-Hans"
        case .japanese: "ja"
        }
    }

    var localizedTitle: String {
        switch self {
        case .system:
            KidoXL10n.string(.languageSystem)
        case .english:
            "English"
        case .simplifiedChinese:
            "简体中文"
        case .japanese:
            "日本語"
        }
    }

    static func selected(from rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? .system
    }
}

enum KidoXL10nKey: String {
    case general = "General"
    case appearance = "Appearance"
    case hiddenApps = "Hidden Apps"
    case advanced = "Advanced"
    case license = "License"
    case about = "About"
    case helpCenter = "Help Center"
    case versionAvailable = "Version %@ available"
    case language = "Language"
    case appLanguage = "App language"
    case appLanguageDescription = "Choose the display language used by KidoX."
    case languageSystem = "System"
    case searchApplications = "Search Applications"
    case settings = "Settings"
    case open = "Open"
    case rename = "Rename"
    case showInFinder = "Show in Finder"
    case hideApp = "Hide App"
    case uninstallAppEllipsis = "Uninstall App..."
    case uninstallTitle = "Uninstall %@"
    case uninstallQuestionTitle = "Uninstall %@?"
    case uninstallDescription = "This will delete the app and its related data from this Mac."
    case scanningRelatedAppData = "Scanning related app data..."
    case appData = "App Data"
    case app = "App"
    case total = "Total"
    case items = "Items"
    case noMatchingBundleData = "No matching bundle-id user data found."
    case cancel = "Cancel"
    case done = "Done"
    case uninstall = "Uninstall"
    case uninstalling = "Uninstalling..."
    case uninstalledTitle = "Uninstalled %@"
    case uninstalledWithIssues = "Uninstalled with issues"
    case uninstalledSuccessDescription = "The app and confirmed user data were removed from this Mac."
    case uninstalledIssuesDescription = "The app was removed, but some app data could not be deleted."
    case failedRemovals = "Failed removals"
    case appDataPermissionRequired = "Full Disk Access required"
    case appDataPermissionDescription = "Allow KidoX in Privacy & Security > Full Disk Access, then retry these sandbox data items."
    case mayRequireAppDataPermission = "Some sandbox data may require Full Disk Access."
    case requiresPermission = "Requires Permission"
    case grantPermission = "Grant Permission"
    case openPrivacySettings = "Open Full Disk Access"
    case retryFailedItems = "Retry Failed Items"
    case retrying = "Retrying..."
    case andMore = "And %d more."
    case unableToUninstall = "Unable to uninstall %@"
}

enum KidoXL10n {
    static func string(_ key: KidoXL10nKey, languageRawValue: String? = nil) -> String {
        localizedString(key.rawValue, languageRawValue: languageRawValue)
    }

    static func ui(_ key: String, languageRawValue: String? = nil) -> String {
        localizedString(key, languageRawValue: languageRawValue)
    }

    static func format(_ key: KidoXL10nKey, _ arguments: CVarArg..., languageRawValue: String? = nil) -> String {
        String(format: string(key, languageRawValue: languageRawValue), arguments: arguments)
    }

    static func uiFormat(_ key: String, _ arguments: CVarArg..., languageRawValue: String? = nil) -> String {
        String(format: ui(key, languageRawValue: languageRawValue), arguments: arguments)
    }

    static func dataLocations(_ count: Int, languageRawValue: String? = nil) -> String {
        let key = count == 1 ? "%d data location" : "%d data locations"
        return uiFormat(key, count, languageRawValue: languageRawValue)
    }

    private static func localizedString(_ key: String, languageRawValue: String?) -> String {
        bundle(languageRawValue: languageRawValue).localizedString(forKey: key, value: key, table: nil)
    }

    private static func bundle(languageRawValue: String?) -> Bundle {
        let selected = KidoXLanguage.selected(
            from: languageRawValue ?? UserDefaults.standard.string(forKey: KidoXLanguage.storageKey) ?? KidoXLanguage.system.rawValue
        )
        guard
            let lprojIdentifier = selected.lprojIdentifier,
            let path = Bundle.main.path(forResource: lprojIdentifier, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else {
            return .main
        }
        return bundle
    }
}
