import Foundation
import HoovaCore
import Observation

/// Les étapes de l'accueil, au premier lancement (étape 4 de `docs/plan.md`), dans l'ordre.
enum SetupStep: String, CaseIterable {
    /// Ce que fait Hoova, et le geste.
    case welcome
    /// L'Accessibilité (obligatoire : lire le texte, détecter le geste) et l'Enregistrement de l'écran (lire partout).
    case permissions
    /// Le modèle : Gemma 4 E4B, E2B ou un modèle externe, et sa préparation.
    case model
    /// La langue des explications.
    case language
    /// L'essai du geste, sur une phrase d'exemple.
    case trial
    /// L'accueil est fini : il ne revient plus au lancement.
    case done
}

/// Ce que montre l'accueil. L'app le tient à jour : les autorisations sont suivies chaque seconde tant qu'il est ouvert,
/// la préparation du modèle et l'essai du geste au fil de l'eau.
///
/// Contrat entre la session moteur (qui remplit cet état et réalise les actions) et la session interface (qui le
/// montre, dans `SetupWindow.swift`) : un champ ou une action en plus se demande à la session moteur.
@Observable
final class SetupState {
    /// L'étape affichée. Elle est gardée dans les préférences : après une relance, l'accueil reprend au même endroit.
    var step = Preferences.setupStep
    /// La touche du double appui (son symbole : `triggerKey.symbol`, « ⌃ »), changée par `SetupActions.setTrigger`.
    var triggerKey = Preferences.triggerKey
    /// Hoova s'ouvre au démarrage du Mac (`SetupActions.setLaunchAtLogin`).
    var launchAtLogin = Preferences.launchAtLogin

    // MARK: Les autorisations

    /// L'Accessibilité est accordée : Hoova lit le texte et détecte le geste. Sans elle, rien ne marche.
    var accessibility = false
    /// L'Enregistrement de l'écran est accordé : Hoova lit partout, par l'OCR (images, vidéos, PDF scannés).
    var screenRecording = false
    /// L'Enregistrement de l'écran a été demandé dans cette session. Il ne compte qu'après une relance de Hoova
    /// (`SetupActions.relaunch`), et macOS peut le redemander chaque mois.
    var screenRecordingAsked = false

    // MARK: Le modèle

    /// La mémoire du Mac, en octets : sur un Mac de 8 Go, l'accueil prévient qu'E4B peut ralentir les autres apps. Il ne
    /// conseille aucun modèle (décision du 9 novembre 2026).
    let memory = Int64(ProcessInfo.processInfo.physicalMemory)
    /// La place libre sur le disque des modèles, en octets. Ce qu'il faut pour chacun : `LocalChoice.spaceNeeded`.
    /// Place, mémoire, vitesse et justesse de chaque modèle : `LocalChoice.facts`, et `Provider.facts` pour un modèle
    /// externe (la confidentialité et le coût suivent de `ModelFacts.isLocal`).
    var freeSpace: Int64 = 0
    /// Les modèles de Hoova déjà prêts sur ce Mac.
    var ready: Set<LocalChoice> = []
    /// La part déjà téléchargée d'un modèle commencé puis coupé, de 0 à 1 : son téléchargement reprendra là.
    var started: [LocalChoice: Double] = [:]
    /// Le modèle utilisé : un modèle de Hoova, ou le nom d'un modèle externe (« gemini-3.5-flash-lite (Google Gemini) »).
    /// Les deux à nil : rien n'est encore choisi.
    var local: LocalChoice?
    var remote: String?
    /// La préparation du modèle choisi (téléchargement compris), de 0 à 1 ; nil quand rien ne se prépare.
    var preparing: Double?
    /// Pourquoi le modèle n'a pas pu être préparé (connexion coupée, disque plein…), en une phrase à montrer telle
    /// quelle, avec `SetupActions.retry`.
    var failure: String?
    /// Le modèle choisi est prêt à expliquer.
    var modelReady = false

    // MARK: La langue

    /// La langue des explications : `ExplanationLanguage.text` (celle du texte lu), ou le code d'une langue de
    /// `ExplanationLanguage.choices`.
    var language = ExplanationLanguage.setting

    // MARK: L'essai

    /// Une explication s'est affichée pendant l'essai : le geste marche.
    var trialDone = false
}

/// Ce que l'accueil demande à l'app.
struct SetupActions {
    /// Passe à une étape, gardée pour reprendre au même endroit après une relance ; `.done` termine l'accueil.
    var go: (SetupStep) -> Void
    /// Change la touche du double appui, tout de suite (sans relancer), comme dans les réglages.
    var setTrigger: (TriggerKey) -> Void
    /// Ouvre Hoova au démarrage du Mac, ou plus (un élément de connexion de macOS).
    var setLaunchAtLogin: (Bool) -> Void
    /// Demande l'autorisation à macOS, puis ouvre le bon réglage. L'état suit tout seul.
    var askAccessibility: () -> Void
    var askScreenRecording: () -> Void
    /// Relance Hoova, pour que l'Enregistrement de l'écran compte. L'accueil revient à la même étape.
    var relaunch: () -> Void
    /// Utilise un modèle de Hoova. S'il n'est pas sur ce Mac, il se télécharge depuis Hugging Face après vérification de
    /// la place libre : le clic vaut accord, l'accueil montre avant le nom, la source et la taille.
    var useLocal: (LocalChoice) -> Void
    /// Vérifie la clé par une toute petite demande, puis utilise ce modèle externe (un nom vide : son modèle par défaut ;
    /// une clé vide : celle déjà enregistrée). Renvoie la phrase d'erreur à montrer, sinon nil.
    var useRemote: (_ provider: Provider, _ model: String, _ key: String) async -> String?
    /// Reprend la préparation du modèle après un échec : le téléchargement repart de là où il s'était arrêté.
    var retry: () -> Void
    var setLanguage: (String) -> Void
    /// Ouvre la fenêtre de réglages (pour changer de raccourci, par exemple).
    var openSettings: () -> Void
}
