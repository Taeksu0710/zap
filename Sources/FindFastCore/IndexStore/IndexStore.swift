import Foundation

public enum SearchSortOrder: String, CaseIterable, Sendable {
    case relevance, name, modified, created
}

/// Owns the built index and serves searches against it.
///
/// `actor` isolation gives single-writer/many-reader safety: `build(root:)`
/// replaces the whole snapshot atomically, so a `search` that starts before a
/// rebuild completes still sees a fully-formed, consistent index.
public actor IndexStore {
    private var index: BuiltIndex = .empty
    /// Source-of-truth entry list backing `index`. Kept alongside the derived
    /// `BuiltIndex` so the index can be persisted and reconciled against
    /// filesystem changes without re-scanning disk — `index` is always
    /// re-derivable from this via `IndexBuilder.build(from:)`.
    private var liveEntries: [FileEntry] = []
    private var scanRoot: String = "/"
    public private(set) var lastBuildDuration: TimeInterval = 0

    public init() {}

    /// Scans `root` and replaces the current index with the freshly built
    /// one. Scanning itself runs off-actor (on Scanner's worker threads); only
    /// the final array swap happens inside the actor. Does not persist —
    /// callers that want the result saved (so the next launch can load it
    /// instead of re-scanning) should call `saveIndex()` afterward.
    @discardableResult
    public func build(root: String = "/") async -> Int {
        let start = Date()
        self.scanRoot = root
        let builder = IndexBuilder()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                Scanner.scan(root: root) { batch in
                    builder.add(batch)
                }
                continuation.resume()
            }
        }

        let entries = builder.snapshotEntries()
        let built = IndexBuilder.build(from: entries)
        self.index = built
        self.liveEntries = entries
        self.lastBuildDuration = Date().timeIntervalSince(start)
        return built.count
    }

    /// Loads a previously persisted index for `root` if one exists and is
    /// still valid (matching format version, volume, and scan root).
    /// Otherwise falls back to a full `build(root:)` and persists the result,
    /// so a corrupt/stale/missing cache self-heals on the very next launch.
    @discardableResult
    public func loadOrBuild(root: String = "/") async -> Int {
        self.scanRoot = root
        do {
            let entries = try IndexFile.load(expecting: root)
            self.index = IndexBuilder.build(from: entries)
            self.liveEntries = entries
            self.lastBuildDuration = 0
            return index.count
        } catch {
            FileHandle.standardError.write("[IndexStore] cache miss (\(error)), rescanning\n".data(using: .utf8)!)
            let count = await build(root: root)
            await saveIndex()
            return count
        }
    }

    /// Persists the current in-memory entry list to disk. Runs the file I/O
    /// off-actor since writing can take tens to low-hundreds of ms for large
    /// indexes and shouldn't block `search()` callers queued on the actor.
    public func saveIndex() async {
        let entries = liveEntries
        let root = scanRoot
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                try? IndexFile.save(entries: entries, scanRoot: root)
                continuation.resume()
            }
        }
    }

    // MARK: - Live watching

    private var watcher: Watcher?

    /// Starts watching `root` (defaults to the last scan/load root) for
    /// filesystem changes, keeping the index up to date without requiring a
    /// full rescan. Idempotent — calling again replaces any existing watch.
    ///
    /// FSEvents itself needs no special permission, but re-indexing a dirty
    /// directory still goes through `Scanner.scan`, which uses
    /// `getattrlistbulk` — inside a TCC-protected folder (Desktop/Documents/
    /// Downloads/Photos) without Full Disk Access, that silently yields no
    /// entries, same as the initial scan. A change there just won't be
    /// picked up; nothing crashes or hangs.
    public func startWatching(root: String? = nil) {
        let watchRoot = root ?? scanRoot
        let w = Watcher()
        self.watcher = w
        w.start(paths: [watchRoot]) { [weak self] dirtyDirs in
            guard let self else { return }
            Task { await self.handleDirtyPaths(dirtyDirs) }
        }
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    /// Reconciles `dirtyDirs` (directories FSEvents reported as changed)
    /// against the live index: drops every entry whose path falls under a
    /// dirty directory, re-scans each dirty directory that still exists,
    /// merges the fresh results back in, and rebuilds + persists the index.
    ///
    /// Marked `public` (rather than kept `private`) purely so tests can drive
    /// deterministic reconciliation scenarios directly instead of racing real
    /// FSEvents timing — not intended as a normal external entry point.
    public func handleDirtyPaths(_ dirtyDirs: Set<String>) async {
        // Drop anything a normal scan would never have touched in the first
        // place (e.g. other apps' `~/Library/Containers/...` data) *before*
        // doing anything else with it — otherwise re-scanning it below
        // triggers a macOS cross-app-data-access prompt for every such
        // directory FSEvents happens to report, which on a home-directory
        // watch is effectively every other running app's background writes.
        let dirtyDirs = dirtyDirs.filter { !Scanner.isPathExcluded($0, root: scanRoot) }
        guard !dirtyDirs.isEmpty else { return }

        // A single dirty parent correctly cascades to its whole subtree here:
        // if "/a" is marked dirty, "/a/b/c/file.txt" (parentPath "/a/b/c")
        // still matches `hasPrefix("/a/")`, so a deleted subtree is fully
        // purged even though only its (still-existing) parent was reported.
        var pruned = liveEntries.filter { entry in
            !dirtyDirs.contains { dirty in
                entry.parentPath == dirty || entry.parentPath.hasPrefix(dirty + "/")
            }
        }

        let existingDirtyDirs = dirtyDirs.filter { FileManager.default.fileExists(atPath: $0) }
        if !existingDirtyDirs.isEmpty {
            let freshEntries = await withCheckedContinuation { (continuation: CheckedContinuation<[FileEntry], Never>) in
                DispatchQueue.global(qos: .utility).async {
                    let builder = IndexBuilder()
                    for dir in existingDirtyDirs {
                        Scanner.scan(root: dir) { batch in builder.add(batch) }
                    }
                    continuation.resume(returning: builder.snapshotEntries())
                }
            }
            pruned.append(contentsOf: freshEntries)
        }

        self.index = IndexBuilder.build(from: pruned)
        self.liveEntries = pruned
        await saveIndex()
    }

    public var entryCount: Int { index.count }

    public func search(_ query: ParsedQuery, limit: Int = Int.max, sortOrder: SearchSortOrder = .relevance, ascending: Bool = true) -> [SearchResult] {
        guard index.count > 0 else { return [] }

        let hasExtFilter = !query.extensionFilter.isEmpty
        let extSet = Set(query.extensionFilter)

        var allCandidates = false
        let candidateIndices: [UInt32]
        if query.raw.isEmpty {
            // Extension-only query (e.g. `*.sql`) — scan all entries.
            allCandidates = true
            candidateIndices = Array(0..<UInt32(index.count))
        } else if query.isJamoQuery {
            candidateIndices = jamoCandidates(matching: query.raw)
        } else {
            let qScalars = Array(query.raw.lowercased().unicodeScalars)
            if qScalars.count >= 3 {
                candidateIndices = trigramCandidates(qScalars)
            } else {
                allCandidates = true
                candidateIndices = Array(0..<UInt32(index.count))
            }
        }

        let qLower = query.raw.lowercased()
        let qBytes = Array(qLower.utf8)
        var matched: [(idx: UInt32, rank: Int)] = []
        matched.reserveCapacity(limit < Int.max / 8 ? min(candidateIndices.count, limit * 8) : candidateIndices.count)

        for idx in candidateIndices {
            // For text queries: byte-level containment check against pre-stored
            // lowercased buffer — no String allocation for non-matching candidates.
            // Extension-only and jamo queries skip this (handled below).
            if !query.raw.isEmpty && !query.isJamoQuery {
                guard lowerContains(at: Int(idx), qBytes: qBytes) else { continue }
            }

            // Extension filter — only allocate nameString for candidates that
            // passed the text check (or for extension-only / jamo queries).
            if hasExtFilter {
                let name = nameString(at: Int(idx))
                let fileExt = (name as NSString).pathExtension.lowercased()
                guard extSet.contains(fileExt) else { continue }
            }

            if query.raw.isEmpty {
                matched.append((idx, 0))
                continue
            }

            if query.isJamoQuery {
                matched.append((idx, 0))
                continue
            }

            // Rank computation from bytes — no String allocation needed.
            let lLen = Int(index.lowerLengths[Int(idx)])
            let rank: Int
            if lLen == qBytes.count {
                rank = 0  // exact: same length + contains → must be equal
            } else {
                // Prefix check: compare first qBytes.count bytes.
                let isPfx = index.lowerBuffer.withUnsafeBufferPointer { buf in
                    let base = buf.baseAddress! + Int(index.lowerOffsets[Int(idx)])
                    return qBytes.withUnsafeBufferPointer { qBuf in
                        memcmp(base, qBuf.baseAddress!, qBytes.count) == 0
                    }
                }
                rank = isPfx ? 1 : 2
            }
            matched.append((idx, rank))
        }

        // Fast path: when the candidate set is all entries and the sort order is
        // .modified, iterate the pre-sorted mtimeSortedIndices with early
        // termination at `limit` — avoids collecting all matches then sorting.
        if sortOrder == .modified && allCandidates {
            var results: [SearchResult] = []
            results.reserveCapacity(min(limit, 1_000))
            let seq: AnySequence<UInt32> = ascending
                ? AnySequence(index.mtimeSortedIndices.reversed())
                : AnySequence(index.mtimeSortedIndices)
            for idx in seq {
                if hasExtFilter {
                    let name = nameString(at: Int(idx))
                    guard extSet.contains((name as NSString).pathExtension.lowercased()) else { continue }
                }
                if !query.raw.isEmpty {
                    guard lowerContains(at: Int(idx), qBytes: qBytes) else { continue }
                }
                results.append(makeResult(at: Int(idx)))
                if results.count >= limit { break }
            }
            return results
        }

        // Pre-compute sort keys in O(n) before sorting to avoid O(n log n) random
        // buffer lookups / string allocations inside the comparator.
        switch sortOrder {
        case .relevance:
            let lens = matched.map { nameLength(at: Int($0.idx)) }
            let order = matched.indices.sorted { i, j in
                if matched[i].rank != matched[j].rank { return matched[i].rank < matched[j].rank }
                return lens[i] < lens[j]
            }
            matched = order.map { matched[$0] }
        case .name:
            let keys = matched.map { lowerString(at: Int($0.idx)) }
            let order = keys.indices.sorted { ascending ? keys[$0] < keys[$1] : keys[$0] > keys[$1] }
            matched = order.map { matched[$0] }
        case .modified:
            let keys = matched.map { index.mtimes[Int($0.idx)] }
            let order = keys.indices.sorted { ascending ? keys[$0] < keys[$1] : keys[$0] > keys[$1] }
            matched = order.map { matched[$0] }
        case .created:
            let keys = matched.map { index.crtimes[Int($0.idx)] }
            let order = keys.indices.sorted { ascending ? keys[$0] < keys[$1] : keys[$0] > keys[$1] }
            matched = order.map { matched[$0] }
        }

        return matched.prefix(limit).map { makeResult(at: Int($0.idx)) }
    }

    // MARK: - Candidate selection

    private func trigramCandidates(_ qScalars: [Unicode.Scalar]) -> [UInt32] {
        let hashes = TrigramIndex.trigrams(of: qScalars)
        guard !hashes.isEmpty else { return Array(0..<UInt32(index.count)) }

        var lists: [[UInt32]] = []
        for h in hashes {
            guard let list = index.trigramIndex[h] else { return [] }
            lists.append(list)
        }
        lists.sort { $0.count < $1.count }

        var result = Set(lists[0])
        for list in lists.dropFirst() {
            result.formIntersection(list)
            if result.isEmpty { break }
        }
        return Array(result)
    }

    private func jamoCandidates(matching raw: String) -> [UInt32] {
        var matches: [UInt32] = []
        for i in 0..<index.count {
            if jamoString(at: i).contains(raw) {
                matches.append(UInt32(i))
            }
        }
        return matches
    }

    // MARK: - Buffer accessors

    private func nameLength(at i: Int) -> Int { Int(index.nameLengths[i]) }

    private func nameString(at i: Int) -> String {
        let offset = Int(index.nameOffsets[i])
        let length = Int(index.nameLengths[i])
        return index.nameBuffer.withUnsafeBufferPointer { buf in
            String(decoding: buf[offset..<(offset + length)], as: UTF8.self)
        }
    }

    private func lowerString(at i: Int) -> String {
        let offset = Int(index.lowerOffsets[i])
        let length = Int(index.lowerLengths[i])
        return index.lowerBuffer.withUnsafeBufferPointer { buf in
            String(decoding: buf[offset..<(offset + length)], as: UTF8.self)
        }
    }

    // Byte-level substring search against the pre-stored lowercased buffer.
    // Avoids any String allocation for candidates that don't match — the hot
    // path is O(candidates) calls, so every allocation saved here matters.
    private func lowerContains(at i: Int, qBytes: [UInt8]) -> Bool {
        let offset = Int(index.lowerOffsets[i])
        let length = Int(index.lowerLengths[i])
        let qLen = qBytes.count
        guard length >= qLen else { return false }
        return index.lowerBuffer.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress! + offset
            return qBytes.withUnsafeBufferPointer { qBuf in
                let qBase = qBuf.baseAddress!
                for start in 0...(length - qLen) {
                    if memcmp(base + start, qBase, qLen) == 0 { return true }
                }
                return false
            }
        }
    }

    private func jamoString(at i: Int) -> String {
        let offset = Int(index.jamoOffsets[i])
        let length = Int(index.jamoLengths[i])
        return index.jamoBuffer.withUnsafeBufferPointer { buf in
            String(decoding: buf[offset..<(offset + length)], as: UTF8.self)
        }
    }

    private func makeResult(at i: Int) -> SearchResult {
        let name = nameString(at: i)
        let parentPath = index.parentPaths[Int(index.parentIndices[i])]
        let fullPath = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
        return SearchResult(
            name: name,
            path: fullPath,
            isDirectory: index.isDirectory[i],
            size: index.sizes[i],
            mtime: index.mtimes[i],
            crtime: index.crtimes[i]
        )
    }
}
