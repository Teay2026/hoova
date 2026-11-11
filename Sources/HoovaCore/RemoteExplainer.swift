import AnyLanguageModel
import Foundation
import Synchronization
import os

private let log = Logger(subsystem: "com.teayouness.hoova", category: "modèle")

/// Explique un terme avec un modèle externe (OpenAI, Anthropic, Gemini, Mistral, ou Ollama sur ce Mac), par
/// AnyLanguageModel. Rien à télécharger ni à garder en mémoire, mais le terme, le passage et le titre partent chez le
/// fournisseur. Les consignes, le prompt et la langue sont ceux du modèle local.
public final class RemoteExplainer: Engine {
    public let modelName: String
    public let contextBudget = budgetSetting(default: 12_000)
    private let provider: Provider
    private let modelID: String
    private let model: any LanguageModel
    /// Toutes les demandes au fournisseur passent par cette session : la connexion ouverte au premier ⌃ sert au second.
    private let session: URLSession
    /// L'adresse du fournisseur, à joindre d'avance. Nil pour Ollama, sur ce Mac.
    private let address: URL?
    /// La dernière connexion ouverte d'avance : une toutes les 20 secondes au plus.
    private let warmedUp = Mutex<ContinuousClock.Instant?>(nil)

    private static let mistral = URL(string: "https://api.mistral.ai/v1/")!

    public init(provider: Provider, model: String, apiKey: String) {
        self.provider = provider
        modelID = model
        modelName = "\(model) (\(provider.name))"
        let session = URLSession(configuration: .default)
        self.session = session
        self.model =
            switch provider {
            case .openAI: OpenAILanguageModel(apiKey: apiKey, model: model, transport: session)
            case .anthropic: AnthropicLanguageModel(apiKey: apiKey, model: model, transport: session)
            case .gemini: GeminiLanguageModel(apiKey: apiKey, model: model, transport: session)
            case .mistral: OpenAILanguageModel(baseURL: Self.mistral, apiKey: apiKey, model: model, transport: session)
            case .ollama: OllamaLanguageModel(model: model, transport: session)
            }
        address =
            switch provider {
            case .openAI: OpenAILanguageModel.defaultBaseURL
            case .anthropic: AnthropicLanguageModel.defaultBaseURL
            case .gemini: GeminiLanguageModel.defaultBaseURL
            case .mistral: Self.mistral
            case .ollama: nil
            }
    }

    /// Les mêmes limites que le modèle local : une réponse courte, la plus probable. Les modèles récents d'OpenAI
    /// refusent une température fixée : ils gardent la leur.
    private var options: GenerationOptions {
        GenerationOptions(temperature: provider == .openAI ? nil : 0, maximumResponseTokens: 110)
    }

    /// Ouvre la connexion au fournisseur dès le premier ⌃ : au second, la demande part sans attendre la connexion ni le
    /// chiffrement (TLS), soit 25 à 100 ms de moins sur une bonne connexion (docs/decisions.md, 10 novembre 2026). Rien
    /// ne part ici, ni le texte lu ni la clé : une simple demande HEAD à l'adresse du service, dont la réponse est
    /// ignorée.
    public func prepare() async throws {
        guard let address else { return }
        let now = ContinuousClock.now
        let due = warmedUp.withLock { last in
            guard last.map({ now - $0 > .seconds(20) }) ?? true else { return false }
            last = now
            return true
        }
        guard due else { return }
        var request = URLRequest(url: address, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        // Sans attendre : ne retarde ni le chargement, ni le premier ⌃.
        Task { [session] in
            _ = try? await session.data(for: request)
            log.notice(
                "Connexion à \(address.host() ?? "?", privacy: .public) ouverte d'avance en \(ContinuousClock.now - now, privacy: .public)"
            )
        }
    }

    public func prepare(for capture: Capture) async { try? await prepare() }
    public func onLoadedChange(_ action: @escaping @Sendable (Bool) -> Void) async { action(true) }
    public func onPreparing(_ action: @escaping @Sendable (Double?) -> Void) async {}
    public func unload() async {}

    public func explain(_ capture: Capture) -> AsyncThrowingStream<Explanation, Error> {
        let grounding = Grounding.find(for: capture)
        let prompt = Prompts.prompt(
            for: capture, grounding: grounding, language: ExplanationLanguage.code(for: capture), budget: contextBudget)
        let (model, options) = (model, options)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Une session par explication : chaque terme s'explique seul, sans l'historique des précédents.
                    let session = LanguageModelSession(model: model, instructions: Prompts.instructions)
                    var raw = ""
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        raw = snapshot.content
                        let (text, uncertain) = Prompts.split(raw)
                        continuation.yield(Explanation(text: text, source: .model, uncertain: uncertain, isFinal: false))
                    }
                    let (text, uncertain) = Prompts.split(raw)
                    continuation.yield(
                        Explanation(
                            text: text, source: grounding.source(of: text, term: capture.term), uncertain: uncertain,
                            isFinal: true))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: self.readable(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Vérifie la clé et le modèle par une toute petite demande, avant de les garder.
    public func check() async throws {
        do {
            _ = try await LanguageModelSession(model: model)
                .respond(to: "Reply with: OK", options: GenerationOptions(maximumResponseTokens: 16))
        } catch {
            throw readable(error)
        }
    }

    /// Une phrase claire à la place de l'erreur technique : c'est elle que montre le pop-up.
    private func readable(_ error: Error) -> Error {
        if error is CancellationError { return error }
        let name = provider.name
        if let network = (error as? URLError) ?? ((error as? HTTPTransportError)?.underlyingError as? URLError) {
            if provider.isLocal, network.code == .cannotConnectToHost {
                return Failure("Ollama ne répond pas : ouvre-le sur ce Mac, puis réessaie.")
            }
            return Failure("Pas de connexion à Internet : \(name) est injoignable.")
        }
        guard let status = (error as? HTTPTransportError)?.response?.status.code else { return error }
        return switch status {
        case 401, 403: Failure("\(name) refuse la clé API.")
        case 402: Failure("Le crédit est épuisé chez \(name).")
        case 404: Failure("Le modèle « \(modelID) » n'existe pas chez \(name).")
        case 429: Failure("\(name) refuse pour l'instant : trop de demandes, ou crédit épuisé.")
        case 500...599: Failure("\(name) ne répond pas pour l'instant.")
        default: Failure("\(name) a renvoyé une erreur (\(status)).")
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String.LocalizationValue) { errorDescription = String(localized: message) }
    }
}
