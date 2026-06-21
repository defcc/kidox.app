import Foundation

extension Notification.Name {
    static let kidoXPagesDidChangeExternally = Notification.Name("KidoX.pagesDidChangeExternally")
}

struct KidoXData: Codable {
    var pages: [LaunchPage]
}

struct KidoXDatabase: Sendable {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    func load() -> KidoXData {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return KidoXData(pages: [])
        }

        do {
            let data = try Data(contentsOf: databaseURL)
            return try decoder.decode(KidoXData.self, from: data)
        } catch {
            return KidoXData(pages: [])
        }
    }

    func loadPages() -> [LaunchPage] {
        load().pages
    }

    func loadPagesAsync() async -> [LaunchPage] {
        let url = databaseURL
        return await Task.detached(priority: .userInitiated) {
            Self.loadPages(from: url)
        }.value
    }

    func savePages(_ pages: [LaunchPage]) {
        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(KidoXData(pages: pages))
            try data.write(to: databaseURL, options: [.atomic])
        } catch {
            assertionFailure("Failed to save KidoX database: \(error.localizedDescription)")
        }
    }

    func savePagesAsync(_ pages: [LaunchPage]) async {
        let url = databaseURL
        await Task.detached(priority: .utility) {
            Self.savePages(pages, to: url)
        }.value
    }

    private static func loadPages(from url: URL) -> [LaunchPage] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(KidoXData.self, from: data).pages
        } catch {
            return []
        }
    }

    private static func savePages(_ pages: [LaunchPage], to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(KidoXData(pages: pages))
            try data.write(to: url, options: [.atomic])
        } catch {
            assertionFailure("Failed to save KidoX database: \(error.localizedDescription)")
        }
    }

    private var databaseURL: URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]

        return supportDirectory
            .appendingPathComponent("KidoX", isDirectory: true)
            .appendingPathComponent("pages.json")
    }
}
