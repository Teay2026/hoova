import Foundation

/// Retrouve la forme longue d'un sigle dans le texte du document.
enum Acronyms {
    /// « BCE », « EBITDA », « PME », « COVID-19 »…
    static func isAcronym(_ s: String) -> Bool {
        let letters = s.filter(\.isLetter)
        guard (2...10).contains(s.count), letters.count >= 2, !s.contains(" ") else { return false }
        return Double(letters.filter(\.isUppercase).count) / Double(letters.count) >= 0.6
    }

    static func longForm(of acronym: String, in text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: acronym)
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)

        // « … Banque centrale européenne (BCE) »
        if let before = try? NSRegularExpression(pattern: #"([^()\n.;:]{3,200})\(\s*"# + escaped + #"\s*\)"#) {
            for match in before.matches(in: text, range: all) {
                let words = ns.substring(with: match.range(at: 1)).split(separator: " ").suffix(acronym.count * 2 + 3)
                if let found = bestLongForm(short: acronym, long: words.joined(separator: " ")) { return found }
            }
        }
        // « BCE (Banque centrale européenne) »
        if let after = try? NSRegularExpression(pattern: #"\b"# + escaped + #"\s*\(([^()]{3,150})\)"#) {
            for match in after.matches(in: text, range: all) {
                let inside = ns.substring(with: match.range(at: 1))
                if bestLongForm(short: acronym, long: inside) != nil {
                    return inside.trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    /// Algorithme de Schwartz & Hearst : chaque lettre du sigle se retrouve, dans l'ordre,
    /// dans la forme longue, et la première lettre commence un mot.
    static func bestLongForm(short: String, long: String) -> String? {
        let original = Array(long)
        var folded = Array(long.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
        if folded.count != original.count { folded = Array(long.lowercased()) }
        guard folded.count == original.count else { return nil }
        let letters = Array(short.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
            .filter { $0.isLetter || $0.isNumber }

        var s = letters.count - 1
        var l = folded.count - 1
        while s >= 0 {
            while l >= 0,
                folded[l] != letters[s] || (s == 0 && l > 0 && (folded[l - 1].isLetter || folded[l - 1].isNumber))
            {
                l -= 1
            }
            if l < 0 { return nil }
            l -= 1
            s -= 1
        }
        var start = l + 1
        while start > 0, !folded[start - 1].isWhitespace { start -= 1 }
        let result = String(original[start...]).trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        let words = result.split(separator: " ").count
        return (1...(letters.count * 2 + 3)).contains(words) ? result : nil
    }
}
