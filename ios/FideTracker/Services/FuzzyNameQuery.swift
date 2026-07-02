import Foundation

/// Tokenized, typo-tolerant interpretation of a player-name search query,
/// used by `FIDEDatabase.search`.
///
/// FIDE stores names as "Lastname, Firstname" while users type either order
/// ("Magnus Carlsen" or "Carlsen, Magnus"), so matching is per-token and
/// order-independent: every query token must match somewhere in the name,
/// either as a substring (pass 1 in `FIDEDatabase.search`) or within a small
/// edit distance (pass 2).
struct FuzzyNameQuery {
    /// Lowercase, diacritic-folded query tokens.
    let tokens: [String]

    private let tokenChars: [[Character]]
    private let tokenEdits: [Int]

    /// Returns nil when the query contains no letters or digits.
    init?(_ query: String) {
        let tokens = Self.tokenize(query)
        guard !tokens.isEmpty else { return nil }
        self.tokens = tokens
        self.tokenChars = tokens.map(Array.init)
        self.tokenEdits = tokens.map { Self.maxEdits(forTokenLength: $0.count) }
    }

    /// False when every token is too short to tolerate a typo — the fuzzy
    /// pass could then only ever re-find what the substring pass found.
    var toleratesTypos: Bool { tokenEdits.contains { $0 > 0 } }

    /// One `LIKE` pattern per token for the exact-substring pass.
    var substringPatterns: [String] { tokens.map { "%\($0)%" } }

    /// One group of `LIKE` patterns per token for the typo-tolerant candidate
    /// prefilter. A name matching a token with at most N typos still contains
    /// at least one of these N+1 pieces unchanged (pigeonhole), so ORing the
    /// pieces within a group — and ANDing across groups — never filters out a
    /// tolerable match.
    var blockingPatternGroups: [[String]] {
        zip(tokens, tokenEdits).map { token, edits in
            Self.pieces(of: token, count: edits + 1).map { "%\($0)%" }
        }
    }

    /// Total number of typos needed to match every query token against `name`,
    /// or nil when some token exceeds its tolerance. Lower is better; 0 means
    /// every token is an exact token or token-prefix of the name.
    func cost(ofName name: String) -> Int? {
        let nameTokens = Self.tokenize(name).map(Array.init)
        var total = 0
        for (query, edits) in zip(tokenChars, tokenEdits) {
            var best = Int.max
            for nameToken in nameTokens {
                if let cost = Self.tokenCost(query: query, name: nameToken, maxEdits: edits) {
                    best = min(best, cost)
                    if best == 0 { break }
                }
            }
            guard best != .max else { return nil }
            total += best
        }
        return total
    }

    // MARK: - Tokenizing

    /// Splits a name or query into lowercase tokens on any non-alphanumeric
    /// character (spaces, commas, hyphens, apostrophes) and folds diacritics.
    static func tokenize(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    // MARK: - Typo tolerance

    /// Edits tolerated for a token: short tokens must match exactly so that
    /// initials and particles ("de", "van") don't match half the database.
    static func maxEdits(forTokenLength length: Int) -> Int {
        switch length {
        case ..<4: return 0
        case 4...6: return 1
        default: return 2
        }
    }

    /// Splits a token into `count` contiguous, roughly equal pieces.
    static func pieces(of token: String, count: Int) -> [String] {
        guard count > 1 else { return [token] }
        let chars = Array(token)
        return (0..<count).map { i in
            String(chars[(i * chars.count / count)..<((i + 1) * chars.count / count)])
        }
    }

    // MARK: - Scoring

    /// Typos needed to turn `query` into `name` or into a prefix of `name`
    /// (so a partially typed "carlse" still matches "carlsen"), or nil when
    /// over `maxEdits`.
    static func tokenCost(query: [Character], name: [Character], maxEdits: Int) -> Int? {
        var best = editDistance(query, name, cap: maxEdits)
        if name.count > query.count {
            best = min(best, editDistance(query, Array(name.prefix(query.count)), cap: maxEdits))
        }
        return best <= maxEdits ? best : nil
    }

    /// Damerau–Levenshtein distance (optimal string alignment: substitutions,
    /// insertions, deletions, and adjacent transpositions each cost 1),
    /// clamped to `cap + 1` as soon as the result is known to exceed `cap`.
    static func editDistance(_ a: [Character], _ b: [Character], cap: Int) -> Int {
        if abs(a.count - b.count) > cap { return cap + 1 }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }

        var twoAgo = [Int](repeating: 0, count: b.count + 1)
        var oneAgo = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            var rowMin = i
            for j in 1...b.count {
                let substitution = oneAgo[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                var d = min(oneAgo[j] + 1, current[j - 1] + 1, substitution)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d = min(d, twoAgo[j - 2] + 1)
                }
                current[j] = d
                rowMin = min(rowMin, d)
            }
            if rowMin > cap { return cap + 1 }
            (twoAgo, oneAgo, current) = (oneAgo, current, twoAgo)
        }
        return min(oneAgo[b.count], cap + 1)
    }
}
