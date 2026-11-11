import AppKit
import SwiftUI

/// Au double ⌃, le mot lu s'allume un instant à l'écran : on voit tout de suite ce que Hoova a lu. C'est une fenêtre
/// transparente posée par-dessus, qui laisse passer les clics et ne prend jamais le focus ; elle est créée une seule
/// fois, au lancement.
final class GlowController {
    private let panel: NSPanel
    private let host = NSHostingView(rootView: GlowView(word: nil))
    private var hiding: Task<Void, Never>?
    /// Change à chaque affichage, pour rejouer l'animation.
    private var count = 0

    init() {
        panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = host
    }

    /// `word` en coordonnées globales (origine en haut à gauche), comme la lecture le donne.
    func show(word: CGRect?) {
        hide()
        guard let word, word.width > 1 else { return }
        let area = word.insetBy(dx: -8, dy: -8)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        count += 1
        host.rootView = GlowView(word: word.offsetBy(dx: -area.minX, dy: -area.minY), count: count)
        panel.setFrame(NSRect(x: area.minX, y: top - area.maxY, width: area.width, height: area.height), display: false)
        host.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        hiding = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hiding?.cancel()
        hiding = nil
        panel.orderOut(nil)
        host.rootView = GlowView(word: nil)
    }
}

/// Le mot s'allume 200 ms, au plus près de ses lettres, puis s'efface.
private struct GlowView: View {
    let word: CGRect?
    var count = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let word {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Brand.iris.opacity(0.42))
                    .frame(width: word.width + 2, height: word.height)
                    .offset(x: word.minX - 1, y: word.minY)
                    .modifier(Flash(rise: 0.06, hold: 0.14, fall: 0.2, still: reduceMotion))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id(count)
    }
}

/// Apparaître, rester, disparaître : une seule fois.
private struct Flash: ViewModifier {
    let rise: Double
    let hold: Double
    let fall: Double
    let still: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        if still {
            content
        } else {
            content
                .keyframeAnimator(initialValue: 0.0, trigger: shown) { content, opacity in
                    content.opacity(opacity)
                } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(1, duration: rise)
                        LinearKeyframe(1, duration: hold)
                        LinearKeyframe(0, duration: fall)
                    }
                }
                .onAppear { shown = true }
        }
    }
}
