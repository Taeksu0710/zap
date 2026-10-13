import Foundation
import CFFBulk

/// Thread-safe BFS work queue for parallel directory traversal.
///
/// `pending` tracks directories that are either still queued or currently
/// being scanned by a worker. A directory is only considered "done" once its
/// children (if any) have been pushed, so `pending` never transiently drops
/// to zero while there is still unprocessed work in flight.
final class DirectoryQueue: @unchecked Sendable {
    private var items: [String]
    private var pending: Int
    private let lock = NSCondition()

    init(initial: [String]) {
        self.items = initial
        self.pending = initial.count
    }

    func pop() -> String? {
        lock.lock()
        defer { lock.unlock() }
        while items.isEmpty {
            if pending == 0 {
                lock.broadcast()
                return nil
            }
            lock.wait()
        }
        return items.removeFirst()
    }

    /// Call after fully processing a directory popped via `pop()`, passing
    /// any child directories discovered. Atomically enqueues the children and
    /// marks the parent as complete, so the pending count stays consistent.
    func pushChildrenAndComplete(_ children: [String]) {
        lock.lock()
        items.append(contentsOf: children)
        pending += children.count
        pending -= 1
        lock.broadcast()
        lock.unlock()
    }
}

/// Bridges the C `ff_scan_dir` callback into a Swift closure via a retained
/// context box, since C function pointers cannot capture state directly.
private final class ScanCallbackBox {
    let handler: (UnsafePointer<ff_entry_t>, Int32) -> Void
    init(_ handler: @escaping (UnsafePointer<ff_entry_t>, Int32) -> Void) {
        self.handler = handler
    }
}

private func ffTrampoline(
    _ entries: UnsafePointer<ff_entry_t>?,
    _ count: Int32,
    _ context: UnsafeMutableRawPointer?
) {
    guard let entries, let context else { return }
    let box = Unmanaged<ScanCallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.handler(entries, count)
}

enum ScannerWorker {
    /// Scans the immediate children of a single directory, invoking `handler`
    /// for each entry found. Silently returns if the directory cannot be
    /// opened (permission denied, race with deletion, etc.) — scan failures
    /// on individual directories should not abort the whole tree walk.
    static func scanOneDirectory(_ path: String, handler: @escaping (FileEntry) -> Void) {
        let box = ScanCallbackBox { entriesPtr, count in
            for i in 0..<Int(count) {
                let raw = entriesPtr[i]
                let rawName = withUnsafeBytes(of: raw.name) { buf -> String in
                    let cstr = buf.bindMemory(to: CChar.self)
                    return String(cString: cstr.baseAddress!)
                }
                // APFS returns Hangul filenames in NFD (decomposed conjoining
                // jamo, U+1100 block); normalize to NFC (precomposed syllable
                // block, U+AC00) so choseong decomposition and all downstream
                // string matching see one consistent form.
                let name = rawName.precomposedStringWithCanonicalMapping
                handler(FileEntry(
                    name: name,
                    parentPath: path,
                    isDirectory: raw.is_dir != 0,
                    size: raw.size,
                    mtime: raw.mtime_sec,
                    crtime: raw.crtime_sec,
                    fileID: raw.file_id
                ))
            }
        }
        let boxPtr = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ScanCallbackBox>.fromOpaque(boxPtr).release() }
        _ = path.withCString { cpath in
            ff_scan_dir(cpath, ffTrampoline, boxPtr)
        }
    }
}
