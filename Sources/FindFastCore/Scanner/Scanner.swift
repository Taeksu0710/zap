import Foundation

/// Full-volume directory tree scanner built on `getattrlistbulk`.
public enum Scanner {
    /// Paths that are never descended into. `/System/Volumes/Data` (and its
    /// siblings Preboot/Recovery/VM/Update/...) mirror content already
    /// reachable through top-level firmlinks (see `/usr/share/firmlinks`:
    /// `/Users`, `/Applications`, `/Library`, `/private`, ...), so descending
    /// into `/System/Volumes` as well would double-count every such file.
    public static let defaultSkipPaths: Set<String> = [
        "/System/Volumes",
        "/dev",
        "/.vol",
        "/.Spotlight-V100",
        "/.fseventsd",
        "/.DocumentRevisions-V100",
        "/.Trashes",
        "/private/var/vm",
        "/private/var/folders",
    ]

    /// Directory *names* (matched regardless of where they appear in the
    /// tree) whose contents are never descended into. The directory itself
    /// is still listed as a normal entry (so e.g. searching "node_modules"
    /// still finds it) — only recursion into it is pruned. Without this, a
    /// whole-home-directory scan balloons into millions of low-value entries
    /// (every package's node_modules, every Xcode DerivedData build
    /// artifact, sandboxed app container internals under ~/Library) and
    /// both scan time and index-build time scale with it — measured
    /// blowing past 1.6M entries / 17s on a real dev machine's home
    /// directory before this exclusion existed.
    public static let defaultSkipDirectoryNames: Set<String> = [
        "node_modules", ".git", ".build", "DerivedData", "Pods",
        "Library", ".Trash", ".cache", "__pycache__", ".venv",
    ]

    /// True if `path` (scanned from `root`) is one a normal `scan()` would
    /// never have descended into — e.g. anything under `~/Library`
    /// (including other apps' `Containers`/`Application Support` data).
    /// Used by the FSEvents reconciliation path to drop dirty directories
    /// before re-scanning them: without this check, a live watch on the
    /// whole home folder sees *every* app's background writes under its own
    /// container, and re-scanning those triggers macOS's "would like to
    /// access another app's data" prompt — repeatedly, once per distinct
    /// container a full scan was already designed to never touch.
    ///
    /// Only path components *below* `root` are considered — `root` itself
    /// may legitimately sit inside a path that looks like a skip entry (e.g.
    /// a scan rooted under `/private/var/folders`, where macOS's own temp
    /// directory lives), and that ancestry shouldn't disqualify the root's
    /// own contents, only genuine descendants of a skip rule.
    public static func isPathExcluded(
        _ path: String,
        root: String,
        skipPaths: Set<String> = defaultSkipPaths,
        skipDirectoryNames: Set<String> = defaultSkipDirectoryNames
    ) -> Bool {
        // Normalize a trailing slash on `root` first — otherwise `rootPrefix`
        // below becomes "//" and `path.hasPrefix(rootPrefix)` never matches
        // any real path, silently disabling exclusion entirely (the TCC
        // prompt storm this function exists to prevent would come right
        // back for a root supplied with a trailing slash).
        var normalizedRoot = root
        if normalizedRoot.count > 1, normalizedRoot.hasSuffix("/") {
            normalizedRoot.removeLast()
        }

        let rootPrefix = normalizedRoot == "/" ? "/" : normalizedRoot + "/"
        guard path.hasPrefix(rootPrefix) else { return false }
        let relative = path.dropFirst(rootPrefix.count)

        // Only consider a skip rule that is a genuine descendant of `root`
        // (strictly below it) — deliberately NOT `skip == root`. If the two
        // were equal, `skip + "/"` would equal `rootPrefix` itself, so the
        // `path.hasPrefix(skip + "/")` check below would match *every* path
        // under `root` (since that's already guaranteed by the guard above),
        // excluding the root's entire contents. A root the caller explicitly
        // chose to scan should never be blanket-excluded just because it
        // happens to coincide with a skip-path entry.
        for skip in skipPaths where skip.hasPrefix(rootPrefix) {
            if path == skip || path.hasPrefix(skip + "/") { return true }
        }
        return relative.split(separator: "/").contains { skipDirectoryNames.contains(String($0)) }
    }

    /// Recursively scans the tree rooted at `root`, calling `onEntries` with
    /// batches of discovered entries (files and directories) as they are
    /// found. Traversal is parallelized across `concurrency` worker threads
    /// sharing a single BFS work queue.
    ///
    /// `onEntries` may be called concurrently from multiple threads and must
    /// be safe to call that way.
    public static func scan(
        root: String,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        skipPaths: Set<String> = defaultSkipPaths,
        skipDirectoryNames: Set<String> = defaultSkipDirectoryNames,
        onEntries: @escaping @Sendable ([FileEntry]) -> Void
    ) {
        let queue = DirectoryQueue(initial: [root])
        let workerCount = max(1, concurrency)
        let group = DispatchGroup()

        for _ in 0..<workerCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                while let dir = queue.pop() {
                    if skipPaths.contains(dir) {
                        queue.pushChildrenAndComplete([])
                        continue
                    }

                    var batch: [FileEntry] = []
                    var subdirs: [String] = []
                    ScannerWorker.scanOneDirectory(dir) { entry in
                        batch.append(entry)
                        if entry.isDirectory && !skipDirectoryNames.contains(entry.name) {
                            subdirs.append(entry.fullPath)
                        }
                    }

                    if !batch.isEmpty {
                        onEntries(batch)
                    }
                    queue.pushChildrenAndComplete(subdirs)
                }
            }
        }

        group.wait()
    }
}
