import Darwin
import Dispatch

final class CodexFileWatcher {
    private let source: DispatchSourceFileSystemObject
    private var isCancelled = false

    init?(path: String, onChange: @escaping @Sendable () -> Void) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            return nil
        }

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
    }

    func cancel() {
        guard !isCancelled else {
            return
        }
        isCancelled = true
        source.cancel()
    }

    deinit {
        cancel()
    }
}
