import Darwin
import Foundation

@MainActor
final class ApplicationDirectoryMonitor {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var fileDescriptors: [CInt] = []
    private let onChange: () -> Void

    init(urls: [URL], onChange: @escaping () -> Void) {
        self.onChange = onChange

        for url in urls {
            monitor(url)
        }
    }

    deinit {
        for source in sources {
            source.cancel()
        }
    }

    private func monitor(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        fileDescriptors.append(fileDescriptor)

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.onChange()
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        sources.append(source)
        source.resume()
    }
}
