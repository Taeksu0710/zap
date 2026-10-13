import Foundation

/// Trigram extraction over Unicode scalars (not raw UTF-8 bytes), so a
/// 3-character window works uniformly whether the characters are ASCII
/// letters or multi-byte Hangul syllables.
enum TrigramIndex {
    @inline(__always)
    static func hash(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt32 {
        // Unrolled (no `for v in [a, b, c]`): that literal array heap-allocates
        // on every call, and this runs ~1.7M times over a 95K-entry index —
        // measured as the dominant cost of IndexBuilder.build(from:) (~1s of
        // ~1.16s total) before this fix.
        // Not actually FNV-1a (the real offset basis is
        // 14_695_981_039_346_656_037, and standard FNV-1a XORs individual
        // bytes rather than whole 32-bit scalars) — just an internal,
        // non-cryptographic hash. Never persisted (IndexBuilder always
        // recomputes it from the saved [FileEntry] list on load), so the
        // exact constants are arbitrary as long as they distribute well.
        var h: UInt64 = 1_469_598_103_934_665_603
        h ^= UInt64(a)
        h = h &* 1_099_511_628_211
        h ^= UInt64(b)
        h = h &* 1_099_511_628_211
        h ^= UInt64(c)
        h = h &* 1_099_511_628_211
        return UInt32(truncatingIfNeeded: h)
    }

    /// Returns the set of distinct trigram hashes present in `scalars`.
    /// Empty if there are fewer than 3 scalars.
    ///
    /// Used by query-side candidate selection (small, one-off per search) —
    /// index-build time uses `forEachTrigram` instead (see its doc comment).
    static func trigrams(of scalars: [Unicode.Scalar]) -> Set<UInt32> {
        guard scalars.count >= 3 else { return [] }
        var result = Set<UInt32>()
        result.reserveCapacity(scalars.count - 2)
        for i in 0...(scalars.count - 3) {
            result.insert(hash(scalars[i].value, scalars[i + 1].value, scalars[i + 2].value))
        }
        return result
    }

    /// Calls `body` once per trigram window in `scalars`, in order, WITHOUT
    /// deduplicating repeats within the same name (e.g. "aaaa" yields "aaa"
    /// twice). Used at index-build time across hundreds of thousands of
    /// names — allocating a fresh `Set<UInt32>` per name (as `trigrams(of:)`
    /// does) measured as the dominant cost of `IndexBuilder.build(from:)`.
    /// A posting list containing the same entry index twice for a repeated
    /// trigram is harmless: candidate selection only ever intersects these
    /// lists into a `Set`, which silently absorbs the duplicate.
    @inline(__always)
    static func forEachTrigram(of scalars: [Unicode.Scalar], _ body: (UInt32) -> Void) {
        guard scalars.count >= 3 else { return }
        for i in 0...(scalars.count - 3) {
            body(hash(scalars[i].value, scalars[i + 1].value, scalars[i + 2].value))
        }
    }
}
