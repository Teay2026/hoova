import CoreGraphics

/// Ce que Hoova a lu sous la souris.
public struct Capture: Sendable, Equatable {
    public enum Method: String, Sendable {
        /// Le mot sous la souris, lu par l'accessibilité.
        case accessibility = "Accessibilité"
        /// Le texte sélectionné, lu par l'accessibilité.
        case selection = "Sélection"
        /// Le texte sélectionné, lu au moment où l'utilisateur l'a sélectionné.
        case remembered = "Sélection mémorisée"
        /// Le texte sélectionné, copié avec ⌘C.
        case clipboard = "Sélection copiée"
        /// Le texte sélectionné, lu à l'écran : les mots surlignés de la couleur de sélection.
        case screenSelection = "Sélection lue à l'écran"
        case ocr = "OCR"
        /// Le mot ou le passage choisi dans le pop-up de Hoova : un double ⌃ sur sa propre explication.
        case popup = "Pop-up"
        /// Le mot choisi dans la phrase d'exemple de l'accueil, pour essayer le geste.
        case setup = "Accueil"
        case given = "Fourni"
    }

    /// Le mot survolé, ou la sélection.
    public var term: String
    /// La phrase et le paragraphe autour du terme.
    public var context: String
    /// Plus de texte du document, quand il est disponible, pour y retrouver une définition.
    public var documentText: String?
    /// Le titre de la page ou du document (celui de la fenêtre) : il donne le sujet.
    public var title: String?
    /// Le début du document, quand l'app donne tout son texte et que le passage est plus loin : il donne le sujet.
    public var beginning: String?
    /// Le texte juste avant le paragraphe du terme, puis juste après. Larges : le prompt n'en garde que ce que
    /// permet le modèle (`Prompts.prompt`).
    public var before: String?
    public var after: String?
    /// Position du terme à l'écran (coordonnées globales, origine en haut à gauche).
    public var anchor: CGRect?
    public var method: Method
    /// Le contexte vient de la lecture faite au moment de la sélection, pas de celle du double ⌃.
    public var contextFromSelection = false

    public init(
        term: String, context: String, documentText: String? = nil,
        anchor: CGRect? = nil, method: Method = .given
    ) {
        self.term = term
        self.context = context
        self.documentText = documentText
        self.anchor = anchor
        self.method = method
    }

    /// Ce qui entoure le passage, tel que le donne `TextAround.surroundings`.
    mutating func surround(with found: (beginning: String?, before: String?, after: String?)) {
        (beginning, before, after) = found
    }

    /// Le texte lu autour du passage, en caractères : pour le journal.
    public var surroundingCount: Int { (beginning?.count ?? 0) + (before?.count ?? 0) + (after?.count ?? 0) }
}
