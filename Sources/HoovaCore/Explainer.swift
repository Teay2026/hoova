import CryptoKit
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
import os

private let log = Logger(subsystem: "com.teayouness.hoova", category: "modèle")

/// D'où vient l'explication — affiché dans le pop-up.
public enum Source: String, Sendable {
    case document = "Document"
    case dictionary = "Dictionnaire"
    case model = "IA"
}

public struct Explanation: Sendable, Equatable {
    public var text: String
    public var source: Source
    /// Le modèle a dit qu'il n'était pas sûr.
    public var uncertain: Bool
    public var isFinal: Bool
    /// Ce que le modèle a lu et écrit, sur la version finale d'une réponse qu'il vient d'écrire.
    public var stats: GenerationStats? = nil
    /// Le modèle avait lu le prompt dès la sélection : il n'a eu qu'à écrire.
    public var wasPrepared = false
}

/// Ce que le modèle a lu (la fin du prompt, après les consignes en cache) et écrit, et en combien de temps.
public struct GenerationStats: Sendable, Equatable {
    public var promptTokens: Int
    public var generatedTokens: Int
    public var promptTime: TimeInterval
    public var generateTime: TimeInterval
}

/// Explique un terme dans son contexte, en local, avec un modèle MLX (Gemma 4 E4B par défaut).
///
/// Le modèle lit les consignes une seule fois, au chargement : leur cache est copié pour chaque
/// explication, qui n'a plus qu'à lire le passage. C'est ce qui rend le premier mot rapide.
public actor Explainer {
    public nonisolated let modelName: String
    public nonisolated let contextBudget = budgetSetting(default: 3_000)
    private let configuration: ModelConfiguration
    private var loading: Task<Loaded, Error>?
    private let cachesAnswers: Bool
    private var cache: [String: Explanation] = [:]
    /// La réponse préparée pour la dernière sélection, avec le prompt qu'elle a lu.
    private var preparation: (prompt: String, task: Task<Prepared?, Never>)?
    /// Le dernier usage du modèle : après `idleDelay` sans explication ni préparation, il quitte la mémoire, et revient
    /// au geste suivant. `HOOVA_IDLE_SECONDS` change le délai (essais).
    private var lastUse = ContinuousClock.now
    private var idleWatch: Task<Void, Never>?
    /// Le modèle a déjà été chargé une fois dans ce processus : les shaders sont compilés.
    private var warmedUp = false
    /// Prévenu quand le modèle entre en mémoire (vrai) et quand il la quitte après une pause (faux).
    private var loadedChange: (@Sendable (Bool) -> Void)?
    /// Prévenu de l'avancement de la préparation au premier lancement (de 0 à 1), puis de sa fin (nil).
    private var preparingChange: (@Sendable (Double?) -> Void)?
    /// Les notes que le modèle tire de ses consignes, gardées d'un chargement à l'autre.
    private static let cacheFolder = URL.applicationSupportDirectory.appending(
        path: "Hoova/Cache", directoryHint: .isDirectory)
    private static let idleDelay = Duration.seconds(
        Int(ProcessInfo.processInfo.environment["HOOVA_IDLE_SECONDS"] ?? "") ?? 10 * 60)

    private static let parameters = GenerateParameters(maxTokens: 110, temperature: 0)

    private struct Loaded: Sendable {
        let container: ModelContainer
        let instructions: InstructionsCache
        /// La mémoire du modèle, verrouillée tant qu'il est chargé (Mac de 16 Go et plus).
        let wired: WiredMemoryTicket?
    }

    /// - Parameter cachesAnswers: garder les réponses pour les redonner aussitôt ; le banc d'essai le coupe
    ///   pour mesurer chaque passage.
    public init(configuration: ModelConfiguration = LLMRegistry.gemma4_e4b_it_4bit, cachesAnswers: Bool = true) {
        self.configuration = configuration
        self.cachesAnswers = cachesAnswers
        modelName = configuration.name
    }

    /// Le modèle de Hoova choisi pour ce Mac.
    public init(local choice: LocalChoice, cachesAnswers: Bool = true) {
        self.init(
            configuration: choice == .e4b ? LLMRegistry.gemma4_e4b_it_4bit : LLMRegistry.gemma4_e2b_it_4bit,
            cachesAnswers: cachesAnswers)
    }

    /// Charge le modèle, lui fait lire les consignes et compile ses shaders Metal (quelques secondes, une fois).
    public func prepare() async throws {
        _ = try await loaded()
    }

    /// `action` est appelé quand le modèle entre en mémoire (vrai) et quand il la quitte après une pause (faux).
    public func onLoadedChange(_ action: @escaping @Sendable (Bool) -> Void) {
        loadedChange = action
    }

    /// `action` reçoit l'avancement de la préparation du modèle au premier lancement (téléchargement, dossier,
    /// chargement), de 0 à 1, puis nil quand elle est finie. Rien quand le modèle est déjà prêt sur le disque.
    public func onPreparing(_ action: @escaping @Sendable (Double?) -> Void) {
        preparingChange = action
    }

    /// Prépare l'explication d'une sélection dès qu'elle est faite : le modèle lit son prompt tout de suite, et
    /// le double ⌃ n'aura plus qu'à écrire. Une nouvelle préparation remplace la précédente.
    public func prepare(for capture: Capture) async {
        lastUse = .now
        guard let loaded = try? await loaded() else { return }
        let grounding = Grounding.find(for: capture)
        let user = Prompts.prompt(
            for: capture, grounding: grounding, language: ExplanationLanguage.code(for: capture), budget: contextBudget)
        guard preparation?.prompt != user else { return }
        let instructions = loaded.instructions
        let task = Task<Prepared?, Never> {
            try? await loaded.container.perform { context in
                let (input, kv) = try instructions.input(
                    for: Self.tokens(context, user: user), context: context, parameters: Self.parameters)
                // L'itérateur lit tout le prompt dès sa création : il ne restera qu'à écrire.
                let iterator = try TokenIterator(
                    input: input, model: context.model, cache: kv, parameters: Self.parameters)
                return Prepared(promptTokens: input.text.tokens.size, iterator: iterator)
            }
        }
        preparation = (user, task)
    }

    /// L'explication, envoyée au fur et à mesure qu'elle s'écrit.
    public nonisolated func explain(_ capture: Capture) -> AsyncThrowingStream<Explanation, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(capture) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func loaded() async throws -> Loaded {
        if let loading { return try await loading.value }
        let configuration = configuration
        let start = ContinuousClock.now
        // Les shaders compilés au premier chargement restent prêts : au rechargement, pas besoin de réponse d'essai.
        let warmUp = !warmedUp
        let report = preparingChange
        let task = Task {
            let clock = ContinuousClock()
            let container = try await Self.loadContainer(configuration) { report?($0) }
            let weightsDone = clock.now
            let instructions = try await container.perform { context in
                try InstructionsCache(context: context, parameters: Self.parameters, folder: Self.cacheFolder)
            }
            let instructionsDone = clock.now
            if warmUp {
                try await container.perform { context in
                    // Une courte génération à blanc compile les shaders du décodage.
                    let (input, kv) = try instructions.input(
                        for: Self.tokens(context, user: Prompts.probe("test")), context: context,
                        parameters: Self.parameters)
                    for await _ in try generate(
                        input: input, cache: kv, parameters: GenerateParameters(maxTokens: 2, temperature: 0),
                        context: context)
                    {}
                }
            }
            log.notice(
                "Étapes du chargement : poids \(weightsDone - start, privacy: .public), consignes \(instructionsDone - weightsDone, privacy: .public) (\(instructions.fromDisk ? "relues sur le disque" : "\(instructions.tokens.count) jetons lus", privacy: .public)), réponse d'essai \(warmUp ? "\(clock.now - instructionsDone)" : "sautée", privacy: .public)"
            )
            // Les poids restent en mémoire vive. Sinon, après une pause, macOS les compresse ou les envoie dans le
            // swap, et le premier mot attend plusieurs secondes (docs/decisions.md). Seulement à partir de 16 Go :
            // en dessous, immobiliser plusieurs Go étoufferait les autres apps.
            var wired: WiredMemoryTicket?
            if ProcessInfo.processInfo.physicalMemory >= 16 << 30 {
                let ticket = WiredMemoryTicket(size: Memory.activeMemory, policy: MLX.WiredSumPolicy())
                _ = await ticket.start()
                wired = ticket
            }
            return Loaded(container: container, instructions: instructions, wired: wired)
        }
        loading = task
        defer { preparingChange?(nil) }
        do {
            let value = try await task.value
            warmedUp = true
            loadedChange?(true)
            log.notice("Modèle chargé en \(ContinuousClock.now - start, privacy: .public)")
            lastUse = .now
            watchIdle()
            return value
        } catch {
            loading = nil
            throw error
        }
    }

    /// Le modèle, depuis le dossier allégé de Hoova quand il a une grande table par couche (Gemma 4 E2B et E4B) : la
    /// table reste dans son fichier et n'est jamais chargée, les parties son et image ne sont jamais lues. Les autres
    /// modèles se chargent tels que publiés.
    private static func loadContainer(
        _ configuration: ModelConfiguration, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ModelContainer {
        guard configuration.name.contains("/"),
            let directory = try await LocalModel.directory(for: configuration.name, progress: progress)
        else { return try await #huggingFaceLoadModelContainer(configuration: configuration) }
        await MappedEmbedding.register(file: directory.appending(path: MappedEmbedding.fileName))
        return try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(directory: directory, extraEOSTokens: configuration.extraEOSTokens))
    }

    /// Décharge le modèle quand il n'a pas servi depuis `idleDelay` : Hoova ne garde alors presque rien en mémoire.
    private func watchIdle() {
        idleWatch?.cancel()
        idleWatch = Task { [weak self] in
            while let self, !Task.isCancelled {
                let deadline = await self.lastUse + Self.idleDelay
                try? await Task.sleep(until: deadline, clock: .continuous)
                if Task.isCancelled { return }
                if await self.unloadIfIdle() { return }
            }
        }
    }

    /// Décharge le modèle tout de suite, comme après une pause : le banc d'essai mesure ainsi la reprise.
    public func unload() async {
        idleWatch?.cancel()
        idleWatch = nil
        guard loading != nil else { return }
        await release()
        Memory.clearCache()
        loadedChange?(false)
    }

    /// Vrai quand le guet peut s'arrêter : modèle déchargé, ou plus rien à décharger.
    private func unloadIfIdle() async -> Bool {
        guard loading != nil else { return true }
        guard ContinuousClock.now - lastUse >= Self.idleDelay else { return false }
        await release()
        // Les poids ne sont plus référencés : MLX rend sa réserve à macOS.
        Memory.clearCache()
        loadedChange?(false)
        log.notice("Modèle déchargé après \(Self.idleDelay, privacy: .public) sans usage")
        return true
    }

    /// Oublie le modèle et déverrouille sa mémoire. Les références disparaissent à la fin de la fonction. Un chargement
    /// en cours (un téléchargement, par exemple quand on change de modèle) s'arrête ; il reprendra la prochaine fois.
    private func release() async {
        let current = loading
        loading = nil
        preparation = nil
        current?.cancel()
        if let loaded = try? await current?.value { _ = await loaded.wired?.end() }
    }

    private func run(_ capture: Capture, emit: @escaping @Sendable (Explanation) -> Void) async throws {
        lastUse = .now
        let language = ExplanationLanguage.code(for: capture)
        let around = [capture.beginning, capture.before, capture.after].map { $0 ?? "" }
        let key = "\(language)|\(capture.term.lowercased())|\(capture.context.hashValue)|\(around.hashValue)"
        if cachesAnswers, let cached = cache[key] {
            emit(cached)
            return
        }
        let loaded = try await loaded()
        let grounding = Grounding.find(for: capture)
        let user = Prompts.prompt(for: capture, grounding: grounding, language: language, budget: contextBudget)
        let instructions = loaded.instructions
        // La réponse préparée dès la sélection, si elle a lu exactement ce prompt : il ne reste qu'à écrire.
        var prepared: Prepared?
        if let pending = preparation, pending.prompt == user { prepared = await pending.task.value }
        preparation = nil
        let ready = prepared

        let (raw, stats) = try await loaded.container.perform { context in
            let stream: AsyncStream<Generation>
            if let ready {
                stream = generateTask(
                    promptTokenCount: ready.promptTokens, modelConfiguration: context.configuration,
                    tokenizer: context.tokenizer, iterator: ready.iterator
                ).0
            } else {
                let (input, kv) = try instructions.input(
                    for: Self.tokens(context, user: user), context: context, parameters: Self.parameters)
                stream = try generate(input: input, cache: kv, parameters: Self.parameters, context: context)
            }
            var raw = ""
            var stats: GenerationStats?
            for await generation in stream {
                if Task.isCancelled { break }
                switch generation {
                case .chunk(let chunk):
                    raw += chunk
                    let (text, uncertain) = Prompts.split(raw)
                    emit(Explanation(text: text, source: .model, uncertain: uncertain, isFinal: false))
                case .info(let info):
                    stats = GenerationStats(
                        promptTokens: info.promptTokenCount, generatedTokens: info.generationTokenCount,
                        promptTime: info.promptTime, generateTime: info.generateTime)
                default:
                    break
                }
            }
            return (raw, stats)
        }
        try Task.checkCancellation()

        let (text, uncertain) = Prompts.split(raw)
        let final = Explanation(
            text: text, source: grounding.source(of: text, term: capture.term),
            uncertain: uncertain, isFinal: true, stats: stats, wasPrepared: ready != nil)
        if cachesAnswers { cache[key] = final }
        emit(final)
    }

    fileprivate static func tokens(_ context: ModelContext, user: String) throws -> [Int] {
        try context.tokenizer.applyChatTemplate(messages: [
            ["role": "system", "content": Prompts.instructions],
            ["role": "user", "content": user],
        ])
    }
}

/// Une réponse préparée dès la sélection : le modèle a lu son prompt, l'itérateur n'a plus qu'à écrire.
/// Elle n'est utilisée que dans `ModelContainer.perform`, qui sérialise les accès au modèle.
private final class Prepared: @unchecked Sendable {
    let promptTokens: Int
    let iterator: TokenIterator

    init(promptTokens: Int, iterator: TokenIterator) {
        self.promptTokens = promptTokens
        self.iterator = iterator
    }
}

/// Le cache KV des consignes : ce que le modèle tire du texte fixe qui précède chaque passage. Calculé une fois, puis
/// gardé sur le disque : un rechargement le relit au lieu de le recalculer (0,7 s de moins). Il n'est lu et copié que
/// dans `ModelContainer.perform`, qui sérialise les accès au modèle.
private final class InstructionsCache: @unchecked Sendable {
    /// Les jetons communs à tous les prompts : les consignes, puis le début de la première ligne, avant le titre.
    let tokens: [Int]
    /// Les notes viennent du disque.
    let fromDisk: Bool
    private let kv: [KVCache]

    init(context: ModelContext, parameters: GenerateParameters, folder: URL) throws {
        // Le début du titre peut former un seul jeton avec le guillemet qui l'ouvre : un titre vide, ou qui commence par
        // une ponctuation (« (3) Boîte de réception »). Les jetons communs à ces titres s'arrêtent avant le guillemet et
        // valent pour tous ; sinon, le modèle relirait ses consignes (docs/decisions.md, 9 novembre 2026).
        let probes = try ["a", "b", "", "("].map { try Explainer.tokens(context, user: Prompts.probe($0)) }
        let shared = probes.map { probe in zip(probes[0], probe).prefix { $0 == $1 }.count }.min() ?? 0
        tokens = Array(probes[0].prefix(shared))
        let fresh = try context.model.newCache(parameters: parameters)
        // Le fichier dépend du modèle et des jetons exacts des consignes : s'ils changent, il ne sert plus.
        let key = SHA256.hash(data: Data("\(context.configuration.name)|\(tokens)".utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let file = folder.appending(path: "consignes-\(key).safetensors")
        if let (saved, metadata) = try? loadPromptCache(url: file), saved.count == fresh.count,
            metadata["tokens"] == "\(tokens.count)"
        {
            kv = saved
            fromDisk = true
        } else {
            kv = fresh
            fromDisk = false
            // L'itérateur lit tout le prompt dès sa création : le cache contient alors exactement les consignes.
            _ = try TokenIterator(
                input: LMInput(tokens: MLXArray(tokens)), model: context.model, cache: kv, parameters: parameters)
        }
        eval(kv.flatMap(\.state))
        if !fromDisk {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? savePromptCache(url: file, cache: kv, metadata: ["tokens": "\(tokens.count)"])
        }
    }

    /// Ce qu'il reste à lire au modèle : la fin du prompt, avec une copie du cache des consignes.
    func input(for prompt: [Int], context: ModelContext, parameters: GenerateParameters) throws -> (LMInput, [KVCache]) {
        guard prompt.count > tokens.count, prompt.starts(with: tokens) else {
            return (LMInput(tokens: MLXArray(prompt)), try context.model.newCache(parameters: parameters))
        }
        return (LMInput(tokens: MLXArray(Array(prompt[tokens.count...]))), kv.map { $0.copy() })
    }
}
