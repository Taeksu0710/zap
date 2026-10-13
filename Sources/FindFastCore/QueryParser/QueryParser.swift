import Foundation

/// Parses raw search box text into a `ParsedQuery`.
///
/// Extension tokens are stripped before the name portion is evaluated:
/// - `*.sql` or `*.SQL`  → extensionFilter: ["sql"]
/// - `ext:sql`           → extensionFilter: ["sql"]
/// - `*.py *.js report`  → extensionFilter: ["py", "js"], raw: "report"
public enum QueryParser {
    private static let choseongSet: Set<Character> = [
        "ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ",
        "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ",
    ]

    public static func parse(_ text: String) -> ParsedQuery {
        // Normalize to NFC to match the form filenames are stored in after
        // Scanner's own normalization (see ScannerWorker) — some Korean input
        // sources can hand us decomposed (NFD) text otherwise.
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping

        var extensionFilter: [String] = []
        var nameTokens: [String] = []

        for token in trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            if token.hasPrefix("*."), token.count > 2 {
                // *.sql → "sql"
                let ext = String(token.dropFirst(2)).lowercased()
                if !ext.isEmpty { extensionFilter.append(ext) }
            } else if token.lowercased().hasPrefix("ext:"), token.count > 4 {
                // ext:sql → "sql"
                let ext = String(token.dropFirst(4)).lowercased()
                if !ext.isEmpty { extensionFilter.append(ext) }
            } else {
                nameTokens.append(token)
            }
        }

        let raw = nameTokens.joined(separator: " ")
        let isJamo = !raw.isEmpty && raw.allSatisfy { choseongSet.contains($0) }
        return ParsedQuery(raw: raw, isJamoQuery: isJamo, extensionFilter: extensionFilter)
    }
}
