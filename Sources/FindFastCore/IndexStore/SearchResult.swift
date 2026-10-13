import Foundation

public struct SearchResult: Sendable, Equatable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: UInt64
    public let mtime: Int64
    public let crtime: Int64

    public init(name: String, path: String, isDirectory: Bool, size: UInt64, mtime: Int64, crtime: Int64) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.mtime = mtime
        self.crtime = crtime
    }
}
