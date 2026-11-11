import CoreGraphics
import Foundation

/// Ce qu'il faut expliquer : la sélection s'il y en a une, sinon le mot sous la souris,
/// avec le titre de la page ou du document pour le sujet.
public enum TextReader {
    /// - Parameters:
    ///   - selectionLikely: l'utilisateur vient de sélectionner du texte. Hoova cherche alors aussi la sélection
    ///     dans le contenu sous la souris, puis la copie en dernier recours.
    ///   - copySelection: copie la sélection avec ⌘C, pour les apps qui ne la donnent pas par l'accessibilité
    ///     (navigateurs, apps web et Electron, certains PDF…). Renvoie `nil` si rien n'a été copié.
    ///   - remembered: la sélection lue au moment où l'utilisateur l'a faite, pour les sites qui l'effacent
    ///     dès qu'on appuie sur une touche.
    ///   - onlyCopy: pour les tests, passe directement à la copie.
    public static func read(
        at point: CGPoint, selectionLikely: Bool, remembered: Capture? = nil, onlyCopy: Bool = false,
        copySelection: @Sendable () async -> String?
    ) async -> Capture? {
        let found =
            onlyCopy
            ? await copySelection().map { Capture(term: TextAround.clean($0), context: $0, method: .clipboard) }
            : await find(
                at: point, selectionLikely: selectionLikely, remembered: remembered, copySelection: copySelection)
        guard var capture = found else { return nil }
        // Même sélection qu'au moment du geste : on reprend tout ce qui a été lu alors, souris encore sur le texte
        // (contexte, titre). La réponse préparée dès la sélection correspond alors exactement.
        if let remembered, fold(remembered.term) == fold(capture.term), !isShort(remembered) {
            var same = remembered
            same.contextFromSelection = true
            return same
        }
        // Le contexte lu au moment de la sélection, quand la souris était encore sur le texte : depuis, elle a pu
        // s'éloigner, et Chrome ne donne pas toujours le paragraphe de sa sélection.
        if isShort(capture), let remembered, !isShort(remembered),
            fold(remembered.context).contains(needle(capture.term))
        {
            capture.context = remembered.context
            capture.contextFromSelection = true
        }
        capture = await withContext(capture, at: point)
        capture.title = AccessibilityReader.frontmostWindowTitle()
        return capture
    }

    /// Complète un contexte trop court : certaines apps (Chrome) donnent la sélection mais pas le paragraphe
    /// autour. On prend le texte du bloc à cet endroit (accessibilité), sinon on le lit à l'écran (OCR).
    public static func withContext(_ capture: Capture, at point: CGPoint) async -> Capture {
        guard isShort(capture) else { return capture }
        var capture = capture
        // Chrome donne parfois un cadre vide pour la sélection : on se fie alors à la position donnée.
        let spot = capture.anchor.flatMap { $0.width > 0 ? CGPoint(x: $0.midX, y: $0.midY) : nil } ?? point
        let needle = needle(capture.term)
        if let block = AccessibilityReader.blockText(at: spot), fold(block).contains(needle),
            let found = block.range(of: capture.term, options: [.caseInsensitive, .diacriticInsensitive])
        {
            capture.context = TextAround.paragraph(in: block, around: found, maxLength: 900)
        } else if let screen = await ScreenOCRReader.read(at: spot), fold(screen.context).contains(needle) {
            capture.context = screen.context
            if capture.surroundingCount == 0 { (capture.before, capture.after) = (screen.before, screen.after) }
        }
        return capture
    }

    /// Le contexte se réduit au terme, ou presque : il n'aide pas le modèle.
    private static func isShort(_ capture: Capture) -> Bool { capture.context.count < capture.term.count + 40 }

    /// Le début du terme, sous la forme qui permet de le retrouver dans un texte lu autrement.
    private static func needle(_ term: String) -> String { fold(String(term.prefix(25))) }

    private static func find(
        at point: CGPoint, selectionLikely: Bool, remembered: Capture?, copySelection: @Sendable () async -> String?
    ) async -> Capture? {
        if case .text(let capture) = AccessibilityReader.focusedSelection() { return capture }
        guard selectionLikely else { return await word(at: point) }
        if let capture = AccessibilityReader.selection(near: point) { return capture }
        if var remembered {
            remembered.method = .remembered
            return remembered
        }

        // L'OCR du paragraphe sous la souris tourne pendant la copie : il servira de contexte.
        async let screen = ScreenOCRReader.read(at: point)
        guard let copied = await copySelection() else {
            // Ni l'accessibilité ni ⌘C : on lit la sélection telle qu'elle est surlignée à l'écran.
            if let shown = await ScreenOCRReader.highlightedSelection(around: point) { return shown }
            if let hovered = AccessibilityReader.read(at: point) { return hovered }
            return await screen
        }
        let around = await screen
        var capture = Capture(
            term: TextAround.clean(copied), context: context(of: copied, at: point, screen: around),
            method: .clipboard)
        // Le texte visible autour, tel qu'il est lu à l'écran.
        (capture.before, capture.after) = (around?.before, around?.after)
        return capture
    }

    /// Le paragraphe qui contient la sélection copiée : par l'accessibilité, sinon tel qu'il est lu à l'écran.
    private static func context(of selection: String, at point: CGPoint, screen: Capture?) -> String {
        // Une longue sélection est déjà son propre contexte.
        guard selection.count < 200 else { return selection }
        let start = fold(String(selection.prefix(25)))
        for around in [AccessibilityReader.read(at: point)?.context, screen?.context].compactMap({ $0 })
        where fold(around).contains(start) {
            return around
        }
        return selection
    }

    /// Minuscules, sans accents ni espaces multiples : l'OCR et le texte copié se comparent ainsi.
    private static func fold(_ text: String) -> String {
        TextAround.clean(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
    }

    /// Le mot sous la souris : deux lectures en même temps, l'accessibilité (texte exact)
    /// si elle trouve, sinon l'OCR (marche partout).
    public static func word(at point: CGPoint) async -> Capture? {
        await withTaskGroup(of: Capture?.self) { group in
            group.addTask { AccessibilityReader.read(at: point) }
            group.addTask { await ScreenOCRReader.read(at: point) }
            var fallback: Capture?
            for await capture in group {
                guard let capture else { continue }
                if capture.method != .ocr {
                    group.cancelAll()
                    return capture
                }
                fallback = capture
            }
            return fallback
        }
    }
}
