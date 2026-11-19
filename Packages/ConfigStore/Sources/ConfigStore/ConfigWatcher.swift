public import Foundation
import CoreServices

/// Reports changes in a config folder, whoever makes them.
public enum ConfigWatcher {
    /// A stream that yields once for each burst of changes under `root`.
    ///
    /// Changes to the app's own backups and temporary files are left out. The stream ends when the task that
    /// reads it is cancelled.
    public static func changes(in root: URL, latency: TimeInterval = 0.2) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let stream = EventStream(root: root, latency: latency) { continuation.yield() }
            continuation.onTermination = { _ in stream.stop() }
            if !stream.start() {
                continuation.finish()
            }
        }
    }
}

/// Owns one FSEvents stream. Its state is touched only on its own queue.
private final class EventStream: @unchecked Sendable {
    private let root: URL
    private let latency: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.zardozgroup.abbrio.config-watcher")
    private var stream: FSEventStreamRef?

    init(root: URL, latency: TimeInterval, onChange: @escaping @Sendable () -> Void) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.latency = latency
        self.onChange = onChange
    }

    func start() -> Bool {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info, let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            let watcher = Unmanaged<EventStream>.fromOpaque(info).takeUnretainedValue()
            if paths.prefix(count).contains(where: watcher.isRelevant) {
                watcher.onChange()
            }
        }
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, FSEventStreamCreateFlags(flags)
        ) else { return false }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        queue.sync { self.stream = stream }
        return true
    }

    func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func isRelevant(_ path: String) -> Bool {
        !path.contains("/.abbrio/") && !path.hasSuffix("/.abbrio")
            && !path.hasSuffix(".tmp") && !path.hasSuffix(".DS_Store")
    }
}
