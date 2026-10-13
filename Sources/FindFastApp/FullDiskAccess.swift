import Foundation

/// No public API exists to query Full Disk Access status for the current
/// process, so this probes a file that's only readable with FDA granted —
/// the same trick used by most FDA-gating utilities (e.g. BlockBlock).
enum FullDiskAccess {
    private static let probePath = "/Library/Application Support/com.apple.TCC/TCC.db"

    static var isGranted: Bool {
        guard let handle = FileHandle(forReadingAtPath: probePath) else { return false }
        handle.closeFile()
        return true
    }
}
