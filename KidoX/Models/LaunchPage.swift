import Foundation

struct LaunchPage: Identifiable, Hashable, Codable {
    static let defaultCapacity = 35

    let id: UUID
    var sortIndex: Int
    var items: [LaunchItem]

    init(
        id: UUID = UUID(),
        sortIndex: Int,
        items: [LaunchItem] = []
    ) {
        self.id = id
        self.sortIndex = sortIndex
        self.items = items
    }

    var rootItems: [LaunchItem] {
        items
            .filter { !$0.isHidden && $0.parentID == nil }
            .sorted { $0.sortIndex < $1.sortIndex }
    }
}
