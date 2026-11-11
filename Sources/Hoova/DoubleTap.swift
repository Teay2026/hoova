import AppKit
import os

private let log = Logger(subsystem: "com.teayouness.hoova", category: "déclencheur")

/// Détecte le double appui sur une touche de modification (⌃ par défaut), partout sur le Mac.
///
/// Deux appuis brefs sur la touche seule, à moins de 0,4 s d'écart, sans autre touche ni clic entre les deux.
/// Les raccourcis qui utilisent cette touche avec une autre (⌃C, ⌃ + clic…) restent intacts.
final class DoubleTap {
    var onDoubleTap: (CGPoint) -> Void = { _ in }
    /// Un premier appui bref, sans savoir encore s'il y en aura un second : de quoi commencer à lire sous la souris.
    var onFirstTap: (CGPoint) -> Void = { _ in }

    private(set) var isRunning = false
    /// La touche surveillée, et son symbole pour les traces. Elle peut changer à tout moment (réglages).
    var key: NSEvent.ModifierFlags {
        didSet { reset() }
    }
    var symbol: String
    private var monitors: [Any] = []
    private var pressedAt: ContinuousClock.Instant?
    private var lastTapAt: ContinuousClock.Instant?

    /// Durée maximale d'un appui, et écart maximal entre les deux appuis.
    private let maxPress = Duration.milliseconds(300)
    private let maxGap = Duration.milliseconds(400)
    private static let modifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command, .function]

    init(key: NSEvent.ModifierFlags = .control, symbol: String = "⌃") {
        self.key = key
        self.symbol = symbol
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        // Surveiller le clavier hors de l'app demande l'autorisation Accessibilité. Les moniteurs globaux ne voient que
        // les autres apps : dans les fenêtres de Hoova (l'accueil, pour essayer le geste), ce sont les moniteurs locaux.
        let interrupting: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let keys = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.modifiersChanged(event.modifierFlags.intersection(Self.modifiers))
        }
        let interruptions = NSEvent.addGlobalMonitorForEvents(matching: interrupting) { [weak self] _ in self?.reset() }
        let localKeys = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.modifiersChanged(event.modifierFlags.intersection(Self.modifiers))
            return event
        }
        let localInterruptions = NSEvent.addLocalMonitorForEvents(matching: interrupting) { [weak self] event in
            self?.reset()
            return event
        }
        monitors = [keys, interruptions, localKeys, localInterruptions].compactMap { $0 }
        isRunning = monitors.count == 4
        if isRunning {
            log.notice("Déclencheur actif : double \(self.symbol, privacy: .public)")
        } else {
            monitors.forEach(NSEvent.removeMonitor)
            monitors.removeAll()
            log.error("Impossible de surveiller le clavier")
        }
        return isRunning
    }

    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let now = ContinuousClock.now
        if flags == key {
            pressedAt = now  // la touche est enfoncée, seule
        } else if flags.isEmpty, let pressed = pressedAt {
            // Touche relâchée : un appui bref compte comme un « tap ».
            pressedAt = nil
            guard now - pressed <= maxPress else { return reset() }
            // Niveau « debug » : visible en direct (log stream --level debug), jamais enregistré sur disque.
            let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
            log.debug("\(self.symbol, privacy: .public) tapé dans \(app, privacy: .public)")
            if let last = lastTapAt, now - last <= maxGap {
                lastTapAt = nil
                log.notice("Double \(self.symbol, privacy: .public) détecté")
                onDoubleTap(CGEvent(source: nil)?.location ?? .zero)
            } else {
                lastTapAt = now
                onFirstTap(CGEvent(source: nil)?.location ?? .zero)
            }
        } else {
            reset()  // une autre combinaison de touches : ce n'est pas un double appui
        }
    }

    private func reset() {
        pressedAt = nil
        lastTapAt = nil
    }
}
