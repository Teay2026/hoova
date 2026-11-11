import AppKit
import ApplicationServices
import Foundation
import Synchronization
import os

private let log = Logger(subsystem: "com.teayouness.hoova", category: "lecture")

/// Lit le texte sous la souris grâce à l'accessibilité de macOS (l'API de VoiceOver).
/// Texte exact et quasi instantané, quand l'app expose son contenu.
public enum AccessibilityReader {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public enum FocusedSelection: Sendable {
        case text(Capture)
        /// L'app dit que rien n'est sélectionné.
        case none
        /// L'app ne le dit pas : il faut copier la sélection pour savoir.
        case unknown

        var summary: String {
            switch self {
            case .text(let capture): "\(capture.term.count) caractères sélectionnés"
            case .none: "rien de sélectionné"
            case .unknown: "inconnue"
            }
        }
    }

    /// Le texte sélectionné dans l'app au premier plan, où que soit la souris.
    public static func focusedSelection() -> FocusedSelection {
        // On interroge l'app au premier plan elle-même : l'élément « actif » de tout le système peut rester
        // celui d'une autre app quand celle de devant n'expose pas encore son contenu (Chrome).
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return .unknown }
        let frontmost = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(frontmost, 0.3)
        exposeContent(of: frontmost)
        guard let found = attribute(frontmost, kAXFocusedUIElementAttribute) else {
            log.notice("Sélection : aucun élément actif lisible dans \(bundleIdentifier(of: frontmost) ?? "?", privacy: .public)")
            return .unknown
        }
        let focused = found as! AXUIElement
        let app = bundleIdentifier(of: focused)
        let role = attribute(focused, kAXRoleAttribute) as? String ?? "?"

        let result: FocusedSelection
        if let area = webArea(containing: focused), let range = attribute(area, "AXSelectedTextMarkerRange") {
            let selected = parameterized(area, "AXStringForTextMarkerRange", range) as? String
            let box = rectValue(parameterized(area, "AXBoundsForTextMarkerRange", range))
            log.notice(
                "Page web : texte de la sélection \(selected.map { "\($0.count) caractères" } ?? "illisible", privacy: .public), cadre \(box.map { "\(Int($0.width))×\(Int($0.height))" } ?? "inconnu", privacy: .public)"
            )
            if let capture = webSelection(in: area, at: nil) {
                result = .text(capture)
            } else if let selected {
                result = TextAround.clean(selected).isEmpty ? .none : .unknown
            } else {
                result = .unknown
            }
        } else {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &value) == .success,
                let selected = value as? String
            {
                result = TextAround.clean(selected).isEmpty
                    ? .none : selection(in: focused, at: nil).map(FocusedSelection.text) ?? .unknown
            } else {
                result = .unknown
            }
        }
        log.notice("Sélection dans \(app ?? "?", privacy: .public) (\(role, privacy: .public)) : \(result.summary, privacy: .public)")
        return result
    }

    /// Le titre de la fenêtre au premier plan : souvent celui de la page, de la vidéo ou du document.
    public static func frontmostWindowTitle() -> String? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let window = attribute(app, kAXFocusedWindowAttribute),
            let title = attribute(window as! AXUIElement, kAXTitleAttribute) as? String
        else { return nil }
        let clean = TextAround.clean(title)
        return clean.isEmpty ? nil : String(clean.prefix(150))
    }

    private static func bundleIdentifier(of element: AXUIElement) -> String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// La sélection telle qu'on peut la lire maintenant : dans l'élément actif, sinon sous la souris.
    public static func currentSelection(near point: CGPoint) -> Capture? {
        if case .text(let capture) = focusedSelection() { return capture }
        return selection(near: point)
    }

    /// La sélection dans le contenu sous la souris, même si la souris n'est pas exactement dessus.
    /// Pour les apps web où le champ de saisie garde le focus clavier (Claude, ChatGPT…).
    public static func selection(near point: CGPoint) -> Capture? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &found) == .success,
            let element = found
        else { return nil }
        let capture = selection(in: element, at: nil) ?? webArea(containing: element).flatMap { webSelection(in: $0, at: nil) }
        log.notice("Sélection sous la souris : \(capture.map { "\($0.term.count) caractères" } ?? "aucune", privacy: .public)")
        return capture
    }

    /// Le texte du bloc sous la souris (un paragraphe de page web, par exemple), pour servir de contexte.
    public static func blockText(at point: CGPoint) -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &found) == .success,
            var element = found
        else { return nil }
        for _ in 0..<3 {
            let text = textContent(of: element)
            if text.count >= 80 { return String(text.prefix(4_000)) }
            guard let parent = attribute(element, kAXParentAttribute) else { break }
            element = parent as! AXUIElement
        }
        return nil
    }

    /// La valeur texte d'un élément, ou celle de ses enfants mises bout à bout.
    private static func textContent(of element: AXUIElement) -> String {
        if let value = attribute(element, kAXValueAttribute) as? String, !value.isEmpty { return value }
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return children.prefix(60)
            .compactMap { attribute($0, kAXValueAttribute) as? String }
            .joined(separator: " ")
    }

    /// Le mot sous la souris (ou la sélection, si la souris est dessus).
    public static func read(at point: CGPoint) -> Capture? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &found) == .success,
            let element = found
        else { return nil }
        exposeContent(of: element)
        return selection(in: element, at: point)
            ?? text(in: element, at: point)
            ?? webText(in: element, at: point)
    }

    // MARK: - Apps Cocoa (Notes, Mail, Pages, Aperçu, TextEdit…)

    /// Texte sélectionné : on explique toute la sélection. Avec `point`, seulement si la souris est dessus.
    private static func selection(in element: AXUIElement, at point: CGPoint?) -> Capture? {
        guard let selected = attribute(element, kAXSelectedTextAttribute) as? String else { return nil }
        let term = TextAround.clean(selected)
        guard (2...300).contains(term.count),
            let range = rangeValue(attribute(element, kAXSelectedTextRangeAttribute))
        else { return nil }
        let box = bounds(element, range)
        if let point {
            guard let box, box.insetBy(dx: -4, dy: -4).contains(point) else { return nil }
        }

        let total = attribute(element, kAXNumberOfCharactersAttribute) as? Int ?? range.location + range.length + 1_000
        let start = max(0, range.location - 1_000)
        var context = term
        if let around = string(element, CFRange(location: start, length: min(total - start, range.length + 2_000))),
            range.location - start + range.length <= around.utf16.count
        {
            let lower = String.Index(utf16Offset: range.location - start, in: around)
            let upper = String.Index(utf16Offset: range.location - start + range.length, in: around)
            context = TextAround.paragraph(in: around, around: lower..<upper, maxLength: 900)
        }
        let document = document(element, total: total, around: range.location)
        var capture = Capture(term: term, context: context, documentText: document?.text, anchor: box, method: .selection)
        if let document {
            capture.surround(
                with: TextAround.surroundings(
                    in: document.text, utf16: range.location - document.start, length: range.length))
        }
        return capture
    }

    /// Position de la souris → caractère → mot, puis son paragraphe.
    private static func text(in element: AXUIElement, at point: CGPoint) -> Capture? {
        var position = point
        guard let positionValue = AXValueCreate(.cgPoint, &position),
            let hit = rangeValue(parameterized(element, kAXRangeForPositionParameterizedAttribute, positionValue)),
            // Le caractère trouvé doit vraiment être sous la souris, pas le plus proche dans une marge.
            let hitBox = bounds(element, CFRange(location: hit.location, length: max(hit.length, 1))),
            hitBox.insetBy(dx: -3, dy: -3).contains(point)
        else { return nil }

        let total = attribute(element, kAXNumberOfCharactersAttribute) as? Int ?? hit.location + 1_000
        let start = max(0, hit.location - 1_000)
        let length = min(total - start, 2_000)
        guard length > 0,
            let around = string(element, CFRange(location: start, length: length)),
            let word = TextAround.word(in: around, atUTF16Offset: hit.location - start)
        else { return nil }

        let location = start + word.range.lowerBound.utf16Offset(in: around)
        let document = document(element, total: total, around: hit.location)
        var capture = Capture(
            term: word.text,
            context: TextAround.paragraph(in: around, around: word.range),
            documentText: document?.text,
            anchor: bounds(element, CFRange(location: location, length: word.text.utf16.count)),
            method: .accessibility)
        if let document {
            capture.surround(
                with: TextAround.surroundings(
                    in: document.text, utf16: location - document.start, length: word.text.utf16.count))
        }
        return capture
    }

    /// Le texte du document (ou une large fenêtre autour du mot), et où il commence dans le document, en unités UTF-16 :
    /// pour y retrouver une définition, et pour le texte autour du passage.
    private static func document(_ element: AXUIElement, total: Int, around location: Int) -> (text: String, start: Int)? {
        if total <= 100_000 { return (attribute(element, kAXValueAttribute) as? String).map { ($0, 0) } }
        let start = max(0, location - 30_000)
        return string(element, CFRange(location: start, length: min(total - start, 60_000))).map { ($0, start) }
    }

    // MARK: - Pages web (Safari, et Chrome quand il expose son contenu)

    private static func webText(in element: AXUIElement, at point: CGPoint) -> Capture? {
        guard let area = webArea(containing: element) else { return nil }
        if let capture = webSelection(in: area, at: point) { return capture }

        var position = point
        guard let positionValue = AXValueCreate(.cgPoint, &position),
            let marker = parameterized(area, "AXTextMarkerForPosition", positionValue),
            let paragraphRange = parameterized(area, "AXParagraphTextMarkerRangeForTextMarker", marker),
            let paragraph = parameterized(area, "AXStringForTextMarkerRange", paragraphRange) as? String,
            let paragraphStart = parameterized(area, "AXStartTextMarkerForTextMarkerRange", paragraphRange),
            let leading = parameterized(
                area, "AXTextMarkerRangeForUnorderedTextMarkers", [paragraphStart, marker] as CFArray),
            let offset = parameterized(area, "AXLengthForTextMarkerRange", leading) as? Int,
            let word = TextAround.word(in: paragraph, atUTF16Offset: offset)
        else { return nil }

        // Le mot doit vraiment être sous la souris (le marqueur peut tomber juste avant ou juste après).
        let boxes = ["AXLeftWordTextMarkerRangeForTextMarker", "AXRightWordTextMarkerRangeForTextMarker"]
            .compactMap { parameterized(area, $0, marker) }
            .compactMap { rectValue(parameterized(area, "AXBoundsForTextMarkerRange", $0)) }
        let anchor = boxes.first { $0.insetBy(dx: -4, dy: -4).contains(point) }
        if !boxes.isEmpty, anchor == nil { return nil }

        let main = mainText(in: area, at: marker)
        var capture = Capture(
            term: word.text,
            context: TextAround.paragraph(in: paragraph, around: word.range),
            documentText: Acronyms.isAcronym(word.text) ? main?.text ?? pageText(area) : nil,
            anchor: anchor, method: .accessibility)
        if let main { capture.surround(with: TextAround.surroundings(in: main.text, utf16: main.offset, length: 1)) }
        return capture
    }

    private static func webSelection(in area: AXUIElement, at point: CGPoint?) -> Capture? {
        guard let range = attribute(area, "AXSelectedTextMarkerRange"),
            let selected = parameterized(area, "AXStringForTextMarkerRange", range) as? String
        else { return nil }
        let term = TextAround.clean(selected)
        guard (2...300).contains(term.count) else { return nil }
        let box = rectValue(parameterized(area, "AXBoundsForTextMarkerRange", range))
        if let point {
            guard let box, box.insetBy(dx: -4, dy: -4).contains(point) else { return nil }
        }

        var context = term
        let start = parameterized(area, "AXStartTextMarkerForTextMarkerRange", range)
        if let start, let paragraph = paragraphText(in: area, at: start, containing: selected),
            let found = paragraph.range(of: selected)
        {
            context = TextAround.paragraph(in: paragraph, around: found, maxLength: 900)
        }
        let main = start.flatMap { mainText(in: area, at: $0) }
        var capture = Capture(
            term: term, context: context,
            documentText: Acronyms.isAcronym(term) ? main?.text ?? pageText(area) : nil,
            anchor: box, method: .selection)
        if let main {
            capture.surround(
                with: TextAround.surroundings(in: main.text, utf16: main.offset, length: selected.utf16.count))
        }
        return capture
    }

    /// Le texte de la partie principale de la page, sans les menus ni la barre latérale quand la page la marque
    /// (`<main>`, comme ChatGPT, Claude ou Wikipédia), sinon de toute la page ; et la place de `marker` dans ce texte,
    /// en unités UTF-16.
    private static func mainText(in area: AXUIElement, at marker: CFTypeRef) -> (text: String, offset: Int)? {
        let started = ContinuousClock.now
        var main: AXUIElement?
        var element = parameterized(area, "AXUIElementForTextMarker", marker).map { $0 as! AXUIElement }
        for _ in 0..<40 {
            guard let current = element, attribute(current, kAXRoleAttribute) as? String != "AXWebArea" else { break }
            if attribute(current, kAXSubroleAttribute) as? String == "AXLandmarkMain" {
                main = current
                break
            }
            element = attribute(current, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        guard let all = parameterized(area, "AXTextMarkerRangeForUIElement", main ?? area),
            let text = parameterized(area, "AXStringForTextMarkerRange", all) as? String,
            let start = parameterized(area, "AXStartTextMarkerForTextMarkerRange", all),
            let leading = parameterized(area, "AXTextMarkerRangeForUnorderedTextMarkers", [start, marker] as CFArray),
            let offset = parameterized(area, "AXLengthForTextMarkerRange", leading) as? Int
        else { return nil }
        log.notice(
            "Page web : \(main == nil ? "toute la page" : "partie principale", privacy: .public), \(text.count, privacy: .public) caractères, lus en \(ContinuousClock.now - started, privacy: .public)"
        )
        return (text, offset)
    }

    /// Le paragraphe qui contient `selected` : celui que donne la page, sinon le texte du bloc qui
    /// contient le début de la sélection (Chrome ne sait pas toujours donner le paragraphe).
    private static func paragraphText(in area: AXUIElement, at start: CFTypeRef, containing selected: String) -> String? {
        if let range = parameterized(area, "AXParagraphTextMarkerRangeForTextMarker", start),
            let paragraph = parameterized(area, "AXStringForTextMarkerRange", range) as? String,
            paragraph.count > selected.count, paragraph.contains(selected)
        {
            return paragraph
        }
        guard let found = parameterized(area, "AXUIElementForTextMarker", start) else { return nil }
        var element: AXUIElement? = (found as! AXUIElement)
        for _ in 0..<4 {
            guard let current = element else { break }
            if let range = parameterized(area, "AXTextMarkerRangeForUIElement", current),
                let text = parameterized(area, "AXStringForTextMarkerRange", range) as? String,
                text.count >= selected.count + 40, text.contains(selected)
            {
                return text
            }
            element = attribute(current, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        return nil
    }

    private static func pageText(_ area: AXUIElement) -> String? {
        guard let all = parameterized(area, "AXTextMarkerRangeForUIElement", area),
            let text = parameterized(area, "AXStringForTextMarkerRange", all) as? String
        else { return nil }
        return String(text.prefix(100_000))
    }

    private static func webArea(containing element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<30 {
            guard let candidate = current else { return nil }
            if attribute(candidate, kAXRoleAttribute) as? String == "AXWebArea" { return candidate }
            current = attribute(candidate, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        return nil
    }

    // MARK: - Chrome et Electron

    /// Chrome et les apps Electron (Slack, Notion, VS Code…) n'exposent leur texte que si on le leur demande.
    private static let exposedApps = Mutex<Set<pid_t>>([])

    private static func exposeContent(of element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
            exposedApps.withLock({ $0.insert(pid).inserted })
        else { return }
        AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    // MARK: - Appels bas niveau

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func parameterized(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success
            ? value : nil
    }

    private static func string(_ element: AXUIElement, _ range: CFRange) -> String? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        return parameterized(element, kAXStringForRangeParameterizedAttribute, parameter) as? String
    }

    private static func bounds(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        return rectValue(parameterized(element, kAXBoundsForRangeParameterizedAttribute, parameter))
    }

    private static func rangeValue(_ value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    private static func rectValue(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
    }
}
