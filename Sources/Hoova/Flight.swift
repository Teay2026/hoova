import AppKit
import SwiftUI

/// Hoova éveil final vole d'une carte à l'autre : une fenêtre transparente, posée au-dessus des deux cartes le temps du
/// vol, qui laisse passer les clics et ne prend jamais le focus. Elle est créée une seule fois, au lancement.
final class FlightController {
    /// La durée du vol : la mascotte de la carte d'arrivée se montre à la fin.
    static let duration = 0.6
    private let panel: NSPanel
    private let host = NSHostingView(rootView: FlightView(route: nil))
    private var landing: Task<Void, Never>?

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

    /// Du centre de la mascotte au départ jusqu'à son centre à l'arrivée (coordonnées AppKit). `side` : la taille de sa
    /// vue, aura comprise.
    func fly(from: CGPoint, to: CGPoint, side: CGFloat) {
        hide()
        // L'arc monte un peu au-dessus du départ et de l'arrivée.
        let control = CGPoint(x: (from.x + to.x) / 2, y: max(from.y, to.y) + 40)
        let area = CGRect(
            x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: control.y - min(from.y, to.y)
        ).insetBy(dx: -side, dy: -side)
        // Dans la fenêtre, l'origine est en haut à gauche.
        func local(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - area.minX, y: area.maxY - point.y) }
        host.rootView = FlightView(
            route: Route(from: local(from), to: local(to), control: local(control), start: .now, side: side))
        panel.setFrame(area, display: false)
        host.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        landing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.duration + 0.05))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        landing?.cancel()
        landing = nil
        panel.orderOut(nil)
        host.rootView = FlightView(route: nil)
    }
}

/// Le chemin du vol, dans la fenêtre (origine en haut à gauche).
private struct Route {
    let from: CGPoint
    let to: CGPoint
    let control: CGPoint
    let start: Date
    let side: CGFloat

    /// Où il est à cette étape du vol (de 0 à 1) : sur un arc, en accélérant puis en ralentissant.
    func point(_ progress: Double) -> CGPoint {
        let t = CGFloat(progress * progress * (3 - 2 * progress))
        let u = 1 - t
        return CGPoint(
            x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
            y: u * u * from.y + 2 * u * t * control.y + t * t * to.y)
    }
}

/// Il vole en arc, en flottant, et laisse derrière lui des reflets qui s'effacent.
private struct FlightView: View {
    let route: Route?

    var body: some View {
        if let route {
            TimelineView(.animation) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let progress = min(max(timeline.date.timeIntervalSince(route.start) / FlightController.duration, 0), 1)
                ZStack(alignment: .topLeading) {
                    ForEach(1..<4) { echo in
                        mascot(time: time, side: route.side)
                            .position(route.point(max(progress - Double(echo) * 0.08, 0)))
                            .opacity(progress < 1 ? 0.22 / Double(echo) : 0)
                    }
                    mascot(time: time, side: route.side).position(route.point(progress))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func mascot(time: Double, side: CGFloat) -> some View {
        MascotView(awake: true, final: 1, lift: 30, time: time, frame: Mascot.auraFrame).frame(width: side, height: side)
    }
}
