import Foundation

/// Sidecar metadata written alongside the binary index file, purely for
/// human/tool diagnostics (`cat index.meta.json`). The load path never reads
/// this file — the binary header (see `IndexFile.swift`) is the sole source
/// of truth for compatibility checks.
public struct IndexMetadata: Codable, Sendable {
    public let formatVersion: Int
    public let entryCount: Int
    public let scanRoot: String
    public let savedAt: Date
    public let savedEventID: UInt64
    public let volumeUUID: String

    public static func current(entryCount: Int, scanRoot: String, savedEventID: UInt64 = 0) -> IndexMetadata {
        IndexMetadata(
            formatVersion: Int(IndexFile.formatVersion),
            entryCount: entryCount,
            scanRoot: scanRoot,
            savedAt: Date(),
            savedEventID: savedEventID,
            volumeUUID: IndexMetadata.volumeUUIDString(for: scanRoot) ?? ""
        )
    }

    /// The volume UUID string (e.g. "2E95D097-AB2C-489A-AD52-73125E7378F7")
    /// for the volume containing `path`. Used to detect "this index was built
    /// on a different disk/Mac" at load time.
    static func volumeUUIDString(for path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]) else { return nil }
        return values.volumeUUIDString
    }
}
