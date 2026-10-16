import Foundation

/// How a find field reads what you typed. Two modes, the pair every editor
/// that does this well offers: a literal string, and a regular expression.
nonisolated enum MatchMode: String, CaseIterable, Identifiable, Sendable {
    case plain = "Text"
    case regex = "Regex"

    var id: String { rawValue }
}

/// A search over the document: what to look for, not what to do about it, so
/// strip today and replace tomorrow share one definition of "a hit". Both modes
/// run through `NSRegularExpression` — a literal search is an escaped pattern —
/// so the two paths cannot drift apart.
nonisolated struct FindPattern: Sendable, Equatable {
    var text = ""
    var mode = MatchMode.plain
    var isCaseSensitive = false
    var isWholeWord = false

    /// Every hit, in document order.
    func ranges(in string: String) throws -> [NSRange] {
        try matches(in: string)?.hits.map(\.range) ?? []
    }

    /// Every hit paired with what should take its place, in the shape
    /// `EditorController.replace` eats. The template is
    /// `NSRegularExpression`'s, so `$1` reads a capture group in regex mode; in
    /// plain mode it is taken literally, the same promise the search side
    /// makes — a user replacing prices with `$5` has typed no pattern syntax.
    func replacements(in string: String, template: String) throws -> [(range: NSRange, string: String)] {
        guard let (expression, hits) = try matches(in: string) else { return [] }
        let template = mode == .plain ? NSRegularExpression.escapedTemplate(for: template) : template
        return hits.map {
            (range: $0.range, string: expression.replacementString(for: $0, in: string, offset: 0, template: template))
        }
    }

    /// Empty matches are dropped: a pattern like `x*` matches between every
    /// pair of characters, which would report hundreds of hits and act on none
    /// of them.
    /// An empty field is checked first, since `NSRegularExpression` rejects an
    /// empty pattern.
    private func matches(in string: String) throws -> (expression: NSRegularExpression, hits: [NSTextCheckingResult])? {
        guard !text.isEmpty else { return nil }
        let expression = try NSRegularExpression(
            pattern: pattern,
            options: isCaseSensitive ? [] : [.caseInsensitive]
        )
        let whole = NSRange(string.startIndex..., in: string)
        let deadline = Date.now.addingTimeInterval(Self.timeBudget)
        var hits: [NSTextCheckingResult] = []
        var timedOut = false
        expression.enumerateMatches(in: string, options: .reportProgress, range: whole) { result, _, stop in
            if let result, result.range.length > 0 { hits.append(result) }
            if Date.now > deadline {
                timedOut = true
                stop.pointee = true
            }
        }
        if timedOut { throw TooSlow() }
        return (expression, hits)
    }

    /// Matching runs on the main actor on every keystroke, so a pattern that
    /// backtracks catastrophically, such as `(a+)+b`, would freeze the app.
    /// Past this budget the search gives up instead.
    static let timeBudget: TimeInterval = 0.25

    struct TooSlow: Error {}

    /// The whole-word wrapper is a non-capturing group, so alternation inside a
    /// regular expression keeps binding the way it reads.
    private var pattern: String {
        let body = mode == .plain ? NSRegularExpression.escapedPattern(for: text) : text
        return isWholeWord ? #"\b(?:\#(body))\b"# : body
    }
}
