import AppKit
import ServiceManagement
import os

private let log = Logger(subsystem: "com.teayouness.hoova", category: "réglages")

/// La touche du double appui. Pas fn : macOS s'en sert déjà, deux fois de suite, pour la dictée.
enum TriggerKey: String, CaseIterable {
    case control, option, shift, command

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .control: .control
        case .option: .option
        case .shift: .shift
        case .command: .command
        }
    }

    var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }
}

/// Les réglages de l'app, gardés dans ses préférences. Ceux du moteur sont dans HoovaCore : la langue
/// (`ExplanationLanguage`) et le modèle externe (`Provider`).
enum Preferences {
    static var triggerKey: TriggerKey {
        get { UserDefaults.standard.string(forKey: "triggerKey").flatMap(TriggerKey.init(rawValue:)) ?? .control }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "triggerKey") }
    }

    /// L'étape de l'accueil où l'on en est, `.done` une fois fini. `HOOVA_SETUP=1` le rouvre au début (essais).
    static var setupStep: SetupStep {
        get { UserDefaults.standard.string(forKey: "setupStep").flatMap(SetupStep.init(rawValue:)) ?? .welcome }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "setupStep") }
    }

    /// Ouvrir Hoova à l'ouverture de session : un élément de connexion de macOS, visible dans Réglages Système.
    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                try newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            } catch {
                log.error("Ouverture au démarrage : \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
