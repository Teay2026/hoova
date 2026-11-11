import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import ScreenCaptureKit
import Vision
import os

private let log = Logger(subsystem: "com.teayouness.hoova", category: "lecture")

/// Lit le texte sous la souris par capture d'écran + lecture de document (Vision, sur le Neural Engine).
/// Marche partout : images, vidéos, PDF scannés, apps qui n'exposent rien.
public enum ScreenOCRReader {
    public static var isAllowed: Bool { CGPreflightScreenCaptureAccess() }

    public static func read(at point: CGPoint) async -> Capture? {
        guard isAllowed else { return nil }
        let rect = zone(around: point)
        guard let image = try? await screen(in: rect) else {
            log.notice("OCR : capture d'écran impossible")
            return nil
        }
        return await recognize(image, in: rect, at: point)
    }

    /// Rien autour de la souris, ni texte ni dessin : une seule couleur. C'est ce que donne une vidéo protégée contre
    /// la copie (Udemy, Netflix…) : le navigateur la retire des captures d'écran, on n'y voit que le fond du lecteur.
    public static func isBlank(around point: CGPoint) async -> Bool {
        guard isAllowed,
            let image = try? await screen(in: CGRect(x: point.x - 60, y: point.y - 30, width: 120, height: 60)),
            let pixels = Pixels(image)
        else { return false }
        return pixels.isUniform
    }

    /// La sélection telle qu'elle apparaît à l'écran : les mots surlignés de la couleur de sélection.
    /// Dernier recours pour les sites qui ne donnent leur sélection ni par l'accessibilité, ni par ⌘C.
    public static func highlightedSelection(around point: CGPoint) async -> Capture? {
        guard isAllowed else { return nil }
        let rect = zone(around: point)
        guard let image = try? await screen(in: rect),
            let pixels = Pixels(image),
            let document = try? await request().perform(on: image).first?.document
        else { return nil }
        let colors = highlightColors()

        var selected: [(text: String, box: CGRect)] = []
        var touched: [Int] = []
        let paragraphs = document.paragraphs
        for (index, paragraph) in paragraphs.enumerated() {
            let hits = (paragraph.words ?? []).compactMap { word -> (text: String, box: CGRect)? in
                guard let text = word.topCandidates(1).first?.string,
                    pixels.isHighlighted(word.boundingBox.cgRect, by: colors)
                else { return nil }
                return (text, word.boundingBox.cgRect)
            }
            guard !hits.isEmpty else { continue }
            selected += hits
            touched.append(index)
        }
        guard let first = selected.first, let low = touched.first, let high = touched.last else { return nil }
        // Le contexte : les paragraphes de la sélection, plus celui d'avant et celui d'après.
        let context = paragraphs[max(low - 1, 0)...min(high + 1, paragraphs.count - 1)]
            .map(\.transcript).joined(separator: " ")
        let union = selected.dropFirst().reduce(first.box) { $0.union($1.box) }
        let anchor = CGRect(
            x: rect.minX + union.minX * rect.width, y: rect.minY + (1 - union.maxY) * rect.height,
            width: union.width * rect.width, height: union.height * rect.height)
        // Le surlignage commence souvent après l'élision : « l'effet de levier » → « effet de levier ».
        let term = TextAround.clean(selected.map(\.text).joined(separator: " "))
            .replacingOccurrences(of: #"^(?:[cdjlmnst]|qu)['’]"#, with: "", options: [.regularExpression, .caseInsensitive])
        let text = TextAround.clean(context)
        let around = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
            .map { TextAround.paragraph(in: text, around: $0, maxLength: 900) } ?? String(text.prefix(900))
        var capture = Capture(term: term, context: around, anchor: anchor, method: .screenSelection)
        (capture.before, capture.after) = column(of: blocks(paragraphs), around: low...high)
        return capture
    }

    /// Les couleurs de surlignage de la sélection, en clair et en sombre. Pas celles d'une fenêtre inactive : leurs gris
    /// sont aussi ceux des boutons et des encadrés de beaucoup de pages, et le lecteur de YouTube passait pour sélectionné.
    private static func highlightColors() -> [SIMD3<Double>] {
        let appearances = [NSAppearance.Name.aqua, .darkAqua].compactMap { NSAppearance(named: $0) }
        var colors: [SIMD3<Double>] = []
        for appearance in appearances {
            appearance.performAsCurrentDrawingAppearance {
                guard let rgb = NSColor.selectedTextBackgroundColor.usingColorSpace(.deviceRGB) else { return }
                colors.append(SIMD3(rgb.redComponent, rgb.greenComponent, rgb.blueComponent) * 255)
            }
        }
        return colors
    }

    /// Une lecture à blanc : macOS charge ses modèles une fois (jusqu'à 30 s la toute première fois).
    public static func prewarm() async {
        guard
            let context = CGContext(
                data: nil, width: 240, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 48))
        let font = CTFontCreateWithName("Helvetica" as CFString, 26, nil)
        let text = NSAttributedString(
            string: "Hoova prêt", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        context.textPosition = CGPoint(x: 8, y: 14)
        CTLineDraw(CTLineCreateWithAttributedString(text as CFAttributedString), context)
        guard let image = context.makeImage() else { return }
        _ = try? await request().perform(on: image)
    }

    /// L'écran dans `rect` (coordonnées globales, origine en haut à gauche), sans les fenêtres de Hoova : la carte
    /// s'ouvre dès le second ⌃, pendant la lecture, et ne doit ni cacher le texte autour du mot ni être lue avec lui.
    /// Quand la zone déborde de son écran, ou que le filtre échoue, l'écran tel quel.
    private static func screen(in rect: CGRect) async throws -> CGImage {
        let start = ContinuousClock.now
        if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
            let display = content.displays.first(where: { $0.frame.contains(rect) })
        {
            let me = ProcessInfo.processInfo.processIdentifier
            let filter = SCContentFilter(
                display: display, excludingApplications: content.applications.filter { $0.processID == me },
                exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            configuration.width = Int((rect.width * CGFloat(filter.pointPixelScale)).rounded())
            configuration.height = Int((rect.height * CGFloat(filter.pointPixelScale)).rounded())
            configuration.showsCursor = false
            if let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
            {
                log.notice("OCR : capture sans les fenêtres de Hoova, en \(ContinuousClock.now - start, privacy: .public)")
                return image
            }
        }
        log.notice("OCR : capture de l'écran tel quel, fenêtres de Hoova comprises")
        return try await SCScreenshotManager.captureImage(in: rect)
    }

    /// La fenêtre sous la souris, sur ± 500 points de hauteur : des lignes entières, et le texte visible autour du
    /// passage.
    static func zone(around point: CGPoint) -> CGRect {
        let band = CGRect(x: point.x - 700, y: point.y - 500, width: 1400, height: 1000)
        guard let window = windowBounds(at: point) else { return band }
        let width = min(window.width, 1800)
        let x = min(max(point.x - width / 2, window.minX), window.maxX - width)
        return CGRect(x: x, y: band.minY, width: width, height: band.height).intersection(window)
    }

    /// La fenêtre d'app la plus en avant sous la souris (coordonnées globales, origine en haut à gauche).
    private static func windowBounds(at point: CGPoint) -> CGRect? {
        guard
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        for window in windows {
            guard window[kCGWindowLayer as String] as? Int == 0,
                window[kCGWindowOwnerPID as String] as? pid_t != me,
                let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                bounds.contains(point)
            else { continue }
            return bounds
        }
        return nil
    }

    static func recognize(_ image: CGImage, in rect: CGRect, at point: CGPoint) async -> Capture? {
        guard let document = try? await request().perform(on: image).first?.document else { return nil }
        // La souris, en coordonnées Vision : de 0 à 1, origine en bas à gauche.
        let target = CGPoint(x: (point.x - rect.minX) / rect.width, y: 1 - (point.y - rect.minY) / rect.height)

        // Le mot sous la souris, sinon le plus proche à moins de 14 points : sur une vidéo ou dans une image,
        // la pointe de la souris tombe souvent juste à côté des lettres.
        let paragraphs = document.paragraphs
        var nearest: (paragraph: Int, word: Int, distance: CGFloat)?
        var count = 0
        var closest = CGFloat.infinity
        for (p, paragraph) in paragraphs.enumerated() {
            for (w, candidate) in (paragraph.words ?? []).enumerated() {
                let box = candidate.boundingBox.cgRect
                let dx = max(box.minX - target.x, 0, target.x - box.maxX) * rect.width
                let dy = max(box.minY - target.y, 0, target.y - box.maxY) * rect.height
                let distance = (dx * dx + dy * dy).squareRoot()
                count += 1
                closest = min(closest, distance)
                if distance < (nearest?.distance ?? 14) { nearest = (p, w, distance) }
            }
        }
        log.notice(
            "OCR : \(count, privacy: .public) mots lus dans une zone de \(Int(rect.width), privacy: .public)×\(Int(rect.height), privacy: .public) pt, souris en \(Int(point.x), privacy: .public),\(Int(point.y), privacy: .public), mot le plus proche à \(closest.isFinite ? Int(closest) : -1, privacy: .public) pt"
        )
        if nearest == nil, Switches.isOn("DEBUG") {
            saveMissed(image, words: paragraphs.flatMap { ($0.words ?? []).map(\.boundingBox.cgRect) }, target: target)
        }
        if let nearest {
            let paragraph = paragraphs[nearest.paragraph]
            let words = paragraph.words ?? []
            let index = nearest.word
            guard let raw = words[index].topCandidates(1).first?.string,
                let letter = raw.firstIndex(where: \.isLetter),
                let word = TextAround.word(in: raw, atUTF16Offset: letter.utf16Offset(in: raw))
            else { return nil }

            // Le même mot dans le texte du paragraphe : la n-ième occurrence si le mot s'y répète.
            let transcript = paragraph.transcript.replacingOccurrences(of: "\n", with: " ")
            let repeats = words[..<index].filter { $0.topCandidates(1).first?.string == raw }.count
            var found: Range<String.Index>?
            var from = transcript.startIndex
            for _ in 0...repeats {
                guard let range = transcript.range(of: word.text, range: from..<transcript.endIndex) else { break }
                found = range
                from = range.upperBound
            }
            let context = found.map { TextAround.paragraph(in: transcript, around: $0) }
                ?? TextAround.clean(transcript.prefix(700))

            let box = words[index].boundingBox.cgRect
            let anchor = CGRect(
                x: rect.minX + box.minX * rect.width,
                y: rect.minY + (1 - box.maxY) * rect.height,
                width: box.width * rect.width,
                height: box.height * rect.height)
            var capture = Capture(term: word.text, context: context, anchor: anchor, method: .ocr)
            (capture.before, capture.after) = column(of: blocks(paragraphs), around: nearest.paragraph...nearest.paragraph)
            return capture
        }
        return nil
    }

    /// Chaque paragraphe lu, avec son cadre (coordonnées Vision : de 0 à 1, origine en bas à gauche).
    private static func blocks(_ paragraphs: [DocumentObservation.Container.Text]) -> [(box: CGRect, text: String)] {
        paragraphs.map { paragraph in
            ((paragraph.words ?? []).reduce(CGRect.null) { $0.union($1.boundingBox.cgRect) }, paragraph.transcript)
        }
    }

    /// Les paragraphes de la même colonne que ceux de `range`, au-dessus puis au-dessous, dans l'ordre de lecture : le
    /// texte visible autour du passage. La colonne écarte par exemple la barre latérale d'une app de discussion.
    static func column(of blocks: [(box: CGRect, text: String)], around range: ClosedRange<Int>)
        -> (before: String?, after: String?)
    {
        let column = blocks[range].map(\.box).reduce(CGRect.null) { $0.union($1) }
        guard !column.isNull else { return (nil, nil) }
        var above: [(y: CGFloat, text: String)] = []
        var below: [(y: CGFloat, text: String)] = []
        for (index, block) in blocks.enumerated() where !range.contains(index) && !block.box.isNull {
            let overlap = min(block.box.maxX, column.maxX) - max(block.box.minX, column.minX)
            let text = TextAround.clean(block.text)
            guard overlap > 0.5 * min(block.box.width, column.width), !text.isEmpty else { continue }
            if block.box.midY > column.maxY {
                above.append((block.box.midY, text))
            } else if block.box.midY < column.minY {
                below.append((block.box.midY, text))
            }
        }
        // Plus haut à l'écran, c'est un y plus grand : on lit de haut en bas.
        let before = above.sorted { $0.y > $1.y }.map(\.text).joined(separator: "\n")
        let after = below.sorted { $0.y > $1.y }.map(\.text).joined(separator: "\n")
        return (before.isEmpty ? nil : before, after.isEmpty ? nil : after)
    }

    /// Mode test : la dernière capture où aucun mot n'était sous la souris, avec les mots lus (en bleu) et la souris
    /// (en rouge), dans ~/Library/Application Support/Hoova/derniere-capture-ratee.png. Elle reste sur le Mac.
    private static func saveMissed(_ image: CGImage, words: [CGRect], target: CGPoint) {
        let (width, height) = (CGFloat(image.width), CGFloat(image.height))
        guard
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        // Comme Vision, CGContext a son origine en bas à gauche.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setLineWidth(2)
        context.setStrokeColor(red: 0, green: 0.4, blue: 1, alpha: 1)
        for box in words {
            context.stroke(
                CGRect(x: box.minX * width, y: box.minY * height, width: box.width * width, height: box.height * height))
        }
        let (x, y) = (target.x * width, target.y * height)
        context.setStrokeColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.strokeLineSegments(between: [
            CGPoint(x: x - 24, y: y), CGPoint(x: x + 24, y: y), CGPoint(x: x, y: y - 24), CGPoint(x: x, y: y + 24),
        ])
        guard let marked = context.makeImage() else { return }
        let url = URL.applicationSupportDirectory.appending(path: "Hoova/derniere-capture-ratee.png")
        guard let file = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(file, marked, nil)
        CGImageDestinationFinalize(file)
    }

    private static func request() -> RecognizeDocumentsRequest {
        var request = RecognizeDocumentsRequest()
        // Vision reconnaît la langue du texte lui-même : aussi rapide que le français et l'anglais imposés, et toutes
        // les langues sont lues (essai du 2 novembre 2026).
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        request.textRecognitionOptions.useLanguageCorrection = true
        return request
    }
}

/// Les pixels d'une capture d'écran, en RGBA 8 bits, pour lire la couleur autour d'un mot.
private struct Pixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(_ image: CGImage) {
        let (width, height) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        (self.width, self.height, self.bytes) = (width, height, bytes)
    }

    /// Le fond du mot a la couleur de sélection. On regarde le haut et le milieu du mot : le cadre que
    /// donne Vision descend plus bas que le surlignage, et le milieu tombe parfois sur une lettre.
    /// `box` est en coordonnées Vision : de 0 à 1, origine en bas à gauche.
    func isHighlighted(_ box: CGRect, by colors: [SIMD3<Double>]) -> Bool {
        let top = Int((1 - box.maxY) * Double(height))
        let bottom = Int((1 - box.minY) * Double(height))
        var matches = 0
        for fraction in [0.2, 0.5, 0.8] {
            let x = Int((box.minX + box.width * fraction) * Double(width))
            for y in [top - 2, top + 1, (top + bottom) / 2] {
                guard let pixel = color(x: x, y: y) else { continue }
                if colors.contains(where: { distance($0, pixel) < 45 }) { matches += 1 }
            }
        }
        return matches >= 4
    }

    /// Une seule couleur partout, à peu de chose près.
    var isUniform: Bool {
        let (r, g, b) = (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
        return stride(from: 0, to: bytes.count, by: 4).allSatisfy {
            abs(Int(bytes[$0]) - r) <= 4 && abs(Int(bytes[$0 + 1]) - g) <= 4 && abs(Int(bytes[$0 + 2]) - b) <= 4
        }
    }

    private func color(x: Int, y: Int) -> SIMD3<Double>? {
        guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        let i = (y * width + x) * 4
        return SIMD3(Double(bytes[i]), Double(bytes[i + 1]), Double(bytes[i + 2]))
    }

    private func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let d = a - b
        return (d * d).sum().squareRoot()
    }
}
