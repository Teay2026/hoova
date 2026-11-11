import AppKit
import HoovaCore
import KeyboardShortcuts
import SwiftUI
import os

private let log = Logger(subsystem: "com.teayouness.hoova", category: "pop-up")

/// L'état du pop-up, mis à jour au fil de l'écriture.
@Observable
final class PopupModel {
    enum Phase: Equatable {
        case reading, waitingModel, writing, done, nothingFound
        /// Rien sous la souris qu'une seule couleur : sans doute une vidéo protégée contre la copie.
        case blank
        case failed(String)
    }

    var term = ""
    var text = ""
    var source: Source?
    var uncertain = false
    var phase = Phase.reading
    var anchor: CGRect?
    /// Le titre de la page ou du document lu, affiché au-dessus du terme : on voit dans quel contexte Hoova a compris.
    var title: String?
    /// Hoova sur Hoova : l'explication d'un passage du pop-up lui-même, demandée d'un double ⌃ sur son texte. Elle
    /// s'ouvre dans une deuxième carte.
    var awake = false
    /// L'état de la mascotte, selon les explications faites de suite : 1, Hoova ; 2, Hoova éveil ; 3, Hoova éveil
    /// final. C'est le pop-up qui le fixe, en affichant la carte.
    var level = 1
    /// Cette explication est celle qui atteint l'éveil final : la mascotte se transforme.
    var awakening = false
    /// La mascotte arrive en volant depuis l'autre carte : elle n'apparaît sur celle-ci qu'à la fin du vol.
    var flying = false
    /// Cette explication compte dans la série (elle n'en sort que si elle échoue).
    @ObservationIgnored var inStreak = false

    /// Une explication, et non un message (rien sous le pointeur, vidéo protégée, erreur).
    var isExplanation: Bool {
        switch phase {
        case .reading, .waitingModel, .writing, .done: true
        case .nothingFound, .blank, .failed: false
        }
    }

    /// Hoova lit ou écrit encore.
    var isWorking: Bool {
        switch phase {
        case .reading, .waitingModel, .writing: true
        case .done, .nothingFound, .blank, .failed: false
        }
    }
}

/// Où sont le pointeur et la fenêtre du pop-up à l'écran (coordonnées AppKit) : la mascotte regarde le pointeur.
@Observable
final class PopupPointer {
    var location = CGPoint.zero
    var window = CGRect.zero
    /// La souris survole la mascotte : elle sourit.
    var hovering = false
    /// La carte et la mascotte dans la fenêtre (origine en haut à gauche) : un double ⌃ sur elles ne relit pas l'écran.
    @ObservationIgnored var card = CGRect.zero
    @ObservationIgnored var mascot = CGRect.zero
    /// Le pointeur bouge au-dessus de la mascotte, quand elle prend la souris.
    @ObservationIgnored var moved: () -> Void = {}
}

/// Le pop-up : une carte sous le mot lu. Un double ⌃ sur une explication en ouvre une autre sous le mot choisi : la
/// carte d'où vient le mot reste derrière, et Hoova y passe, éveillé. Jamais plus de deux cartes : celle qui ne sert
/// plus disparaît. Les fenêtres sont créées une seule fois, au lancement : au double ⌃, il n'y a plus qu'à les placer
/// et à les afficher.
final class PopupController {
    /// Deux fenêtres de carte, qui se relaient : celle du dessus montre la dernière explication.
    private let first = CardWindow()
    private let second = CardWindow()
    private var secondOnTop = false
    private var front: CardWindow { secondOnTop ? second : first }
    private var back: CardWindow { secondOnTop ? first : second }
    /// Le mot lu qui s'allume.
    private let glow = GlowController()
    /// Hoova éveil final qui vole d'une carte à l'autre.
    private let flight = FlightController()
    /// La série : les explications faites de suite, chacune moins de 5 minutes après la précédente. Elle fait évoluer la
    /// mascotte, et repart à zéro au lancement.
    private var streak = 0
    private var lastExplanation: ContinuousClock.Instant?
    private static let calm = Duration.seconds(5 * 60)
    private var monitors: [Any] = []
    private var shownAt = NSPoint.zero
    /// La dernière explication, suivie jusqu'à la fin de l'écriture, même pop-up fermé.
    private weak var current: PopupModel?
    /// La carte dont le mot s'est déjà allumé.
    private weak var glowed: PopupModel?
    private var working = false {
        didSet { if working != oldValue { onWorkChange(working) } }
    }
    /// Hoova commence ou finit de lire et d'écrire : pour la mascotte de la barre des menus.
    var onWorkChange: (Bool) -> Void = { _ in }

    init() {
        first.warmUp(level: 1)
        second.warmUp(level: 3)
        for card in [first, second] {
            card.text.pointerMoved = { [weak self] in self?.pointerMoved() }
            card.pointer.moved = { [weak self] in self?.pointerMoved() }
        }
    }

    func show(_ model: PopupModel, at point: CGPoint) {
        let start = ContinuousClock.now
        joinStreak(model)
        if model.awake, front.isVisible {
            showNested(model)
            log.info("Carte de Hoova sur Hoova affichée en \(ContinuousClock.now - start, privacy: .public)")
            return
        }
        hide()
        secondOnTop = false
        // Le mot si on connaît sa position, sinon la souris (coordonnées globales, origine en haut à gauche).
        guard first.show(model, under: model.anchor ?? CGRect(x: point.x, y: point.y - 10, width: 1, height: 20))
        else { return }
        shownAt = NSEvent.mouseLocation
        monitors = [
            NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
            ) { [weak self] _ in self?.hide() },
            NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.pointerMoved() },
        ].compactMap { $0 }
        current = model
        follow(model)
        log.info("Pop-up affiché en \(ContinuousClock.now - start, privacy: .public)")
    }

    /// L'état de la mascotte pour cette carte. Une explication compte dans la série ; un message montre la mascotte
    /// dans l'état où elle est. Après 5 minutes sans explication, la série repart à zéro.
    private func joinStreak(_ model: PopupModel) {
        let now = ContinuousClock.now
        if let last = lastExplanation, now - last > Self.calm { streak = 0 }
        if model.isExplanation {
            streak += 1
            lastExplanation = now
            model.inStreak = true
        }
        model.level = max(1, min(streak, 3))
        model.awakening = model.inStreak && streak == 3
        log.info("Série : \(self.streak, privacy: .public) explication(s) de suite, état \(model.level, privacy: .public)")
    }

    /// Hoova sur Hoova : une nouvelle carte s'ouvre sous le mot choisi. La carte d'où vient le mot reste derrière ;
    /// l'autre, qui ne sert plus, disparaît et accueille la nouvelle explication. Hoova se glisse derrière la carte d'où
    /// vient le mot, puis sort la tête de la nouvelle ; en éveil final, il vole de l'une à l'autre.
    private func showNested(_ model: PopupModel) {
        let anchor = model.anchor ?? .zero
        let word = cocoa(CGPoint(x: anchor.midX, y: anchor.midY))
        let source = back.contains(word, mascot: false) && !front.contains(word, mascot: false) ? back : front
        let target = source === first ? second : first
        let takeOff = source.mascotCenter
        let flies = model.level == 3 && source.model?.level == 3 && takeOff != nil
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.flying = flies
        target.hide()
        target.show(model, under: anchor)
        secondOnTop = target === second
        shownAt = NSEvent.mouseLocation
        current = model
        follow(model)
        // La mascotte quitte l'autre carte juste après : la nouvelle s'affiche sans l'attendre. Son arrivée en volant
        // n'est connue qu'une fois la nouvelle carte mise en page.
        Task { @MainActor [flight] in
            source.sendMascotAway(flies ? .flight : .behind)
            guard flies, let takeOff, let landing = target.mascotCenter else { return }
            flight.fly(from: takeOff, to: landing, side: PerchedMascot.auraSide)
        }
    }

    func hide() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        second.hide()
        first.hide()
        glow.hide()
        flight.hide()
    }

    /// Ce que montre le pop-up sous ce point (coordonnées globales, origine en haut à gauche) : la sélection faite dans
    /// une explication, sinon le mot sous le pointeur. Pour un double ⌃ sur le pop-up lui-même ; nil ailleurs.
    func capture(at point: CGPoint) -> Capture? {
        let location = cocoa(point)
        // La carte du dessus cache ce qu'elle recouvre de l'autre.
        guard let card = [front, back].first(where: { $0.contains(location, mascot: false) }),
            let model = card.model, let picked = card.text.view?.pick(at: location)
        else { return nil }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        var capture = Capture(
            term: picked.text, context: model.text,
            anchor: CGRect(
                x: picked.frame.minX, y: top - picked.frame.maxY, width: picked.frame.width,
                height: picked.frame.height),
            method: .popup)
        // Le terme de la carte donne le sujet : « Dans « taux directeur » ».
        capture.title = model.term
        return capture
    }

    /// Le point (coordonnées globales, origine en haut à gauche) est sur une carte ou sur la mascotte. Un double ⌃ là,
    /// hors de ce que donne `capture(at:)`, ne doit pas relire l'écran : on y lirait le pop-up lui-même.
    func contains(_ point: CGPoint) -> Bool {
        let location = cocoa(point)
        return [first, second].contains { $0.contains(location) }
    }

    /// La mascotte suit le pointeur des yeux, et sourit quand il la survole ; le pop-up se ferme quand il s'éloigne.
    private func pointerMoved(to now: NSPoint = NSEvent.mouseLocation) {
        first.pointer.location = now
        second.pointer.location = now
        // Le texte et la mascotte prennent la souris quand elle les survole : on sélectionne le texte, on touche la
        // mascotte. Ailleurs, les clics passent au travers du pop-up, et le ferment. La carte du dessus cache ce qu'elle
        // recouvre de l'autre.
        let overFront = front.contains(now, mascot: false)
        for card in [first, second] {
            let overMascot = card.mascotContains(now)
            if card.pointer.hovering != overMascot { card.pointer.hovering = overMascot }
            let overText = (card === front || !overFront) && (card.text.view?.contains(screenPoint: now) ?? false)
            let takesMouse = overText || overMascot
            if card.panel.ignoresMouseEvents == takesMouse { card.panel.ignoresMouseEvents = !takesMouse }
        }
        // Il se ferme quand le pointeur s'éloigne du mot lu, sauf s'il va vers une carte ou vers la mascotte.
        let nearCards = first.isNear(now) || second.isNear(now)
        if !nearCards, hypot(now.x - shownAt.x, now.y - shownAt.y) > 260 { hide() }
    }

    /// Suit la phase de la dernière explication, pour savoir quand Hoova a fini.
    private func follow(_ model: PopupModel) {
        guard model === current else { return }
        working = model.isWorking
        // Une explication qui échoue, ou une lecture qui ne trouve rien, ne compte pas dans la série.
        if model.inStreak, !model.isExplanation {
            model.inStreak = false
            streak = max(streak - 1, 0)
        }
        // Le mot s'allume dès qu'il est connu : à l'ouverture de la carte, ou à la fin de la lecture si la carte s'est
        // ouverte dès le second ⌃.
        if let anchor = model.anchor, glowed !== model {
            glowed = model
            glow.show(word: anchor)
        }
        withObservationTracking {
            _ = model.phase
            _ = model.anchor
        } onChange: { [weak self, weak model] in
            Task { @MainActor in
                guard let self, let model else { return }
                self.follow(model)
            }
        }
    }
}

/// Une fenêtre de carte : flottante, elle ne prend pas le focus et laisse passer les clics, sauf sur le texte de
/// l'explication, qu'on peut sélectionner.
private final class CardWindow {
    static let size = CGSize(width: 380, height: 260)
    let panel: NSPanel
    let pointer = PopupPointer()
    /// Le texte de l'explication affichée.
    let text = PopupTextHandle()
    private let host: NSHostingView<PopupView>
    /// L'explication affichée.
    private(set) var model: PopupModel?
    /// La carte est sous le mot (sinon au-dessus).
    private var below = true
    /// La mascotte est passée sur l'autre carte.
    private var mascotAway = false

    var isVisible: Bool { panel.isVisible }

    init() {
        host = NSHostingView(rootView: PopupView(model: nil, below: true, pointer: pointer, text: text))
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = host
    }

    /// Une première mise en page, hors écran : la première vraie carte s'affiche aussi vite que les suivantes.
    func warmUp(level: Int) {
        let warmUp = PopupModel()
        warmUp.term = "Hoova"
        warmUp.text = "Hoova"
        warmUp.title = "Hoova"
        warmUp.source = .model
        warmUp.phase = .done
        warmUp.level = level
        host.rootView = PopupView(model: warmUp, below: true, pointer: pointer, text: text)
        host.layoutSubtreeIfNeeded()
        host.rootView = PopupView(model: nil, below: true, pointer: pointer, text: text)
    }

    /// Sous le mot si la place le permet, sinon au-dessus (`anchor` en coordonnées globales, origine en haut à gauche).
    @discardableResult
    func show(_ model: PopupModel, under anchor: CGRect) -> Bool {
        let bottom = cocoa(CGPoint(x: anchor.minX, y: anchor.maxY))
        let top = cocoa(CGPoint(x: anchor.minX, y: anchor.minY))
        let screen = NSScreen.screens.first { $0.frame.contains(bottom) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return false }
        below = bottom.y - Self.size.height - 2 >= visible.minY
        let x = min(max(anchor.minX - 10, visible.minX), visible.maxX - Self.size.width)
        let y = below ? bottom.y - 2 - Self.size.height : top.y + 2
        self.model = model
        mascotAway = false
        host.rootView = PopupView(model: model, below: below, pointer: pointer, text: text)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: Self.size), display: false)
        pointer.window = panel.frame
        pointer.location = NSEvent.mouseLocation
        // Le contenu est à jour avant l'affichage : pas d'image de l'explication précédente.
        host.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        return true
    }

    /// La mascotte quitte la carte pour la suivante : elle se glisse derrière, ou elle s'envole.
    func sendMascotAway(_ departure: MascotDeparture) {
        guard let model else { return }
        mascotAway = true
        pointer.hovering = false
        host.rootView = PopupView(model: model, below: below, pointer: pointer, text: text, departure: departure)
    }

    /// Ce point de l'écran (coordonnées AppKit) est sur la carte ou sur sa mascotte, ou à moins de 40 points.
    func isNear(_ location: NSPoint) -> Bool {
        guard panel.isVisible else { return false }
        return [pointer.card, pointer.mascot].contains { frame in
            frame != .zero
                && CGRect(
                    x: panel.frame.minX + frame.minX, y: panel.frame.maxY - frame.maxY, width: frame.width,
                    height: frame.height
                ).insetBy(dx: -40, dy: -40).contains(location)
        }
    }

    /// La mascotte, quand elle est sur cette carte, est sous ce point de l'écran (coordonnées AppKit).
    func mascotContains(_ location: NSPoint) -> Bool {
        guard panel.isVisible, !mascotAway, pointer.mascot != .zero else { return false }
        let frame = pointer.mascot
        return CGRect(
            x: panel.frame.minX + frame.minX, y: panel.frame.maxY - frame.maxY, width: frame.width, height: frame.height
        ).contains(location)
    }

    /// Le centre de la mascotte à l'écran (coordonnées AppKit), une fois la carte mise en page.
    var mascotCenter: CGPoint? {
        guard panel.isVisible, pointer.mascot != .zero else { return nil }
        return CGPoint(x: panel.frame.minX + pointer.mascot.midX, y: panel.frame.maxY - pointer.mascot.midY)
    }

    func hide() {
        panel.orderOut(nil)
        panel.ignoresMouseEvents = true
        model = nil
        mascotAway = false
        pointer.hovering = false
        // Plus rien à animer tant que la carte est cachée.
        host.rootView = PopupView(model: nil, below: true, pointer: pointer, text: text)
    }

    /// La carte, ou sa mascotte, est sous ce point de l'écran (coordonnées AppKit).
    func contains(_ location: NSPoint, mascot: Bool = true) -> Bool {
        guard panel.isVisible else { return false }
        let frames = mascot ? [pointer.card, pointer.mascot] : [pointer.card]
        return frames.contains { frame in
            CGRect(
                x: panel.frame.minX + frame.minX, y: panel.frame.maxY - frame.maxY, width: frame.width,
                height: frame.height
            ).contains(location)
        }
    }
}

/// Coordonnées globales (origine en haut à gauche) → coordonnées AppKit (origine en bas à gauche).
private func cocoa(_ point: CGPoint) -> NSPoint {
    NSPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
}

struct PopupView: View {
    let model: PopupModel?
    let below: Bool
    let pointer: PopupPointer
    let text: PopupTextHandle
    /// La mascotte est passée sur l'autre carte.
    var departure = MascotDeparture.none

    var body: some View {
        VStack(spacing: 0) {
            if let model {
                if !below { Spacer(minLength: 0) }
                // Une carte neuve à chaque explication, pour rejouer son apparition.
                PopupCard(model: model, below: below, pointer: pointer, text: text, departure: departure)
                    .id(ObjectIdentifier(model))
                if below { Spacer(minLength: 0) }
            }
        }
        // Sous le mot, la place de la mascotte debout sur la carte, et de son petit saut ; éveillée, celle de ses étincelles
        // et de son aura. Au-dessus du mot, elle se tient loin du mot.
        .padding(.top, below ? ((model?.level ?? 1) >= 2 ? 38 : 30) : 0)
        .padding(.bottom, below ? 0 : 12)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// La carte de verre « Pastel doux » : le terme et son explication, ou un message, avec la mascotte assise dessus.
private struct PopupCard: View {
    let model: PopupModel
    let below: Bool
    let pointer: PopupPointer
    let text: PopupTextHandle
    let departure: MascotDeparture
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false
    /// Chaque morceau de texte reçu et l'heure de son arrivée : les nouveaux mots apparaissent en fondu.
    @State private var arrivals: [Arrival] = []

    private struct Arrival {
        let count: Int
        let date: Date
    }

    /// La durée du fondu des mots.
    private static let fade = 0.3

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        content
            .padding(.horizontal, 15)
            .padding(.top, 12)
            .padding(.bottom, 13)
            .frame(width: 340, alignment: .leading)
            .foregroundStyle(ink)
            // Les couleurs sous le verre plutôt que sa teinte, qui reste grise.
            .background { pastel.clipShape(shape) }
            .glassEffect(.regular, in: shape)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { pointer.card = $0 }
            .overlay(alignment: .topTrailing) {
                PerchedMascot(
                    mood: mood, working: model.isWorking, cheer: model.phase == .done && !model.uncertain,
                    answered: model.phase == .done && !model.text.isEmpty, uncertain: model.uncertain,
                    level: model.level, awakening: model.awakening, nested: model.awake, flying: model.flying,
                    departure: departure,
                    pointer: pointer)
                    .frame(width: PerchedMascot.side, height: PerchedMascot.side)
                    // Debout sur le bord de la carte, comme sur une pancarte : le bas de sa vue est sous ses pieds.
                    .offset(x: -16, y: -28)
            }
            // Le texte est lisible dès la première image : seule la taille finit de se poser.
            // Quand la mascotte arrive en volant, la carte est déjà à sa taille : le vol vise la place où elle reste.
            .scaleEffect(settled || reduceMotion || model.flying ? 1 : 0.97, anchor: below ? .topLeading : .bottomLeading)
            .accessibilityElement(children: .combine)
            .onAppear { withAnimation(.spring(duration: 0.3, bounce: 0.3)) { settled = true } }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .reading, .writing, .done: explanation
        case .waitingModel: message("Je me réveille…", "Quelques secondes, j'arrive.")
        case .nothingFound:
            message("Je ne vois pas de texte ici", "Survole ou sélectionne un mot, puis\u{00A0}\(Self.gesture).")
        case .blank:
            message(
                "Je ne peux pas lire cette image",
                "Si c'est une vidéo protégée (Netflix, Udemy…), survole plutôt ses sous-titres ou sa transcription.")
        case .failed(let reason): message("Je n'ai pas réussi", "Réessaie avec \(Self.gesture).", detail: reason)
        }
    }

    /// Le geste choisi, sans retour à la ligne au milieu : le raccourci classique s'il y en a un, sinon le double appui de
    /// la touche réglée (« ⌃ ⌃ », comme l'en-tête du menu).
    private static var gesture: String {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .explain) { return shortcut.description }
        let symbol = Preferences.triggerKey.symbol
        return "\(symbol)\u{00A0}\(symbol)"
    }

    /// L'expression de la mascotte : elle lit, puis réagit à la réponse et à sa source.
    private var mood: Mascot.Mood {
        switch model.phase {
        case .reading, .writing: .reading
        case .waitingModel: .sleepy
        case .nothingFound: .searching
        case .blank: .squinting
        case .failed: .lost
        case .done:
            if model.text.isEmpty { .lost }
            else if model.uncertain { .doubtful }
            else if model.source == .document || model.source == .dictionary { .proud }
            else { .happy }
        }
    }

    /// La carte s'est ouverte dès le second ⌃, et la lecture n'a pas encore trouvé le mot.
    private var reading: Bool { model.phase == .reading && model.term.isEmpty }

    /// Pendant la lecture, la carte a déjà sa forme : des barres tiennent la place de la ligne de contexte, du terme et
    /// de l'explication, et chaque morceau prend la place de sa barre en arrivant.
    private var explanation: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title = model.title, !title.isEmpty {
                HStack(spacing: 0) {
                    Text("Dans «\u{00A0}")
                    Text(title).lineLimit(1)
                    Text("\u{00A0}»")
                }
                .font(.system(size: 11))
                .foregroundStyle(secondary)
            } else if reading {
                bar(width: 150, height: 8).padding(.vertical, 2.5)
            }
            HStack(spacing: 8) {
                if reading {
                    bar(width: 120, height: 13).padding(.vertical, 3.5)
                } else {
                    Text(model.term)
                        .font(.system(size: 15.5, weight: .bold, design: .rounded))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if model.phase == .done, let source = model.source { pill(for: source) }
            }
            if !model.text.isEmpty {
                fadingText
            } else if model.phase == .done {
                Text("Je n'ai pas de réponse pour ce mot.").font(.system(size: 13.5)).foregroundStyle(secondary)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    bar(width: 290)
                    bar(width: 230)
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Une barre qui tient la place d'un texte pas encore arrivé.
    private func bar(width: CGFloat, height: CGFloat = 9) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(ink.opacity(dark ? 0.16 : 0.11))
            .frame(width: width, height: height)
    }

    /// L'explication : les mots qui arrivent apparaissent en fondu, sans retarder leur affichage. Elle se sélectionne à
    /// la souris, pour en expliquer un mot d'un double ⌃.
    private var fadingText: some View {
        TimelineView(.explicit(fadeFrames)) { timeline in
            SelectableText(
                text: attributed(at: timeline.date), highlight: Brand.iris.opacity(dark ? 0.5 : 0.45), handle: text)
        }
        .onChange(of: model.text, initial: true) { _, text in
            arrivals.append(Arrival(count: Self.formatted(text).characters.count, date: .now))
        }
    }

    /// Les images du fondu du dernier morceau reçu, à 30 par seconde.
    private var fadeFrames: [Date] {
        guard !reduceMotion, let last = arrivals.last?.date else { return [] }
        return stride(from: 0, through: Self.fade, by: 1.0 / 30).map { last.addingTimeInterval($0) }
    }

    /// L'explication pour la vue de texte : sa police et son interligne, l'italique et le gras du modèle, et les mots
    /// qui arrivent en fondu.
    private func attributed(at date: Date) -> NSAttributedString {
        let formatted = Self.formatted(model.text)
        let plain = String(formatted.characters)
        let font = NSFont.systemFont(ofSize: 13.5)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let color = NSColor(ink)
        let result = NSMutableAttributedString()
        for run in formatted.runs {
            var traits: NSFontDescriptor.SymbolicTraits = []
            if run.inlinePresentationIntent?.contains(.emphasized) == true { traits.insert(.italic) }
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { traits.insert(.bold) }
            let styled = traits.isEmpty ? font : NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: 13.5)
            result.append(
                NSAttributedString(
                    string: String(formatted[run.range].characters),
                    attributes: [.font: styled ?? font, .foregroundColor: color, .paragraphStyle: paragraph]))
        }
        guard !reduceMotion else { return result }
        var start = 0
        for arrival in arrivals {
            let end = min(arrival.count, plain.count)
            let progress = date.timeIntervalSince(arrival.date) / Self.fade
            if end > start, progress < 1 {
                let lower = plain.index(plain.startIndex, offsetBy: start)
                let upper = plain.index(plain.startIndex, offsetBy: end)
                result.addAttribute(
                    .foregroundColor, value: color.withAlphaComponent(max(progress, 0.1)),
                    range: NSRange(lower..<upper, in: plain))
            }
            start = max(start, end)
        }
        return result
    }

    /// Un message : son titre et son texte sont traduits ; `detail`, la raison d'un échec, l'est déjà par le moteur.
    private func message(_ title: LocalizedStringKey, _ text: LocalizedStringKey, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 14.5, weight: .bold, design: .rounded))
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(tertiary).lineLimit(2).padding(.top, 2)
            }
        }
    }

    private func pill(for source: Source) -> some View {
        let (label, fill, sparkle): (LocalizedStringKey, Color?, Bool) =
            if model.uncertain { ("IA, à vérifier", peachFill, true) } else {
                switch source {
                case .document: ("Document", mintFill, false)
                case .dictionary: ("Dictionnaire", irisFill, false)
                case .model: ("IA", nil, true)
                }
            }
        return HStack(spacing: 4) {
            if sparkle {
                Sparkle().stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round)).frame(width: 8, height: 8)
            }
            Text(label)
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(fill ?? .clear, in: Capsule())
        // Un trait fin garde le badge net sur le pastel.
        .overlay { Capsule().strokeBorder(ink.opacity(fill == nil ? 0.22 : dark ? 0 : 0.1)) }
    }

    /// Le modèle met parfois un mot en *italique* ou en **gras** : on l'affiche ainsi plutôt qu'avec les astérisques.
    private static func formatted(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// Le style « Pastel doux » (`docs/styles-de-carte.md`) : menthe en haut à gauche, lavande en haut à droite,
    /// pêche en bas, sur crème en mode clair et sur nuit en mode sombre.
    private var pastel: some View {
        ZStack {
            dark ? Brand.night.opacity(0.9) : Brand.cream.opacity(0.92)
            RadialGradient(
                colors: [Brand.mint.opacity(dark ? 0.28 : 0.95), .clear], center: .topLeading, startRadius: 0,
                endRadius: 230)
            RadialGradient(
                colors: [Brand.iris.opacity(dark ? 0.38 : 0.8), .clear], center: UnitPoint(x: 1, y: 0.1),
                startRadius: 0, endRadius: 210)
            RadialGradient(
                colors: [Brand.peach.opacity(dark ? 0.24 : 0.6), .clear], center: UnitPoint(x: 0.6, y: 1.2),
                startRadius: 0, endRadius: 230)
        }
    }

    // MARK: - Couleurs : nuit sur crème en mode clair, crème sur nuit en mode sombre.

    private var dark: Bool { colorScheme == .dark }
    private var ink: Color { dark ? Brand.cream : Brand.night }
    private var secondary: Color { ink.opacity(dark ? 0.7 : 0.72) }
    private var tertiary: Color { ink.opacity(0.5) }
    // Des badges pleins en mode clair, pour ressortir sur le pastel.
    private var mintFill: Color { dark ? Brand.mint.opacity(0.3) : Brand.mint }
    private var irisFill: Color { dark ? Brand.iris.opacity(0.32) : Brand.iris }
    private var peachFill: Color { dark ? Brand.peach.opacity(0.36) : Brand.peach }
}

/// Comment la mascotte quitte une carte pour l'autre, pendant Hoova sur Hoova.
enum MascotDeparture {
    case none
    /// Elle se glisse derrière la carte.
    case behind
    /// Elle s'envole : c'est la fenêtre du vol qui la montre.
    case flight
}

/// La mascotte, sur le bord de la carte. Elle évolue avec les explications faites de suite :
/// - Hoova, et Hoova éveil (menthe à la lune d'or), arrivent de l'une de trois façons, tirée au sort : elle regarde
///   depuis derrière la carte et y reste, elle est debout et fait deux petits pas pour lire la réponse, ou elle est
///   simplement debout à sa place. Sur la carte de Hoova sur Hoova, elle sort de derrière la carte, une petite pause
///   après s'être glissée derrière l'autre ;
/// - Hoova éveil final sort de derrière la carte et s'envole, puis flotte sur la pointe des pieds, son aura en flamme
///   autour de lui. La première fois, il se transforme en chemin ; d'une carte à l'autre, il vole.
/// Elle lit et suit le texte des yeux pendant le travail, puis te regarde : ses yeux suivent le pointeur. Sa lune a la
/// phase de la vraie lune et respire pendant le travail ; au réveil de l'IA, elle se remplit comme une barre de
/// progression. Elle cligne des yeux et sautille quand la réponse est sûre. Elle se touche : survolée, elle sourit ;
/// un clic, et elle ferme les yeux, comme si elle avait mal ; si on essaie de la déplacer, elle dit non de la tête
/// tant qu'on ne l'a pas lâchée.
private struct PerchedMascot: View {
    /// Sa taille sur la carte. En éveil final, sa vue s'agrandit autour du même centre, pour l'aura et la lévitation.
    static let side: CGFloat = 28
    static let auraSide = side * Mascot.auraFrame.width / Mascot.frame.width
    let mood: Mascot.Mood
    let working: Bool
    let cheer: Bool
    /// La réponse est là, avec un texte à lire.
    let answered: Bool
    let uncertain: Bool
    /// 1 : Hoova ; 2 : Hoova éveil ; 3 : Hoova éveil final.
    let level: Int
    /// Elle atteint l'éveil final sur cette carte : elle se transforme.
    let awakening: Bool
    /// La carte de Hoova sur Hoova : elle vient de l'autre carte.
    let nested: Bool
    /// Elle arrive en volant depuis l'autre carte.
    let flying: Bool
    /// Elle est passée sur l'autre carte.
    let departure: MascotDeparture
    let pointer: PopupPointer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Sa place dans la fenêtre du pop-up, pour savoir où regarder.
    @State private var seat = CGRect.zero
    @State private var arrived = false
    /// Arrivée en volant : elle se montre ici une fois le vol fini.
    @State private var landed = false
    /// Tirée au sort à chaque carte, pour Hoova.
    @State private var arrival = [Way.peeking, .stepping, .standing].randomElement() ?? .standing
    /// Les deux petits pas : le chemin fait vers la gauche, et ses pieds.
    @State private var shift: CGFloat = 0
    @State private var stepped = false
    /// Pendant qu'elle lit la réponse : son regard vers le texte, puis son sourire.
    @State private var glance: CGPoint?
    @State private var smiling = false
    /// La souris sur elle : un clic, puis si on essaie de la déplacer.
    @State private var touch = Touch.none
    /// Les étincelles de Hoova éveil, une gerbe à chaque clic.
    @State private var bursts = 0
    private let moonAge = Mascot.moonAge()

    private enum Touch {
        case none, pressed, refusing
    }

    /// Regarder depuis derrière la carte, faire deux petits pas pour lire la réponse, être simplement debout, ou flotter
    /// au-dessus du bord.
    private enum Way {
        case peeking, stepping, standing, floating
    }

    /// Hoova éveil final flotte ; Hoova et Hoova éveil sont là de l'une des trois façons.
    private var way: Way { level >= 3 ? .floating : arrival }

    /// Le temps qu'elle attend avant de sortir de derrière la carte : sur la carte de Hoova sur Hoova, celui de se
    /// glisser derrière l'autre carte (0,3 s), puis une petite pause.
    private var wait: Double { nested && !flying ? 0.55 : 0.01 }

    /// Son visage selon la souris : elle sourit quand on la survole ; Hoova a mal quand on clique dessus. Éveillée, elle
    /// n'a pas mal : Hoova éveil en est ravi (il jette des étincelles), l'éveil final laisse jaillir son aura.
    private var expression: Mascot.Mood {
        switch touch {
        case .pressed: level == 1 ? .hurt : level == 2 ? .proud : mood
        case .refusing: level == 1 ? .hurt : mood
        case .none: pointer.hovering || smiling ? .proud : mood
        }
    }

    private struct Gaze {
        var look = CGPoint.zero
        var openness: CGFloat = 1
        var moon = 1.0
    }

    private struct Hop {
        var lift: CGFloat = 0
        var squash: CGFloat = 1
    }

    /// La transformation et l'envol de l'éveil final ; la valeur de départ est celle du repos.
    private struct Rise {
        var final = 1.0
        var lift: CGFloat = 30
    }

    var body: some View {
        // Tant qu'on essaie de la déplacer, elle dit non de la tête.
        TimelineView(.animation(paused: touch != .refusing || reduceMotion)) { timeline in
            Group {
                if reduceMotion { still } else { animated }
            }
            .rotationEffect(
                .degrees(touch == .refusing && !reduceMotion ? 8 * sin(timeline.date.timeIntervalSinceReferenceDate * 6 * .pi) : 0),
                anchor: .bottom)
        }
        // Un clic : elle se tasse, comme si elle avait mal.
        .scaleEffect(x: touch == .none || reduceMotion ? 1 : 1.05, y: touch == .none || reduceMotion ? 1 : 0.92, anchor: .bottom)
        .animation(.spring(duration: 0.25, bounce: 0.4), value: touch == .none)
        // Derrière la carte, on ne voit que le haut de sa tête et ses yeux ; partie sur l'autre carte, plus rien.
        .offset(y: (way == .peeking ? 6 : 0) + (departure == .behind ? 29 : 0))
        .animation(reduceMotion ? nil : .easeIn(duration: 0.3), value: departure)
        .opacity(departure == .flight || (flying && !landed) ? 0 : 1)
        // Ce qui passe sous le bord de la carte est caché. Le masque s'aligne sur sa place de 28 points, et non sur la vue
        // de l'éveil final, plus grande pour l'aura : sinon le haut de sa tête dépasserait du bord avant qu'il sorte.
        .frame(width: Self.side, height: Self.side)
        .mask(alignment: .bottomTrailing) { Rectangle().frame(width: 700, height: 400).offset(x: 10) }
        .overlay { if level == 2 && !reduceMotion { SparkleBurst(trigger: bursts) } }
        // L'aura de l'éveil final jaillit derrière lui.
        .background { if level >= 3 && !reduceMotion { AuraBurst(trigger: bursts) } }
        .overlay {
            MascotTouchArea(
                onPress: {
                    touch = .pressed
                    if level >= 2 { bursts += 1 }
                }, onDrag: { touch = .refusing }, onRelease: { touch = .none }, onMove: pointer.moved)
        }
    }

    /// Sans animation : elle est là, dans son état.
    @ViewBuilder private var still: some View {
        if way == .floating {
            MascotView(mood: expression, awake: true, final: 1, lift: 30, frame: Mascot.auraFrame)
                .frame(width: Self.auraSide, height: Self.auraSide)
        } else {
            MascotView(mood: expression, moonAge: moonAge, awake: level >= 2)
        }
    }

    /// D'où elle part, derrière la carte : un peu (la tête sort), ou tout entière (debout sur la carte de Hoova sur
    /// Hoova, ou l'éveil final, qui s'envole). En volant, elle arrive par les airs.
    private var hidden: CGFloat {
        switch way {
        case .peeking: 23
        case .floating: flying ? 0 : 29
        case .stepping, .standing: nested ? 29 : 0
        }
    }

    private var animated: some View {
        alive
            // Elle sort de derrière la carte jusqu'à sa place. Si SwiftUI repart de la valeur initiale, elle reste à sa
            // place.
            .keyframeAnimator(initialValue: CGFloat(0), trigger: arrived) { content, rise in
                content.offset(y: rise)
            } keyframes: { _ in
                KeyframeTrack {
                    MoveKeyframe(hidden)
                    // Sur la carte de Hoova sur Hoova, elle attend d'avoir quitté l'autre carte.
                    LinearKeyframe(hidden, duration: wait)
                    CubicKeyframe(0, duration: 0.4)
                }
            }
            // Avant que son arrivée commence, elle est déjà à son point de départ : pas une image d'elle à sa place.
            .offset(y: arrived ? 0 : hidden)
            .offset(x: shift)
            // Deux pas : le pied gauche, puis le droit.
            .keyframeAnimator(initialValue: CGFloat(0), trigger: stepped) { content, step in
                content.environment(\.mascotStep, step)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(-1, duration: 0.12)
                    CubicKeyframe(1, duration: 0.22)
                    CubicKeyframe(0, duration: 0.12)
                }
            }
            // Pas de petit saut quand elle va lire la réponse (son sourire suffit), ni quand elle flotte.
            .keyframeAnimator(initialValue: Hop(), trigger: cheer && way != .stepping && way != .floating) {
                content, hop in
                content.offset(y: hop.lift).scaleEffect(x: 2 - hop.squash, y: hop.squash, anchor: .bottom)
            } keyframes: { _ in
                KeyframeTrack(\.lift) {
                    CubicKeyframe(0, duration: 0.08)
                    CubicKeyframe(-3, duration: 0.16)
                    SpringKeyframe(0, duration: 0.35, spring: .smooth)
                }
                KeyframeTrack(\.squash) {
                    CubicKeyframe(0.94, duration: 0.08)
                    CubicKeyframe(1.03, duration: 0.16)
                    SpringKeyframe(1, duration: 0.35, spring: .smooth)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                seat = $0
                pointer.mascot = $0
            }
            .onAppear { arrived = true }
            .task(id: answered) { await readAnswer() }
            .task {
                guard flying, await pause(FlightController.duration) else { return }
                landed = true
            }
    }

    /// Les deux petits pas : quand la réponse est là, elle fait deux petits pas vers la gauche, regarde ce qui est
    /// écrit, sourit, puis te regarde de nouveau.
    private func readAnswer() async {
        guard answered, way == .stepping, await pause(0.3) else { return }
        withAnimation(.linear(duration: 0.46)) { shift = -8 }
        stepped = true
        guard await pause(0.6) else { return }
        glance = CGPoint(x: -6, y: 14)
        guard await pause(1.2) else { return }
        glance = nil
        // Si l'IA doute, elle garde son air de doute.
        smiling = !uncertain
        guard await pause(0.9) else { return }
        smiling = false
    }

    /// Faux si la carte a disparu entre-temps.
    private func pause(_ seconds: Double) async -> Bool {
        (try? await Task.sleep(for: .seconds(seconds))) != nil
    }

    @ViewBuilder private var alive: some View {
        if way == .floating {
            floating
        } else if mood == .sleepy {
            // Au réveil de l'IA, sa lune se remplit du croissant à la pleine lune, comme une barre de progression :
            // le réveil dure environ 1,4 s, puis elle attend, presque pleine.
            KeyframeAnimator(initialValue: 0.0, trigger: arrived) { fill in
                MascotView(mood: expression, moonAge: 0.04 + 0.46 * fill, awake: level >= 2)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(0.9, duration: 1.4)
                    LinearKeyframe(0.98, duration: 4)
                }
            }
        } else {
            gaze
        }
    }

    /// L'éveil final : la première fois, il se transforme une fois sorti de derrière la carte (ses yeux s'allument, sa
    /// bouche s'efface, l'anneau se forme, la flamme s'allume) ; puis il s'envole juste au-dessus du bord et flotte, son
    /// aura qui ondule et ses yeux qui pulsent. Ses yeux vont vers le texte pendant le travail, puis suivent le pointeur.
    private var floating: some View {
        let target = working ? CGPoint(x: -2, y: 12) : lookAtPointer
        return KeyframeAnimator(initialValue: Rise(), trigger: arrived) { rise in
            // 20 images par seconde suffisent à une aura qui bouge lentement : une carte en éveil final coûte alors au
            // processeur autant qu'une carte en éveil.
            TimelineView(.periodic(from: .now, by: 1.0 / 20)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                // Il monte et descend d'un rien en flottant, d'autant moins qu'il est près du bord.
                let bob = 6 * CGFloat(sin(2 * .pi * time / 2.5)) * rise.lift / 30
                MascotView(
                    mood: expression, look: target, awake: true, final: rise.final, lift: rise.lift + bob, time: time,
                    frame: Mascot.auraFrame
                )
                .frame(width: Self.auraSide, height: Self.auraSide)
            }
        } keyframes: { _ in
            // Une fois sorti de derrière la carte, il se transforme (la première fois), puis s'envole.
            KeyframeTrack(\.final) {
                MoveKeyframe(awakening ? 0 : 1)
                LinearKeyframe(awakening ? 0 : 1, duration: awakening ? wait + 0.85 : 0.01)
                CubicKeyframe(1, duration: 0.5)
            }
            KeyframeTrack(\.lift) {
                MoveKeyframe(flying ? 30 : 0)
                LinearKeyframe(flying ? 30 : 0, duration: flying ? 0.01 : wait + (awakening ? 1.15 : 0.65))
                CubicKeyframe(30, duration: 0.6)
            }
        }
    }

    /// Un cycle de 3,2 s : les yeux vont et viennent sur le texte (ou suivent le pointeur), clignent une fois, et la
    /// lune respire si Hoova travaille.
    private var gaze: some View {
        // Son sourire, quand elle a lu la réponse ou qu'on la survole, et son air quand on la touche.
        let face = expression
        let (center, swing): (CGPoint, CGFloat) =
            switch face {
            case .reading: (CGPoint(x: -2, y: 14), 8)
            case .searching: (CGPoint(x: 0, y: -4), 16)
            default: (.zero, 0)
            }
        let follows = swing == 0
        // Vers ce qui est écrit pendant qu'elle lit la réponse, sinon vers le pointeur.
        let target = glance ?? lookAtPointer
        let left = CGPoint(x: center.x - swing, y: center.y)
        let right = CGPoint(x: center.x + swing, y: center.y)
        let glow = working ? 0.4 : 1
        return KeyframeAnimator(initialValue: Gaze(look: left), repeating: true) { gaze in
            MascotView(
                mood: face, look: follows ? target : gaze.look, openness: gaze.openness, moon: gaze.moon,
                moonAge: moonAge, awake: level >= 2)
        } keyframes: { _ in
            KeyframeTrack(\.look) {
                CubicKeyframe(right, duration: 0.8)
                CubicKeyframe(left, duration: 0.8)
                CubicKeyframe(right, duration: 0.8)
                CubicKeyframe(left, duration: 0.8)
            }
            KeyframeTrack(\.openness) {
                LinearKeyframe(1, duration: 2.9)
                LinearKeyframe(0.1, duration: 0.07)
                LinearKeyframe(1, duration: 0.11)
                LinearKeyframe(1, duration: 0.12)
            }
            KeyframeTrack(\.moon) {
                CubicKeyframe(glow, duration: 0.8)
                CubicKeyframe(1, duration: 0.8)
                CubicKeyframe(glow, duration: 0.8)
                CubicKeyframe(1, duration: 0.8)
            }
        }
        // Un nouveau cycle quand l'expression change.
        .id("\(face)\(working)")
    }

    /// Ses yeux vers le pointeur, sans sortir du visage : ils vont d'autant plus loin qu'il est loin d'elle.
    private var lookAtPointer: CGPoint {
        guard seat != .zero else { return .zero }
        let center = CGPoint(x: pointer.window.minX + seat.midX, y: pointer.window.maxY - seat.midY)
        let dx = pointer.location.x - center.x
        // Vers le bas, comme dans hoova.svg.
        let dy = center.y - pointer.location.y
        let distance = max(hypot(dx, dy), 1)
        let reach = min(distance / 120, 1)
        return CGPoint(x: dx / distance * 12 * reach, y: dy / distance * 9 * reach)
    }
}

/// La mascotte se touche : la vue AppKit qui reçoit la souris sur elle, même dans un pop-up qui ne prend jamais le
/// clavier. Un clic, puis si on essaie de la déplacer, et quand on la lâche.
private struct MascotTouchArea: NSViewRepresentable {
    let onPress: () -> Void
    let onDrag: () -> Void
    let onRelease: () -> Void
    let onMove: () -> Void

    func makeNSView(context: Context) -> MascotTouchView { MascotTouchView() }

    func updateNSView(_ view: MascotTouchView, context: Context) {
        view.onPress = onPress
        view.onDrag = onDrag
        view.onRelease = onRelease
        view.onMove = onMove
    }
}

private final class MascotTouchView: NSView {
    var onPress = {}
    var onDrag = {}
    var onRelease = {}
    var onMove = {}
    private var start = NSPoint.zero
    private var dragging = false

    /// Le premier clic la touche déjà, sans activer Hoova.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onMove() }
    override func mouseMoved(with event: NSEvent) { onMove() }
    override func mouseExited(with event: NSEvent) { onMove() }

    override func mouseDown(with event: NSEvent) {
        start = event.locationInWindow
        dragging = false
        onPress()
    }

    /// Elle ne bouge pas : dès qu'on essaie de l'emmener, elle dit non.
    override func mouseDragged(with event: NSEvent) {
        let now = event.locationInWindow
        guard !dragging, hypot(now.x - start.x, now.y - start.y) > 3 else { return }
        dragging = true
        onDrag()
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        onRelease()
    }
}


/// Les étincelles de Hoova éveil, au clic : des étoiles ✳ et des étincelles d'or, de menthe et de lavande jaillissent
/// vers le haut, puis s'effacent (0,7 s). Au repos, rien.
private struct SparkleBurst: View {
    let trigger: Int

    /// Les étincelles : la direction (en degrés, vers le haut), la distance (en points), la taille, la couleur, et si
    /// c'est l'étoile ✳ de la marque.
    private static let sparks: [(angle: Double, distance: CGFloat, size: CGFloat, color: Color, star: Bool)] = [
        (-165, 22, 8, Mascot.goldColor, true), (-138, 22, 6, Brand.mint, false), (-112, 19, 8, Brand.iris, true),
        (-88, 18, 6, Mascot.goldColor, false), (-64, 19, 8, Brand.mint, true), (-40, 22, 6, Brand.iris, false),
        (-15, 22, 7, Mascot.goldColor, true),
    ]

    var body: some View {
        KeyframeAnimator(initialValue: 1.0, trigger: trigger) { progress in
            Canvas { context, size in
                guard progress < 1 else { return }
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                for spark in Self.sparks {
                    let angle = spark.angle * .pi / 180
                    // Elles filent vite, puis ralentissent ; elles grossissent, puis rapetissent en s'effaçant.
                    let reach = spark.distance * CGFloat(1 - pow(1 - progress, 3))
                    let point = CGPoint(x: center.x + cos(angle) * reach, y: center.y + sin(angle) * reach)
                    let grow: Double = progress < 0.3 ? 0.5 + progress * 2 : 1.1 - (progress - 0.3)
                    let scale = spark.size * CGFloat(grow)
                    var spot = context
                    spot.opacity = progress < 0.6 ? 1 : (1 - progress) / 0.4
                    let rect = CGRect(x: point.x - scale / 2, y: point.y - scale / 2, width: scale, height: scale)
                    if spark.star {
                        spot.stroke(Sparkle().path(in: rect), with: .color(spark.color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    } else {
                        spot.fill(Self.twinkle(in: rect), with: .color(spark.color))
                    }
                }
            }
        } keyframes: { _ in
            KeyframeTrack {
                MoveKeyframe(0)
                LinearKeyframe(1, duration: 0.7)
            }
        }
        .frame(width: 90, height: 90)
        .allowsHitTesting(false)
    }

    /// Une étincelle à quatre branches.
    private static func twinkle(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = rect.width / 2
        let waist = r * 0.3
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: c.y - r))
        path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + waist, y: c.y - waist))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + waist, y: c.y + waist))
        path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - waist, y: c.y + waist))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - waist, y: c.y - waist))
        return path
    }
}

/// L'aura de l'éveil final qui jaillit de lui, au clic : un éclat, puis sa silhouette, en menthe et en or, s'élargit
/// vers l'extérieur en deux ondes, surtout vers les côtés (au-dessus, la fenêtre du pop-up s'arrête vite), et s'efface
/// (0,9 s). Au repos, rien.
private struct AuraBurst: View {
    let trigger: Int
    /// Plus grand que sa vue d'éveil final : la place de l'onde.
    private static let frame = Mascot.auraFrame.insetBy(dx: -170, dy: -170)

    var body: some View {
        KeyframeAnimator(initialValue: 1.0, trigger: trigger) { progress in
            Canvas { context, size in
                guard progress < 1 else { return }
                let frame = Self.frame
                context.scaleBy(x: size.width / frame.width, y: size.height / frame.height)
                context.translateBy(x: -frame.minX, y: -frame.minY)
                // Sa silhouette, à la hauteur où il flotte, élargie autour de son centre.
                let body = Mascot.body.offsetBy(dx: 0, dy: -30)
                let center = CGPoint(x: 515, y: 478)
                func grown(_ amount: Double) -> Path {
                    body.applying(
                        CGAffineTransform(translationX: center.x, y: center.y)
                            .scaledBy(x: 1 + 1.6 * amount, y: 1 + 0.5 * amount)
                            .translatedBy(x: -center.x, y: -center.y))
                }
                // D'abord un éclat, au ras de son corps.
                if progress < 0.3 {
                    var flash = context
                    flash.addFilter(.blur(radius: 14))
                    flash.opacity = 1 - progress / 0.3
                    flash.fill(grown(0.1 + progress), with: .color(Mascot.sunColor))
                }
                for (delay, strength) in [(0.0, 1.0), (0.25, 0.75)] {
                    let wave = min(max((progress - delay) / (1 - delay), 0), 1)
                    guard wave > 0, wave < 1 else { continue }
                    let fade = (1 - wave) * strength
                    var mint = context
                    mint.addFilter(.blur(radius: 18))
                    mint.opacity = fade
                    mint.fill(grown(wave), with: .color(Mascot.mint.body))
                    var gold = context
                    gold.addFilter(.blur(radius: 10))
                    gold.opacity = fade
                    gold.fill(grown(0.7 * wave), with: .color(Mascot.goldColor.opacity(0.75)))
                    var ring = context
                    ring.addFilter(.blur(radius: 2))
                    ring.opacity = fade
                    ring.stroke(grown(0.85 * wave), with: .color(Mascot.goldColor), lineWidth: 20)
                }
            }
        } keyframes: { _ in
            KeyframeTrack {
                MoveKeyframe(0)
                LinearKeyframe(1, duration: 0.9)
            }
        }
        .frame(
            width: PerchedMascot.side * Self.frame.width / Mascot.frame.width,
            height: PerchedMascot.side * Self.frame.height / Mascot.frame.height)
        .allowsHitTesting(false)
    }
}
