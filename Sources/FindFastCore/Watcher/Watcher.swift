import Foundation
import CoreServices

/// Bridges the FSEvents C callback into a Swift closure via a retained
/// context box — the same `Unmanaged` pattern `ScannerWorker.swift` uses for
/// the `getattrlistbulk` callback, since C function pointers can't capture
/// Swift closures directly.
private final class WatcherCallbackBox {
    let handler: (Set<String>) -> Void
    init(_ handler: @escaping (Set<String>) -> Void) {
        self.handler = handler
    }
}

/// Top-level `@convention(c)` trampoline required by `FSEventStreamCreate`.
/// Verified against a standalone spike before integration: `eventPaths` binds
/// as `UnsafeMutablePointer<CChar>` per-path (not `UnsafePointer<CChar>?`) when
/// `kFSEventStreamCreateFlagUseCFTypes` is NOT set, which is the flag
/// configuration `Watcher.start` uses below.
private func fseventsTrampoline(
    _ stream: ConstFSEventStreamRef,
    _ clientInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientInfo else { return }
    let box = Unmanaged<WatcherCallbackBox>.fromOpaque(clientInfo).takeUnretainedValue()

    let pathsPtr = eventPaths.bindMemory(to: UnsafeMutablePointer<CChar>.self, capacity: numEvents)
    var dirtyDirs = Set<String>()

    for i in 0..<numEvents {
        let flags = eventFlags[i]
        // NFC-normalize immediately: APFS/FSEvents can hand back
        // decomposed (NFD) Hangul just like getattrlistbulk does (see
        // ScannerWorker.swift) — without this, prefix-matching a dirty path
        // against `liveEntries.parentPath` (which IS NFC, since Scanner
        // normalizes at the source) would silently fail for any changed
        // file/directory with a Korean name.
        let path = String(cString: pathsPtr[i]).precomposedStringWithCanonicalMapping

        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
            // Coalescing overflow: the daemon couldn't keep up with the
            // volume of changes under `path`. Treat the whole subtree as
            // dirty; handleDirtyPaths' recursive Scanner.scan(root:) rescan
            // is the correct response regardless of what actually changed.
            dirtyDirs.insert(path)
        } else if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
            // The watched root itself moved/was deleted/was recreated.
            dirtyDirs.insert(path)
        } else if flags
            & FSEventStreamEventFlags(kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0 {
            // A volume was mounted/unmounted at `path`. Dirty it so
            // handleDirtyPaths either drops now-gone entries (unmount) or
            // rescans the newly-available content (mount).
            dirtyDirs.insert(path)
        } else if flags
            & FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                    | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified
            ) != 0 {
            // File-level event (kFSEventStreamCreateFlagFileEvents is set):
            // `path` is the changed item itself. Re-index its *parent*
            // directory — Scanner.scan(root:) enumerates a directory's
            // children, it doesn't take a single file path. If the item
            // itself is a directory that was created, also mark it dirty
            // directly so its own (possibly pre-existing) children get
            // picked up by the recursive scan.
            let parent = (path as NSString).deletingLastPathComponent
            dirtyDirs.insert(parent)
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0,
                flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 {
                dirtyDirs.insert(path)
            }
        }
    }

    if !dirtyDirs.isEmpty {
        box.handler(dirtyDirs)
    }
}

/// Thin wrapper around an `FSEventStreamRef`. Not an actor — it's owned by
/// and only ever called from `IndexStore`'s actor context (`start`/`stop`),
/// while the FSEvents callback itself fires on `queue` and only touches the
/// retained `WatcherCallbackBox`, never `Watcher`'s own stored properties.
final class Watcher: @unchecked Sendable {
    // "findfast" is a legacy identifier predating the "Zap" rebrand, kept
    // for consistency with the other legacy identifiers (see
    // SearchViewModel.rootPathDefaultsKey) — this one is diagnostic-only
    // (Instruments/crash reports), so there's no migration cost either way.
    private let queue = DispatchQueue(label: "net.youngsam.findfast.watcher", qos: .utility)
    private var stream: FSEventStreamRef?
    private var boxPtr: UnsafeMutableRawPointer?

    /// Starts watching `paths` for changes. `handler` is called (on an
    /// arbitrary background queue — hop back to the actor yourself) with the
    /// set of directories that need re-indexing.
    func start(paths: [String], handler: @escaping (Set<String>) -> Void) {
        stop() // idempotent: replace any existing stream

        let box = WatcherCallbackBox(handler)
        let ptr = Unmanaged.passRetained(box).toOpaque()
        self.boxPtr = ptr

        var context = FSEventStreamContext(version: 0, info: ptr, retain: nil, release: nil, copyDescription: nil)
        let cfPaths = paths as CFArray

        guard
            let newStream = FSEventStreamCreate(
                nil,
                fseventsTrampoline,
                &context,
                cfPaths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                1.5, // seconds; FSEvents' own coalescing window (see Watcher design notes)
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
            )
        else {
            Unmanaged<WatcherCallbackBox>.fromOpaque(ptr).release()
            self.boxPtr = nil
            return
        }

        self.stream = newStream
        FSEventStreamSetDispatchQueue(newStream, queue)
        FSEventStreamStart(newStream)
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        if let boxPtr {
            Unmanaged<WatcherCallbackBox>.fromOpaque(boxPtr).release()
        }
        boxPtr = nil
    }

    deinit {
        stop()
    }
}
