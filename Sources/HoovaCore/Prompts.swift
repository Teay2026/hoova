import Foundation

/// Les consignes données au modèle. Courtes : moins de texte à lire, c'est plus rapide et plus juste. En anglais, pour
/// toutes les langues : la langue de la réponse est demandée à la fin du prompt (docs/decisions.md, 2 novembre 2026).
enum Prompts {
    static let instructions = """
        You are Hoova. A reader points at a term they do not understand in a text. \
        Explain to them, in simple words, what the term means in this passage.
        Rules:
        - One or two short sentences, 45 words at most.
        - Give the meaning of the term in this passage, not all its meanings.
        - Read the passage first: when its own words show the meaning, use that meaning. Only when the passage allows \
        several meanings, let the title, the beginning of the document and the text around it decide.
        - If the term is part of an expression (for example "interest rate"), explain the whole expression.
        - If a reference definition is given and fits the passage, rely on it.
        - Do not make anything up. If you are not sure, start with "[?]".
        - No introduction, do not copy the passage, no formatting.
        - Write in the language asked at the end, even when the passage is in another language.
        """

    /// `language` : le code de la langue de la réponse (`ExplanationLanguage.code(for:)`). `budget` : ce qu'on envoie au
    /// plus du texte autour du passage, en caractères (`Engine.contextBudget`).
    static func prompt(for capture: Capture, grounding: Grounding, language: String, budget: Int) -> String {
        // Du plus large au plus proche : le sujet, puis le passage, juste avant le terme. Le modèle s'appuie sur ce qu'il
        // lit en dernier (docs/decisions.md, 9 novembre 2026).
        var prompt = probe(capture.title ?? "") + "\""
        let around = surroundings(of: capture, budget: budget)
        if let beginning = around.beginning { prompt += "\nBeginning of the document: \"\(beginning)\"" }
        if let before = around.before { prompt += "\nText just before the passage: \"\(before)\"" }
        if let after = around.after { prompt += "\nText just after the passage: \"\(after)\"" }
        prompt += "\nPassage: \"\(capture.context)\""
        prompt += "\nTerm: \"\(capture.term)\""
        if let definition = grounding.fromDocument { prompt += "\nDefinition given in the document: \"\(definition)\"" }
        if let entry = grounding.fromDictionary { prompt += "\nDictionary definition: \"\(entry)\"" }
        // Les langues dans le prompt plutôt que dans les consignes : leur cache sert à toutes les langues. Celle du
        // passage aide à lire le terme comme un mot de cette langue ; celle de la réponse vient en dernier, juste avant
        // que le modèle écrive.
        if let passage = ExplanationLanguage.passage(of: capture) {
            prompt += "\nThe passage is in \(ExplanationLanguage.name(of: passage))."
        }
        prompt += "\nAnswer in \(ExplanationLanguage.name(of: language))."
        return prompt
    }

    /// Le texte autour du passage, réduit à `budget` caractères. Le début du document et le texte d'après ont chacun un
    /// quart au plus, le texte d'avant le reste ; la part qu'un texte ne prend pas passe aux autres. On garde du texte
    /// d'avant ce qui touche le passage, et des deux autres ce qui vient en premier.
    static func surroundings(of capture: Capture, budget: Int) -> (beginning: String?, before: String?, after: String?) {
        guard budget > 0 else { return (nil, nil, nil) }
        // Le début du document ne vient qu'avec un grand budget, celui d'un modèle externe : au banc, Gemma 4 E4B se
        // laissait emporter par lui quand il emploie le terme dans un autre sens (docs/decisions.md, 9 novembre 2026).
        let beginning = budget >= 4_000 ? capture.beginning : nil
        let lengths = [beginning, capture.before, capture.after].map { $0?.count ?? 0 }
        var shares = [min(lengths[0], budget / 4), 0, min(lengths[2], budget / 4)]
        shares[1] = min(lengths[1], budget - shares[0] - shares[2])
        var spare = budget - shares.reduce(0, +)
        for index in [2, 0] where spare > 0 {
            let more = min(lengths[index] - shares[index], spare)
            shares[index] += more
            spare -= more
        }
        return (head(beginning, shares[0]), tail(capture.before, shares[1]), head(capture.after, shares[2]))
    }

    /// Les `count` premiers caractères, coupés à la fin d'un mot.
    private static func head(_ text: String?, _ count: Int) -> String? {
        guard let text, count > 0 else { return nil }
        guard text.count > count else { return text }
        let cut = text.prefix(count)
        return String(cut[..<(cut.lastIndex(where: \.isWhitespace) ?? cut.endIndex)]) + "…"
    }

    /// Les `count` derniers caractères, coupés au début d'un mot.
    private static func tail(_ text: String?, _ count: Int) -> String? {
        guard let text, count > 0 else { return nil }
        guard text.count > count else { return text }
        let cut = text.suffix(count)
        return "…" + String(cut[(cut.firstIndex(where: \.isWhitespace).map { cut.index(after: $0) } ?? cut.startIndex)...])
    }

    /// Le début de chaque prompt, jusqu'au titre. Tout ce qui le précède est commun et reste en cache.
    static func probe(_ title: String) -> String {
        "Page or document: \"\(title)"
    }

    private static let unsure = ["[?]", "pas sûr :", "pas sûr:", "pas sur :", "pas sur:"]

    /// Sépare la mention d'incertitude (« [?] » ou « Pas sûr : ») du texte, et retire la mise en forme parasite.
    static func split(_ raw: String) -> (text: String, uncertain: Bool) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "**", with: "")
        let lowered = text.lowercased()
        // Pendant l'écriture, « [ » ou « Pas s… » est peut-être le début de la mention : on attend la suite.
        if !lowered.isEmpty, unsure.contains(where: { $0.hasPrefix(lowered) && $0 != lowered }) { return ("", false) }
        guard let marker = unsure.first(where: { lowered.hasPrefix($0) }) else { return (text, false) }
        text = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        return (text, true)
    }
}
