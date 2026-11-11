import AppKit
import HoovaCore
import SwiftUI

/// L'accueil du premier lancement : une nuit qui reprend ses couleurs, de la nouvelle lune à la pleine lune
/// (`docs/direction-artistique.md`, partie 13). Il ne lit l'état et n'agit que par `SetupState` et `SetupActions`
/// (`Setup.swift`).
final class SetupWindow {
    private var window: NSWindow?
    private var state: SetupState?
    /// Ce que l'accueil retient pour lui : le réveil de Hoova, la mascotte passée dans le pop-up pendant l'essai.
    private let scene = SetupScene()
    /// Le vol de Hoova vers la barre des menus, à la fin.
    private let flight = SetupFlight()
    private var monitors: [Any] = []

    var isVisible: Bool { window?.isVisible ?? false }

    func show(state: SetupState, actions: SetupActions) {
        if window == nil {
            // Ouvert plus loin que la bienvenue : l'accueil reprend après une relance, et Hoova est déjà réveillé.
            scene.awake = state.step != .welcome
            scene.resumed = state.step != .welcome
            scene.celebrated = state.trialDone
            scene.state = state
            scene.bringToFront = { [weak self] in self?.bringToFront() }
            scene.leave = { [weak self] frame in self?.leave(from: frame) }
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: SetupView.size),
                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = String(localized: "Bienvenue dans Hoova")
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SetupView(state: state, actions: actions, scene: scene))
            window.center()
            self.window = window
            self.state = state
        }
        watchKeys()
        bringToFront()
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        window?.close()
    }

    /// Le point (coordonnées globales, origine en haut à gauche) est sur l'accueil. Un double ⌃ là, hors de ce que
    /// donne `capture(at:)`, ne fait rien : on y relirait l'accueil lui-même.
    func contains(_ point: CGPoint) -> Bool {
        guard let window, window.isVisible else { return false }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return window.frame.contains(NSPoint(x: point.x, y: top - point.y))
    }

    /// Pendant l'essai, la sélection ou le mot sous ce point dans l'une des deux phrases d'exemple (coordonnées globales,
    /// origine en haut à gauche, comme `PopupController.capture(at:)`) ; nil ailleurs, et tant que le modèle n'est pas
    /// prêt. Le contexte est la phrase elle-même, sans titre.
    func capture(at point: CGPoint) -> Capture? {
        guard let state, state.step == .trial, state.modelReady, isVisible else { return nil }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let location = NSPoint(x: point.x, y: top - point.y)
        for (sentence, handle) in zip(SetupScene.sentences, scene.handles) {
            guard let view = handle.view, view.contains(screenPoint: location), let picked = view.pick(at: location)
            else { continue }
            // Le pop-up va s'ouvrir sous le mot : la mascotte de l'accueil y passe.
            scene.watchPopup()
            return Capture(
                term: picked.text, context: sentence,
                anchor: CGRect(
                    x: picked.frame.minX, y: top - picked.frame.maxY, width: picked.frame.width,
                    height: picked.frame.height),
                method: .setup)
        }
        return nil
    }

    private func bringToFront() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Sur la première page, le geste réveille Hoova : l'accueil voit ses propres touches, même sans l'Accessibilité.
    private func watchKeys() {
        guard monitors.isEmpty else { return }
        monitors = [
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                if let self, let state, state.step == .welcome, event.window === window {
                    scene.modifiersChanged(
                        event.modifierFlags.intersection([.control, .option, .shift, .command]),
                        key: state.triggerKey.flags)
                }
                return event
            },
            NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
                self?.scene.interrupt()
                return event
            },
        ].compactMap { $0 }
    }

    /// « Terminer » : Hoova s'envole de l'accueil jusqu'à son icône, dans la barre des menus. `frame` : sa place dans la
    /// fenêtre (origine en haut à gauche).
    private func leave(from frame: CGRect) {
        guard let window, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let start = CGRect(
            x: window.frame.minX + frame.minX, y: window.frame.maxY - frame.maxY, width: frame.width,
            height: frame.height)
        let screen = window.screen?.frame ?? NSScreen.main?.frame ?? .zero
        let icon = NSApp.windows.first { $0.className == "NSStatusBarWindow" && $0.isVisible }?.frame
        let end = icon.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: screen.maxX - 60, y: screen.maxY - 12)
        flight.fly(from: start, to: end)
    }
}

/// Ce que l'accueil retient pour lui, en plus de `SetupState`.
@Observable
final class SetupScene {
    /// Les deux phrases de l'essai : le même mot, deux sens. Chaque langue a les siennes, et son mot doit s'y retrouver tel
    /// quel, dans les deux.
    static let sentences = [
        String(
            localized: "Pour son divorce, Léa a pris un bon avocat.",
            comment: "Essai de l'accueil : la première phrase, avec le mot à deux sens."),
        String(
            localized: "À l'apéro, elle a coupé un avocat bien mûr.",
            comment: "Essai de l'accueil : la seconde phrase, avec le même mot dans son autre sens."),
    ]
    static let word = String(
        localized: "avocat", comment: "Essai de l'accueil : le mot à deux sens, écrit comme dans les deux phrases.")

    /// Hoova est réveillé : par le geste sur la première page, par « Passer », ou d'emblée si l'accueil reprend plus loin.
    var awake = false
    /// L'accueil reprend après une relance : Hoova dit « Me revoilà ! » sur la page des autorisations.
    var resumed = false
    /// Les ⌃ allumés sur la première page, un par appui (0, 1 ou 2).
    var taps = 0
    /// Change à chaque étoile filante : au réveil par le geste.
    var shootingStars = 0
    /// Change à chaque petit saut de la mascotte : à chaque bonne nouvelle.
    var hops = 0
    /// La mascotte est passée dans le pop-up pendant l'essai : il n'y a jamais qu'un Hoova à l'écran.
    var away = false
    /// L'essai a réussi et le pop-up s'est refermé : c'est la pleine lune, l'or revient.
    var celebrated = false
    /// Elle s'est envolée vers la barre des menus.
    var leaving = false
    /// Le pointeur dans la fenêtre (origine en haut à gauche), pour ses yeux ; nil hors de la fenêtre.
    var pointer: CGPoint?

    /// Le texte des deux phrases, pour y trouver le mot sous le pointeur.
    @ObservationIgnored let handles = [PopupTextHandle(), PopupTextHandle()]
    /// Sa place dans la fenêtre (origine en haut à gauche), d'où elle s'envole.
    @ObservationIgnored var mascotFrame = CGRect.zero
    @ObservationIgnored weak var state: SetupState?
    @ObservationIgnored var bringToFront: () -> Void = {}
    @ObservationIgnored var leave: (CGRect) -> Void = { _ in }
    @ObservationIgnored private var held: NSEvent.ModifierFlags = []
    @ObservationIgnored private var pressed: ContinuousClock.Instant?
    @ObservationIgnored private var lastTap: ContinuousClock.Instant?
    @ObservationIgnored private var fading: Task<Void, Never>?
    @ObservationIgnored private var watching: Task<Void, Never>?

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Ses yeux vers le pointeur, sans sortir du visage, comme dans le pop-up : d'autant plus loin qu'il est loin de lui.
    /// `center` : son centre dans la fenêtre.
    func look(from center: CGPoint) -> CGPoint {
        guard let pointer, center != .zero else { return .zero }
        let dx = pointer.x - center.x
        let dy = pointer.y - center.y
        let distance = max(hypot(dx, dy), 1)
        let reach = min(distance / 120, 1)
        return CGPoint(x: dx / distance * 12 * reach, y: dy / distance * 9 * reach)
    }

    /// Une bonne nouvelle : un petit saut, sauf avec « Réduire les animations ».
    func hop() {
        if !reduceMotion { hops += 1 }
    }

    /// Réveille Hoova : par le geste, avec une étoile filante, ou par « Passer ».
    func wake(byGesture: Bool) {
        guard !awake else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { awake = true }
        taps = 2
        if byGesture, !reduceMotion { shootingStars += 1 }
        // Le saut, une fois debout sur le point.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            self?.hop()
        }
    }

    /// Le double appui de la première page : deux appuis courts sur la touche seule, à 450 ms d'écart au plus, comme
    /// `DoubleTap`. Chaque appui allume un ⌃.
    func modifiersChanged(_ flags: NSEvent.ModifierFlags, key: NSEvent.ModifierFlags) {
        defer { held = flags }
        guard !awake else { return }
        let now = ContinuousClock.now
        if flags == key, held.isEmpty {
            if let lastTap, now - lastTap <= .milliseconds(450) {
                wake(byGesture: true)
            } else {
                taps = 1
                pressed = now
            }
        } else if flags.isEmpty, held == key, let pressed {
            // Un appui court compte ; tenu trop longtemps, ce n'est pas le geste.
            lastTap = now - pressed <= .milliseconds(350) ? now : nil
            self.pressed = nil
            if lastTap == nil { taps = 0 } else { fadeSoon() }
        } else if !flags.isEmpty {
            interrupt()
        }
    }

    /// Une autre touche ou un clic : ce n'est pas le geste.
    func interrupt() {
        guard !awake else { return }
        lastTap = nil
        pressed = nil
        taps = 0
    }

    /// Sans second appui, le ⌃ allumé s'éteint.
    private func fadeSoon() {
        fading?.cancel()
        fading = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled, !awake else { return }
            taps = 0
            lastTap = nil
        }
    }

    /// Pendant l'essai, le pop-up va s'ouvrir sous le mot : la mascotte de l'accueil s'efface quand il paraît, et revient
    /// quand il se ferme. S'il ne paraît pas dans les 6 secondes, rien ne change.
    func watchPopup() {
        watching?.cancel()
        watching = Task { [weak self] in
            let start = ContinuousClock.now
            var seen = false
            while !Task.isCancelled, ContinuousClock.now - start < .seconds(seen ? 600 : 6) {
                try? await Task.sleep(for: .milliseconds(120))
                guard let self else { return }
                let open = Self.popupIsOpen
                if open, !seen {
                    seen = true
                    away = true
                } else if seen, !open {
                    away = false
                    if state?.trialDone == true { celebrated = true }
                    hop()
                    return
                }
            }
            self?.away = false
        }
    }

    /// Une carte du pop-up est à l'écran.
    private static var popupIsOpen: Bool {
        NSApp.windows.contains { $0.isVisible && $0.contentView is NSHostingView<PopupView> }
    }
}

// MARK: - L'accueil, écran par écran

/// Le modèle choisi sur sa page, avant de le prendre.
private enum ModelPick: Hashable {
    case local(LocalChoice)
    case remote

    static let all: [ModelPick] = [.local(.e4b), .local(.e2b), .remote]
}

/// Les couleurs de Hoova que le ciel retrouve, une par étape.
private enum SkyColor: CaseIterable, Hashable {
    case mint, lavender, peach, gold
}

private struct SetupView: View {
    /// La place du contenu, sous la barre de titre.
    static let size = CGSize(width: 600, height: 580)

    let state: SetupState
    let actions: SetupActions
    let scene: SetupScene
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Le modèle choisi : aucun d'avance, sauf celui qui est déjà réglé. Hoova sort de la carte qu'on choisit.
    @State private var pick: ModelPick?
    @State private var provider = Provider.gemini
    @State private var ollamaModel = ""
    @State private var key = ""
    @State private var checking = false
    @State private var remoteError: String?
    /// « Ouvrir Hoova au démarrage du Mac » : cochée d'avance, elle ne compte qu'au clic sur « Terminer ».
    @State private var launchAtLogin = true
    /// L'avancement du téléchargement dans le temps, pour estimer ce qu'il reste.
    @State private var samples: [(date: Date, value: Double)] = []
    /// La langue de « Toujours en… », gardée quand on repasse à la langue du texte.
    @State private var fixedLanguage: String

    init(state: SetupState, actions: SetupActions, scene: SetupScene) {
        self.state = state
        self.actions = actions
        self.scene = scene
        _pick = State(
            initialValue: state.local.map(ModelPick.local) ?? (state.remote == nil ? nil : ModelPick.remote))
        _fixedLanguage = State(
            initialValue: state.language == ExplanationLanguage.text ? Self.macLanguage : state.language)
    }

    /// La langue du Mac, si Hoova la parle ; l'anglais sinon.
    private static var macLanguage: String {
        let code = Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier }
        let choice = code == "zh" ? "zh-Hans" : code ?? "en"
        return ExplanationLanguage.choices.contains(choice) ? choice : "en"
    }

    private var theme: SetupTheme { SetupTheme(dark: colorScheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            // Hoova n'a pas de place fixe : il se tient là où regarder, une place par écran (partie 13 de la DA).
            heading
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .padding(.top, state.step == .welcome ? 64 : 22)
            subtitle
                .font(.system(size: 13))
                .foregroundStyle(theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 470, minHeight: 36, alignment: .top)
                .padding(.top, 4)
            page
                .id(state.step)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 20)
                .padding(.top, 14)
            footer
        }
        // Le contenu reste sous la barre de titre ; le ciel, lui, monte jusqu'en haut de la fenêtre.
        .frame(width: Self.size.width, height: Self.size.height)
        .background {
            NightSky(colors: unlocked, awake: scene.awake, shootingStars: scene.shootingStars, theme: theme)
                .ignoresSafeArea()
        }
        .foregroundStyle(theme.ink)
        .tint(Brand.iris)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: state.step)
        .onContinuousHover(coordinateSpace: .global) { phase in
            switch phase {
            case .active(let point): scene.pointer = point
            case .ended: scene.pointer = nil
            }
        }
        .onChange(of: state.accessibility) { _, granted in
            guard granted else { return }
            scene.hop()
            // L'utilisateur est dans Réglages Système : l'accueil repasse devant.
            scene.bringToFront()
        }
        .onChange(of: state.screenRecording) { _, granted in if granted { scene.hop() } }
        .onChange(of: state.modelReady) { _, ready in if ready { scene.hop() } }
        .onChange(of: state.step) { scene.resumed = false }
        .onChange(of: state.preparing) { _, value in record(value) }
    }

    // MARK: Le ciel et la mascotte

    /// Chaque étape rend une couleur : la menthe avec l'Accessibilité, la lavande avec le modèle, la pêche après la langue,
    /// l'or à la fin de l'essai.
    private var unlocked: Set<SkyColor> {
        var colors: Set<SkyColor> = []
        if state.accessibility { colors.insert(.mint) }
        if state.local != nil || state.remote != nil { colors.insert(.lavender) }
        if state.step == .trial || state.step == .done { colors.insert(.peach) }
        if scene.celebrated { colors.insert(.gold) }
        return colors
    }

    private var mood: Mascot.Mood {
        switch state.step {
        case .welcome: scene.awake ? .happy : .sleepy
        case .permissions: !state.accessibility ? .searching : state.screenRecording ? .proud : .happy
        case .model, .language: state.failure == nil ? .happy : .lost
        case .trial, .done: scene.celebrated ? .proud : state.modelReady ? .reading : .happy
        }
    }

    /// Le halo de sa lune : plus fort quand elle éclaire aussi les images.
    private var halo: Color {
        guard scene.awake else { return .clear }
        if state.screenRecording { return Brand.mint.opacity(theme.dark ? 0.34 : 0.9) }
        return theme.dark ? Brand.cream.opacity(0.1) : .white.opacity(0.7)
    }

    // MARK: Les titres

    /// Le titre de l'écran. Sur la bienvenue, Hoova s'y tient : allongé dessus, endormi, puis debout juste à droite du
    /// point de « hoova. » au réveil.
    @ViewBuilder private var heading: some View {
        if state.step != .welcome {
            title
        } else if scene.awake {
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                Text("Salut, je suis ")
                PerchedWordmark(size: 28) { LiveHoova(mood: .happy, scene: scene).frame(width: 40, height: 40) }
            }
            .font(.system(size: 28, weight: .bold, design: .rounded))
            .transition(.opacity)
        } else {
            Text("Chut… je dors encore")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .overlay(alignment: .topTrailing) {
                    ZStack(alignment: .topTrailing) {
                        LiveHoova(mood: .sleepy, scene: scene).frame(width: 50, height: 50).rotationEffect(.degrees(-84))
                        Text(verbatim: "z").font(.system(size: 13, weight: .bold, design: .rounded)).offset(x: 10, y: -8)
                        Text(verbatim: "z").font(.system(size: 9, weight: .bold, design: .rounded)).offset(x: 18, y: -18)
                    }
                    .foregroundStyle(Brand.iris)
                    .offset(x: -6, y: -34)
                }
                .transition(.opacity)
        }
    }

    private var title: Text {
        switch state.step {
        case .welcome: scene.awake ? Text("Salut, je suis \(Brand.wordmark(size: 23))") : Text("Chut… je dors encore")
        case .permissions: scene.resumed ? Text("Me revoilà !") : Text("Deux clés pour lire")
        case .model: Text("Où vit mon esprit ?")
        case .language: Text("Dans quelle langue je t'explique ?")
        case .trial, .done: scene.celebrated ? Text("Pleine lune !") : Text("À toi de jouer")
        }
    }

    private var subtitle: Text {
        let key = state.triggerKey.symbol
        switch state.step {
        case .welcome:
            return scene.awake
                ? Text(
                    "C'est ce geste qui m'appelle\u{00A0}: survole un mot, ou sélectionne-le, puis \(key)\u{00A0}\(key). Je te l'explique dans son contexte."
                )
                : Text("Pour me réveiller, tape deux fois sur \(key).")
        case .permissions:
            guard scene.resumed else {
                return Text("macOS me les confie avec ton accord. Je ne lis que quand tu me le demandes.")
            }
            return state.screenRecording
                ? Text("Ma lune éclaire aussi les images, maintenant.") : Text("On reprend là où on en était.")
        case .model:
            return Text("C'est lui qui écrit mes explications. Choisis-en un : tu pourras en changer dans les réglages.")
        case .language:
            return Text("Je peux t'expliquer un mot dans la langue de la page, ou toujours dans la même.")
        case .trial, .done:
            return scene.celebrated
                ? Text("Tu sais tout. Je t'attends là-haut, dans la barre des menus.")
                : Text("Survole «\u{00A0}\(SetupScene.word)\u{00A0}», puis tape deux fois sur \(key).")
        }
    }

    // MARK: Les pages

    @ViewBuilder private var page: some View {
        switch state.step {
        case .welcome: welcome
        case .permissions: permissions
        case .model: models
        case .language: language
        case .trial, .done: trial
        }
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            GestureKeys(symbol: state.triggerKey.symbol, lit: scene.awake ? 2 : scene.taps)
                .frame(height: 84)
            if scene.awake {
                HStack(spacing: 10) {
                    Text("Une autre touche ?").foregroundStyle(theme.secondary)
                    Picker(
                        "Touche du double appui",
                        selection: Binding(get: { state.triggerKey }, set: { actions.setTrigger($0) })
                    ) {
                        ForEach(TriggerKey.allCases, id: \.self) { Text($0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .font(.system(size: 12.5))
                .padding(.top, 22)
                Text("Tu pourras aussi choisir un raccourci dans les réglages.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.secondary)
                    .padding(.top, 8)
            } else {
                Text("\(state.triggerKey.symbol) puis \(state.triggerKey.symbol), vite, comme on frappe à une porte.")
                    .font(.system(size: 13, design: .serif).italic())
                    .foregroundStyle(theme.secondary)
                    .padding(.top, 12)
            }
        }
    }

    private var permissions: some View {
        VStack(spacing: 12) {
            card {
                VStack(spacing: 0) {
                    permission(
                        symbol: "eye", title: "Accessibilité", required: true,
                        caption: "Pour lire le texte des apps et sentir ton geste.", granted: state.accessibility
                    ) {
                        Button("Ouvrir le réglage", action: actions.askAccessibility).buttonStyle(secondary)
                    }
                    Rectangle().fill(theme.line).frame(height: 0.5)
                    permission(
                        symbol: "moon.stars", title: "Enregistrement de l'écran", required: false,
                        caption: "Pour que ma lune éclaire tout : images, PDF scannés, vidéos sous-titrées.",
                        granted: state.screenRecording
                    ) {
                        if state.screenRecordingAsked {
                            Button("Relancer Hoova", action: actions.relaunch)
                                .buttonStyle(MoonButtonStyle(primary: true, theme: theme))
                        } else {
                            Button("Ouvrir le réglage", action: actions.askScreenRecording).buttonStyle(secondary)
                        }
                    }
                }
            }
            // Penché, il dépasse de derrière la carte en attendant ton accord ; avec l'Accessibilité, il monte dessus.
            .overlay(alignment: .topTrailing) {
                PerchedHoova(
                    pose: state.accessibility ? .standing : .peeking, mood: mood, halo: halo,
                    tilt: state.accessibility ? 0 : -8, side: 40, scene: scene
                )
                .padding(.trailing, 24)
                .alignmentGuide(.top) { $0[.bottom] }
            }
            .padding(.top, 34)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                if state.screenRecordingAsked, !state.screenRecording {
                    Text("macOS te propose de relancer Hoova : accepte, je reviens ici. \(monthly)")
                } else {
                    monthly
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }

    private var monthly: Text {
        Text("macOS peut te redemander l'enregistrement de l'écran une fois par mois : c'est normal, garde-le.")
    }

    private func permission<Action: View>(
        symbol: String, title: LocalizedStringKey, required: Bool, caption: LocalizedStringKey, granted: Bool,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .foregroundStyle(granted ? theme.ok : theme.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                    Pill(required ? "Obligatoire" : "Conseillée", filled: !required, theme: theme)
                }
                Text(caption).font(.system(size: 12)).foregroundStyle(theme.secondary)
            }
            Spacer(minLength: 8)
            if granted {
                Text("Autorisée").font(.system(size: 12.5)).foregroundStyle(theme.ok)
            } else {
                action()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }

    private var models: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(ModelPick.all, id: \.self) { option in
                    ModelCard(
                        option: option, selected: pick == option,
                        facts: facts(option), theme: theme
                    ) {
                        pick = option
                        remoteError = nil
                    }
                    // Debout sur l'astre choisi. Pour un autre, il se glisse derrière celui-ci, puis sort du nouveau.
                    .overlay(alignment: .topTrailing) {
                        PerchedHoova(
                            pose: pick == option ? .standing : .hidden, mood: mood, side: 36, scene: scene,
                            delay: pick == option ? 0.55 : 0
                        )
                        .padding(.trailing, 14)
                        .alignmentGuide(.top) { $0[.bottom] }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 32)
            modelZone
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
        }
    }

    /// Place, mémoire, vitesse, justesse, confidentialité et coût de chaque modèle (`LocalChoice.facts`).
    private func facts(_ option: ModelPick) -> [Fact] {
        guard case .local(let choice) = option else {
            return [
                Fact(id: 0, symbol: "arrow.down.circle", text: String(localized: "Rien à télécharger")),
                Fact(id: 1, symbol: "memorychip", text: String(localized: "Presque rien")),
                Fact(id: 2, symbol: "bolt", text: String(localized: "Selon ton réseau")),
                Fact(id: 3, symbol: "scope", text: String(localized: "Très juste")),
                Fact(id: 4, symbol: "lock", text: String(localized: "Le texte lu part chez le fournisseur")),
                Fact(id: 5, symbol: "banknote", text: String(localized: "Selon le fournisseur")),
            ]
        }
        let facts = choice.facts
        let place =
            if state.ready.contains(choice) {
                String(localized: "\(bytes(facts.disk)) sur ton Mac")
            } else if let started = state.started[choice] {
                String(localized: "\(bytes(facts.download)) à télécharger, \(percent(started)) déjà là")
            } else {
                String(localized: "\(bytes(facts.download)) à télécharger")
            }
        // E4B sur un Mac de moins de 16 Go : il prend beaucoup de sa mémoire.
        let heavy = choice == .e4b && state.memory < 16 << 30
        return [
            Fact(id: 0, symbol: "arrow.down.circle", text: place),
            Fact(
                id: 1, symbol: "memorychip",
                text: heavy
                    ? String(localized: "\(bytes(facts.memory)) : lourd pour \(gigabytes(state.memory)) Go")
                    : String(localized: "\(bytes(facts.memory)), libérés au repos"),
                warning: heavy),
            Fact(id: 2, symbol: "bolt", text: String(localized: "Premier mot en \(seconds(facts.firstWord))")),
            Fact(
                id: 3, symbol: "scope",
                text: choice == .e4b ? String(localized: "Le plus juste") : String(localized: "Se trompe plus souvent")),
            Fact(id: 4, symbol: "lock", text: String(localized: "Tout reste sur ton Mac")),
            Fact(id: 5, symbol: "banknote", text: String(localized: "Gratuit")),
        ]
    }

    /// Sous les astres : d'où vient le modèle et la place qu'il faut, ou les champs du modèle externe.
    @ViewBuilder private var modelZone: some View {
        switch pick {
        case nil:
            EmptyView()
        case .local(let choice)?:
            if state.ready.contains(choice) {
                Text("Déjà sur ton Mac : rien à télécharger.").foregroundStyle(theme.secondary)
            } else if let failure = state.failure, state.local == choice {
                warning(failure) { Button("Réessayer", action: actions.retry).buttonStyle(secondary) }
            } else if state.local != choice, state.freeSpace < choice.spaceNeeded {
                warning(
                    String(
                        localized:
                            "Il te faut \(bytes(choice.spaceNeeded)) de libre, il t'en reste \(bytes(state.freeSpace)) : fais de la place, ou choisis un esprit plus léger."
                    ))
            } else {
                Text(
                    "\(choice.name), \(bytes(choice.facts.download)) depuis Hugging Face, une seule fois. Il te reste \(bytes(state.freeSpace)) de libre."
                )
                .foregroundStyle(theme.secondary)
            }
        case .remote?:
            remoteFields
        }
    }

    private var remoteFields: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Picker("Fournisseur", selection: $provider) {
                    ForEach(Provider.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                if provider.isLocal {
                    TextField("Modèle", text: $ollamaModel, prompt: Text(provider.defaultModel))
                } else {
                    SecureField("Clé API", text: $key, prompt: Text("Colle ta clé API ici"))
                }
            }
            .textFieldStyle(.roundedBorder)
            Group {
                if checking {
                    Text("Je vérifie ta clé…").foregroundStyle(theme.secondary)
                } else if let remoteError {
                    Text(remoteError).foregroundStyle(theme.warn)
                } else if let remote = state.remote {
                    Text("Utilisé : \(remote)").foregroundStyle(theme.ok)
                } else if provider.isLocal {
                    Text("Ollama fait tourner le modèle sur ce Mac.").foregroundStyle(theme.secondary)
                } else {
                    Text("Ta clé reste dans le trousseau de ce Mac.").foregroundStyle(theme.secondary)
                }
            }
            .font(.system(size: 11.5))
        }
        .onChange(of: provider) { remoteError = nil }
    }

    /// Deux choix, puis un aperçu qui montre ce que le choix change.
    private var language: some View {
        VStack(spacing: 14) {
            card {
                VStack(spacing: 0) {
                    languageChoice(followsText: true, caption: "Une page en anglais ? Je t'explique en anglais.") {
                        Text("Dans la langue de ce que tu lis")
                    }
                    Rectangle().fill(theme.line).frame(height: 0.5)
                    languageChoice(followsText: false, caption: "Pratique pour lire une langue que tu apprends.") {
                        HStack(spacing: 6) {
                            Text("Toujours en")
                            Picker(
                                "Langue des explications",
                                selection: Binding(
                                    get: { fixedLanguage },
                                    set: { code in
                                        fixedLanguage = code
                                        actions.setLanguage(code)
                                    })
                            ) {
                                ForEach(ExplanationLanguage.choices, id: \.self) {
                                    Text(ExplanationLanguage.nativeName(of: $0)).tag($0)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
            }
            LanguagePreview(language: state.language, moon: state.modelReady ? nil : state.preparing, theme: theme)
            if state.remote == nil, let local = state.local { download(local) }
        }
    }

    /// Un des deux choix de la langue : sa pastille, son titre, et la phrase qui dit ce qu'il fait.
    private func languageChoice<Title: View>(
        followsText: Bool, caption: LocalizedStringKey, @ViewBuilder title: () -> Title
    ) -> some View {
        let selected = (state.language == ExplanationLanguage.text) == followsText
        return HStack(alignment: .top, spacing: 12) {
            RadioDot(on: selected, theme: theme).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                title().font(.system(size: 13.5, weight: .semibold)).foregroundStyle(theme.ink)
                Text(caption).font(.system(size: 12)).foregroundStyle(theme.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { actions.setLanguage(followsText ? ExplanationLanguage.text : fixedLanguage) }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Le téléchargement du modèle de Hoova choisi : sa lune qui se remplit, les Go reçus et le temps qu'il reste.
    @ViewBuilder private func download(_ choice: LocalChoice) -> some View {
        if let failure = state.failure {
            warning(failure) { Button("Reprendre", action: actions.retry).buttonStyle(secondary) }
        } else if state.modelReady {
            card {
                HStack(spacing: 10) {
                    MoonProgress(value: 1, color: theme.ok).frame(width: 20, height: 20)
                    Text("C'est prêt : \(choice.name) est sur ton Mac.").foregroundStyle(theme.ok)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        } else {
            let value = state.preparing ?? state.started[choice] ?? 0
            card {
                HStack(spacing: 10) {
                    MoonProgress(value: value, color: theme.moon).frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        if state.preparing == nil {
                            Text("Je me réveille…").font(.system(size: 13))
                            Text("Quelques secondes, j'arrive.")
                        } else {
                            Text("Ma lune se remplit… \(percent(value))").font(.system(size: 13))
                            Text(progress(choice, value))
                        }
                    }
                    .font(.system(size: 11.5))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    /// « Gemma 4 E4B : 1,97 Go sur 5,18 Go, encore 2 min environ ».
    private func progress(_ choice: LocalChoice, _ value: Double) -> String {
        let total = choice.facts.download
        let done = String(localized: "\(choice.name) : \(bytes(Int64(Double(total) * value))) sur \(bytes(total))")
        return remaining.map { "\(done), \($0)" } ?? done
    }

    private var trial: some View {
        VStack(spacing: 0) {
            BookPage(handles: scene.handles, ready: state.modelReady, waiting: waiting, progress: state.preparing ?? 0)
                // Assis au coin de la page, il lit ; il passe dans le pop-up, puis revient s'y asseoir.
                .overlay(alignment: .topTrailing) {
                    LiveHoova(
                        mood: mood, moon: state.modelReady ? nil : state.preparing,
                        gaze: scene.celebrated ? nil : CGPoint(x: -9, y: 8), sitting: true, scene: scene
                    )
                    .frame(width: 42)
                    .padding(.trailing, 22)
                    .alignmentGuide(.top) { $0.height * SittingMascot.seat / SittingMascot.height }
                }
                .padding(.top, 34)
            Text(
                scene.celebrated
                    ? "Essaie l'autre phrase. Et explique deux mots de suite… tu verras."
                    : "Le même mot, deux sens : je lis la phrase autour."
            )
            .font(.system(size: 12.5, design: .serif).italic())
            .foregroundStyle(theme.secondary)
            .padding(.top, 10)
            Toggle("Ouvrir Hoova au démarrage du Mac", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.system(size: 12.5))
                .padding(.top, 20)
        }
    }

    /// Ce que dit la page d'essai tant que le modèle n'est pas prêt.
    private var waiting: Text {
        if let failure = state.failure { return Text(failure) }
        guard let preparing = state.preparing else { return Text("Je me réveille… Quelques secondes, j'arrive.") }
        return Text("Ma lune se remplit encore (\(percent(preparing))) : tu pourras essayer dans un instant.")
    }

    // MARK: Le pied de page

    private var footer: some View {
        HStack(spacing: 8) {
            MoonSteps(current: stepIndex, gold: scene.celebrated, color: theme.ink)
            Spacer()
            buttons
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var stepIndex: Int { min(SetupStep.allCases.firstIndex(of: state.step) ?? 0, 4) }

    @ViewBuilder private var buttons: some View {
        switch state.step {
        case .welcome:
            if scene.awake {
                primary("Continuer") { actions.go(.permissions) }
            } else {
                Button("Passer") { scene.wake(byGesture: false) }.buttonStyle(secondary)
            }
        case .permissions:
            back(.welcome)
            primary("Continuer", disabled: !state.accessibility) { actions.go(.model) }
        case .model:
            back(.permissions)
            modelButton
        case .language:
            back(.model)
            primary("Continuer") { actions.go(.trial) }
        case .trial, .done:
            back(.language)
            primary("Terminer", action: finish)
        }
    }

    /// « Télécharger » vaut accord : le nom, la source et la taille sont écrits juste au-dessus.
    @ViewBuilder private var modelButton: some View {
        switch pick {
        case nil:
            primary("Continuer", disabled: true) {}
        case .local(let choice)?:
            let here = state.ready.contains(choice) || state.local == choice
            primary(here ? "Continuer" : "Télécharger", disabled: !here && state.freeSpace < choice.spaceNeeded) {
                if state.local != choice { actions.useLocal(choice) }
                actions.go(.language)
            }
        case .remote?:
            primary(checking ? "Je vérifie…" : "Continuer", disabled: checking, action: connect)
        }
    }

    private func connect() {
        checking = true
        remoteError = nil
        Task {
            let error = await actions.useRemote(provider, provider.isLocal ? ollamaModel : "", provider.isLocal ? "" : key)
            checking = false
            remoteError = error
            if error == nil { actions.go(.language) }
        }
    }

    /// « Terminer » : la case du démarrage compte, et Hoova s'envole vers la barre des menus.
    private func finish() {
        if launchAtLogin != state.launchAtLogin { actions.setLaunchAtLogin(launchAtLogin) }
        if !reduceMotion {
            scene.leaving = true
            scene.leave(scene.mascotFrame)
        }
        actions.go(.done)
    }

    private func back(_ step: SetupStep) -> some View {
        Button("Retour") { actions.go(step) }.buttonStyle(secondary)
    }

    private func primary(_ title: LocalizedStringKey, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(MoonButtonStyle(primary: true, theme: theme))
            .keyboardShortcut(.defaultAction)
            .disabled(disabled)
    }

    private var secondary: MoonButtonStyle { MoonButtonStyle(primary: false, theme: theme) }

    // MARK: Les petites pièces

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .background(theme.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.line, lineWidth: 0.5) }
    }

    private func warning(_ text: String) -> some View {
        warning(text) { EmptyView() }
    }

    /// Ce qui bloque, en pêche, avec ce qu'on peut y faire.
    private func warning<Action: View>(_ text: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
            action()
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.warn)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.warnFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func record(_ value: Double?) {
        guard let value else { return samples.removeAll() }
        let now = Date()
        samples.append((now, value))
        samples.removeAll { now.timeIntervalSince($0.date) > 20 }
    }

    /// Le temps qu'il reste, d'après la vitesse des 20 dernières secondes.
    private var remaining: String? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let elapsed = last.date.timeIntervalSince(first.date)
        guard elapsed > 3, last.value > first.value else { return nil }
        let seconds = (1 - last.value) / ((last.value - first.value) / elapsed)
        guard seconds < 2 * 3600 else { return nil }
        return seconds < 60
            ? String(localized: "encore moins d'une minute")
            : String(localized: "encore \(Int((seconds / 60).rounded(.up))) min environ")
    }
}

private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

private func percent(_ value: Double) -> String {
    String(localized: "\(Int((min(max(value, 0), 1) * 100).rounded()))\u{00A0}%")
}

private func gigabytes(_ count: Int64) -> Int { Int((Double(count) / Double(1 << 30)).rounded()) }

private func seconds(_ duration: Duration) -> String {
    (duration / .seconds(1)).formatted(.number.precision(.fractionLength(1))) + "\u{00A0}s"
}

/// Une couleur de la nuit, par sa valeur hexadécimale.
private func rgb(_ hex: UInt32) -> Color {
    Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
}

/// Les couleurs de l'accueil : crème nuage sur la nuit en mode sombre, nuit magique sur l'aube en mode clair.
private struct SetupTheme {
    let dark: Bool

    var ink: Color { dark ? Brand.cream : Brand.night }
    var secondary: Color { ink.opacity(dark ? 0.68 : 0.66) }
    /// Les cartes : assez pleines pour cacher les étoiles, assez claires pour laisser passer les couleurs du ciel.
    var glass: Color { dark ? rgb(0x261A5E).opacity(0.8) : .white.opacity(0.72) }
    var selected: Color { dark ? rgb(0x3A2C7A).opacity(0.85) : .white.opacity(0.9) }
    var line: Color { dark ? .white.opacity(0.16) : Brand.night.opacity(0.12) }
    /// Le bouton principal, un morceau de lune : crème sur la nuit, nuit sur l'aube.
    var button: Color { dark ? Brand.cream : Brand.night }
    var buttonInk: Color { dark ? Brand.night : Brand.cream }
    var ok: Color { dark ? rgb(0x9FE8C2) : rgb(0x1F7A4D) }
    var warn: Color { dark ? Brand.peach : rgb(0x9A4F08) }
    var warnFill: Color { Brand.peach.opacity(dark ? 0.16 : 0.45) }
    var star: Color { dark ? Brand.cream : Brand.purple }
    var moon: Color { dark ? Brand.mint : Brand.purple }
    /// La nuit grise, avant le réveil, puis la nuit indigo (l'aube pastel en mode clair).
    var asleepSky: [Color] { dark ? [rgb(0x121218), rgb(0x1C1B26), rgb(0x25242F)] : [rgb(0xECECEF), rgb(0xF6F6F4)] }
    var awakeSky: [Color] { dark ? [rgb(0x0D0830), rgb(0x191050), Brand.night] : [rgb(0xEAE3FA), rgb(0xF6F1F4), Brand.cream] }

    func glow(_ color: SkyColor) -> Color {
        switch color {
        case .mint: Brand.mint.opacity(dark ? 0.3 : 0.95)
        case .lavender: Brand.iris.opacity(dark ? 0.38 : 0.7)
        case .peach: Brand.peach.opacity(dark ? 0.26 : 0.6)
        case .gold: Mascot.goldColor.opacity(dark ? 0.26 : 0.35)
        }
    }

    /// Les étoiles ✳ de chaque couleur : plus soutenues sur l'aube, où le pastel ne se verrait pas.
    func sparkle(_ color: SkyColor) -> Color {
        switch color {
        case .mint: dark ? Brand.mint : rgb(0x6CC79F)
        case .lavender: dark ? Brand.iris : Brand.purple
        case .peach: dark ? Brand.peach : rgb(0xE8964F)
        case .gold: dark ? Mascot.goldColor : rgb(0xD9A400)
        }
    }
}

/// Le ciel de l'accueil : une nuit grise, puis indigo au réveil, où reviennent une à une les couleurs de Hoova. Rien n'y
/// bouge au repos ; une couleur rendue s'ouvre en 1,1 s, et l'étoile filante passe une fois, au réveil.
private struct NightSky: View {
    let colors: Set<SkyColor>
    let awake: Bool
    let shootingStars: Int
    let theme: SetupTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Des étoiles fixes, toujours les mêmes : tirées une fois, d'une graine. Aucune derrière le titre et sa phrase.
    private static let stars: [(x: CGFloat, y: CGFloat, radius: CGFloat, opacity: Double)] = {
        var seed: UInt64 = 11
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }
        let title = CGRect(x: 50, y: 128, width: 500, height: 90)
        return (0..<60).map { _ in
            (x: next() * 600, y: next() * 430, radius: next() < 0.12 ? 1.7 : next() * 0.9 + 0.5, opacity: next() * 0.55 + 0.25)
        }
        .filter { !title.contains(CGPoint(x: $0.x, y: $0.y)) }
    }()
    /// Une étoile ✳ par couleur rendue, loin du texte : de part et d'autre de la mascotte, en bas au milieu, près de la
    /// lune.
    private static let sparkles: [(color: SkyColor, at: CGPoint)] = [
        (.mint, CGPoint(x: 40, y: 112)), (.lavender, CGPoint(x: 560, y: 112)), (.peach, CGPoint(x: 330, y: 560)),
        (.gold, CGPoint(x: 486, y: 70)),
    ]

    var body: some View {
        ZStack {
            LinearGradient(colors: theme.asleepSky, startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: theme.awakeSky, startPoint: .top, endPoint: .bottom).opacity(awake ? 1 : 0)
            ForEach(SkyColor.allCases, id: \.self) { color in
                let (anchor, radius, squash) = Self.shape(of: color)
                RadialGradient(
                    colors: [theme.glow(color), theme.glow(color).opacity(0)], center: anchor, startRadius: 0,
                    endRadius: radius
                )
                .scaleEffect(x: 1, y: squash, anchor: anchor)
                .opacity(colors.contains(color) ? 1 : 0)
                .scaleEffect(colors.contains(color) ? 1 : 0.7, anchor: anchor)
            }
            Canvas { context, _ in
                let brightness = theme.dark ? (awake ? 1 : 0.4) : (awake ? 0.45 : 0.2)
                for star in Self.stars {
                    context.fill(
                        Path(
                            ellipseIn: CGRect(
                                x: star.x - star.radius, y: star.y - star.radius, width: 2 * star.radius,
                                height: 2 * star.radius)),
                        with: .color(theme.star.opacity(star.opacity * brightness)))
                }
            }
            ForEach(Self.sparkles, id: \.color) { sparkle in
                Sparkle()
                    .stroke(theme.sparkle(sparkle.color), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                    .frame(width: 12, height: 12)
                    .position(sparkle.at)
                    .opacity(colors.contains(sparkle.color) ? 1 : 0)
            }
            shootingStar
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 1.1), value: colors)
        .animation(reduceMotion ? nil : .easeOut(duration: 1.1), value: awake)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// D'où vient chaque couleur, comme sur la carte « Pastel doux » : menthe en haut à gauche, lavande en haut à droite,
    /// pêche en bas, et l'or près de la lune.
    private static func shape(of color: SkyColor) -> (UnitPoint, CGFloat, CGFloat) {
        switch color {
        case .mint: (.topLeading, 380, 0.74)
        case .lavender: (.topTrailing, 380, 0.74)
        case .peach: (UnitPoint(x: 0.55, y: 1.08), 440, 0.52)
        case .gold: (UnitPoint(x: 0.82, y: 0.09), 230, 0.9)
        }
    }

    private struct Streak {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var opacity = 0.0
    }

    /// L'étoile filante du réveil : elle traverse le haut du ciel vers la gauche, puis s'efface.
    private var shootingStar: some View {
        let head = theme.dark ? Brand.cream : Brand.purple
        return Capsule()
            .fill(LinearGradient(colors: [head, head.opacity(0)], startPoint: .leading, endPoint: .trailing))
            .frame(width: 96, height: 2)
            .rotationEffect(.degrees(-18))
            .keyframeAnimator(initialValue: Streak(), trigger: shootingStars) { view, streak in
                view.offset(x: streak.x, y: streak.y).opacity(streak.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.x) {
                    MoveKeyframe(0)
                    CubicKeyframe(-280, duration: 0.9)
                }
                KeyframeTrack(\.y) {
                    MoveKeyframe(0)
                    CubicKeyframe(92, duration: 0.9)
                }
                KeyframeTrack(\.opacity) {
                    MoveKeyframe(0)
                    LinearKeyframe(1, duration: 0.12)
                    LinearKeyframe(0, duration: 0.78)
                }
            }
            .position(x: 518, y: 53)
    }
}

/// Hoova tel qu'il vit dans l'accueil, à la place que lui donne l'écran : ses yeux suivent le pointeur (ou regardent
/// `gaze`), sa lune se remplit pendant le téléchargement (`moon`, de 0 à 1), il saute un peu à chaque bonne nouvelle, et
/// s'efface quand il passe dans le pop-up ou s'envole. `sitting` l'assoit au bord, les jambes dans le vide.
private struct LiveHoova: View {
    let mood: Mascot.Mood
    var moon: Double?
    var gaze: CGPoint?
    var sitting = false
    let scene: SetupScene
    @State private var center = CGPoint.zero

    var body: some View {
        Group {
            if sitting {
                SittingMascot(mood: mood, look: look, moonAge: moonAge)
            } else {
                MascotView(mood: mood, look: look, moonAge: moonAge)
            }
        }
        .keyframeAnimator(initialValue: 0.0, trigger: scene.hops) { view, y in
            view.offset(y: y)
        } keyframes: { _ in
            KeyframeTrack {
                MoveKeyframe(0)
                CubicKeyframe(-3, duration: 0.15)
                CubicKeyframe(0, duration: 0.2)
            }
        }
        .opacity(scene.away || scene.leaving ? 0 : 1)
        .animation(.easeOut(duration: 0.22), value: scene.away)
        // Dans la fenêtre, barre de titre comprise (origine en haut à gauche) : pour ses yeux, et d'où il s'envole.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            center = CGPoint(x: frame.midX, y: frame.midY)
            scene.mascotFrame = frame
        }
    }

    private var moonAge: Double? { moon.map { 0.04 + 0.46 * min(max($0, 0), 1) } }

    private var look: CGPoint { gaze ?? scene.look(from: center) }
}

/// Hoova sur le bord d'une carte : debout dessus, qui dépasse de derrière, ou caché derrière. Le bas de la vue est le
/// bord, et ce qui passe dessous est caché. Il passe d'une pose à l'autre en 0,3 s, après `delay` : le temps que
/// l'autre Hoova se soit caché, pour qu'il n'y en ait jamais qu'un à l'écran.
private struct PerchedHoova: View {
    enum Pose {
        case standing, peeking, hidden
    }

    let pose: Pose
    let mood: Mascot.Mood
    var halo = Color.clear
    /// Penché, curieux : en degrés, autour de ses pieds.
    var tilt = 0.0
    let side: CGFloat
    let scene: SetupScene
    var delay = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            // Le halo de sa lune : plus fort quand elle éclaire aussi les images.
            Circle()
                .fill(RadialGradient(colors: [halo, halo.opacity(0)], center: .center, startRadius: 0, endRadius: side * 0.8))
                .frame(width: side * 1.6, height: side * 1.6)
                .offset(y: side * 0.3)
            LiveHoova(mood: mood, scene: scene)
                .frame(width: side, height: side)
                .rotationEffect(.degrees(tilt), anchor: .bottom)
        }
        .offset(y: drop)
        .frame(width: side, height: side, alignment: .bottom)
        .mask(alignment: .bottom) { Rectangle().frame(width: side * 3, height: side * 3) }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3).delay(delay), value: pose)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: tilt)
        .accessibilityHidden(true)
    }

    /// Ce qu'il descend derrière le bord : rien debout, jusque sous les yeux quand il dépasse, tout quand il est caché.
    private var drop: CGFloat {
        switch pose {
        case .standing: 0
        case .peeking: side * 0.36
        case .hidden: side * 1.05
        }
    }
}

/// Le geste dans le ciel : deux fois le symbole de la touche (⌃ ⌃), qui s'allument à chaque appui.
private struct GestureKeys: View {
    let symbol: String
    let lit: Int

    var body: some View {
        HStack(spacing: 44) {
            ForEach(0..<2, id: \.self) { index in
                Text(symbol)
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .opacity(lit > index ? 1 : 0.3)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Une ligne de la carte d'un modèle.
private struct Fact: Identifiable {
    let id: Int
    let symbol: String
    let text: String
    var warning = false
}

/// Un modèle, en astre : la pleine lune (E4B), le quartier (E2B) ou les nuages (externe), avec ce qu'il faut savoir pour
/// le choisir.
private struct ModelCard: View {
    let option: ModelPick
    let selected: Bool
    let facts: [Fact]
    let theme: SetupTheme
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Celestial(option: option, theme: theme).frame(width: 42, height: 42)
                    Spacer(minLength: 4)
                }
                .frame(height: 44)
                Text(name).font(.system(size: 13.5, weight: .semibold)).padding(.top, 6)
                Text(tagline)
                    .font(.system(size: 12, design: .serif).italic())
                    .foregroundStyle(theme.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(facts) { fact in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: fact.symbol)
                                .font(.system(size: 10.5))
                                .foregroundStyle(fact.warning ? theme.warn : theme.secondary)
                                .frame(width: 14)
                            Text(fact.text)
                                .foregroundStyle(fact.warning ? theme.warn : theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.system(size: 11.5))
                .padding(.top, 9)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(selected ? theme.selected : theme.glass, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? Brand.iris : theme.line, lineWidth: selected ? 1.5 : 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var name: String {
        switch option {
        case .local(let choice): choice.name
        case .remote: String(localized: "Modèle externe")
        }
    }

    private var tagline: LocalizedStringKey {
        switch option {
        case .local(.e4b): "La pleine lune, le plus juste"
        case .local(.e2b): "Le quartier, plus léger"
        case .remote: "Dans les nuages, avec ta clé"
        }
    }
}

/// Les astres des modèles, dessinés comme la lune de Hoova : une pleine lune et ses cratères, un premier quartier, un
/// nuage.
private struct Celestial: View {
    let option: ModelPick
    let theme: SetupTheme

    var body: some View {
        Canvas { context, _ in
            let rim = theme.dark ? Brand.mint.opacity(0.35) : Brand.night.opacity(0.22)
            let light = theme.dark ? Brand.cream : rgb(0xFFF3D1)
            let disc = Path(ellipseIn: CGRect(x: 7, y: 7, width: 28, height: 28))
            switch option {
            case .local(.e4b):
                context.fill(Path(ellipseIn: CGRect(x: 2, y: 2, width: 38, height: 38)), with: .color(rim.opacity(0.5)))
                context.fill(disc, with: .color(light))
                context.stroke(disc, with: .color(rim), lineWidth: 1)
                for crater in [
                    CGRect(x: 12.8, y: 13.8, width: 6.4, height: 6.4), CGRect(x: 22.7, y: 23.7, width: 4.6, height: 4.6),
                    CGRect(x: 24.4, y: 12.4, width: 3.2, height: 3.2),
                ] {
                    context.fill(Path(ellipseIn: crater), with: .color(Brand.night.opacity(theme.dark ? 0.13 : 0.08)))
                }
            case .local(.e2b):
                context.stroke(disc, with: .color(rim), lineWidth: 1.2)
                let half = disc.intersection(Path(CGRect(x: 21, y: 7, width: 14, height: 28)))
                context.fill(half, with: .color(light))
                context.stroke(half, with: .color(rim), lineWidth: 1)
            case .remote:
                let cloud = Path(ellipseIn: CGRect(x: 8, y: 17, width: 14, height: 14))
                    .union(Path(ellipseIn: CGRect(x: 14, y: 10, width: 18, height: 18)))
                    .union(Path(ellipseIn: CGRect(x: 24, y: 19, width: 12, height: 12)))
                    .union(Path(roundedRect: CGRect(x: 14, y: 23, width: 17, height: 8), cornerRadius: 4))
                context.fill(cloud, with: .color(theme.dark ? Brand.cream.opacity(0.85) : .white))
                context.stroke(cloud, with: .color(rim), lineWidth: 0.8)
            }
        }
        .accessibilityHidden(true)
    }
}

/// La pastille d'un choix : pleine de violet Hoova quand il est pris.
private struct RadioDot: View {
    let on: Bool
    let theme: SetupTheme

    var body: some View {
        Circle()
            .strokeBorder(on ? Brand.iris : theme.secondary, lineWidth: on ? 5 : 1)
            .background(Circle().fill(on ? Color.white : theme.glass))
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}

/// L'aperçu de la page de la langue : une phrase lue, son mot allumé, et dessous le pop-up de Hoova, dans la langue où
/// il expliquera. Les explications sont écrites à l'avance : aucun modèle ne tourne.
private struct LanguagePreview: View {
    let language: String
    /// La lune de Hoova, qui se remplit pendant le téléchargement.
    let moon: Double?
    let theme: SetupTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var term = CGRect.zero

    private struct Sample {
        let code: String
        let before: String
        let term: String
        let after: String
    }

    private static let english = Sample(code: "en", before: "The ECB raised its ", term: "key rate", after: " again.")
    /// Avec « Toujours en anglais », la phrase lue est en français : sinon, l'aperçu ne montrerait aucun changement.
    private static let french = Sample(code: "fr", before: "La BCE a encore relevé son ", term: "taux directeur", after: ".")
    /// L'explication de « key rate » dans chaque langue de Hoova.
    private static let answers = [
        "en": "Here, the key rate is the interest rate at which the ECB lends money to banks. Raising it makes loans more expensive.",
        "fr": "Ici, le taux directeur est le taux auquel la BCE prête de l'argent aux banques. Le relever rend les crédits plus chers.",
        "es": "Aquí, el tipo de interés oficial es el tipo al que el BCE presta dinero a los bancos. Subirlo encarece los préstamos.",
        "de": "Hier ist der Leitzins der Zinssatz, zu dem die EZB den Banken Geld leiht. Steigt er, werden Kredite teurer.",
        "it": "Qui il tasso di riferimento è il tasso al quale la BCE presta denaro alle banche. Alzarlo rende i prestiti più cari.",
        "pt": "Aqui, a taxa diretora é a taxa a que o BCE empresta dinheiro aos bancos. Subi-la torna os empréstimos mais caros.",
        "zh-Hans": "这里的基准利率，是欧洲央行向银行放贷的利率。提高它，贷款就会变贵。",
        "ja": "ここでの政策金利とは、欧州中央銀行が銀行にお金を貸すときの金利です。引き上げると、ローンが高くなります。",
    ]
    /// « taux directeur », expliqué en anglais.
    private static let frenchInEnglish =
        "Here, the taux directeur (key rate) is the interest rate at which the ECB lends money to banks. Raising it makes loans more expensive."

    var body: some View {
        // La phrase lue est dans l'autre langue que l'app, comme dans le premier choix (« Une page en anglais ? », « A page
        // in French? ») ; avec « Toujours en » cette langue-là, c'est l'autre phrase.
        let other = Bundle.main.preferredLocalizations.first == "fr" ? Self.english : Self.french
        let sample = language == other.code ? (other.code == "en" ? Self.french : Self.english) : other
        let target = language == ExplanationLanguage.text ? sample.code : language
        let answer =
            sample.code == "fr" && target == "en"
            ? Self.frenchInEnglish : Self.answers[target] ?? Self.answers["en"] ?? ""
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(sample.before)
                // Le mot lu s'allume, comme au double ⌃.
                Text(sample.term)
                    .padding(.horizontal, 2)
                    .background(Brand.iris.opacity(0.45), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("aperçu")) } action: { term = $0 }
                Text(sample.after)
            }
            .font(.system(size: 15, design: .serif))
            .foregroundStyle(Brand.night)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.cream, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            // La carte s'ouvre sous le mot, comme dans l'app : 32 points plus bas, un peu à gauche du mot.
            MiniPopup(term: sample.term, text: answer, moon: moon, theme: theme)
                .padding(.top, 32)
                .offset(x: min(max(term.minX - 10, 0), 260))
        }
        .coordinateSpace(.named("aperçu"))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: answer)
    }
}

/// Le pop-up de l'aperçu, comme le vrai : la carte « Pastel doux », le terme et son badge, l'explication, et Hoova
/// debout sur le bord.
private struct MiniPopup: View {
    let term: String
    let text: String
    let moon: Double?
    let theme: SetupTheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let ink = theme.dark ? Brand.cream : Brand.night
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(term).font(.system(size: 15.5, weight: .bold, design: .rounded))
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Sparkle().stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round)).frame(width: 8, height: 8)
                    Text("IA")
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .overlay { Capsule().strokeBorder(ink.opacity(0.22)) }
            }
            Text(text)
                .font(.system(size: 13.5))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .id(text)
                .transition(.opacity)
        }
        .padding(.horizontal, 15)
        .padding(.top, 12)
        .padding(.bottom, 13)
        .frame(width: 300, alignment: .leading)
        .foregroundStyle(ink)
        .background { pastel.clipShape(shape) }
        .overlay { shape.strokeBorder(ink.opacity(theme.dark ? 0.14 : 0.08), lineWidth: 0.5) }
        .overlay(alignment: .topTrailing) {
            // Debout sur le bord de la carte, comme dans le pop-up ; sa lune se remplit pendant le téléchargement.
            MascotView(mood: .happy, moonAge: moon.map { 0.04 + 0.46 * min(max($0, 0), 1) })
                .frame(width: 28, height: 28)
                .offset(x: -16, y: -28)
        }
        .accessibilityElement(children: .combine)
    }

    /// « Pastel doux » : menthe en haut à gauche, lavande en haut à droite, pêche en bas, sur crème ou sur nuit.
    private var pastel: some View {
        ZStack {
            theme.dark ? Brand.night.opacity(0.9) : Brand.cream.opacity(0.92)
            RadialGradient(
                colors: [Brand.mint.opacity(theme.dark ? 0.28 : 0.95), .clear], center: .topLeading, startRadius: 0,
                endRadius: 230)
            RadialGradient(
                colors: [Brand.iris.opacity(theme.dark ? 0.38 : 0.8), .clear], center: UnitPoint(x: 1, y: 0.1),
                startRadius: 0, endRadius: 210)
            RadialGradient(
                colors: [Brand.peach.opacity(theme.dark ? 0.24 : 0.6), .clear], center: UnitPoint(x: 0.6, y: 1.2),
                startRadius: 0, endRadius: 230)
        }
    }
}

/// La page d'essai, comme une page de livre : du papier crème, en New York, avec « avocat » souligné dans deux phrases.
/// Elle se sélectionne à la souris, comme l'explication du pop-up, et donne le mot sous le pointeur.
private struct BookPage: View {
    let handles: [PopupTextHandle]
    let ready: Bool
    let waiting: Text
    let progress: Double

    private static let sentences = SetupScene.sentences.map { sentence($0) }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { index in
                SelectableText(text: Self.sentences[index], highlight: Brand.iris.opacity(0.45), handle: handles[index])
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Brand.cream, in: Self.shape)
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6).fill(Brand.iris).frame(width: 3)
        }
        .overlay {
            if !ready {
                HStack(spacing: 8) {
                    MoonProgress(value: progress, color: Brand.purple).frame(width: 20, height: 20)
                    waiting
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Brand.night.opacity(0.75))
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Brand.cream.opacity(0.92), in: Self.shape)
            }
        }
    }

    private static let shape = UnevenRoundedRectangle(
        topLeadingRadius: 6, bottomLeadingRadius: 6, bottomTrailingRadius: 14, topTrailingRadius: 14, style: .continuous)

    /// Une phrase en New York, avec le mot à survoler souligné de points violets.
    private static func sentence(_ text: String) -> NSAttributedString {
        let size: CGFloat = 16.5
        let system = NSFont.systemFont(ofSize: size)
        let font = system.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let result = NSMutableAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: NSColor(Brand.night), .paragraphStyle: paragraph])
        result.addAttributes(
            [
                .underlineStyle: NSUnderlineStyle.single.union(.patternDot).rawValue,
                .underlineColor: NSColor(Brand.purple),
            ], range: (text as NSString).range(of: SetupScene.word))
        return result
    }
}

/// Les cinq étapes en cinq lunes, de la nouvelle à la pleine : celles déjà faites sont éclairées, la cinquième devient
/// d'or à la fin de l'essai.
private struct MoonSteps: View {
    let current: Int
    let gold: Bool
    let color: Color
    private static let phases = [0.1, 0.3, 0.5, 0.75, 1.0]

    var body: some View {
        HStack(spacing: 9) {
            ForEach(0..<5, id: \.self) { index in
                let lit = index <= current
                MoonProgress(
                    value: Self.phases[index], color: index == 4 && gold ? Mascot.goldColor : color, outline: !lit
                )
                .frame(width: 15, height: 15)
                .opacity(lit ? 1 : 0.35)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Étape \(current + 1) sur 5"))
    }
}

/// Un badge : « Obligatoire » au trait, « Conseillée » en violet Hoova.
private struct Pill: View {
    let text: LocalizedStringKey
    var filled = false
    var sparkle = false
    let theme: SetupTheme

    init(_ text: LocalizedStringKey, filled: Bool = false, sparkle: Bool = false, theme: SetupTheme) {
        self.text = text
        self.filled = filled
        self.sparkle = sparkle
        self.theme = theme
    }

    var body: some View {
        HStack(spacing: 4) {
            if sparkle {
                Sparkle().stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round)).frame(width: 8, height: 8)
            }
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .padding(.horizontal, 7)
        .padding(.vertical, 1.5)
        .foregroundStyle(filled ? theme.ink : theme.secondary)
        .background(filled ? Brand.iris.opacity(theme.dark ? 0.3 : 1) : .clear, in: Capsule())
        .overlay { if !filled { Capsule().strokeBorder(theme.secondary, lineWidth: 0.5) } }
        .fixedSize()
    }
}

/// Les boutons de l'accueil, en capsule : le principal est un morceau de lune, les autres sont translucides.
private struct MoonButtonStyle: ButtonStyle {
    let primary: Bool
    let theme: SetupTheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: primary ? .medium : .regular))
            .padding(.horizontal, 15)
            .padding(.vertical, 5)
            .foregroundStyle(primary ? theme.buttonInk : theme.ink)
            .background(primary ? theme.button : theme.glass, in: Capsule())
            .overlay { if !primary { Capsule().strokeBorder(theme.line, lineWidth: 0.5) } }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

// MARK: - Le vol vers la barre des menus

/// « Terminer » : Hoova s'envole de l'accueil jusqu'à son icône, dans la barre des menus (0,8 s). Une fenêtre
/// transparente, posée le temps du vol, qui laisse passer les clics ; elle n'est créée qu'au premier vol.
private final class SetupFlight {
    static let duration = 0.8
    private var panel: NSPanel?
    private var host: NSHostingView<SetupFlightView>?
    private var landing: Task<Void, Never>?

    /// De la place de la mascotte dans l'accueil jusqu'au centre de l'icône (coordonnées AppKit).
    func fly(from start: CGRect, to end: CGPoint) {
        let control = CGPoint(x: (start.midX + end.x) / 2, y: max(start.midY, end.y) + 60)
        let area = start.union(CGRect(origin: end, size: .zero)).union(CGRect(origin: control, size: .zero))
            .insetBy(dx: -50, dy: -50)
        // Dans la fenêtre, l'origine est en haut à gauche.
        func local(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - area.minX, y: area.maxY - point.y) }
        let route = SetupFlightView.Route(
            from: local(CGPoint(x: start.midX, y: start.midY)), to: local(end), control: local(control), start: .now,
            side: start.width)
        let (panel, host) = surface()
        host.rootView = SetupFlightView(route: route)
        panel.setFrame(area, display: false)
        host.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        landing?.cancel()
        landing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.duration + 0.05))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
            self?.host?.rootView = SetupFlightView(route: nil)
        }
    }

    private func surface() -> (NSPanel, NSHostingView<SetupFlightView>) {
        if let panel, let host { return (panel, host) }
        let host = NSHostingView(rootView: SetupFlightView(route: nil))
        let panel = NSPanel(
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
        self.panel = panel
        self.host = host
        return (panel, host)
    }
}

/// Elle vole en arc, en rapetissant jusqu'à la taille de son icône, puis s'y fond.
private struct SetupFlightView: View {
    struct Route {
        let from: CGPoint
        let to: CGPoint
        let control: CGPoint
        let start: Date
        let side: CGFloat
    }

    let route: Route?

    var body: some View {
        if let route {
            TimelineView(.animation) { timeline in
                let progress = min(max(timeline.date.timeIntervalSince(route.start) / SetupFlight.duration, 0), 1)
                let t = CGFloat(progress * progress * (3 - 2 * progress))
                let u = 1 - t
                let point = CGPoint(
                    x: u * u * route.from.x + 2 * u * t * route.control.x + t * t * route.to.x,
                    y: u * u * route.from.y + 2 * u * t * route.control.y + t * t * route.to.y)
                let side = route.side + (18 - route.side) * t
                MascotView(mood: .proud)
                    .frame(width: side, height: side)
                    .position(point)
                    .opacity(progress < 0.85 ? 1 : (1 - progress) / 0.15)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}
