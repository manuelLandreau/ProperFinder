import Foundation

/// A vnode source on the folder only reports entries added, removed or renamed, not edits inside existing files.
public final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject
    private var pending: DispatchWorkItem?

    public init?(url: URL, debounce: TimeInterval = 0.2, queue: DispatchQueue = .main, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link, .attrib], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            pending?.cancel()
            let work = DispatchWorkItem(block: onChange)
            pending = work
            queue.asyncAfter(deadline: .now() + debounce, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    public func cancel() {
        pending?.cancel()
        source.cancel()
    }

    deinit {
        cancel()
    }
}
