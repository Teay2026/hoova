import AppKit
import SwiftUI

/// L'icône de la barre des menus : la mascotte éveillée, qui lit pendant une explication (ses yeux vont et
/// viennent), ou qui dort quand l'IA est en veille.
final class StatusIcon {
    private weak var button: NSStatusBarButton?
    private var timer: Timer?
    private var step = 0

    var working = false {
        didSet { if working != oldValue { update() } }
    }
    /// L'IA a quitté la mémoire : c'est au moteur de le dire.
    var asleep = false {
        didSet { if asleep != oldValue { update() } }
    }
    /// La préparation du modèle au premier lancement, de 0 à 1 : une petite lune se remplit à côté de la mascotte.
    /// `nil` quand rien n'est en préparation.
    var preparing: Double? {
        didSet { if preparing != oldValue { update() } }
    }

    init(button: NSStatusBarButton?) {
        self.button = button
        update()
    }

    private func update() {
        timer?.invalidate()
        timer = nil
        if let preparing {
            button?.image = Mascot.menuBarImage(.preparing(Int((min(max(preparing, 0), 1) * 10).rounded())))
            return
        }
        guard working else {
            button?.image = Mascot.menuBarImage(asleep ? .asleep : .awake)
            return
        }
        button?.image = Mascot.menuBarImage(.reading(0))
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.step += 1
                self.button?.image = Mascot.menuBarImage(.reading(self.step % 2))
            }
        }
    }
}

/// Les pièces du menu de la barre des menus : l'en-tête à la mascotte et les lignes d'état.
enum StatusMenu {
    /// La mascotte, le logo et le rappel du geste.
    static func header() -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSHostingView(rootView: Header())
        view.frame.size = view.fittingSize
        view.autoresizingMask = .width
        item.view = view
        return item
    }

    /// Une ligne d'état : le nom à gauche, l'état en gris à droite. Elle reste active, donc lisible : sans action,
    /// un clic ferme simplement le menu.
    static func status(_ title: String, _ value: String, action: Selector? = nil, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "\(title) : \(value)"), action: action, keyEquivalent: "")
        item.target = target
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 250)]
        let font = NSFont.menuFont(ofSize: 0)
        let line = NSMutableAttributedString(string: "\(title)\t", attributes: [.font: font, .paragraphStyle: paragraph])
        line.append(
            NSAttributedString(
                string: value,
                attributes: [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.secondaryLabelColor]))
        item.attributedTitle = line
        return item
    }

    /// « mlx-community/gemma-4-e4b-it-4bit » → « Gemma 4 E4B ».
    static func modelName(_ id: String) -> String {
        let words = (id.split(separator: "/").last ?? Substring(id)).split(separator: "-")
            .filter { !["it", "instruct", "mlx", "4bit", "8bit", "bf16"].contains($0.lowercased()) }
        return words.enumerated().map { index, word in
            if index == 0 { return word.prefix(1).uppercased() + word.dropFirst() }
            return word.contains(where: \.isNumber) ? word.uppercased() : String(word)
        }.joined(separator: " ")
    }

    private struct Header: View {
        var body: some View {
            HStack(spacing: 10) {
                MascotView().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Brand.wordmark(size: 18)
                    Text("Survole un mot, puis \(Preferences.triggerKey.symbol)\u{00A0}\(Preferences.triggerKey.symbol)").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 16)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension StatusMenu {
    /// « À propos de Hoova » : le panneau standard de macOS, avec l'icône, le nom, la version, le copyright
    /// (`NSHumanReadableCopyright`) et les crédits (`Credits.html`, dans la langue de l'app).
    static func about() -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: "À propos de Hoova"), action: #selector(AboutPanel.show), keyEquivalent: "")
        item.target = AboutPanel.shared
        return item
    }
}

/// Ouvre le panneau « À propos ». Hoova vit dans la barre des menus : il passe d'abord au premier plan.
final class AboutPanel: NSObject {
    static let shared = AboutPanel()

    @objc func show() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: Self.options)
    }

    /// Les crédits, dans la police du système, et dans la couleur du texte du mode clair ou sombre : le HTML n'a pas de
    /// couleur, et le panneau l'écrirait en noir. Les liens gardent la leur.
    static var options: [NSApplication.AboutPanelOptionKey: Any] {
        guard let url = Bundle.main.url(forResource: "Credits", withExtension: "html"),
            let credits = try? NSMutableAttributedString(
                url: url, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil)
        else { return [:] }
        let all = NSRange(location: 0, length: credits.length)
        credits.enumerateAttribute(.font, in: all) { font, range, _ in
            let bold = (font as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
            credits.addAttribute(.font, value: NSFont.systemFont(ofSize: 11, weight: bold ? .semibold : .regular), range: range)
        }
        credits.enumerateAttribute(.link, in: all) { link, range, _ in
            if link == nil { credits.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range) }
        }
        return [.credits: credits]
    }
}
