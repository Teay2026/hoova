import AppKit
import os

private let log = Logger(subsystem: "com.teayouness.hoova", category: "lecture")

/// Copie la sélection de l'app au premier plan avec ⌘C, puis remet le presse-papiers comme avant.
/// Secours pour les apps qui ne donnent pas leur sélection par l'accessibilité.
enum SelectionCopier {
    static func copy() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let before = pasteboard.changeCount
        let clock = ContinuousClock()
        let start = clock.now
        pressCommandC()

        // Sans sélection, rien ne change : on n'attend pas plus de 300 ms.
        while pasteboard.changeCount == before, clock.now - start < .milliseconds(300) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard pasteboard.changeCount != before else {
            log.notice("⌘C : rien copié en \(clock.now - start, privacy: .public)")
            return nil
        }
        // Chrome et les apps Electron vident d'abord le presse-papiers, puis y écrivent un peu plus tard :
        // on attend que le texte arrive vraiment, sinon on lirait du vide et on restaurerait trop tôt.
        var copied: String?
        let written = clock.now
        while clock.now - written < .milliseconds(300) {
            if let text = text(in: pasteboard), !text.isEmpty {
                copied = text.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let types = (pasteboard.types ?? []).map(\.rawValue).joined(separator: ", ")
        restore(saved, to: pasteboard)
        log.notice(
            "⌘C : \(copied?.count ?? 0, privacy: .public) caractères copiés en \(clock.now - start, privacy: .public) (formats : \(types, privacy: .public))"
        )
        guard let copied, (1...500).contains(copied.count) else { return nil }
        return copied
    }

    /// Le texte copié : en texte brut, sinon tiré du HTML ou du RTF (certaines apps web ne copient que ça).
    private static func text(in pasteboard: NSPasteboard) -> String? {
        if let plain = pasteboard.string(forType: .string), !plain.isEmpty { return plain }
        if let html = pasteboard.data(forType: .html),
            let rich = NSAttributedString(html: html, documentAttributes: nil)
        {
            return rich.string
        }
        if let rtf = pasteboard.data(forType: .rtf), let rich = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            return rich.string
        }
        return nil
    }

    private static func pressCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            // 8 : la touche C, au même endroit en AZERTY et en QWERTY.
            let event = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func restore(_ items: [[(NSPasteboard.PasteboardType, Data)]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { pairs in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
