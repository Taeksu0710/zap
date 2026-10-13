import Foundation
import FindFastCore

func makeFixture() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("findfast-test-\(UUID().uuidString)")
    let sub = dir.appendingPathComponent("sub1/sub2")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

    try "x".write(to: dir.appendingPathComponent("설계도면.dwg"), atomically: true, encoding: .utf8)
    try "x".write(to: dir.appendingPathComponent("나눔고딕.ttf"), atomically: true, encoding: .utf8)
    try "x".write(to: dir.appendingPathComponent("report.pdf"), atomically: true, encoding: .utf8)
    try "x".write(to: dir.appendingPathComponent("sub1/또다른파일.txt"), atomically: true, encoding: .utf8)
    try "x".write(
        to: dir.appendingPathComponent("sub1/sub2/deep나눔file.txt"), atomically: true, encoding: .utf8
    )
    return dir
}

@main
struct FindFastTests {
    static func main() async {
        let check = Check()

        check.suite("HangulDecomposer") {
            check.equal(HangulDecomposer.choseong("설계도면"), "ㅅㄱㄷㅁ", "fastFindExample")
            check.equal(HangulDecomposer.choseong("나눔고딕"), "ㄴㄴㄱㄷ", "fontFileName")
            check.equal(HangulDecomposer.choseong("또다른"), "ㄸㄷㄹ", "doubleConsonantInitial")
            check.equal(HangulDecomposer.choseong("ABCdef123"), "ABCdef123", "nonHangulPassesThrough")
            check.equal(HangulDecomposer.choseong("나눔고딕.ttf"), "ㄴㄴㄱㄷ.ttf", "mixedHangulAndAscii")
            check.equal(HangulDecomposer.choseong(""), "", "emptyString")
            check.equal(HangulDecomposer.choseong("ㅏㅓ"), "ㅏㅓ", "standaloneJamoPassesThrough")
        }

        check.suite("Scanner.isPathExcluded") {
            let home = "/Users/taekskim"
            // The actual bug this guards against: FSEvents reconciliation
            // re-scanning another app's container data triggers macOS's
            // "would like to access another app's data" TCC prompt,
            // repeatedly, for every distinct container touched.
            check.isTrue(
                Scanner.isPathExcluded(
                    "\(home)/Library/Containers/com.other.app/Data/tmp", root: home),
                "otherAppContainerIsExcluded"
            )
            check.isTrue(
                Scanner.isPathExcluded("\(home)/Projects/foo/node_modules/bar", root: home),
                "nodeModulesIsExcluded"
            )
            check.isFalse(
                Scanner.isPathExcluded("\(home)/Desktop/notes.txt", root: home),
                "ordinaryFileIsNotExcluded"
            )
            // Regression: a scan root that itself sits inside a path
            // matching `defaultSkipPaths` (e.g. the system temp directory,
            // under `/private/var/folders`) must not have its own contents
            // excluded — only genuine descendants of a skip rule should be.
            let tmpRoot = "/private/var/folders/xx/yy/T/sometestdir"
            check.isFalse(
                Scanner.isPathExcluded("\(tmpRoot)/실시간파일.txt", root: tmpRoot),
                "rootInsideSkipPathDoesNotExcludeOwnContents"
            )

            // Regression: a trailing slash on `root` used to make the
            // internal `rootPrefix` become "//", which no real path ever
            // has a prefix of — silently disabling exclusion entirely for
            // that call (reopening the exact TCC-prompt-storm bug above).
            check.isTrue(
                Scanner.isPathExcluded(
                    "\(home)/Library/Containers/com.other.app/Data/tmp", root: "\(home)/"),
                "trailingSlashOnRootStillExcludesLibrary"
            )

            // Regression: when `root` itself exactly equals a `skipPaths`
            // entry, that must NOT blanket-exclude every path under root —
            // only genuine descendants of a skip rule should be excluded.
            let skipPathRoot = "/private/var/folders"
            check.isFalse(
                Scanner.isPathExcluded("\(skipPathRoot)/some/file.txt", root: skipPathRoot),
                "rootExactlyEqualToSkipPathDoesNotExcludeEverything"
            )
        }

        check.suite("QueryParser") {
            let q1 = QueryParser.parse("나눔")
            check.equal(q1.raw, "나눔", "plainNameQuery.raw")
            check.isFalse(q1.isJamoQuery, "plainNameQuery.isJamoQuery")

            check.isTrue(QueryParser.parse("ㅅㄱㄷㅁ").isJamoQuery, "jamoOnlyQuery")
            check.isFalse(QueryParser.parse("ㅅㄱ나").isJamoQuery, "mixedJamoAndSyllableIsNotJamoQuery")
            check.equal(QueryParser.parse("  report  ").raw, "report", "trimsWhitespace")

            // APFS hands back Hangul filenames pre-decomposed (NFD); make
            // sure a query gets normalized to the same NFC form Scanner
            // normalizes filenames to, or substring/jamo matching silently
            // fails (see ScannerWorker.swift).
            let nfdInput = "나눔".decomposedStringWithCanonicalMapping
            check.equal(QueryParser.parse(nfdInput).raw, "나눔", "normalizesNFDQueryToNFC")

            let empty = QueryParser.parse("   ")
            check.isTrue(empty.raw.isEmpty, "emptyQuery.raw")
            check.isFalse(empty.isJamoQuery, "emptyQuery.isJamoQuery")
        }

        check.suite("CLIArguments.parse") {
            let defaultRoot = "/Users/someone"

            let full = CLIArguments.parse(["findfast", "-s", "나눔", "-p", "/tmp"], defaultRoot: defaultRoot)
            check.equal(full.searchTerm, "나눔", "shortFlags.searchTerm")
            check.equal(full.rootPath, "/tmp", "shortFlags.rootPath")

            let longSearch = CLIArguments.parse(["findfast", "--search", "report"], defaultRoot: defaultRoot)
            check.equal(longSearch.searchTerm, "report", "longSearchFlag")
            check.equal(longSearch.rootPath, defaultRoot, "longSearchFlag.rootPathDefaults")

            // No -s at all: searchTerm stays nil (main() prints usage + exits
            // on this, but that's not exercised here — just the parse result).
            let missingSearch = CLIArguments.parse(["findfast", "-p", "/tmp"], defaultRoot: defaultRoot)
            check.isTrue(missingSearch.searchTerm == nil, "missingSearchFlag.searchTermIsNil")

            // "-s" as the very last argument, with no value following it —
            // must not crash (array out-of-bounds) and must leave
            // searchTerm nil rather than consuming the next flag as a value.
            let danglingFlag = CLIArguments.parse(["findfast", "-s"], defaultRoot: defaultRoot)
            check.isTrue(danglingFlag.searchTerm == nil, "danglingSearchFlag.searchTermIsNil")

            // Unknown flags are silently ignored, not treated as errors.
            let unknown = CLIArguments.parse(["findfast", "--bogus", "-s", "x"], defaultRoot: defaultRoot)
            check.equal(unknown.searchTerm, "x", "unknownFlagIgnored")
        }

        await check.suite("IndexStore") {
            let dir = try makeFixture()
            defer { try? FileManager.default.removeItem(at: dir) }

            let store = IndexStore()
            let count = await store.build(root: dir.path)
            check.equal(count, 7, "entryCount") // 5 files + 2 directories (sub1, sub1/sub2)

            let jamoResults = await store.search(QueryParser.parse("ㅅㄱㄷㅁ"))
            check.equal(jamoResults.map(\.name), ["설계도면.dwg"], "jamoSearch")

            let substringResults = await store.search(QueryParser.parse("나눔"))
            check.equal(
                Set(substringResults.map(\.name)), ["나눔고딕.ttf", "deep나눔file.txt"],
                "substringSearchNested"
            )

            let exactResults = await store.search(QueryParser.parse("report.pdf"))
            check.equal(exactResults.first?.name, "report.pdf", "exactMatchRanksFirst")

            let noResults = await store.search(QueryParser.parse("doesnotexist"))
            check.isTrue(noResults.isEmpty, "noMatchReturnsEmpty")
        }

        check.suite("IndexFile") {
            let dir = try makeFixture()
            let storageDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("findfast-index-storage-\(UUID().uuidString)")
            IndexFile.baseDirectoryOverride = storageDir
            defer {
                try? FileManager.default.removeItem(at: dir)
                try? FileManager.default.removeItem(at: storageDir)
                IndexFile.baseDirectoryOverride = nil
            }

            let original: [FileEntry] = [
                FileEntry(name: "설계도면.dwg", parentPath: dir.path, isDirectory: false, size: 5, mtime: 1_700_000_000, crtime: 1_690_000_000, fileID: 1),
                FileEntry(name: "나눔고딕.ttf", parentPath: dir.path, isDirectory: false, size: 8, mtime: 1_700_000_001, crtime: 1_690_000_001, fileID: 2),
                FileEntry(name: "report.pdf", parentPath: dir.path, isDirectory: false, size: 1024, mtime: 1_700_000_002, crtime: 1_690_000_002, fileID: 3),
                FileEntry(name: "sub1", parentPath: dir.path, isDirectory: true, size: 0, mtime: 1_700_000_003, crtime: 1_690_000_003, fileID: 4),
                FileEntry(name: "또다른파일.txt", parentPath: dir.path + "/sub1", isDirectory: false, size: 2, mtime: 1_700_000_004, crtime: 1_690_000_004, fileID: 5),
            ]

            try IndexFile.save(entries: original, scanRoot: dir.path)
            check.isTrue(
                FileManager.default.fileExists(atPath: IndexFile.indexURL.path), "indexFileExists"
            )

            let loaded = try IndexFile.load(expecting: dir.path)
            check.equal(loaded.count, original.count, "roundTripCount")
            check.equal(Set(loaded.map(\.name)), Set(original.map(\.name)), "roundTripNamesMatch")
            check.equal(Set(loaded.map(\.fileID)), Set(original.map(\.fileID)), "roundTripFileIDsMatch")
            check.equal(Set(loaded.map(\.parentPath)), Set(original.map(\.parentPath)), "roundTripParentPathsMatch")
            check.equal(Set(loaded.map(\.size)), Set(original.map(\.size)), "roundTripSizesMatch")
            check.equal(Set(loaded.map(\.mtime)), Set(original.map(\.mtime)), "roundTripMtimesMatch")
            check.equal(Set(loaded.map(\.crtime)), Set(original.map(\.crtime)), "roundTripCrtimesMatch")
            check.equal(Set(loaded.map(\.isDirectory)), Set(original.map(\.isDirectory)), "roundTripIsDirectoryMatch")

            // Wrong scan root should be rejected (root mismatch), not silently
            // accepted with mismatched data.
            do {
                _ = try IndexFile.load(expecting: "/some/other/root")
                check.isTrue(false, "rootMismatchShouldThrow")
            } catch IndexFileError.rootMismatch {
                // expected
            } catch {
                check.isTrue(false, "rootMismatchShouldThrowSpecificError:\(error)")
            }

            // Corrupting the file should make load() fail cleanly rather than
            // crash or return garbage — loadOrBuild relies on this to fall
            // back to a full rescan.
            var corrupted = try Data(contentsOf: IndexFile.indexURL)
            for i in 0..<min(8, corrupted.count) { corrupted[i] = 0xFF }
            try corrupted.write(to: IndexFile.indexURL)
            do {
                _ = try IndexFile.load(expecting: dir.path)
                check.isTrue(false, "corruptedFileShouldThrow")
            } catch IndexFileError.corrupted {
                // expected
            } catch {
                check.isTrue(false, "corruptedFileShouldThrowSpecificError:\(error)")
            }

            // Re-save a clean copy, then tamper with just the formatVersion
            // field (offset 8-9) to simulate an older/newer binary's index
            // file — loadOrBuild relies on this to fall back to a rescan
            // rather than misinterpret a differently-shaped file.
            try IndexFile.save(entries: original, scanRoot: dir.path)
            var versionTampered = try Data(contentsOf: IndexFile.indexURL)
            versionTampered[8] = 0xFF
            versionTampered[9] = 0xFF
            try versionTampered.write(to: IndexFile.indexURL)
            do {
                _ = try IndexFile.load(expecting: dir.path)
                check.isTrue(false, "versionMismatchShouldThrow")
            } catch IndexFileError.versionMismatch {
                // expected
            } catch {
                check.isTrue(false, "versionMismatchShouldThrowSpecificError:\(error)")
            }

            // Re-save a clean copy, then tamper with the stored volumeUUID
            // bytes (offset 68-83) so they can't match the real volume's
            // UUID — simulates loading an index built on a different disk.
            try IndexFile.save(entries: original, scanRoot: dir.path)
            var volumeTampered = try Data(contentsOf: IndexFile.indexURL)
            for offset in 68..<84 {
                volumeTampered[offset] = 0xAB
            }
            try volumeTampered.write(to: IndexFile.indexURL)
            do {
                _ = try IndexFile.load(expecting: dir.path)
                check.isTrue(false, "volumeMismatchShouldThrow")
            } catch IndexFileError.volumeMismatch {
                // expected
            } catch {
                check.isTrue(false, "volumeMismatchShouldThrowSpecificError:\(error)")
            }
        }

        await check.suite("IndexStore.handleDirtyPaths") {
            let dir = try makeFixture()
            let storageDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("findfast-reconcile-\(UUID().uuidString)")
            IndexFile.baseDirectoryOverride = storageDir
            defer {
                try? FileManager.default.removeItem(at: dir)
                try? FileManager.default.removeItem(at: storageDir)
                IndexFile.baseDirectoryOverride = nil
            }

            let store = IndexStore()
            _ = await store.build(root: dir.path)

            // Regression: a dirty path that's entirely filtered out by
            // isPathExcluded (e.g. another app's container under this
            // scan-root's Library folder) must hit the early return and
            // leave the index completely untouched, not just "mostly"
            // untouched — this is the exact scenario the exclusion filter
            // was added for (see Scanner.isPathExcluded).
            let countBeforeExcluded = await store.entryCount
            await store.handleDirtyPaths(["\(dir.path)/Library/Containers/com.other.app/Data"])
            let countAfterExcluded = await store.entryCount
            check.equal(countAfterExcluded, countBeforeExcluded, "allExcludedDirtyPathsAreNoOp")

            // Add a new file on disk, then simulate the watcher reporting the
            // containing directory as dirty (this is the deterministic,
            // non-flaky counterpart to the real-FSEvents test below).
            try "x".write(to: dir.appendingPathComponent("새파일.txt"), atomically: true, encoding: .utf8)
            await store.handleDirtyPaths([dir.path])
            let afterAdd = await store.search(QueryParser.parse("새파일"))
            check.equal(afterAdd.map(\.name), ["새파일.txt"], "reconcileDetectsNewFile")

            // Delete an existing file, reconcile again.
            try FileManager.default.removeItem(at: dir.appendingPathComponent("report.pdf"))
            await store.handleDirtyPaths([dir.path])
            let afterDelete = await store.search(QueryParser.parse("report.pdf"))
            check.isTrue(afterDelete.isEmpty, "reconcileDetectsDeletedFile")

            // Delete the whole sub1 subtree, reconcile at the PARENT level
            // only (mirrors what a real ItemRemoved event's parent-dir
            // computation would report) — confirm the entire nested subtree
            // disappears via prefix-drop cascading, not just the direct child.
            try FileManager.default.removeItem(at: dir.appendingPathComponent("sub1"))
            await store.handleDirtyPaths([dir.path])
            let shallowDeep = await store.search(QueryParser.parse("또다른파일"))
            check.isTrue(shallowDeep.isEmpty, "reconcileCascadesSubtreeDeletion")
            let nestedDeep = await store.search(QueryParser.parse("deep나눔"))
            check.isTrue(nestedDeep.isEmpty, "reconcileCascadesNestedSubtreeDeletion")
        }

        await check.suite("IndexStore.liveWatching") {
            let dir = try makeFixture()
            let storageDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("findfast-watch-\(UUID().uuidString)")
            IndexFile.baseDirectoryOverride = storageDir
            defer {
                try? FileManager.default.removeItem(at: dir)
                try? FileManager.default.removeItem(at: storageDir)
                IndexFile.baseDirectoryOverride = nil
            }

            let store = IndexStore()
            _ = await store.build(root: dir.path)
            await store.startWatching(root: dir.path)

            try "x".write(to: dir.appendingPathComponent("실시간파일.txt"), atomically: true, encoding: .utf8)

            // FSEvents' own coalescing latency is 1.5s (see Watcher.swift) —
            // give real wall-clock margin rather than racing it.
            try await Task.sleep(nanoseconds: 3_000_000_000)

            let found = await store.search(QueryParser.parse("실시간"))
            check.equal(found.map(\.name), ["실시간파일.txt"], "liveWatchingPicksUpNewFile")

            await store.stopWatching()
        }

        let ok = check.report()
        exit(ok ? 0 : 1)
    }
}
