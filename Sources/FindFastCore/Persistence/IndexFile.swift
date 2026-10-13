import Foundation

public enum IndexFileError: Error, CustomStringConvertible, Sendable {
    case notFound
    case versionMismatch(found: Int, expected: Int)
    case volumeMismatch
    case rootMismatch
    case corrupted(String)

    public var description: String {
        switch self {
        case .notFound:
            return "index file not found"
        case .versionMismatch(let found, let expected):
            return "index format version mismatch (found \(found), expected \(expected))"
        case .volumeMismatch:
            return "index was built for a different volume"
        case .rootMismatch:
            return "index was built for a different scan root"
        case .corrupted(let reason):
            return "index file corrupted: \(reason)"
        }
    }
}

/// Binary persistence for the index's source-of-truth `[FileEntry]` list.
///
/// Deliberately does NOT serialize `BuiltIndex` (trigram posting lists, jamo
/// buffers, etc.) directly — those are cheap to recompute from a flat entry
/// list via `IndexBuilder.build(from:)`, so this format only needs to be a
/// simple, robust record list. This avoids writing a custom binary parser for
/// the more complex derived structures.
///
/// Layout (all integers little-endian):
///   Header (512 bytes, fixed):
///     0   8   magic: "FFAST" + 0x01 + 0x00 0x00 (sanity check only)
///     8   2   formatVersion: UInt16 (authoritative compatibility check)
///     10  2   flags: UInt16 (reserved, 0)
///     12  4   entryCount: UInt32
///     16  4   parentCount: UInt32
///     20  8   entryBlockOffset: UInt64 (always 512)
///     28  8   parentTableOffset: UInt64
///     36  8   nameDataOffset: UInt64
///     44  8   nameDataLength: UInt64
///     52  8   savedEventID: UInt64
///     60  8   savedAt: Int64 (unix epoch seconds)
///     68  16  volumeUUID: 16 raw bytes
///     84  256 scanRoot: NUL-terminated UTF-8, zero-padded
///     340 172 reserved (zero)
///   Entry block (entryCount * 44 bytes, immediately after header):
///     0  8  fileID: UInt64
///     8  8  mtime: Int64
///     16 8  crtime: Int64 (creation/birth time)
///     24 8  size: UInt64
///     32 4  parentIndex: UInt32
///     36 4  nameOffset: UInt32 (relative to nameDataOffset)
///     40 2  nameLength: UInt16
///     42 1  isDirectory: UInt8 (0/1)
///     43 1  reserved
///   Parent path table (parentCount entries, immediately after entry block):
///     UInt16 byteLength, then that many UTF-8 bytes (no terminator)
///   Name data blob (immediately after parent table):
///     concatenated UTF-8 name bytes, referenced by nameOffset/nameLength
public enum IndexFile {
    public static let formatVersion: UInt16 = 2

    private static let magic: [UInt8] = [0x46, 0x46, 0x41, 0x53, 0x54, 0x01, 0x00, 0x00] // "FFAST" + 0x01 0x00 0x00
    private static let headerSize = 512
    private static let entryRecordSize = 44
    private static let scanRootFieldOffset = 84
    private static let scanRootFieldSize = 256

    /// Overrides the storage directory (tests only — so a test run never
    /// reads/writes/corrupts the real `~/Library/Application Support/FindFast`
    /// that an actual app session relies on). `nil` uses the real location.
    nonisolated(unsafe) public static var baseDirectoryOverride: URL?

    private static var directoryURL: URL {
        if let override = baseDirectoryOverride { return override }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        // "FindFast" is a legacy identifier predating the "Zap" rebrand, kept
        // deliberately: both the CLI and GUI share this one hardcoded path,
        // so they'd need to change in lockstep anyway, and renaming it would
        // silently abandon any already-indexed user's cache (forcing a full
        // rescan on next launch) for a purely cosmetic gain.
        return base.appendingPathComponent("FindFast", isDirectory: true)
    }

    public static var indexURL: URL { directoryURL.appendingPathComponent("index.bin") }
    public static var metaURL: URL { directoryURL.appendingPathComponent("index.meta.json") }

    // MARK: - Save

    public static func save(entries: [FileEntry], scanRoot: String, savedEventID: UInt64 = 0) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        // Intern parent paths.
        var parentIntern: [String: UInt32] = [:]
        var parentPaths: [String] = []
        var parentIndexFor = [UInt32]()
        parentIndexFor.reserveCapacity(entries.count)
        for e in entries {
            if let existing = parentIntern[e.parentPath] {
                parentIndexFor.append(existing)
            } else {
                let idx = UInt32(parentPaths.count)
                parentPaths.append(e.parentPath)
                parentIntern[e.parentPath] = idx
                parentIndexFor.append(idx)
            }
        }

        // Name data blob + per-entry offset/length.
        //
        // `nameLengths` below is clamped to UInt16.max, but macOS's NAME_MAX
        // (255 bytes) makes that unreachable in practice — a defensive clamp
        // only, not a real truncation path (it would otherwise desync from
        // the full byte count appended to `nameBlob`, but that can't happen
        // on this filesystem).
        var nameBlob = [UInt8]()
        nameBlob.reserveCapacity(entries.count * 24)
        var nameOffsets = [UInt32]()
        var nameLengths = [UInt16]()
        nameOffsets.reserveCapacity(entries.count)
        nameLengths.reserveCapacity(entries.count)
        for e in entries {
            let bytes = Array(e.name.utf8)
            nameOffsets.append(UInt32(nameBlob.count))
            nameLengths.append(UInt16(min(bytes.count, Int(UInt16.max))))
            nameBlob.append(contentsOf: bytes)
        }

        // Parent path table.
        var parentTable = [UInt8]()
        for p in parentPaths {
            let bytes = Array(p.utf8)
            appendU16LE(UInt16(min(bytes.count, Int(UInt16.max))), to: &parentTable)
            parentTable.append(contentsOf: bytes)
        }

        let entryBlockOffset = UInt64(headerSize)
        let parentTableOffset = entryBlockOffset + UInt64(entries.count * entryRecordSize)
        let nameDataOffset = parentTableOffset + UInt64(parentTable.count)
        let nameDataLength = UInt64(nameBlob.count)

        var volumeUUIDBytes = [UInt8](repeating: 0, count: 16)
        if let uuidString = IndexMetadata.volumeUUIDString(for: scanRoot), let uuid = UUID(uuidString: uuidString) {
            let t = uuid.uuid
            volumeUUIDBytes = [
                t.0, t.1, t.2, t.3, t.4, t.5, t.6, t.7,
                t.8, t.9, t.10, t.11, t.12, t.13, t.14, t.15,
            ]
        }

        // Header.
        var header = [UInt8](repeating: 0, count: headerSize)
        setBytes(magic, in: &header, at: 0)
        setU16LE(formatVersion, in: &header, at: 8)
        setU16LE(0, in: &header, at: 10) // flags, reserved
        setU32LE(UInt32(entries.count), in: &header, at: 12)
        setU32LE(UInt32(parentPaths.count), in: &header, at: 16)
        setU64LE(entryBlockOffset, in: &header, at: 20)
        setU64LE(parentTableOffset, in: &header, at: 28)
        setU64LE(nameDataOffset, in: &header, at: 36)
        setU64LE(nameDataLength, in: &header, at: 44)
        setU64LE(savedEventID, in: &header, at: 52)
        setI64LE(Int64(Date().timeIntervalSince1970), in: &header, at: 60)
        setBytes(volumeUUIDBytes, in: &header, at: 68)
        let rootBytes = Array(scanRoot.utf8.prefix(scanRootFieldSize - 1))
        setBytes(rootBytes, in: &header, at: scanRootFieldOffset)
        // remaining header bytes (version marker tail, reserved) stay zero

        // Entry block.
        var entryBlock = [UInt8]()
        entryBlock.reserveCapacity(entries.count * entryRecordSize)
        for (i, e) in entries.enumerated() {
            appendU64LE(e.fileID, to: &entryBlock)
            appendI64LE(e.mtime, to: &entryBlock)
            appendI64LE(e.crtime, to: &entryBlock)
            appendU64LE(e.size, to: &entryBlock)
            appendU32LE(parentIndexFor[i], to: &entryBlock)
            appendU32LE(nameOffsets[i], to: &entryBlock)
            appendU16LE(nameLengths[i], to: &entryBlock)
            entryBlock.append(e.isDirectory ? 1 : 0)
            entryBlock.append(0) // reserved pad byte
        }

        // Assemble and write atomically: temp file + fsync + rename.
        var fileData = Data(capacity: headerSize + entryBlock.count + parentTable.count + nameBlob.count)
        fileData.append(contentsOf: header)
        fileData.append(contentsOf: entryBlock)
        fileData.append(contentsOf: parentTable)
        fileData.append(contentsOf: nameBlob)

        // `.atomic` has Foundation write to a temp file then rename over the
        // destination, so a crash mid-write can never leave a partial index.bin.
        try fileData.write(to: indexURL, options: .atomic)

        let metadata = IndexMetadata.current(entryCount: entries.count, scanRoot: scanRoot, savedEventID: savedEventID)
        if let metaData = try? JSONEncoder.indexMetadataEncoder.encode(metadata) {
            try? metaData.write(to: metaURL, options: .atomic)
        }
    }

    // MARK: - Load

    public static func load(expecting scanRoot: String) throws -> [FileEntry] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            throw IndexFileError.notFound
        }
        let data = try Data(contentsOf: indexURL)
        guard data.count >= headerSize else {
            throw IndexFileError.corrupted("file shorter than header (\(data.count) bytes)")
        }

        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [FileEntry] in
            let headerBytes = Array(raw[0..<8])
            guard headerBytes == magic else {
                throw IndexFileError.corrupted("magic bytes mismatch")
            }
            let version = readU16LE(raw, at: 8)
            guard version == formatVersion else {
                throw IndexFileError.versionMismatch(found: Int(version), expected: Int(formatVersion))
            }
            let entryCount = Int(readU32LE(raw, at: 12))
            let parentCount = Int(readU32LE(raw, at: 16))
            let entryBlockOffset = Int(readU64LE(raw, at: 20))
            let parentTableOffset = Int(readU64LE(raw, at: 28))
            let nameDataOffset = Int(readU64LE(raw, at: 36))
            let nameDataLength = Int(readU64LE(raw, at: 44))

            // If the current volume's UUID lookup fails (all-zero
            // `currentVolumeUUIDBytes`), this check is skipped entirely
            // rather than treated as a mismatch — a transient lookup
            // failure shouldn't force a full rescan. The `rootMismatch`
            // check just below still catches the common case of loading
            // against an unrelated path.
            let storedVolumeUUID = Array(raw[68..<84])
            let currentVolumeUUIDBytes = volumeUUIDBytes(for: scanRoot)
            if currentVolumeUUIDBytes != [UInt8](repeating: 0, count: 16),
                storedVolumeUUID != currentVolumeUUIDBytes {
                throw IndexFileError.volumeMismatch
            }

            let rootBytes = Array(raw[scanRootFieldOffset..<(scanRootFieldOffset + scanRootFieldSize)])
            let nulIndex = rootBytes.firstIndex(of: 0) ?? rootBytes.count
            let storedRoot = String(decoding: rootBytes[0..<nulIndex], as: UTF8.self)
            guard storedRoot == scanRoot else {
                throw IndexFileError.rootMismatch
            }

            guard data.count >= nameDataOffset + nameDataLength else {
                throw IndexFileError.corrupted("file truncated before name data end")
            }

            // Parent path table.
            var parentPaths: [String] = []
            parentPaths.reserveCapacity(parentCount)
            var cursor = parentTableOffset
            for _ in 0..<parentCount {
                guard cursor + 2 <= raw.count else {
                    throw IndexFileError.corrupted("parent table truncated")
                }
                let len = Int(readU16LE(raw, at: cursor))
                cursor += 2
                guard cursor + len <= raw.count else {
                    throw IndexFileError.corrupted("parent path entry truncated")
                }
                let bytes = Array(raw[cursor..<(cursor + len)])
                // No re-normalization here: the UTF-8 bytes are a faithful
                // round trip of whatever was saved, and everything that ever
                // reaches IndexFile.save(entries:) already passed through
                // ScannerWorker's NFC normalization at the true source
                // boundary (APFS hands back decomposed/NFD Hangul). A
                // redundant per-entry `.precomposedStringWithCanonicalMapping`
                // here measured as a meaningful chunk of load() time at
                // ~100K entries for zero behavioral benefit.
                parentPaths.append(String(decoding: bytes, as: UTF8.self))
                cursor += len
            }
            guard cursor <= nameDataOffset else {
                throw IndexFileError.corrupted("parent table overruns name data region")
            }

            // Entry block.
            var result: [FileEntry] = []
            result.reserveCapacity(entryCount)
            for i in 0..<entryCount {
                let base = entryBlockOffset + i * entryRecordSize
                guard base + entryRecordSize <= raw.count else {
                    throw IndexFileError.corrupted("entry block truncated at index \(i)")
                }
                let fileID = readU64LE(raw, at: base)
                let mtime = readI64LE(raw, at: base + 8)
                let crtime = readI64LE(raw, at: base + 16)
                let size = readU64LE(raw, at: base + 24)
                let parentIndex = Int(readU32LE(raw, at: base + 32))
                let nameOffset = Int(readU32LE(raw, at: base + 36))
                let nameLength = Int(readU16LE(raw, at: base + 40))
                let isDirectory = raw[base + 42] != 0

                guard parentIndex < parentPaths.count else {
                    throw IndexFileError.corrupted("parent index out of range at entry \(i)")
                }
                let nameStart = nameDataOffset + nameOffset
                guard nameStart + nameLength <= raw.count else {
                    throw IndexFileError.corrupted("name bytes out of range at entry \(i)")
                }
                let nameBytes = Array(raw[nameStart..<(nameStart + nameLength)])
                let name = String(decoding: nameBytes, as: UTF8.self) // see NFC note above

                result.append(FileEntry(
                    name: name,
                    parentPath: parentPaths[parentIndex],
                    isDirectory: isDirectory,
                    size: size,
                    mtime: mtime,
                    crtime: crtime,
                    fileID: fileID
                ))
            }
            return result
        }
    }
}

// MARK: - Byte packing helpers (little-endian, manual — no struct overlay to
// avoid any compiler-inserted padding/alignment surprises).

private func appendU16LE(_ v: UInt16, to buf: inout [UInt8]) {
    let le = v.littleEndian
    buf.append(UInt8(le & 0xFF))
    buf.append(UInt8((le >> 8) & 0xFF))
}

private func appendU32LE(_ v: UInt32, to buf: inout [UInt8]) {
    let le = v.littleEndian
    for shift in stride(from: 0, to: 32, by: 8) {
        buf.append(UInt8((le >> shift) & 0xFF))
    }
}

private func appendU64LE(_ v: UInt64, to buf: inout [UInt8]) {
    let le = v.littleEndian
    for shift in stride(from: 0, to: 64, by: 8) {
        buf.append(UInt8((le >> shift) & 0xFF))
    }
}

private func appendI64LE(_ v: Int64, to buf: inout [UInt8]) {
    appendU64LE(UInt64(bitPattern: v), to: &buf)
}

private func setBytes(_ bytes: [UInt8], in buf: inout [UInt8], at offset: Int) {
    for (i, b) in bytes.enumerated() {
        buf[offset + i] = b
    }
}

private func setU16LE(_ v: UInt16, in buf: inout [UInt8], at offset: Int) {
    var tmp = [UInt8]()
    appendU16LE(v, to: &tmp)
    setBytes(tmp, in: &buf, at: offset)
}

private func setU32LE(_ v: UInt32, in buf: inout [UInt8], at offset: Int) {
    var tmp = [UInt8]()
    appendU32LE(v, to: &tmp)
    setBytes(tmp, in: &buf, at: offset)
}

private func setU64LE(_ v: UInt64, in buf: inout [UInt8], at offset: Int) {
    var tmp = [UInt8]()
    appendU64LE(v, to: &tmp)
    setBytes(tmp, in: &buf, at: offset)
}

private func setI64LE(_ v: Int64, in buf: inout [UInt8], at offset: Int) {
    setU64LE(UInt64(bitPattern: v), in: &buf, at: offset)
}

private func readU16LE(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt16 {
    UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
}

private func readU32LE(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
    var v: UInt32 = 0
    for i in 0..<4 {
        v |= UInt32(raw[offset + i]) << (8 * i)
    }
    return v
}

private func readU64LE(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<8 {
        v |= UInt64(raw[offset + i]) << (8 * i)
    }
    return v
}

private func readI64LE(_ raw: UnsafeRawBufferPointer, at offset: Int) -> Int64 {
    Int64(bitPattern: readU64LE(raw, at: offset))
}

private func volumeUUIDBytes(for path: String) -> [UInt8] {
    guard let uuidString = IndexMetadata.volumeUUIDString(for: path), let uuid = UUID(uuidString: uuidString) else {
        return [UInt8](repeating: 0, count: 16)
    }
    let t = uuid.uuid
    return [t.0, t.1, t.2, t.3, t.4, t.5, t.6, t.7, t.8, t.9, t.10, t.11, t.12, t.13, t.14, t.15]
}

extension JSONEncoder {
    fileprivate static let indexMetadataEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
