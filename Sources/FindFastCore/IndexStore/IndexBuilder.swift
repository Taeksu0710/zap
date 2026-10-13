import Foundation

/// Wraps a value the compiler can't verify `Sendable` for, where the
/// surrounding code structure already guarantees race-free access (e.g. a
/// raw buffer pointer whose concurrent writers touch strictly disjoint
/// indices). An assertion to the type checker, not a safety mechanism.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// The finalized flat-array representation of a built index. Immutable once
/// produced by `IndexBuilder.build(from:)`.
struct BuiltIndex {
    var nameBuffer: [UInt8]
    var nameOffsets: [UInt32]
    var nameLengths: [UInt16]
    // Pre-computed lowercased UTF-8 bytes — enables allocation-free byte-level
    // containment checks in the search loop without calling String.lowercased()
    // per candidate. Populated at build time alongside nameBuffer at zero extra
    // runtime cost (lowercased() is already computed for the trigram index).
    var lowerBuffer: [UInt8]
    var lowerOffsets: [UInt32]
    var lowerLengths: [UInt16]
    var jamoBuffer: [UInt8]
    var jamoOffsets: [UInt32]
    var jamoLengths: [UInt16]
    var parentIndices: [UInt32]
    var parentPaths: [String]
    var isDirectory: [Bool]
    var sizes: [UInt64]
    var mtimes: [Int64]
    var crtimes: [Int64]
    var fileIDs: [UInt64]
    var trigramIndex: [UInt32: [UInt32]]
    // Entry indices sorted by mtime descending (most-recent-first). Built once
    // at index build time; used by the search fast path to iterate matches in
    // mtime order without a separate sort step.
    var mtimeSortedIndices: [UInt32]

    var count: Int { nameOffsets.count }

    static let empty = BuiltIndex(
        nameBuffer: [], nameOffsets: [], nameLengths: [],
        lowerBuffer: [], lowerOffsets: [], lowerLengths: [],
        jamoBuffer: [], jamoOffsets: [], jamoLengths: [],
        parentIndices: [], parentPaths: [],
        isDirectory: [], sizes: [], mtimes: [], crtimes: [], fileIDs: [],
        trigramIndex: [:], mtimeSortedIndices: []
    )
}

/// Accumulates `FileEntry` batches streamed concurrently from `Scanner.scan`,
/// then builds the flat-array index in a single finalize pass.
final class IndexBuilder: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [FileEntry] = []

    func add(_ batch: [FileEntry]) {
        lock.lock()
        records.append(contentsOf: batch)
        lock.unlock()
    }

    /// Returns a copy of the entries accumulated so far without clearing
    /// them. `IndexStore` uses this to retain the source-of-truth entry list
    /// for persistence, alongside the derived `BuiltIndex`.
    func snapshotEntries() -> [FileEntry] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func finalize() -> BuiltIndex {
        lock.lock()
        let snapshot = records
        records.removeAll(keepingCapacity: false)
        lock.unlock()
        return IndexBuilder.build(from: snapshot)
    }

    /// Per-shard intermediate result from `buildShard(_:)` — everything is
    /// built using entry indices and byte offsets LOCAL to that shard's
    /// slice, so shards can be built fully independently with no shared
    /// mutable state, then stitched together in `mergeShards`.
    private struct ShardResult {
        var nameBuffer: [UInt8] = []
        var nameOffsets: [UInt32] = []
        var nameLengths: [UInt16] = []
        var lowerBuffer: [UInt8] = []
        var lowerOffsets: [UInt32] = []
        var lowerLengths: [UInt16] = []
        var jamoBuffer: [UInt8] = []
        var jamoOffsets: [UInt32] = []
        var jamoLengths: [UInt16] = []
        var isDirectory: [Bool] = []
        var sizes: [UInt64] = []
        var mtimes: [Int64] = []
        var crtimes: [Int64] = []
        var fileIDs: [UInt64] = []
        var localParentIndices: [UInt32] = []  // index into localParentPaths
        var localParentPaths: [String] = []
        // Posting lists use LOCAL entry indices (0..<shard.count) — remapped
        // to global indices during the merge.
        var trigramIndex: [UInt32: [UInt32]] = [:]
    }

    /// Pure function: builds the flat-array index (name/jamo buffers,
    /// interned parent paths, trigram posting list) from a list of entries.
    /// Shared by `finalize()` (fresh scans) and by `IndexStore` when
    /// reconstructing the index from a persisted or reconciled entry list,
    /// so a loaded-from-disk index and a freshly-scanned one are built by
    /// identical, already-tested logic.
    ///
    /// Parallelized across `ProcessInfo.processInfo.activeProcessorCount`
    /// shards: at ~450K entries this function was measured as the dominant
    /// cost of both a fresh scan and a cache load (~5-6s, entirely
    /// single-threaded before this change) — mostly the trigram posting-list
    /// dictionary (`trigramIndex[h, default: []].append(...)`, ~8-10M
    /// inserts, each a dictionary-value CoW array mutation). Each shard
    /// builds its slice of entries completely independently; a single merge
    /// pass then stitches the per-shard buffers/dictionaries together,
    /// adjusting byte offsets and entry indices from shard-local to global.
    /// `Scanner.scan` already parallelizes the scan phase this way — this
    /// extends the same approach to the build phase, which previously ran
    /// single-threaded regardless of core count.
    static func build(from entries: [FileEntry]) -> BuiltIndex {
        guard !entries.isEmpty else { return .empty }

        let shardCount = max(1, min(ProcessInfo.processInfo.activeProcessorCount, entries.count))
        let shardSize = (entries.count + shardCount - 1) / shardCount

        var shardResults = [ShardResult](repeating: ShardResult(), count: shardCount)
        shardResults.withUnsafeMutableBufferPointer { buffer in
            // `DispatchQueue.concurrentPerform` iterations each write to a
            // distinct `shardIndex` slot — genuinely race-free by
            // construction, but the compiler can't prove disjoint-index
            // writes are safe for a raw pointer, hence the explicit
            // `@unchecked Sendable` box asserting that to the checker.
            let box = UncheckedSendableBox(buffer)
            DispatchQueue.concurrentPerform(iterations: shardCount) { shardIndex in
                let start = shardIndex * shardSize
                let end = min(start + shardSize, entries.count)
                guard start < end else { return }
                box.value[shardIndex] = buildShard(entries[start..<end])
            }
        }

        return mergeShards(shardResults)
    }

    private static func buildShard(_ slice: ArraySlice<FileEntry>) -> ShardResult {
        var result = ShardResult()
        let count = slice.count
        result.nameBuffer.reserveCapacity(count * 24)
        result.nameOffsets.reserveCapacity(count)
        result.nameLengths.reserveCapacity(count)
        result.lowerBuffer.reserveCapacity(count * 24)
        result.lowerOffsets.reserveCapacity(count)
        result.lowerLengths.reserveCapacity(count)
        result.jamoBuffer.reserveCapacity(count * 16)
        result.jamoOffsets.reserveCapacity(count)
        result.jamoLengths.reserveCapacity(count)
        result.isDirectory.reserveCapacity(count)
        result.sizes.reserveCapacity(count)
        result.mtimes.reserveCapacity(count)
        result.crtimes.reserveCapacity(count)
        result.fileIDs.reserveCapacity(count)
        result.localParentIndices.reserveCapacity(count)

        var parentIntern: [String: UInt32] = [:]

        for (localIdx, rec) in slice.enumerated() {
            let idx = UInt32(localIdx)

            let nameBytes = Array(rec.name.utf8)
            result.nameOffsets.append(UInt32(result.nameBuffer.count))
            result.nameLengths.append(UInt16(min(nameBytes.count, Int(UInt16.max))))
            result.nameBuffer.append(contentsOf: nameBytes)

            let jamoString = HangulDecomposer.choseong(rec.name)
            let jamoBytes = Array(jamoString.utf8)
            result.jamoOffsets.append(UInt32(result.jamoBuffer.count))
            result.jamoLengths.append(UInt16(min(jamoBytes.count, Int(UInt16.max))))
            result.jamoBuffer.append(contentsOf: jamoBytes)

            let parentIdx: UInt32
            if let existing = parentIntern[rec.parentPath] {
                parentIdx = existing
            } else {
                parentIdx = UInt32(result.localParentPaths.count)
                result.localParentPaths.append(rec.parentPath)
                parentIntern[rec.parentPath] = parentIdx
            }
            result.localParentIndices.append(parentIdx)

            result.isDirectory.append(rec.isDirectory)
            result.sizes.append(rec.size)
            result.mtimes.append(rec.mtime)
            result.crtimes.append(rec.crtime)
            result.fileIDs.append(rec.fileID)

            let lower = rec.name.lowercased()
            let lowerBytes = Array(lower.utf8)
            result.lowerOffsets.append(UInt32(result.lowerBuffer.count))
            result.lowerLengths.append(UInt16(min(lowerBytes.count, Int(UInt16.max))))
            result.lowerBuffer.append(contentsOf: lowerBytes)

            let lowerScalars = Array(lower.unicodeScalars)
            TrigramIndex.forEachTrigram(of: lowerScalars) { h in
                result.trigramIndex[h, default: []].append(idx)
            }
        }

        return result
    }

    /// Stitches per-shard results into one `BuiltIndex`, in shard order (so
    /// the resulting entry order exactly matches the original `entries`
    /// array) — adjusting byte offsets (flat buffers) and entry indices
    /// (trigram posting lists) from shard-local to global, and re-interning
    /// parent paths globally. This merge is single-threaded, but cheap: at
    /// most a few thousand distinct parent directories and ~100K distinct
    /// trigram keys, versus the millions of per-entry operations each shard
    /// already did independently and in parallel.
    private static func mergeShards(_ shards: [ShardResult]) -> BuiltIndex {
        let totalCount = shards.reduce(0) { $0 + $1.isDirectory.count }

        var nameBuffer = [UInt8]()
        var nameOffsets = [UInt32]()
        var nameLengths = [UInt16]()
        var lowerBuffer = [UInt8]()
        var lowerOffsets = [UInt32]()
        var lowerLengths = [UInt16]()
        var jamoBuffer = [UInt8]()
        var jamoOffsets = [UInt32]()
        var jamoLengths = [UInt16]()
        var parentIndices = [UInt32]()
        var parentIntern: [String: UInt32] = [:]
        var parentPaths: [String] = []
        var isDirectory = [Bool]()
        var sizes = [UInt64]()
        var mtimes = [Int64]()
        var crtimes = [Int64]()
        var fileIDs = [UInt64]()
        var trigramIndex: [UInt32: [UInt32]] = [:]

        nameBuffer.reserveCapacity(shards.reduce(0) { $0 + $1.nameBuffer.count })
        nameOffsets.reserveCapacity(totalCount)
        nameLengths.reserveCapacity(totalCount)
        lowerBuffer.reserveCapacity(shards.reduce(0) { $0 + $1.lowerBuffer.count })
        lowerOffsets.reserveCapacity(totalCount)
        lowerLengths.reserveCapacity(totalCount)
        jamoBuffer.reserveCapacity(shards.reduce(0) { $0 + $1.jamoBuffer.count })
        jamoOffsets.reserveCapacity(totalCount)
        jamoLengths.reserveCapacity(totalCount)
        parentIndices.reserveCapacity(totalCount)
        isDirectory.reserveCapacity(totalCount)
        sizes.reserveCapacity(totalCount)
        mtimes.reserveCapacity(totalCount)
        crtimes.reserveCapacity(totalCount)
        fileIDs.reserveCapacity(totalCount)

        var entryBase: UInt32 = 0
        for shard in shards {
            let nameBase = UInt32(nameBuffer.count)
            let lowerBase = UInt32(lowerBuffer.count)
            let jamoBase = UInt32(jamoBuffer.count)

            nameBuffer.append(contentsOf: shard.nameBuffer)
            lowerBuffer.append(contentsOf: shard.lowerBuffer)
            jamoBuffer.append(contentsOf: shard.jamoBuffer)
            for o in shard.nameOffsets { nameOffsets.append(o + nameBase) }
            for o in shard.lowerOffsets { lowerOffsets.append(o + lowerBase) }
            for o in shard.jamoOffsets { jamoOffsets.append(o + jamoBase) }
            nameLengths.append(contentsOf: shard.nameLengths)
            lowerLengths.append(contentsOf: shard.lowerLengths)
            jamoLengths.append(contentsOf: shard.jamoLengths)
            isDirectory.append(contentsOf: shard.isDirectory)
            sizes.append(contentsOf: shard.sizes)
            mtimes.append(contentsOf: shard.mtimes)
            crtimes.append(contentsOf: shard.crtimes)
            fileIDs.append(contentsOf: shard.fileIDs)

            // Re-intern this shard's local parent paths into the global
            // table, then translate its per-entry local parent indices
            // through that mapping.
            var localToGlobalParent = [UInt32](repeating: 0, count: shard.localParentPaths.count)
            for (localIdx, path) in shard.localParentPaths.enumerated() {
                let globalIdx: UInt32
                if let existing = parentIntern[path] {
                    globalIdx = existing
                } else {
                    globalIdx = UInt32(parentPaths.count)
                    parentPaths.append(path)
                    parentIntern[path] = globalIdx
                }
                localToGlobalParent[localIdx] = globalIdx
            }
            for localParentIdx in shard.localParentIndices {
                parentIndices.append(localToGlobalParent[Int(localParentIdx)])
            }

            let base = entryBase
            for (key, localPostings) in shard.trigramIndex {
                trigramIndex[key, default: []].append(contentsOf: localPostings.map { $0 + base })
            }
            entryBase += UInt32(shard.isDirectory.count)
        }

        let mtimeSortedIndices = (0..<UInt32(totalCount)).sorted { mtimes[Int($1)] < mtimes[Int($0)] }

        return BuiltIndex(
            nameBuffer: nameBuffer, nameOffsets: nameOffsets, nameLengths: nameLengths,
            lowerBuffer: lowerBuffer, lowerOffsets: lowerOffsets, lowerLengths: lowerLengths,
            jamoBuffer: jamoBuffer, jamoOffsets: jamoOffsets, jamoLengths: jamoLengths,
            parentIndices: parentIndices, parentPaths: parentPaths,
            isDirectory: isDirectory, sizes: sizes, mtimes: mtimes, crtimes: crtimes, fileIDs: fileIDs,
            trigramIndex: trigramIndex, mtimeSortedIndices: mtimeSortedIndices
        )
    }
}
