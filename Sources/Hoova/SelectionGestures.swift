import AppKit

/// Repère les gestes qui sélectionnent du texte : glisser, double ou triple clic, ⇧ + clic, ⌘A, ⇧ + flèches.
/// Sert à savoir s'il faut copier la sélection (⌘C) quand l'app ne la donne pas par l'accessibilité,
/// sans envoyer ⌘C à chaque explication.
final class SelectionGestures {
    /// Un geste de sélection vient de se terminer : c'est le moment de lire la sélection, avant toute touche.
    var onSelectionMade: () -> Void = {}

    private var monitors: [Any] = []
    private var dragging = false
    private var selectingClick = false
    private var lastSelection: ContinuousClock.Instant?

    /// Une sélection faite il y a moins de 30 s, et pas annulée depuis par un simple clic.
    var selectionIsLikely: Bool {
        guard let lastSelection else { return false }
        return ContinuousClock.now - lastSelection < .seconds(30)
    }

    func start() {
        guard monitors.isEmpty else { return }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
                [weak self] event in self?.mouse(event)
            },
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in self?.key(event) },
        ].compactMap { $0 }
    }

    private func mouse(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragging = false
            // Un simple clic désélectionne ; un double ou triple clic, ou ⇧ + clic, sélectionne.
            selectingClick = event.clickCount >= 2 || event.modifierFlags.contains(.shift)
            lastSelection = selectingClick ? ContinuousClock.now : nil
        case .leftMouseDragged:
            dragging = true
        case .leftMouseUp:
            if dragging || selectingClick {
                lastSelection = ContinuousClock.now
                onSelectionMade()
            }
            dragging = false
            selectingClick = false
        default:
            break
        }
    }

    private func key(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let arrows: Set<UInt16> = [123, 124, 125, 126]
        let selects =
            (flags == .command && event.charactersIgnoringModifiers?.lowercased() == "a")
            || (flags.contains(.shift) && arrows.contains(event.keyCode))
        if selects {
            lastSelection = ContinuousClock.now
            onSelectionMade()
        }
    }
}
