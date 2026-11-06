/// Spaces around a transcription typed into existing text, so it never runs into the words around it.
enum TextSpacing {
    /// Marks that open a phrase: no space after them, and a space before them.
    private static let openers: Set<Character> = ["(", "[", "{", "“", "‘", "«", "¿", "¡"]
    /// Marks that close or follow a phrase: no space before them.
    private static let closers: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "”", "’", "»", "…", "%", "\"", "'"]

    /// `before` and `after` are the text around the cursor, as the keyboard sees it.
    static func padded(_ text: String, before: String?, after: String?) -> String {
        let spaceBefore = before?.last.map { !$0.isWhitespace && !openers.contains($0) } ?? false
        let spaceAfter = after?.first.map { !$0.isWhitespace && !closers.contains($0) } ?? false
        return (spaceBefore ? " " : "") + text + (spaceAfter ? " " : "")
    }
}
