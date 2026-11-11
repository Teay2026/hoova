import Foundation
import Security

/// Ce qui écrit les explications : le modèle local (`Explainer`, avec MLX) ou un modèle externe (`RemoteExplainer`).
public protocol Engine: Sendable {
    /// Le nom du modèle, pour le menu.
    var modelName: String { get }
    /// Ce qu'on envoie au plus du texte autour du passage, en caractères : peu au modèle du Mac, qui lit environ
    /// 500 jetons par seconde (docs/decisions.md, 9 novembre 2026), beaucoup à un modèle externe.
    var contextBudget: Int { get }
    /// Charge le modèle local ; pour un modèle externe, ouvre la connexion d'avance.
    func prepare() async throws
    /// Fait lire le prompt au modèle avant le double ⌃, quand il le peut.
    func prepare(for capture: Capture) async
    /// L'explication, envoyée au fur et à mesure qu'elle s'écrit.
    func explain(_ capture: Capture) -> AsyncThrowingStream<Explanation, Error>
    /// `action` est appelé quand le modèle entre en mémoire (vrai) et quand il la quitte (faux).
    func onLoadedChange(_ action: @escaping @Sendable (Bool) -> Void) async
    /// `action` suit la préparation du modèle au premier lancement, de 0 à 1, puis nil.
    func onPreparing(_ action: @escaping @Sendable (Double?) -> Void) async
    /// Libère la mémoire du modèle.
    func unload() async
}

extension Explainer: Engine {}

/// Le budget de texte autour du passage, ou celui de `HOOVA_CONTEXT` (essais au banc).
func budgetSetting(default value: Int) -> Int {
    ProcessInfo.processInfo.environment["HOOVA_CONTEXT"].flatMap { Int($0) } ?? value
}

/// Aucun modèle choisi : au premier lancement, tant que l'accueil n'a pas fait choisir. Rien ne se télécharge sans ce
/// choix ; une explication demandée entre-temps renvoie à l'accueil.
public final class NoEngine: Engine {
    public let modelName = "aucun"
    public let contextBudget = 0

    public init() {}

    public func prepare() async throws {}
    public func prepare(for capture: Capture) async {}
    public func onLoadedChange(_ action: @escaping @Sendable (Bool) -> Void) async {}
    public func onPreparing(_ action: @escaping @Sendable (Double?) -> Void) async {}
    public func unload() async {}

    public func explain(_ capture: Capture) -> AsyncThrowingStream<Explanation, Error> {
        AsyncThrowingStream { $0.finish(throwing: Missing()) }
    }

    struct Missing: LocalizedError {
        var errorDescription: String? { String(localized: "Choisis d'abord un modèle : menu de Hoova, « Terminer l'installation ».") }
    }
}

/// Ce qu'il faut savoir d'un modèle pour le choisir. Mesuré sur un MacBook Air M3 de 16 Go (docs/decisions.md).
public struct ModelFacts: Sendable {
    /// Ce qui se télécharge depuis Hugging Face, en octets ; rien pour un modèle externe.
    public var download: Int64
    /// La place sur le disque une fois prêt, en octets : Hoova ne garde que la partie texte.
    public var disk: Int64
    /// La mémoire prise pendant l'usage, en octets. Un modèle de Hoova la rend après 10 minutes sans usage.
    public var memory: Int64
    /// Le premier mot et la réponse complète, en temps habituel (médiane au banc d'essai, sur des passages courts).
    public var firstWord: Duration
    public var answer: Duration
    /// Le premier mot sur une longue page, avec tout le texte autour que le modèle reçoit (3 000 caractères pour un
    /// modèle de Hoova) ; nil si pas mesuré.
    public var longPageFirstWord: Duration? = nil
    /// La part des cas où il choisit le bon sens d'un mot ambigu (78 cas de la vague 3) ; nil si pas mesuré.
    public var rightSense: Double?
    /// Tout reste sur ce Mac. Sinon, le terme, le passage et le titre partent chez le fournisseur.
    public var isLocal: Bool
}

/// Les modèles de Hoova sur ce Mac : E4B, le plus juste (par défaut), et E2B, plus léger, mais qui se trompe plus souvent
/// (docs/decisions.md). L'utilisateur choisit, sans conseil. Le choix est gardé dans les préférences.
public enum LocalChoice: String, CaseIterable, Sendable {
    case e4b = "mlx-community/gemma-4-e4b-it-4bit"
    case e2b = "mlx-community/gemma-4-e2b-it-4bit"

    public static let key = "localModel"

    public static var chosen: LocalChoice {
        UserDefaults.standard.string(forKey: key).flatMap(LocalChoice.init(rawValue:)) ?? .e4b
    }

    public var name: String { self == .e4b ? "Gemma 4 E4B" : "Gemma 4 E2B" }

    /// La version exacte du modèle sur Hugging Face, la dernière publiée (6 juillet 2026) : Hoova télécharge toujours les
    /// fichiers mesurés au banc, même si le dépôt change ensuite (docs/decisions.md, 10 novembre 2026).
    public var revision: String {
        switch self {
        case .e4b: "475b9088d29754a3379866cf5aeb6b41acd313c2"
        case .e2b: "238767527555cb75a05732a84dff5d6ba0dd6809"
        }
    }

    /// Téléchargement : les fichiers publiés sur Hugging Face, relevés le 2 novembre 2026. Sur une longue page : E4B
    /// mesuré sur secteur le 10 novembre (docs/decisions.md) ; E2B pas encore.
    public var facts: ModelFacts {
        switch self {
        case .e4b:
            ModelFacts(
                download: 5_179_241_512, disk: 4_200_000_000, memory: 2_700_000_000, firstWord: .milliseconds(400),
                answer: .milliseconds(1_500), longPageFirstWord: .milliseconds(2_000), rightSense: 0.87, isLocal: true)
        case .e2b:
            ModelFacts(
                download: 3_583_088_661, disk: 2_630_000_000, memory: 1_540_000_000, firstWord: .milliseconds(210),
                answer: .milliseconds(890), rightSense: 0.76, isLocal: true)
        }
    }

    /// Ce que pèse le téléchargement depuis Hugging Face (« 5,18 Go »). Hoova n'en garde que la partie texte.
    public var downloadSize: String { ByteCountFormatter.string(fromByteCount: facts.download, countStyle: .file) }

    /// La place libre qu'il faut pour le préparer, en octets : la suite du téléchargement, et le dossier allégé écrit à
    /// côté avant que le téléchargement soit effacé ; rien s'il est déjà prêt.
    public var spaceNeeded: Int64 {
        guard !LocalModel.isReady(rawValue) else { return 0 }
        let download = LocalModel.hasSharedCopy(rawValue) ? 0 : facts.download - LocalModel.downloaded(rawValue)
        return download + facts.disk + 500_000_000
    }
}

extension Provider {
    /// Mesuré avec Gemini 3.5 Flash-Lite et l'offre gratuite (docs/decisions.md) ; les autres fournisseurs ne sont pas
    /// encore essayés, et le premier mot dépend du réseau.
    public static let facts = ModelFacts(
        download: 0, disk: 0, memory: 29_000_000, firstWord: .milliseconds(550), answer: .milliseconds(665),
        rightSense: nil, isLocal: false)
}

/// Les fournisseurs de modèles externes. Chacun a un modèle par défaut : le plus rapide et le moins cher qu'il propose
/// (pages officielles, 2 novembre 2026). On peut en choisir un autre.
public enum Provider: String, CaseIterable, Sendable {
    case openAI = "openai", anthropic, gemini, mistral, ollama

    public var name: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .mistral: "Mistral"
        case .ollama: "Ollama"
        }
    }

    public var defaultModel: String {
        switch self {
        case .openAI: "gpt-6-luna"
        case .anthropic: "claude-haiku-5-5"
        case .gemini: "gemini-3.5-flash-lite"
        case .mistral: "mistral-small-latest"
        case .ollama: "gemma4:e4b"
        }
    }

    /// Ollama fait tourner le modèle sur ce Mac, sans clé ; les autres reçoivent le texte lu.
    public var isLocal: Bool { self == .ollama }

    // MARK: - Le réglage

    /// Le réglage : le fournisseur choisi, ou rien pour le modèle local de Hoova. `HOOVA_ENGINE` le remplace, pour le
    /// banc d'essai (avec `HOOVA_API_KEY` pour la clé).
    public static let key = "engine"

    public static var chosen: Provider? {
        (ProcessInfo.processInfo.environment["HOOVA_ENGINE"] ?? UserDefaults.standard.string(forKey: key))
            .flatMap(Provider.init(rawValue:))
    }

    /// Le modèle choisi chez ce fournisseur.
    public var model: String {
        get { UserDefaults.standard.string(forKey: "\(Self.key).\(rawValue).model") ?? defaultModel }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: "\(Self.key).\(rawValue).model") }
    }

    /// La clé API, rangée dans le trousseau de macOS : jamais dans les réglages ni dans les journaux. `HOOVA_API_KEY` la
    /// remplace, pour le banc d'essai.
    public var apiKey: String? {
        get {
            if let key = ProcessInfo.processInfo.environment["HOOVA_API_KEY"] { return key }
            var query = keychainQuery
            query[kSecReturnData as String] = true
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
        nonmutating set {
            SecItemDelete(keychainQuery as CFDictionary)
            guard let newValue else { return }
            var item = keychainQuery
            item[kSecValueData as String] = Data(newValue.utf8)
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.teayouness.hoova.api",
            kSecAttrAccount as String: rawValue,
        ]
    }
}
