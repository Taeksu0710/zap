import Foundation

/// A single file-system entry discovered during a directory scan.
public struct FileEntry: Sendable {
    public let name: String
    public let parentPath: String
    public let isDirectory: Bool
    public let size: UInt64
    public let mtime: Int64
    public let crtime: Int64
    public let fileID: UInt64

    public init(name: String, parentPath: String, isDirectory: Bool, size: UInt64, mtime: Int64, crtime: Int64, fileID: UInt64) {
        self.name = name
        self.parentPath = parentPath
        self.isDirectory = isDirectory
        self.size = size
        self.mtime = mtime
        self.crtime = crtime
        self.fileID = fileID
    }

    public var fullPath: String {
        parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
    }
}
