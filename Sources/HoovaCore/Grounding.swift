import CoreServices
import Foundation

/// Les sources fiables qu'on donne au modèle avant qu'il réponde : il reformule au lieu d'inventer.
public struct Grounding: Sendable {
    /// Définition trouvée dans le document lui-même (« Banque centrale européenne (BCE) »).
    public var fromDocument: String?
    /// Entrée du dictionnaire intégré de macOS, quand elle porte bien sur ce terme.
    public var fromDictionary: String?

    public static func find(for capture: Capture) -> Grounding {
        if Acronyms.isAcronym(capture.term),
            let longForm = Acronyms.longForm(of: capture.term, in: capture.documentText ?? "")
                ?? Acronyms.longForm(of: capture.term, in: capture.context)
        {
            return Grounding(fromDocument: "\(capture.term) = \(longForm)")
        }
        // Les dictionnaires de macOS sont dans les langues du lecteur : pour un mot d'un texte étranger, ils donnent
        // souvent un faux ami (« latino », en italien le latin, est en français l'Amérique latine). La définition ne
        // sert que si elle est dans la langue du passage.
        guard let entry = MacDictionary.entry(for: capture.term) else { return Grounding() }
        if let passage = ExplanationLanguage.passage(of: capture), let written = ExplanationLanguage.recognize(entry),
            passage.prefix(2) != written.prefix(2)
        {
            return Grounding()
        }
        return Grounding(fromDictionary: entry)
    }

    /// D'où vient vraiment l'explication : on ne crédite le dictionnaire que si le modèle s'en est servi.
    func source(of explanation: String, term: String) -> Source {
        if fromDocument != nil { return .document }
        if let entry = fromDictionary, Self.sharedWords(explanation, entry, excluding: term) >= 2 {
            return .dictionary
        }
        return .model
    }

    /// Nombre de mots significatifs (5 lettres et plus) communs aux deux textes.
    static func sharedWords(_ a: String, _ b: String, excluding term: String) -> Int {
        func words(_ s: String) -> Set<String> {
            Set(
                s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                    .split { !$0.isLetter }
                    .filter { $0.count >= 5 }
                    .map(String.init))
        }
        return words(a).intersection(words(b)).subtracting(words(term)).count
    }
}

/// Les dictionnaires intégrés de macOS (ceux de l'app Dictionnaire) : gratuits, locaux, ~1 ms.
enum MacDictionary {
    static func entry(for term: String) -> String? {
        let length = (term as NSString).length
        guard length > 0,
            let definition = DCSCopyTextDefinition(nil, term as CFString, CFRange(location: 0, length: length))?
                .takeRetainedValue() as String?,
            // Il renvoie parfois l'entrée d'un mot plus court (« taux » pour « taux directeur ») : on vérifie.
            definition.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        else { return nil }
        // Le début de l'article : 160 caractères font lire un tiers de jetons en moins que 420, et le premier mot
        // arrive un tiers plus tôt, sans perte de justesse mesurée (docs/decisions.md).
        return String(TextAround.clean(definition).prefix(160))
    }
}
