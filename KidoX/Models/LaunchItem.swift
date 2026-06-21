import Foundation

enum LaunchItemKind: String, Codable, CaseIterable, Identifiable {
    case application
    case folder
    case file
    case url

    var id: String { rawValue }
}

struct LaunchItem: Identifiable, Hashable, Codable {
    let id: UUID
    var kind: LaunchItemKind
    var displayName: String
    var subtitle: String
    var url: URL
    var bundleIdentifier: String?
    var bundleName: String?
    var version: String?
    var customDisplayName: String?
    var sourcePath: String
    var isHidden: Bool
    var sortIndex: Int
    var addedAt: Date
    var lastOpenedAt: Date?
    var openCount: Int
    var parentID: UUID?

    init(
        id: UUID = UUID(),
        kind: LaunchItemKind,
        displayName: String,
        subtitle: String,
        url: URL,
        bundleIdentifier: String? = nil,
        bundleName: String? = nil,
        version: String? = nil,
        customDisplayName: String? = nil,
        sourcePath: String,
        isHidden: Bool = false,
        sortIndex: Int = 0,
        addedAt: Date = Date(),
        lastOpenedAt: Date? = nil,
        openCount: Int = 0,
        parentID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.subtitle = subtitle
        self.url = url
        self.bundleIdentifier = bundleIdentifier
        self.bundleName = bundleName
        self.version = version
        self.customDisplayName = customDisplayName
        self.sourcePath = sourcePath
        self.isHidden = isHidden
        self.sortIndex = sortIndex
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.openCount = openCount
        self.parentID = parentID
    }

    var effectiveDisplayName: String {
        customDisplayName ?? displayName
    }

    var searchText: String {
        [
            displayName,
            customDisplayName,
            subtitle,
            bundleIdentifier,
            bundleName,
            sourcePath
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .localizedLowercase
    }
}
