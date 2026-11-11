// All rights reserved. Not covered by the MIT license: see TRADEMARKS.md.
//
// Les dessins de Hoova : sa mascotte (tracés, couleurs, visages, poses, lune, aura), le logo « hoova. » et l'icône de la
// barre des menus. Le reste du code de l'app est sous licence MIT.

import AppKit
import SwiftUI

nonisolated extension Brand {
    /// « hoova. », le point en violet Hoova. Le v est de la couleur du mot : blanc en mode sombre.
    static func wordmark(size: CGFloat) -> Text {
        var dot = AttributedString(".")
        dot.foregroundColor = iris
        return Text(AttributedString("hoova") + dot)
            .font(.system(size: size, weight: .black, design: .rounded))
            .tracking(-size * 0.06)
    }
}

/// La mascotte, redessinée d'après `hoova.svg` : un carré de 480 points dont le coin haut gauche est en (272, 262).
nonisolated enum Mascot {
    /// Une expression par moment de l'explication.
    enum Mood: Sendable {
        /// Contente : la réponse vient de l'IA, et dans le logo.
        case happy
        /// Fière : la réponse vient du document ou du dictionnaire.
        case proud
        /// Elle lit, puis suit le texte des yeux pendant l'écriture.
        case reading
        /// « Hmm » : l'IA n'est pas sûre.
        case doubtful
        case sleepy, searching, squinting, lost
        /// On a cliqué sur elle : elle ferme les yeux, comme si elle avait mal.
        case hurt
    }

    /// Un œil rond : il peut regarder ailleurs et cligner.
    struct Eye: Sendable {
        let center: CGPoint
        let radius: CGFloat
    }

    struct Mark: Sendable {
        let path: Path
        /// Un trait de cette épaisseur, sinon une forme pleine.
        var lineWidth: CGFloat?
    }

    struct Face: Sendable {
        var eyes: [Eye] = []
        var marks: [Mark]
    }

    /// Le cadre de `hoova.svg`, descendu de 6 points : son bas tombe juste sous les pieds, et la mascotte debout touche
    /// le bas de sa vue.
    static let frame = CGRect(x: 272, y: 268, width: 480, height: 480)
    static let body = Brand.path(
        "M440 718C418 728 396 718 398 694C368 672 339 638 337 580C335 522 352 474 368 442C374 410 370 372 385 356C398 342 424 346 440 360C468 336 504 312 528 298C546 288 560 298 562 314C566 334 572 348 584 356C602 344 634 346 645 372C651 398 655 432 668 466C690 522 694 592 668 640C652 668 632 684 616 690C618 712 600 728 576 722C556 718 546 702 540 693C512 696 482 694 470 690C466 704 456 714 440 718Z"
    )
    static let light = Brand.path("M280 270H640C648 400 668 508 650 574C612 650 452 670 340 606L280 600Z")
    static let ear = Brand.path(
        "M545 300C552 318 556 340 574 356C584 362 592 360 596 352C580 346 570 330 566 312C562 296 552 290 545 300Z")
    /// Le pli de la jambe gauche.
    static let crease = Brand.path(
        "M428 676C440 682 454 690 466 700C470 708 462 714 456 712C446 702 434 690 428 676Z")
    /// Le croissant : les deux arcs du SVG, soit le grand cercle moins le petit.
    static let moon = Path(ellipseIn: circle(474.985, 427.998, 31))
        .subtracting(Path(ellipseIn: circle(492.158, 411.856, 23)))

    /// Les couleurs du corps : lavande, ou menthe pour Hoova éveil.
    struct Palette {
        let shadow: Color
        let body: Color
        let ear: Color
        let crease: Color
        let feet: Color
    }

    static let lavender = Palette(
        shadow: Color(hex: 0x9F88EE), body: Color(hex: 0xC4B1FB), ear: Color(hex: 0xA890F1),
        crease: Color(hex: 0x6A4FD0), feet: Color(hex: 0x8A6FE4))
    /// Hoova éveil, quand on lui demande d'expliquer son propre texte : son corps prend la menthe de sa lune.
    static let mint = Palette(
        shadow: Color(hex: 0xA3E6C4), body: Color(hex: 0xC9F4DD), ear: Color(hex: 0xB3EDCF),
        crease: Color(hex: 0x6CC79F), feet: Color(hex: 0x86D6AF))
    static let moonColor = Color(hex: 0xC9F4DD)
    /// La lune de Hoova éveil : pleine, d'un or lumineux.
    static let goldColor = Color(hex: 0xFFCC3D)
    static let faceColor = Color(hex: 0x26174F)

    /// Ses petits pieds, sous les jambes et un peu tournés vers l'extérieur. Ils se dessinent derrière le corps : on ne
    /// voit que ce qui dépasse. `step` les fait marcher : -1 lève le pied gauche, 1 le droit.
    static func feet(step: CGFloat = 0) -> Path {
        let feet: [(x: CGFloat, angle: CGFloat, lift: CGFloat)] = [(419, -0.1, max(-step, 0)), (593, 0.1, max(step, 0))]
        var path = Path()
        for foot in feet {
            path.addPath(
                Path(ellipseIn: CGRect(x: -33, y: -23, width: 66, height: 46)),
                transform: CGAffineTransform(translationX: foot.x, y: 724 - 22 * foot.lift).rotated(by: foot.angle))
        }
        return path
    }

    static func face(_ mood: Mood) -> Face {
        switch mood {
        case .happy:
            Face(
                eyes: [Eye(center: CGPoint(x: 410, y: 507), radius: 21), Eye(center: CGPoint(x: 546, y: 507), radius: 21)],
                marks: [Mark(path: Brand.path("M447 526Q475 533 503 526Q502 552 475 553Q448 552 447 526Z"))])
        case .proud:
            Face(marks: [
                Mark(path: Brand.path("M388 516Q410 494 432 516"), lineWidth: 14),
                Mark(path: Brand.path("M524 516Q546 494 568 516"), lineWidth: 14),
                Mark(path: Brand.path("M440 530Q475 540 510 530Q508 566 475 567Q442 566 440 530Z")),
            ])
        case .reading:
            Face(
                eyes: [Eye(center: CGPoint(x: 410, y: 507), radius: 19), Eye(center: CGPoint(x: 546, y: 507), radius: 19)],
                marks: [Mark(path: Brand.path("M460 548Q474 554 488 548"), lineWidth: 13)])
        case .doubtful:
            Face(
                eyes: [Eye(center: CGPoint(x: 410, y: 510), radius: 20), Eye(center: CGPoint(x: 546, y: 512), radius: 15)],
                marks: [
                    Mark(path: Brand.path("M524 478L566 466"), lineWidth: 12),
                    Mark(path: Brand.path("M455 546L497 536"), lineWidth: 12),
                ])
        case .sleepy:
            Face(marks: [
                Mark(path: Brand.path("M388 508Q410 524 432 508"), lineWidth: 14),
                Mark(path: Brand.path("M524 508Q546 524 568 508"), lineWidth: 14),
                Mark(path: Brand.path("M462 542Q475 548 488 542"), lineWidth: 14),
            ])
        case .searching:
            Face(
                eyes: [Eye(center: CGPoint(x: 410, y: 503), radius: 20), Eye(center: CGPoint(x: 546, y: 503), radius: 20)],
                marks: [Mark(path: Path(ellipseIn: CGRect(x: 459, y: 528, width: 22, height: 24)))])
        case .squinting:
            Face(marks: [
                Mark(path: Brand.path("M388 507H432"), lineWidth: 15),
                Mark(path: Brand.path("M524 507H568"), lineWidth: 15),
                Mark(path: Brand.path("M458 541H492"), lineWidth: 15),
            ])
        case .lost:
            Face(
                eyes: [Eye(center: CGPoint(x: 410, y: 507), radius: 21), Eye(center: CGPoint(x: 546, y: 503), radius: 14)],
                marks: [Mark(path: Brand.path("M448 542Q461 530 474 542T500 542"), lineWidth: 12)])
        case .hurt:
            Face(marks: [
                Mark(path: Brand.path("M392 494L426 507L392 520"), lineWidth: 13),
                Mark(path: Brand.path("M564 494L530 507L564 520"), lineWidth: 13),
                Mark(path: Brand.path("M455 548Q465 540 475 548T495 548"), lineWidth: 11),
            ])
        }
    }

    private static func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> CGRect {
        CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)
    }
}

extension Mascot {
    /// La lune entière, à la place du croissant : on la voit même à la nouvelle lune.
    static let moonDisc = Path(ellipseIn: circle(474.985, 427.998, 31))

    /// L'âge de la lune, de 0 (nouvelle lune) à 1 (la suivante) : un cycle de 29,530588853 jours depuis la nouvelle
    /// lune du 6 janvier 2000 à 18 h 14 UTC. Assez juste pour dessiner sa phase, sans réseau.
    static func moonAge(at date: Date = .now) -> Double {
        let days = date.timeIntervalSince(Date(timeIntervalSince1970: 947_182_440)) / 86_400
        let age = (days / 29.530588853).truncatingRemainder(dividingBy: 1)
        return age < 0 ? age + 1 : age
    }

    /// La partie éclairée de la lune à cet âge, à la place du croissant de `hoova.svg`, inclinée comme lui.
    static func lunarPhase(age: Double) -> Path {
        let radius: CGFloat = 31
        // Un quart de cercle ou d'ellipse en une courbe de Bézier.
        let k: CGFloat = 0.5523
        let waxing = age < 0.5
        // La limite de l'ombre : de r (nouvelle lune) à -r (pleine lune).
        let edge = radius * CGFloat(cos(2 * Double.pi * (waxing ? age : 1 - age)))
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -radius))
        path.addCurve(
            to: CGPoint(x: radius, y: 0), control1: CGPoint(x: k * radius, y: -radius),
            control2: CGPoint(x: radius, y: -k * radius))
        path.addCurve(
            to: CGPoint(x: 0, y: radius), control1: CGPoint(x: radius, y: k * radius),
            control2: CGPoint(x: k * radius, y: radius))
        path.addCurve(
            to: CGPoint(x: edge, y: 0), control1: CGPoint(x: k * edge, y: radius), control2: CGPoint(x: edge, y: k * radius))
        path.addCurve(
            to: CGPoint(x: 0, y: -radius), control1: CGPoint(x: edge, y: -k * radius),
            control2: CGPoint(x: k * edge, y: -radius))
        path.closeSubpath()
        // Croissante, elle est éclairée à droite, puis à gauche quand elle décroît.
        return path.applying(
            CGAffineTransform(translationX: 474.985, y: 427.998)
                .rotated(by: -.pi / 6)
                .scaledBy(x: waxing ? 1 : -1, y: 1))
    }
}

extension Mascot {
    /// Ce que fait la mascotte de la barre des menus.
    enum MenuBarMood: Hashable {
        case awake
        /// Elle lit : ses yeux vont à gauche (0), puis à droite (1).
        case reading(Int)
        /// L'IA est en veille.
        case asleep
        /// Le modèle se prépare au premier lancement : une petite lune se remplit à côté d'elle, de 0 à 10 dixièmes.
        case preparing(Int)
    }

    @MainActor private static var menuBarImages: [MenuBarMood: NSImage] = [:]

    /// L'icône de la barre des menus : la silhouette, les yeux découpés, en une seule couleur.
    @MainActor static func menuBarImage(_ mood: MenuBarMood) -> NSImage {
        if let image = menuBarImages[mood] { return image }
        let width: CGFloat = if case .preparing = mood { 28 } else { 18 }
        let image = NSImage(size: NSSize(width: width, height: 18), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            if case .preparing(let tenths) = mood {
                // La lune, à droite : son contour, et sa part éclairée qui grandit du croissant à la pleine lune.
                let moon = CGRect(x: rect.maxX - 9, y: rect.midY - 4, width: 8, height: 8)
                context.setLineWidth(1)
                context.strokeEllipse(in: moon.insetBy(dx: 0.5, dy: 0.5))
                let scale = moon.width / 62
                let phase = Mascot.lunarPhase(age: 0.04 + 0.46 * Double(tenths) / 10)
                    .applying(
                        CGAffineTransform(translationX: moon.midX, y: moon.midY).scaledBy(x: scale, y: scale)
                            .translatedBy(x: -474.985, y: -427.998))
                context.addPath(phase.cgPath)
                context.fillPath()
            }
            let box = Mascot.body.boundingRect.union(Mascot.feet().boundingRect)
            let scale = (rect.height - 1) / box.height
            context.translateBy(x: 9 - box.midX * scale, y: rect.midY - box.midY * scale)
            context.scaleBy(x: scale, y: scale)
            context.addPath(Mascot.body.cgPath)
            context.fillPath()
            context.addPath(Mascot.feet().cgPath)
            context.fillPath()
            // Les yeux sont des trous dans la silhouette.
            context.setBlendMode(.clear)
            switch mood {
            case .awake, .preparing:
                for x in [410.0, 546.0] { context.fillEllipse(in: CGRect(x: x - 32, y: 478, width: 64, height: 64)) }
            case .reading(let step):
                let shift: CGFloat = step == 0 ? -18 : 14
                for x in [410.0, 546.0] {
                    context.fillEllipse(in: CGRect(x: x + shift - 30, y: 494, width: 60, height: 60))
                }
            case .asleep:
                context.setLineWidth(22)
                context.setLineCap(.round)
                for x in [410.0, 546.0] {
                    context.move(to: CGPoint(x: x - 28, y: 512))
                    context.addQuadCurve(to: CGPoint(x: x + 28, y: 512), control: CGPoint(x: x, y: 534))
                }
                context.strokePath()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Hoova"
        menuBarImages[mood] = image
        return image
    }
}

/// La mascotte à la taille qu'on lui donne (elle reste carrée). `look` déplace ses yeux ronds (en points de
/// `hoova.svg`), `openness` les ferme (0) ou les ouvre (1), et `moon` règle l'éclat de sa lune. `moonAge` dessine
/// la lune à cette phase (`Mascot.moonAge()`) ; sans lui, c'est le croissant de la marque. `awake` en fait Hoova
/// éveil : corps menthe et pleine lune d'or. `final`, de 0 à 1, le mène à l'éveil final : yeux blancs qui brillent,
/// plus de bouche, anneau autour de la lune et aura en flamme, qui ondule avec `time` (en secondes). `lift` le fait
/// flotter sur la pointe des pieds (en points de `hoova.svg`). `frame` est la part de `hoova.svg` que montre la vue :
/// `Mascot.auraFrame` laisse la place de l'aura et de la lévitation. Ses pieds marchent avec `\.mascotStep`.
struct MascotView: View {
    var mood = Mascot.Mood.happy
    var look = CGPoint.zero
    var openness: CGFloat = 1
    var moon = 1.0
    var moonAge: Double?
    var awake = false
    var final = 0.0
    var lift: CGFloat = 0
    var time = 0.0
    var frame = Mascot.frame
    @Environment(\.mascotStep) private var step
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let scale = side / frame.width
            context.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -frame.minX, y: -frame.minY)
            let colors = awake ? Mascot.mint : Mascot.lavender
            // Quand il flotte, son ombre reste au sol, plus petite et plus claire à mesure qu'il monte.
            if lift > 2 {
                var shadow = context
                shadow.addFilter(.blur(radius: 7))
                shadow.opacity = min(Double(lift) / 20, 1) * (colorScheme == .dark ? 0.35 : 0.16)
                let spread = max(0.6, 1 - lift / 160)
                shadow.fill(
                    Path(ellipseIn: CGRect(x: 515 - 105 * spread, y: Mascot.ground - 7, width: 210 * spread, height: 14)),
                    with: .color(.black))
            }
            if final > 0 { Mascot.drawAura(in: context, lift: lift, time: time, strength: final) }
            context.translateBy(x: 0, y: -lift)
            if lift > 8 {
                context.fill(Mascot.tiptoes(lift: lift), with: .color(colors.feet))
            } else {
                context.fill(Mascot.feet(step: step), with: .color(colors.feet))
            }
            context.drawLayer { layer in
                layer.clip(to: Mascot.body)
                layer.fill(Mascot.body, with: .color(colors.shadow))
                layer.fill(Mascot.light, with: .color(colors.body))
                layer.fill(Mascot.ear, with: .color(colors.ear))
                layer.fill(Mascot.crease, with: .color(colors.crease))
            }
            if awake {
                // Une pleine lune d'or, qui rayonne, avec un reflet.
                let center = CGPoint(x: 474.985, y: 427.998)
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - 66, y: center.y - 66, width: 132, height: 132)),
                    with: .radialGradient(
                        Gradient(colors: [Mascot.goldColor.opacity(0.7 * moon), Mascot.goldColor.opacity(0)]),
                        center: center, startRadius: 24, endRadius: 66))
                // L'anneau de lumière de l'éveil final : il se resserre autour de la lune pendant la transformation.
                if final > 0 {
                    var ring = context
                    ring.addFilter(.blur(radius: 3))
                    ring.opacity = final
                    let radius = 47 + 30 * (1 - final)
                    ring.stroke(
                        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)),
                        with: .color(Mascot.goldColor.opacity(0.9)), lineWidth: 7)
                }
                context.fill(Mascot.moonDisc, with: .color(Mascot.goldColor.opacity(moon)))
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - 19, y: center.y - 19, width: 14, height: 11)),
                    with: .color(.white.opacity(0.55 * moon)))
            } else if let moonAge {
                context.fill(Mascot.moonDisc, with: .color(Mascot.moonColor.opacity(0.22 * moon)))
                context.fill(Mascot.lunarPhase(age: moonAge), with: .color(Mascot.moonColor.opacity(moon)))
            } else {
                context.fill(Mascot.moon, with: .color(Mascot.moonColor.opacity(moon)))
            }
            // Son visage s'efface à l'éveil final : il ne garde que des yeux blancs, sans âme, qui brillent.
            if final < 1 {
                var face = context
                face.opacity = 1 - final
                let expression = Mascot.face(mood)
                for eye in expression.eyes {
                    let height = 2 * eye.radius * max(openness, 0.12)
                    let rect = CGRect(
                        x: eye.center.x + look.x - eye.radius, y: eye.center.y + look.y - height / 2,
                        width: 2 * eye.radius, height: height)
                    face.fill(Path(ellipseIn: rect), with: .color(Mascot.faceColor))
                }
                for mark in expression.marks {
                    if let width = mark.lineWidth {
                        face.stroke(
                            mark.path, with: .color(Mascot.faceColor),
                            style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                    } else {
                        face.fill(mark.path, with: .color(Mascot.faceColor))
                    }
                }
            }
            if final > 0 {
                var lit = context
                // Les yeux blancs s'allument avant que les autres ne s'effacent : pas de regard gris entre les deux.
                lit.opacity = min(final * 1.6, 1)
                let glow = 66 + 6 * CGFloat(sin(2 * .pi * time / 1.6))
                for (index, center) in [CGPoint(x: 410, y: 507), CGPoint(x: 546, y: 507)].enumerated() {
                    let eye = CGPoint(x: center.x + look.x, y: center.y + look.y)
                    lit.fill(
                        Path(ellipseIn: CGRect(x: eye.x - glow, y: eye.y - glow, width: 2 * glow, height: 2 * glow)),
                        with: .radialGradient(
                            Gradient(colors: [Mascot.sunColor.opacity(0.8), Mascot.sunColor.opacity(0)]), center: eye,
                            startRadius: 10, endRadius: glow))
                    // Il sourit, ou ferme les yeux de douleur : les mêmes traits que son visage, en lumière.
                    if mood == .proud || mood == .hurt {
                        var line = Path()
                        if mood == .proud {
                            line.move(to: CGPoint(x: eye.x - 22, y: eye.y + 9))
                            line.addQuadCurve(to: CGPoint(x: eye.x + 22, y: eye.y + 9), control: CGPoint(x: eye.x, y: eye.y - 22))
                        } else {
                            let side: CGFloat = index == 0 ? 1 : -1
                            line.move(to: CGPoint(x: eye.x - 16 * side, y: eye.y - 13))
                            line.addLine(to: CGPoint(x: eye.x + 14 * side, y: eye.y))
                            line.addLine(to: CGPoint(x: eye.x - 16 * side, y: eye.y + 13))
                        }
                        lit.stroke(
                            line, with: .color(.white), style: StrokeStyle(lineWidth: 14, lineCap: .round, lineJoin: .round))
                        continue
                    }
                    lit.fill(
                        Path(ellipseIn: CGRect(x: eye.x - 23, y: eye.y - 23, width: 46, height: 46)),
                        with: .radialGradient(
                            Gradient(stops: [
                                .init(color: .white, location: 0), .init(color: .white, location: 0.55),
                                .init(color: Mascot.eyeRimColor, location: 1),
                            ]), center: eye, startRadius: 0, endRadius: 25))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

extension Mascot {
    /// La place de l'aura de l'éveil final et de la lévitation : le cadre de la mascotte, agrandi de 140 points de tous
    /// côtés. Une vue qui le montre doit être 760 / 480 fois plus grande, pour garder la mascotte à la même taille.
    static let auraFrame = frame.insetBy(dx: -140, dy: -140)
    /// Le sol : le bas de ses pieds, debout.
    static let ground = frame.maxY
    /// Ses yeux à l'éveil final : soleil autour, blancs au milieu.
    static let sunColor = Color(hex: 0xFFD84A)
    static let eyeRimColor = Color(hex: 0xFFF1A6)

    /// Sur la pointe des pieds, talons levés : deux gouttes, pointe en bas, qui arrivent presque au sol quand il flotte
    /// de `lift` (dans le repère déjà monté de `lift`).
    static func tiptoes(lift: CGFloat) -> Path {
        var path = Path()
        for (x, angle) in [(CGFloat(428), CGFloat(0.18)), (CGFloat(584), CGFloat(-0.18))] {
            path.addPath(
                drop(width: 30, height: 62, pointDown: true),
                transform: CGAffineTransform(translationX: x, y: ground + lift - 36).rotated(by: angle))
        }
        return path
    }

    /// L'aura en flamme de l'éveil final, derrière lui : deux silhouettes floues qui ondulent, et des langues de flamme
    /// qui montent et s'effacent. `time` en secondes, `strength` de 0 (éteinte) à 1.
    static func drawAura(in context: GraphicsContext, lift: CGFloat, time: Double, strength: Double) {
        func wave(_ period: Double, _ phase: Double = 0) -> CGFloat { CGFloat(sin(2 * .pi * time / period + phase)) }
        let raised = body.offsetBy(dx: 0, dy: -lift)
        let base = CGPoint(x: 515 + 5 * wave(1.3), y: 735 - lift)
        var outer = context
        outer.addFilter(.blur(radius: 26))
        outer.opacity = strength
        outer.fill(
            scaled(raised, x: 1.17 + 0.02 * wave(1.1), y: 1.28 + 0.05 * wave(0.9), around: base),
            with: .color(mint.body.opacity(0.6)))
        var inner = context
        inner.addFilter(.blur(radius: 16))
        inner.opacity = strength
        inner.fill(
            scaled(raised, x: 1.08, y: 1.18 + 0.05 * wave(0.7, 1), around: base),
            with: .color(goldColor.opacity(0.5 + 0.1 * Double(wave(1.6)))))
        var tongues = context
        tongues.addFilter(.blur(radius: 9))
        for (index, x) in [CGFloat(452), 515, 578].enumerated() {
            let phase = (time / 1.2 + Double(index) * 0.37).truncatingRemainder(dividingBy: 1)
            tongues.fill(
                drop(width: 26, height: 70, pointDown: false).offsetBy(
                    dx: x + 8 * wave(0.8, Double(index)), dy: 315 - lift - CGFloat(phase) * 60),
                with: .color((index == 1 ? goldColor : mint.body).opacity(0.7 * sin(.pi * phase) * strength)))
        }
    }

    /// Une goutte, arrondie d'un côté et en pointe de l'autre : les pieds sur la pointe, les langues de flamme.
    private static func drop(width: CGFloat, height: CGFloat, pointDown: Bool) -> Path {
        let tip: CGFloat = pointDown ? height / 2 : -height / 2
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -tip))
        path.addCurve(
            to: CGPoint(x: 0, y: tip), control1: CGPoint(x: width, y: -tip), control2: CGPoint(x: width * 0.45, y: tip * 0.6))
        path.addCurve(
            to: CGPoint(x: 0, y: -tip), control1: CGPoint(x: -width * 0.45, y: tip * 0.6), control2: CGPoint(x: -width, y: -tip))
        return path
    }

    /// Un tracé agrandi autour d'un point.
    private static func scaled(_ path: Path, x: CGFloat, y: CGFloat, around center: CGPoint) -> Path {
        path.applying(
            CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: x, y: y)
                .translatedBy(x: -center.x, y: -center.y))
    }
}

nonisolated extension EnvironmentValues {
    /// Les pas de la mascotte quand elle marche : -1 lève son pied gauche, 1 le droit.
    @Entry var mascotStep: CGFloat = 0
}

/// Hoova assis sur un bord, les jambes dans le vide : son corps s'arrête au bord (à 690 dans `hoova.svg`), et ses jambes
/// pendent devant ce qui le porte. La vue garde ses proportions : le bord est à `seat` de sa largeur depuis le haut.
struct SittingMascot: View {
    var mood = Mascot.Mood.happy
    var look = CGPoint.zero
    var moonAge: Double?
    /// Le bord, en part de la largeur de la vue, depuis le haut.
    nonisolated static let seat: CGFloat = (690 - 268) / 480
    /// La hauteur de la vue, en part de sa largeur : le corps jusqu'au bord, puis les jambes qui pendent.
    nonisolated static let height: CGFloat = seat + 0.2

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            ZStack(alignment: .topLeading) {
                MascotView(mood: mood, look: look, moonAge: moonAge)
                    .frame(width: side, height: side)
                    .mask(alignment: .top) { Rectangle().frame(height: side * Self.seat) }
                ForEach([CGFloat(425), 587], id: \.self) { x in
                    VStack(spacing: -side * 0.035) {
                        RoundedRectangle(cornerRadius: side * 0.05, style: .continuous)
                            .fill(Mascot.lavender.shadow)
                            .frame(width: side * 0.12, height: side * 0.1)
                        Ellipse().fill(Mascot.lavender.feet).frame(width: side * 0.14, height: side * 0.1)
                    }
                    // Un peu tournées vers l'extérieur, comme ses pieds debout.
                    .rotationEffect(.degrees(x < 500 ? 8 : -8), anchor: .top)
                    .position(x: (x - 272) / 480 * side, y: side * Self.seat + side * 0.085)
                }
            }
        }
        .aspectRatio(1 / Self.height, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// « hoova. », avec Hoova (`perched`) debout juste à droite du point, les pieds sur la ligne des lettres.
struct PerchedWordmark<Perched: View>: View {
    let size: CGFloat
    @ViewBuilder var perched: Perched

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            // Le logo ne se traduit pas.
            Text(verbatim: "hoova")
            Text(verbatim: ".")
                .foregroundStyle(Brand.iris)
                // Juste à droite du point, les pieds sur la ligne des lettres : jamais sur le point (règle de l'utilisateur,
                // comme sur le site). En surimpression : le logo garde sa place, rien ne bouge quand Hoova apparaît.
                .overlay(alignment: Alignment(horizontal: .trailing, vertical: .lastTextBaseline)) {
                    perched.fixedSize()
                        .alignmentGuide(.trailing) { $0[.leading] - size * 0.12 }
                        .alignmentGuide(.lastTextBaseline) { $0[.bottom] }
                }
        }
        .font(.system(size: size, weight: .black, design: .rounded))
        .tracking(-size * 0.06)
    }
}

/// Une petite lune qui se remplit, du croissant à la pleine lune : l'avancement d'une préparation, comme celle de la barre
/// des menus. Avec `outline`, il ne reste que son contour.
struct MoonProgress: View {
    var value: Double
    var color: Color
    var outline = false

    var body: some View {
        Canvas { context, size in
            // La lune de `hoova.svg` (31 points de rayon) et son contour de 3 points, au centre de la vue.
            let scale = min(size.width, size.height) / 66
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -474.985, y: -427.998)
            context.stroke(Mascot.moonDisc, with: .color(color.opacity(0.55)), lineWidth: 3)
            if !outline { context.fill(Mascot.lunarPhase(age: 0.04 + 0.46 * fraction), with: .color(color)) }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(Text("\(Int((fraction * 100).rounded())) %"))
    }

    private var fraction: Double { min(max(value, 0), 1) }
}
