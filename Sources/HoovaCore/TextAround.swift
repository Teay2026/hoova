import Foundation
import NaturalLanguage

/// Retrouve le mot et le paragraphe autour d'une position dans un texte.
enum TextAround {
    struct Word {
        let text: String
        let range: Range<String.Index>
    }

    /// Le mot qui contient le caractère situé à `offset` (en unités UTF-16, comme les API d'accessibilité).
    static func word(in text: String, atUTF16Offset offset: Int) -> Word? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let clamped = min(max(offset, 0), ns.length - 1)
        guard let hit = Range(ns.rangeOfComposedCharacterSequence(at: clamped), in: text) else { return nil }

        var start = hit.lowerBound
        if !isWordCharacter(text[start]) {
            // Souris juste après la fin du mot : on prend le mot de gauche.
            guard start > text.startIndex, isWordCharacter(text[text.index(before: start)]) else { return nil }
            start = text.index(before: start)
        }

        var lower = start
        while lower > text.startIndex {
            let previous = text.index(before: lower)
            if isWordCharacter(text[previous]) {
                lower = previous
            } else if isJoiner(text[previous]), previous > text.startIndex,
                isWordCharacter(text[text.index(before: previous)])
            {
                lower = previous
            } else {
                break
            }
        }

        var upper = text.index(after: start)
        while upper < text.endIndex {
            if isWordCharacter(text[upper]) {
                upper = text.index(after: upper)
                continue
            }
            let next = text.index(after: upper)
            if isJoiner(text[upper]), next < text.endIndex, isWordCharacter(text[next]) {
                upper = next
                continue
            }
            break
        }

        // Élision : « l’atome » → « atome », « qu’il » → « il ».
        if let elision = text[lower..<upper].range(
            of: #"^(?:[cdjlmnst]|qu|jusqu|lorsqu|puisqu)['’]"#,
            options: [.regularExpression, .caseInsensitive])
        {
            lower = elision.upperBound
        }
        let word = text[lower..<upper]
        guard word.contains(where: \.isLetter) else { return nil }
        return Word(text: String(word), range: lower..<upper)
    }

    /// Le paragraphe qui contient `range`, réduit aux phrases voisines s'il est trop long.
    static func paragraph(in text: String, around range: Range<String.Index>, maxLength: Int = 700) -> String {
        var start = range.lowerBound
        while start > text.startIndex, !text[text.index(before: start)].isNewline {
            start = text.index(before: start)
        }
        var end = range.upperBound
        while end < text.endIndex, !text[end].isNewline {
            end = text.index(after: end)
        }
        if text.distance(from: start, to: end) <= maxLength {
            return clean(text[start..<end])
        }
        return clean(sentences(in: text, bounds: start..<end, around: range, maxLength: maxLength))
    }

    /// Ce qui entoure, dans un long texte, le paragraphe qui contient les caractères `location..<location + length`
    /// (en unités UTF-16) : le début du texte s'il est plus loin, le texte juste avant le paragraphe et juste après.
    static func surroundings(in text: String, utf16 location: Int, length: Int)
        -> (beginning: String?, before: String?, after: String?)
    {
        let count = text.utf16.count
        guard count > 0 else { return (nil, nil, nil) }
        let lower = String.Index(utf16Offset: min(max(location, 0), count), in: text)
        let upper = String.Index(utf16Offset: min(max(location + length, 0), count), in: text)
        var start = lower
        while start > text.startIndex, !text[text.index(before: start)].isNewline { start = text.index(before: start) }
        var end = max(upper, lower)
        while end < text.endIndex, !text[end].isNewline { end = text.index(after: end) }
        let from = text.index(start, offsetBy: -Self.beforeLength, limitedBy: text.startIndex) ?? text.startIndex
        let to = text.index(end, offsetBy: Self.afterLength, limitedBy: text.endIndex) ?? text.endIndex
        let beginning = from > text.startIndex ? paragraphs(text.prefix(Self.beginningLength)) : ""
        let before = paragraphs(text[from..<start])
        let after = paragraphs(text[end..<to])
        return (beginning.isEmpty ? nil : beginning, before.isEmpty ? nil : before, after.isEmpty ? nil : after)
    }

    /// Ce qu'on lit autour du passage, au plus, en caractères : assez pour un modèle externe.
    static let beginningLength = 1_500
    static let beforeLength = 10_000
    static let afterLength = 3_000

    /// Comme `clean`, mais un paragraphe par ligne : les intertitres restent à part.
    static func paragraphs<S: StringProtocol>(_ s: S) -> String {
        s.split(whereSeparator: \.isNewline).map(clean).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Espaces et retours à la ligne ramenés à un seul espace. Les « ￼ » (U+FFFC) disparaissent aussi : les pages web
    /// en mettent à la place des icônes et des images, dans la sélection comme dans le texte autour.
    static func clean<S: StringProtocol>(_ s: S) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0 == "\u{FFFC}" }).joined(separator: " ")
    }

    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
    private static func isJoiner(_ c: Character) -> Bool { c == "-" || c == "‑" || c == "'" || c == "’" }

    /// Les phrases autour de `range`, sans dépasser `maxLength` caractères.
    private static func sentences(
        in text: String, bounds: Range<String.Index>, around range: Range<String.Index>, maxLength: Int
    ) -> Substring {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        let spans = tokenizer.tokens(for: bounds)
        func length(_ lo: Int, _ hi: Int) -> Int {
            text.distance(from: spans[lo].lowerBound, to: spans[hi].upperBound)
        }
        guard let hit = spans.firstIndex(where: { $0.contains(range.lowerBound) }), length(hit, hit) <= maxLength
        else { return window(in: text, around: range, maxLength: maxLength) }

        var lo = hit
        var hi = hit
        var grew = true
        while grew {
            grew = false
            if lo > 0, length(lo - 1, hi) <= maxLength {
                lo -= 1
                grew = true
            }
            if hi < spans.count - 1, length(lo, hi + 1) <= maxLength {
                hi += 1
                grew = true
            }
        }
        return text[spans[lo].lowerBound..<spans[hi].upperBound]
    }

    /// Une fenêtre de `maxLength` caractères centrée sur `range`.
    private static func window(in text: String, around range: Range<String.Index>, maxLength: Int) -> Substring {
        let half = maxLength / 2
        let lower = text.index(range.lowerBound, offsetBy: -half, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: half, limitedBy: text.endIndex) ?? text.endIndex
        return text[lower..<upper]
    }
}
