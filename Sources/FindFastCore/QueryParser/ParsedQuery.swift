import Foundation

/// The parsed form of a user search query.
///
/// Supported syntax (combinable):
/// - Plain text / 초성(jamo): `report`, `ㄴㄴ`
/// - Glob extension: `*.sql`, `*.py *.js`
/// - Keyword extension: `ext:sql`, `ext:py`
/// - Mixed: `report *.sql`  (name contains "report" AND extension is .sql)
public struct ParsedQuery: Sendable, Equatable {
    /// The name portion of the query after extension tokens are stripped out.
    /// Empty when the user typed only extension filters (e.g. `*.sql`).
    public let raw: String
    public let isJamoQuery: Bool
    /// Lower-cased extension list to include, without the leading dot.
    /// Empty means "no extension filter — match any file".
    public let extensionFilter: [String]

    public init(raw: String, isJamoQuery: Bool, extensionFilter: [String] = []) {
        self.raw = raw
        self.isJamoQuery = isJamoQuery
        self.extensionFilter = extensionFilter
    }
}
