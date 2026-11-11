import AppKit
import HoovaCore
import KeyboardShortcuts
import Sparkle
import os

private let log = Logger(subsystem: "com.teayouness.hoova", category: "explication")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum ModelStatus {
        case loading, ready
        /// Aucun modèle choisi : au premier lancement, tant que l'accueil n'a pas fait choisir.
        case missing
        case failed(String)
    }

    /// Le modèle qui écrit : celui de Hoova sur ce Mac, ou un modèle externe choisi dans le menu.
    private var explainer = AppDelegate.chosenEngine()
    private let trigger = DoubleTap(key: Preferences.triggerKey.flags, symbol: Preferences.triggerKey.symbol)
    private let gestures = SelectionGestures()
    private let popup = PopupController()
    /// La fenêtre de réglages et ce qu'elle montre.
    private let settings = SettingsState()
    private let settingsWindow = SettingsWindow()
    /// L'accueil du premier lancement et ce qu'il montre, suivi chaque seconde tant qu'il est ouvert.
    private let setup = SetupState()
    private let setupWindow = SetupWindow()
    private var setupWatch: Task<Void, Never>?
    private var statusItem: NSStatusItem?
    /// Les mises à jour : Sparkle lit la liste des versions publiées sur GitHub (`SUFeedURL`), et installe la nouvelle
    /// une fois vérifiée sa signature (`SUPublicEDKey`). Au deuxième lancement, il demande s'il peut vérifier tout seul.
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    /// La mascotte de la barre des menus : elle dort quand l'IA a quitté la mémoire.
    private var statusIcon: StatusIcon?
    /// Le modèle est en mémoire : faux avant le premier chargement et après une pause.
    private var modelLoaded = false
    private var modelStatus = ModelStatus.loading
    private var reading: Task<Capture?, Never>?
    private var explaining: Task<Void, Never>?
    /// La sélection lue au moment où elle a été faite, et l'app où elle l'a été.
    private var remembered: (capture: Capture, pid: pid_t)?
    /// La lecture commencée au premier ⌃, avec l'endroit et le moment où elle a commencé.
    private var early: (point: CGPoint, start: ContinuousClock.Instant, task: Task<Capture?, Never>)?
    /// Mode test : `HOOVA_DEBUG=1`. Chaque explication y est aussi ajoutée aux cas du banc d'essai.
    private let debug = ProcessInfo.processInfo.environment["HOOVA_DEBUG"] == "1"
    /// Les étapes de chaque explication, visibles dans Instruments (Points of Interest).
    private let signposter = OSSignposter(subsystem: "com.teayouness.hoova", category: .pointsOfInterest)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.editMenu()
        setUpStatusItem()
        trigger.onDoubleTap = { [weak self] point in self?.explainOnGesture(at: point) }
        // Le raccourci classique des réglages, s'il y en a un : il explique ce qui est sous la souris.
        KeyboardShortcuts.onKeyUp(for: .explain) { [weak self] in
            self?.explainOnGesture(at: CGEvent(source: nil)?.location ?? .zero)
        }
        trigger.onFirstTap = { [weak self] point in self?.startReading(at: point) }
        gestures.onSelectionMade = { [weak self] in self?.rememberSelection() }

        log.notice(
            "Hoova démarré · accessibilité \(AccessibilityReader.isTrusted ? "oui" : "non", privacy: .public) · enregistrement de l'écran \(ScreenOCRReader.isAllowed ? "oui" : "non", privacy: .public)"
        )
        if ProcessInfo.processInfo.environment["HOOVA_SETUP"] == "1" { setupGo(.welcome) }
        if Preferences.setupStep == .done {
            Permissions.askForAccessibility()
            Permissions.askForScreenRecording()
        } else {
            // Premier lancement : l'accueil explique chaque autorisation avant de la demander, et fait choisir le modèle
            // avant tout téléchargement.
            openSetup()
        }
        startTriggerWhenAllowed()
        Task.detached { await ScreenOCRReader.prewarm() }
        Task { await loadModel() }
        if debug { listenForTests() }
    }

    /// Tests automatiques : « explique à x,y » sans faire le geste.
    /// `HOOVA_DEBUG=1`, puis une notification distribuée `com.teayouness.hoova.explain` dont l'objet vaut
    /// "x,y", ou "x,y,selection" pour faire comme si l'utilisateur venait de sélectionner du texte,
    /// ou "x,y,copy" pour passer directement à la copie (⌘C).
    private func listenForTests() {
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.teayouness.hoova.explain"), object: nil, queue: .main
        ) { [weak self] note in
            let parts = (note.object as? String)?.split(separator: ",") ?? []
            guard parts.count >= 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return }
            let mode = parts.dropFirst(2).first
            MainActor.assumeIsolated {
                self?.explain(at: CGPoint(x: x, y: y), selectionLikely: mode != nil, onlyCopy: mode == "copy")
            }
        }
    }

    // MARK: - L'explication

    /// Le geste (double appui ou raccourci) : la sélection mémorisée sert si elle vient de l'app au premier plan.
    private func explainOnGesture(at point: CGPoint) {
        let likely = gestures.selectionIsLikely
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let memo = likely && remembered?.pid == pid ? remembered?.capture : nil
        explain(at: point, selectionLikely: likely, remembered: memo)
    }

    /// Double ⌃ : le pop-up s'ouvre tout de suite, on lit la sélection (sinon le mot sous la souris), on lance l'IA, et
    /// le pop-up se remplit au fil de la lecture puis de l'écriture.
    /// - Parameter selectionLikely: l'utilisateur vient de sélectionner du texte ; si l'app ne le dit pas,
    ///   on copie la sélection avec ⌘C.
    private func explain(
        at point: CGPoint, selectionLikely: Bool, remembered: Capture? = nil, onlyCopy: Bool = false
    ) {
        // Double ⌃ sur le pop-up lui-même : Hoova explique un mot de sa propre explication, et la carte reste en place.
        // Ailleurs sur la carte (le terme, la ligne de contexte, la mascotte, le badge), il ne fait rien.
        let inPopup = popup.capture(at: point)
        if inPopup == nil, popup.contains(point) {
            log.notice("Double ⌃ sur la carte, hors de l'explication : rien à faire")
            return
        }
        // Double ⌃ sur la phrase d'exemple de l'accueil : l'essai du geste. Ailleurs sur l'accueil, il ne fait rien.
        let inSetup = inPopup == nil ? setupWindow.capture(at: point) : nil
        if inPopup == nil, inSetup == nil, setupWindow.contains(point) {
            log.notice("Double ⌃ sur l'accueil, hors de la phrase d'exemple : rien à faire")
            return
        }
        let given = inPopup ?? inSetup
        // Dans les autres fenêtres de Hoova (réglages, alertes), le geste ne fait rien : les moniteurs locaux de
        // `DoubleTap` ne servent qu'à l'essai de l'accueil.
        if given == nil, NSApp.isActive { return }
        cancel()
        if inPopup == nil { popup.hide() }
        // La lecture commencée au premier ⌃ sert si la souris n'a pas bougé et qu'il n'y a pas de sélection à lire.
        let early = self.early.flatMap { early in
            given == nil && !selectionLikely && !onlyCopy && remembered == nil
                && hypot(early.point.x - point.x, early.point.y - point.y) <= 4
                && ContinuousClock.now - early.start < .seconds(1) ? early.task : nil
        }
        if early == nil { self.early?.task.cancel() }
        self.early = nil
        let reading =
            early
            ?? Task.detached {
                if let given { return given }
                return await TextReader.read(
                    at: point, selectionLikely: selectionLikely, remembered: remembered, onlyCopy: onlyCopy,
                    copySelection: { await SelectionCopier.copy() })
            }
        self.reading = reading
        let startedAtFirstTap = early != nil
        let model = PopupModel()
        model.awake = inPopup != nil
        // La carte s'ouvre dès le second ⌃, en phase de lecture, sauf quand Hoova peut devoir copier la sélection : son
        // ⌘C la fermerait aussitôt. Le pop-up et l'accueil donnent leur texte tout de suite : la carte l'attend.
        let opensAtOnce = given == nil && (remembered != nil || (!selectionLikely && !onlyCopy))
        if opensAtOnce {
            popup.show(model, at: point)
            log.notice("Carte ouverte au second ⌃, pendant la lecture")
        }
        // Le modèle n'est pas en mémoire au premier lancement, ni après une pause : la mascotte se réveille.
        let modelReady = if case .ready = modelStatus { modelLoaded } else { false }
        let debug = debug
        explaining = Task { [explainer, popup, signposter, setup] in
            let clock = ContinuousClock()
            let start = clock.now
            let signpost = signposter.makeSignpostID()
            let interval = signposter.beginInterval("Explication", id: signpost)
            defer { signposter.endInterval("Explication", interval) }
            let capture = await reading.value
            guard !Task.isCancelled else { return }
            let read = clock.now - start
            signposter.emitEvent("Texte lu", id: signpost)
            guard let capture else {
                let blank = await ScreenOCRReader.isBlank(around: point)
                guard !Task.isCancelled else { return }
                model.phase = blank ? .blank : .nothingFound
                if !opensAtOnce { popup.show(model, at: point) }
                log.notice(
                    "Rien lu sous la souris (\(read, privacy: .public))\(blank ? " · zone d'une seule couleur : vidéo protégée ?" : "", privacy: .public)"
                )
                return
            }
            log.notice(
                "Lu par \(capture.method.rawValue, privacy: .public) en \(read, privacy: .public)\(startedAtFirstTap ? " (commencé au premier ⌃)" : "", privacy: .public) : « \(capture.term) » · contexte \(capture.context.count, privacy: .public) caractères\(capture.contextFromSelection ? " (lu à la sélection)" : "", privacy: .public) · autour \(capture.surroundingCount, privacy: .public) caractères, dont début \(capture.beginning?.count ?? 0, privacy: .public) · titre \(capture.title == nil ? "non" : "oui", privacy: .public)"
            )
            model.term = capture.term
            model.anchor = Self.usable(capture.anchor, near: point)
            model.title = capture.title
            model.phase = modelReady ? .writing : .waitingModel
            // Ouverte dès le second ⌃, la carte reste où elle est : le mot s'allume quand `anchor` arrive.
            if !opensAtOnce { popup.show(model, at: point) }
            var firstWord: Duration?
            do {
                for try await explanation in explainer.explain(capture) {
                    if model.text.isEmpty, !explanation.text.isEmpty {
                        firstWord = clock.now - start
                        signposter.emitEvent("Premier mot", id: signpost)
                        log.notice("Premier mot après \(clock.now - start, privacy: .public)")
                    }
                    model.text = explanation.text
                    model.uncertain = explanation.uncertain
                    if !explanation.text.isEmpty { model.phase = .writing }
                    if explanation.isFinal {
                        let total = clock.now - start
                        model.source = explanation.source
                        model.phase = .done
                        log.notice("Réponse complète après \(total, privacy: .public) [\(explanation.source.rawValue, privacy: .public)] : \(explanation.text)")
                        Measurements.record(
                            capture: capture, explanation: explanation, startedAtFirstTap: startedAtFirstTap,
                            read: read, firstWord: firstWord, total: total)
                        if debug { BenchCases.save(capture, answer: explanation.text) }
                        // Pendant l'essai de l'accueil, une explication affichée prouve que le geste marche.
                        if setup.step == .trial, !explanation.text.isEmpty { setup.trialDone = true }
                    }
                }
            } catch is CancellationError {
            } catch {
                model.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Premier ⌃ : on commence déjà à lire sous la souris, sans ⌘C, pour gagner le temps du second appui. Si le texte
    /// est lu avant le second ⌃, le modèle commence aussi à lire le prompt. Rien quand on vient de sélectionner : la
    /// réponse est alors préparée dès la sélection.
    private func startReading(at point: CGPoint) {
        early?.task.cancel()
        early = nil
        // Si le modèle a été déchargé après une pause, il revient dès maintenant.
        Task { [explainer] in try? await explainer.prepare() }
        // Sur le pop-up, rien à lire : il donne lui-même son texte, et le modèle peut déjà lire le prompt. Ailleurs sur
        // la carte, le double ⌃ ne fera rien.
        if let given = popup.capture(at: point) ?? setupWindow.capture(at: point) {
            Task { [explainer] in await explainer.prepare(for: given) }
            return
        }
        guard !gestures.selectionIsLikely, !popup.contains(point), !setupWindow.contains(point), !NSApp.isActive else {
            return
        }
        let task = Task.detached {
            await TextReader.read(
                at: point, selectionLikely: false, remembered: nil, onlyCopy: false, copySelection: { nil })
        }
        early = (point, ContinuousClock.now, task)
        log.notice("Premier ⌃ : lecture commencée")
        Task { [weak self, explainer] in
            // Le second ⌃ n'est pas encore venu : le modèle peut déjà lire le prompt.
            guard let capture = await task.value, self?.early?.task == task else { return }
            await explainer.prepare(for: capture)
        }
    }

    /// Lit la sélection juste après le geste qui l'a faite, avant toute touche : certains sites
    /// (YouTube, ChatGPT…) l'effacent ou la déplacent dès qu'on appuie sur une touche.
    private func rememberSelection() {
        let point = CGEvent(source: nil)?.location ?? .zero
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        remembered = nil
        Task { [weak self] in
            // Le temps que l'app mette sa sélection à jour.
            try? await Task.sleep(for: .milliseconds(80))
            let capture = await Task.detached { () -> Capture? in
                var capture = AccessibilityReader.currentSelection(near: point)
                // L'app ne donne pas sa sélection : on la lit telle qu'elle est surlignée à l'écran.
                if capture == nil { capture = await ScreenOCRReader.highlightedSelection(around: point) }
                guard let found = capture else { return nil }
                // Le paragraphe autour, tant que la souris est encore sur la sélection, et le titre de la page.
                var read = await TextReader.withContext(found, at: point)
                read.title = AccessibilityReader.frontmostWindowTitle()
                return read
            }.value
            guard let capture, let self else { return }
            remembered = (capture, pid)
            log.notice(
                "Sélection mémorisée (\(capture.method.rawValue, privacy: .public)) : \(capture.term.count, privacy: .public) caractères · contexte \(capture.context.count, privacy: .public) caractères"
            )
            // Le modèle lit déjà le prompt : au double ⌃, il n'aura plus qu'à écrire.
            if capture.term.count <= 200 { await explainer.prepare(for: capture) }
        }
    }

    private func cancel() {
        explaining?.cancel()
        reading?.cancel()
        explaining = nil
        reading = nil
    }

    /// Le cadre du mot, s'il est crédible ; sinon nil, et le pop-up se place à la souris. Chrome donne souvent un cadre
    /// vide pour une sélection, parfois celui de toute la page, et une sélection mémorisée a pu défiler depuis
    /// (coordonnées globales, origine en haut à gauche).
    private static func usable(_ anchor: CGRect?, near point: CGPoint) -> CGRect? {
        guard let anchor else { return nil }
        let distance = hypot(
            max(anchor.minX - point.x, 0, point.x - anchor.maxX), max(anchor.minY - point.y, 0, point.y - anchor.maxY))
        let flaw: String? =
            if anchor.width < 1 || anchor.height < 1 {
                "vide"
            } else if anchor.height > 400 {
                "trop grand"
            } else if distance > 250 {
                "loin de la souris, à \(Int(distance)) pt"
            } else {
                nil
            }
        guard let flaw else { return anchor }
        log.notice(
            "Cadre du mot écarté (\(flaw, privacy: .public)) : \(Int(anchor.width), privacy: .public)×\(Int(anchor.height), privacy: .public) en \(Int(anchor.minX), privacy: .public),\(Int(anchor.minY), privacy: .public), souris en \(Int(point.x), privacy: .public),\(Int(point.y), privacy: .public) ; pop-up à la souris"
        )
        return nil
    }

    // MARK: - Démarrage

    /// Le modèle externe choisi, s'il a sa clé ; sinon celui de Hoova, sur ce Mac. Au premier lancement, rien ne se
    /// télécharge avant le choix fait dans l'accueil, sauf un téléchargement déjà commencé, qui reprend.
    private static func chosenEngine() -> any Engine {
        if let provider = Provider.chosen, let key = provider.isLocal ? "" : provider.apiKey {
            return RemoteExplainer(provider: provider, model: provider.model, apiKey: key)
        }
        let local = LocalChoice.chosen.rawValue
        guard Preferences.setupStep == .done || LocalModel.isReady(local) || LocalModel.downloaded(local) > 0 else {
            return NoEngine()
        }
        return Explainer(local: LocalChoice.chosen)
    }

    /// Passe à un autre modèle : l'ancien libère la mémoire (ou arrête son téléchargement), le nouveau se prépare.
    private func use(_ engine: any Engine) {
        cancel()
        let previous = explainer
        explainer = engine
        modelStatus = .loading
        settings.local = engine is Explainer ? LocalChoice.chosen : nil
        settings.remote = (engine as? RemoteExplainer)?.modelName
        refreshSetup()
        Task {
            await previous.unload()
            await loadModel()
        }
    }

    /// Ce modèle est toujours celui de Hoova : un modèle remplacé pendant sa préparation ne change plus rien.
    private func isCurrent(_ engine: any Engine) -> Bool { (engine as AnyObject) === (explainer as AnyObject) }

    private func loadModel() async {
        let engine = explainer
        // La mascotte de la barre des menus suit le modèle : préparation au premier lancement, sommeil après une
        // pause, réveil au rechargement.
        await engine.onPreparing { [weak self] fraction in
            Task { @MainActor in
                self?.statusIcon?.preparing = fraction
                self?.settings.preparing = fraction
                self?.setup.preparing = fraction
                if fraction == nil { self?.settings.refreshSizes() }
            }
        }
        await engine.onLoadedChange { [weak self] loaded in
            Task { @MainActor in
                self?.modelLoaded = loaded
                self?.statusIcon?.asleep = !loaded
            }
        }
        modelStatus = .loading
        setup.failure = nil
        refreshSetup()
        do {
            try await engine.prepare()
            guard isCurrent(engine) else { return }
            modelStatus = engine is NoEngine ? .missing : .ready
        } catch {
            guard isCurrent(engine), !(error is CancellationError) else { return }
            modelStatus = .failed(error.localizedDescription)
            setup.failure = error.localizedDescription
            log.error("Modèle indisponible : \(error.localizedDescription, privacy: .public)")
        }
        refreshSetup()
    }

    // MARK: - L'accueil

    /// L'accueil : au premier lancement, puis depuis le menu tant qu'il n'est pas fini. Les autorisations sont suivies
    /// chaque seconde tant qu'il est ouvert.
    private func openSetup() {
        refreshSetup()
        setupWindow.show(
            state: setup,
            actions: SetupActions(
                go: { [weak self] step in self?.setupGo(step) },
                setTrigger: { [weak self] key in self?.setTrigger(key) },
                setLaunchAtLogin: { [weak self] on in
                    Preferences.launchAtLogin = on
                    self?.setup.launchAtLogin = Preferences.launchAtLogin
                    self?.settings.launchAtLogin = Preferences.launchAtLogin
                },
                askAccessibility: {
                    Permissions.askForAccessibility()
                    Permissions.openAccessibilitySettings()
                },
                askScreenRecording: { [weak self] in
                    Permissions.askForScreenRecording()
                    Permissions.openScreenRecordingSettings()
                    self?.setup.screenRecordingAsked = true
                },
                relaunch: { [weak self] in self?.relaunch() },
                useLocal: { [weak self] choice in self?.useLocal(choice, confirm: false) },
                useRemote: { [weak self] provider, model, key in
                    guard let self else { return nil }
                    return await connect(provider, model: model, key: key)
                },
                retry: { [weak self] in self?.retryModel() },
                setLanguage: { [weak self] language in
                    UserDefaults.standard.set(language, forKey: ExplanationLanguage.key)
                    self?.setup.language = language
                    self?.settings.language = language
                },
                openSettings: { [weak self] in self?.openSettings() }))
        setupWatch?.cancel()
        setupWatch = Task { [weak self] in
            while !Task.isCancelled, let self, setupWindow.isVisible {
                refreshSetup()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Passe à une étape de l'accueil, gardée pour reprendre au même endroit après une relance ; `.done` le termine.
    private func setupGo(_ step: SetupStep) {
        Preferences.setupStep = step
        setup.step = step
        guard step == .done else { return }
        setupWatch?.cancel()
        setupWindow.close()
        log.notice("Accueil terminé")
    }

    /// Met l'accueil à jour : autorisations, place libre, modèles prêts ou commencés, modèle utilisé, langue.
    private func refreshSetup() {
        setup.triggerKey = Preferences.triggerKey
        setup.launchAtLogin = Preferences.launchAtLogin
        setup.accessibility = AccessibilityReader.isTrusted
        setup.screenRecording = ScreenOCRReader.isAllowed
        setup.freeSpace = LocalModel.freeSpace
        setup.ready = Set(LocalChoice.allCases.filter { LocalModel.isReady($0.rawValue) })
        var started: [LocalChoice: Double] = [:]
        for choice in LocalChoice.allCases where !setup.ready.contains(choice) {
            let fraction = Double(LocalModel.downloaded(choice.rawValue)) / Double(choice.facts.download)
            if fraction > 0 { started[choice] = min(fraction, 1) }
        }
        setup.started = started
        setup.local = explainer is Explainer ? LocalChoice.chosen : nil
        setup.remote = (explainer as? RemoteExplainer)?.modelName
        setup.modelReady = if case .ready = modelStatus { !(explainer is NoEngine) } else { false }
        setup.language = ExplanationLanguage.setting
    }

    /// Reprend la préparation du modèle après un échec : le téléchargement repart de là où il s'était arrêté.
    private func retryModel() {
        setup.failure = nil
        guard !(explainer is NoEngine) else { return }
        Task { await loadModel() }
    }

    /// Le déclencheur a besoin de l'accessibilité : on attend que l'utilisateur l'autorise.
    private func startTriggerWhenAllowed() {
        if AccessibilityReader.isTrusted, trigger.start() {
            gestures.start()
            return
        }
        Task {
            while !trigger.isRunning {
                try? await Task.sleep(for: .seconds(1.5))
                if AccessibilityReader.isTrusted, trigger.start() { gestures.start() }
            }
        }
    }

    // MARK: - Menu de la barre des menus

    /// Hoova n'a pas de barre de menus : sans menu Édition, ⌘V, ⌘C, ⌘X et ⌘A ne font rien dans ses champs (la clé API,
    /// par exemple). Ce menu reste invisible ; il ne sert qu'à ces raccourcis.
    private static func editMenu() -> NSMenu {
        let edit = NSMenu(title: String(localized: "Édition"))
        // Sa propre clé : « Annuler » est aussi le bouton des alertes, qui se traduit autrement.
        let undo = String(localized: "menu.annuler", defaultValue: "Annuler", comment: "Menu Édition : annuler la dernière action.")
        edit.addItem(withTitle: undo, action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: String(localized: "Rétablir"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: String(localized: "Couper"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copier"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Coller"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(
            withTitle: String(localized: "Tout sélectionner"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem()
        item.submenu = edit
        let menu = NSMenu()
        menu.addItem(item)
        return menu
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = StatusIcon(button: item.button)
        statusIcon = icon
        // Pendant une explication, la mascotte de la barre des menus lit.
        popup.onWorkChange = { icon.working = $0 }
        let menu = NSMenu()
        // Les lignes d'état sans action restent lisibles au lieu d'être grisées.
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(StatusMenu.header())
        menu.addItem(.separator())
        if Preferences.setupStep != .done {
            menu.addItem(action("Terminer l'installation…", #selector(openSetupFromMenu)))
        }
        menu.addItem(
            AccessibilityReader.isTrusted
                ? StatusMenu.status(
                    String(localized: "Accessibilité"), String(localized: "Autorisée"),
                    action: #selector(openAccessibilitySettings), target: self)
                : action("Autoriser l'accessibilité…", #selector(openAccessibilitySettings)))
        menu.addItem(
            ScreenOCRReader.isAllowed
                ? StatusMenu.status(
                    String(localized: "Lecture partout (écran)"), String(localized: "Autorisée"),
                    action: #selector(openScreenRecordingSettings), target: self)
                : action("Autoriser l'enregistrement de l'écran…", #selector(openScreenRecordingSettings)))
        menu.addItem(modelItem)
        menu.addItem(StatusMenu.about())
        menu.addItem(action("Rechercher des mises à jour…", #selector(checkForUpdates)))
        menu.addItem(action("Réglages…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(action("Relancer Hoova", #selector(relaunch)))
        menu.addItem(action("Quitter Hoova", #selector(quit), key: "q"))
    }

    private var modelItem: NSMenuItem {
        if explainer is NoEngine {
            return StatusMenu.status(
                String(localized: "IA"), String(localized: "À choisir"), action: #selector(openSetupFromMenu), target: self)
        }
        let remote = explainer is RemoteExplainer
        let name =
            remote
            ? String(localized: "IA externe, \(explainer.modelName)")
            : String(localized: "IA locale, \(StatusMenu.modelName(explainer.modelName))")
        let item: NSMenuItem
        switch modelStatus {
        case .loading: item = StatusMenu.status(name, String(localized: "Se charge…"))
        case .ready: item = StatusMenu.status(name, String(localized: "Prête"))
        case .missing: item = StatusMenu.status(name, String(localized: "À choisir"))
        case .failed(let reason):
            item = StatusMenu.status(name, String(localized: "Indisponible"))
            item.subtitle = reason
        }
        return item
    }

    /// Passe à un modèle de Hoova sur ce Mac. Un modèle absent se télécharge, si la place libre suffit. Depuis les
    /// réglages (`confirm`), on demande d'abord, avec son nom, sa source et sa taille ; l'accueil les montre avant le clic.
    private func useLocal(_ choice: LocalChoice, confirm: Bool) {
        if explainer is Explainer, LocalChoice.chosen == choice {
            // Le modèle déjà choisi : s'il n'a pas pu se préparer, on reprend.
            if case .failed = modelStatus { retryModel() }
            return
        }
        let missing = choice.spaceNeeded - LocalModel.freeSpace
        guard missing <= 0 else {
            let message = String(
                localized:
                    "Il manque \(ByteCountFormatter.string(fromByteCount: missing, countStyle: .file)) sur le disque pour \(choice.name). Libère de la place, puis réessaie.")
            setup.failure = message
            if confirm { warn("Pas assez de place", message) }
            return
        }
        if confirm, !LocalModel.isReady(choice.rawValue) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Télécharger \(choice.name) ?")
            alert.informativeText = String(
                localized:
                    "\(choice.downloadSize) depuis Hugging Face (\(choice.rawValue)). Hoova n'en garde que la partie texte, et la mascotte de la barre des menus montre l'avancement.")
            alert.addButton(withTitle: String(localized: "Télécharger"))
            alert.addButton(withTitle: String(localized: "Annuler"))
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        UserDefaults.standard.removeObject(forKey: Provider.key)
        UserDefaults.standard.set(choice.rawValue, forKey: LocalChoice.key)
        log.notice("Modèle local choisi : \(choice.name, privacy: .public)")
        use(Explainer(local: choice))
    }

    private func trash(_ choice: LocalChoice) {
        do {
            try LocalModel.trash(choice.rawValue)
            settings.refreshSizes()
            log.notice("\(choice.name, privacy: .public) mis à la corbeille")
        } catch {
            warn("\(choice.name) n'a pas pu aller à la corbeille", error.localizedDescription)
        }
    }

    /// La clé API et le modèle d'un fournisseur, vérifiés par une toute petite demande avant d'être gardés.
    private func askForKey(_ provider: Provider) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Utiliser \(provider.name)")
        alert.informativeText =
            provider.isLocal
            ? String(localized: "Ollama fait tourner le modèle sur ce Mac. Indique un modèle déjà téléchargé dans Ollama.")
            : String(
                localized:
                    "Pour chaque explication, Hoova enverra à \(provider.name) le terme, le passage autour et le titre de la page. Ta clé reste dans le trousseau de ce Mac.")
        let key = NSSecureTextField()
        key.placeholderString =
            provider.apiKey == nil ? String(localized: "à coller ici") : String(localized: "déjà enregistrée")
        let model = NSTextField(string: provider.model)
        model.placeholderString = provider.defaultModel
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: provider.isLocal ? 24 : 56))
        func row(_ title: LocalizedStringResource, _ field: NSTextField, y: CGFloat) {
            let label = NSTextField(labelWithString: String(localized: title))
            label.frame = NSRect(x: 0, y: y + 3, width: 70, height: 18)
            field.frame = NSRect(x: 74, y: y, width: 246, height: 24)
            fields.addSubview(label)
            fields.addSubview(field)
        }
        row("Modèle", model, y: 0)
        if !provider.isLocal { row("Clé API", key, y: 32) }
        alert.accessoryView = fields
        alert.addButton(withTitle: String(localized: "Utiliser"))
        alert.addButton(withTitle: String(localized: "Annuler"))
        NSApp.activate()
        // La mise en page d'abord : sinon NSAlert choisit lui-même le champ actif, et la clé ne l'est pas.
        alert.layout()
        alert.window.initialFirstResponder = provider.isLocal ? model : key
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            if let failure = await connect(provider, model: model.stringValue, key: key.stringValue) {
                warn("\(provider.name) n'a pas pu être utilisé", failure)
            }
        }
    }

    /// Vérifie la clé et le modèle par une toute petite demande, puis les garde et passe à ce modèle externe. Un nom de
    /// modèle vide prend celui par défaut, une clé vide celle déjà enregistrée. Renvoie la phrase d'erreur, sinon nil.
    private func connect(_ provider: Provider, model: String, key: String) async -> String? {
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiKey = provider.isLocal ? "" : typed.isEmpty ? provider.apiKey : typed else {
            return String(localized: "Il faut une clé API : tu la trouves dans ton compte \(provider.name), rubrique des clés API.")
        }
        let engine = RemoteExplainer(provider: provider, model: name.isEmpty ? provider.defaultModel : name, apiKey: apiKey)
        do {
            try await engine.check()
        } catch {
            return error.localizedDescription
        }
        if !typed.isEmpty { provider.apiKey = typed }
        provider.model = name.isEmpty ? provider.defaultModel : name
        UserDefaults.standard.set(provider.rawValue, forKey: Provider.key)
        log.notice("Modèle externe choisi : \(engine.modelName, privacy: .public)")
        use(engine)
        return nil
    }

    private func warn(_ title: LocalizedStringResource, _ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: title)
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }

    /// La fenêtre de réglages, qui remplace les sous-menus d'avant : chaque réglage compte tout de suite.
    @objc private func openSettings() {
        settings.triggerKey = Preferences.triggerKey
        settings.language = ExplanationLanguage.setting
        settings.launchAtLogin = Preferences.launchAtLogin
        settings.local = explainer is Explainer ? LocalChoice.chosen : nil
        settings.remote = (explainer as? RemoteExplainer)?.modelName
        settings.refreshSizes()
        settingsWindow.show(
            state: settings,
            actions: SettingsActions(
                trigger: { [weak self] key in self?.setTrigger(key) },
                useLocal: { [weak self] choice in self?.useLocal(choice, confirm: true) },
                trash: { [weak self] choice in self?.trash(choice) },
                useRemote: { [weak self] provider in self?.askForKey(provider) }))
    }

    private func setTrigger(_ key: TriggerKey) {
        Preferences.triggerKey = key
        trigger.key = key.flags
        trigger.symbol = key.symbol
        setup.triggerKey = key
        settings.triggerKey = key
        log.notice("Raccourci : double \(key.symbol, privacy: .public)")
    }

    private func action(_ title: LocalizedStringResource, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: title), action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openSetupFromMenu() { openSetup() }
    @objc private func openAccessibilitySettings() { Permissions.openAccessibilitySettings() }
    @objc private func openScreenRecordingSettings() { Permissions.openScreenRecordingSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    /// Hoova vit dans la barre des menus : la fenêtre de Sparkle ne passe devant les autres apps que si Hoova est active.
    @objc private func checkForUpdates() {
        NSApp.activate()
        updater.checkForUpdates(nil)
    }

    /// L'enregistrement de l'écran n'est pris en compte qu'après un redémarrage de l'app.
    @objc private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
