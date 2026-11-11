import AppKit
import SwiftUI

/// Le texte de l'explication, dessiné par TextKit plutôt que par `Text` : on peut y sélectionner un passage à la
/// souris sans que le pop-up prenne le clavier (le double ⌃ continue d'arriver à Hoova), et on sait quel mot est sous
/// le pointeur. C'est ce qui permet d'expliquer un mot du pop-up lui-même.
struct SelectableText: NSViewRepresentable {
    let text: NSAttributedString
    /// La couleur de la sélection.
    let highlight: Color
    let handle: PopupTextHandle

    func makeNSView(context: Context) -> PopupTextView {
        PopupTextView()
    }

    func updateNSView(_ view: PopupTextView, context: Context) {
        let highlight = NSColor(highlight)
        if view.highlight != highlight { view.highlight = highlight }
        view.text = text
        view.handle = handle
        handle.view = view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: PopupTextView, context: Context) -> CGSize? {
        // La largeur du texte dans la carte, si SwiftUI n'en propose pas.
        var width = proposal.width ?? 310
        if !width.isFinite { width = 310 }
        return CGSize(width: width, height: view.height(forWidth: width))
    }
}

/// Le lien entre le pop-up et la vue de son texte : pour lire ce qu'on y a choisi, et savoir où est le pointeur.
final class PopupTextHandle {
    weak var view: PopupTextView?
    /// Le pointeur bouge au-dessus du texte, y entre ou en sort.
    var pointerMoved: () -> Void = {}
}

/// Le texte d'une explication. Il se sélectionne à la souris (en glissant, ou d'un double-clic pour un mot), même dans
/// une fenêtre qui ne prend jamais le clavier.
final class PopupTextView: NSView {
    var text = NSAttributedString() {
        didSet {
            guard text != oldValue else { return }
            storage.setAttributedString(text)
            if NSMaxRange(selection) > storage.length { selection = NSRange(location: 0, length: 0) }
            needsDisplay = true
        }
    }
    var highlight = NSColor.selectedTextBackgroundColor {
        didSet { needsDisplay = true }
    }
    weak var handle: PopupTextHandle?
    /// Le passage sélectionné à la souris.
    private(set) var selection = NSRange(location: 0, length: 0)
    /// Là où la sélection a commencé.
    private var anchor = 0
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))

    override init(frame: NSRect) {
        super.init(frame: frame)
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Le premier clic sélectionne déjà, sans activer Hoova.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityValue() -> Any? { storage.string }

    /// La hauteur du texte pour cette largeur.
    func height(forWidth width: CGFloat) -> CGFloat {
        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    /// SwiftUI peut mesurer le texte à une autre largeur : on revient à celle de la vue avant de dessiner ou de
    /// chercher un mot.
    private func fitWidth() {
        if container.size.width != bounds.width {
            container.size = CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
        }
    }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        fitWidth()
        if selection.length > 0 {
            highlight.setFill()
            for rect in rects(for: selection) { NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill() }
        }
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: .zero)
    }

    // MARK: - La souris

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag],
                owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.iBeam.set()
        handle?.pointerMoved()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.iBeam.set()
        handle?.pointerMoved()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        handle?.pointerMoved()
    }

    override func mouseDown(with event: NSEvent) {
        let index = insertionIndex(at: convert(event.locationInWindow, from: nil))
        if event.clickCount >= 2, let word = wordRange(containing: index) {
            selection = word
        } else {
            anchor = index
            selection = NSRange(location: index, length: 0)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let index = insertionIndex(at: convert(event.locationInWindow, from: nil))
        selection = NSRange(location: min(anchor, index), length: abs(index - anchor))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        handle?.pointerMoved()
    }

    // MARK: - Ce qu'on a choisi

    /// Ce que le double ⌃ doit expliquer : la sélection, sinon le mot sous `point` (coordonnées de l'écran, origine en
    /// bas à gauche), avec son cadre à l'écran.
    func pick(at point: NSPoint) -> (text: String, frame: NSRect)? {
        guard let window else { return nil }
        let range = selection.length > 0 ? selection : word(at: convert(window.convertPoint(fromScreen: point), from: nil))
        guard let range else { return nil }
        let text = (storage.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        fitWidth()
        let box = rects(for: range).reduce(NSRect.null) { $0.union($1) }
        return (text, window.convertToScreen(convert(box, to: nil)))
    }

    /// Le pointeur est au-dessus du texte (coordonnées de l'écran, origine en bas à gauche).
    func contains(screenPoint point: NSPoint) -> Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.convertPoint(fromScreen: point), from: nil))
    }

    /// Le cadre de chaque ligne d'un passage.
    private func rects(for range: NSRange) -> [NSRect] {
        var rects: [NSRect] = []
        layout.enumerateEnclosingRects(
            forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
        ) { rect, _ in rects.append(rect) }
        return rects
    }

    /// Entre quels caractères tombe ce point, pour une sélection.
    private func insertionIndex(at point: NSPoint) -> Int {
        fitWidth()
        var fraction: CGFloat = 0
        let index = layout.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        return min(index + (fraction > 0.5 ? 1 : 0), storage.length)
    }

    /// Le mot sous ce point, s'il y en a un : pas au bout d'une ligne, ni entre deux lignes.
    private func word(at point: NSPoint) -> NSRange? {
        guard storage.length > 0 else { return nil }
        fitWidth()
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let box = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard box.insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        return wordRange(containing: layout.characterIndexForGlyph(at: glyph))
    }

    /// Le mot qui contient ce caractère, comme au double-clic. Pas un espace ni une ponctuation seule.
    private func wordRange(containing index: Int) -> NSRange? {
        guard index < storage.length else { return nil }
        let range = storage.doubleClick(at: index)
        let word = (storage.string as NSString).substring(with: range)
        return word.contains { $0.isLetter || $0.isNumber } ? range : nil
    }
}
