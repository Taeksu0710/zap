import Foundation

/// Converts Hangul text into its choseong (leading consonant) representation.
/// Non-Hangul characters pass through unchanged.
public enum HangulDecomposer {
    private static let choseongTable: [Character] = [
        "ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ",
        "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ",
    ]

    private static let syllableBase: UInt32 = 0xAC00
    private static let syllableLast: UInt32 = 0xD7A3
    private static let jamoPerSyllable: UInt32 = 588 // 21 jungseong * 28 jongseong

    /// Returns the choseong-only string for `text`. Non-Hangul-syllable
    /// scalars (including standalone jamo, Latin letters, digits) are copied
    /// through unchanged, so mixed-language names stay searchable.
    public static func choseong(_ text: String) -> String {
        var result = String()
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value >= syllableBase, value <= syllableLast {
                let index = (value - syllableBase) / jamoPerSyllable
                result.append(choseongTable[Int(index)])
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
