import AppKit
import SwiftUI

/// La marque : la palette, et la lecture des tracés SVG (docs/direction-artistique.md). Le logo, la mascotte et l'icône
/// de la barre des menus sont dans `Mascot.swift`, tous droits réservés.
nonisolated enum Brand {
    /// Violet Hoova : la signature, pour les fonds et les détails (trop clair pour du texte).
    static let iris = Color(hex: 0xB8A1EE)
    /// Violet profond : l'accent, pour les grands textes et les repères.
    static let purple = Color(hex: 0x9276E8)
    /// Nuit magique : le texte sur fond clair, et le fond en mode sombre.
    static let night = Color(hex: 0x22155B)
    /// Menthe lunaire : la couleur du croissant, en petites touches.
    static let mint = Color(hex: 0xC9F4DC)
    /// Crème nuage : le texte en mode sombre, et le fond en mode clair.
    static let cream = Color(hex: 0xFBF8EE)
    /// Hors palette : la seule couleur d'alerte, pour « à vérifier ».
    static let peach = Color(hex: 0xFFC48C)

    /// Lit un tracé SVG en coordonnées absolues (M, L, H, V, C, Q, T, Z) : ceux de `hoova.svg`.
    static func path(_ svg: String) -> Path {
        var path = Path()
        var command: Character = "M"
        var values: [CGFloat] = []
        var current = CGPoint.zero
        var lastControl: CGPoint?
        func point(_ i: Int) -> CGPoint { CGPoint(x: values[i], y: values[i + 1]) }
        for match in svg.matches(of: /[A-Za-z]|-?[0-9]*\.?[0-9]+/) {
            let token = match.output
            if let letter = token.first, letter.isLetter {
                command = letter
                if letter == "Z" {
                    path.closeSubpath()
                    current = path.currentPoint ?? current
                }
                continue
            }
            values.append(CGFloat(Double(token) ?? 0))
            let needed =
                switch command {
                case "H", "V": 1
                case "M", "L", "T": 2
                case "Q": 4
                case "C": 6
                default: 0
                }
            guard values.count == needed else { continue }
            var control: CGPoint?
            switch command {
            case "M":
                path.move(to: point(0))
                // Les points qui suivent un M sont des lignes.
                command = "L"
            case "L": path.addLine(to: point(0))
            case "H": path.addLine(to: CGPoint(x: values[0], y: current.y))
            case "V": path.addLine(to: CGPoint(x: current.x, y: values[0]))
            case "C": path.addCurve(to: point(4), control1: point(0), control2: point(2))
            case "Q":
                control = point(0)
                path.addQuadCurve(to: point(2), control: point(0))
            case "T":
                // Le point de contrôle est le reflet du précédent.
                let reflected = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                control = reflected
                path.addQuadCurve(to: point(0), control: reflected)
            default: break
            }
            lastControl = control
            current = path.currentPoint ?? current
            values.removeAll()
        }
        return path
    }
}

/// L'étoile ✳ de la DA : ce qu'écrit l'IA.
nonisolated struct Sparkle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2
        for step in 0..<4 {
            let angle = Double(step) * .pi / 4
            let dx = cos(angle) * radius
            let dy = sin(angle) * radius
            path.move(to: CGPoint(x: rect.midX - dx, y: rect.midY - dy))
            path.addLine(to: CGPoint(x: rect.midX + dx, y: rect.midY + dy))
        }
        return path
    }
}

nonisolated extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}
