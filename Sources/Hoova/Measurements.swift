import Foundation
import HoovaCore
import NaturalLanguage
import os

/// Les temps de chaque explication, une ligne JSON par explication et sans aucun texte lu, dans
/// ~/Library/Application Support/Hoova/mesures.jsonl : pour suivre la médiane et le pire cas sur plusieurs jours.
enum Measurements {
    private struct Entry: Encodable {
        let date: Date
        let method: String
        let termLength: Int
        let contextLength: Int
        /// Le contexte vient de la lecture faite au moment de la sélection.
        let contextFromSelection: Bool
        let hasTitle: Bool
        let source: String
        let uncertain: Bool
        /// Le modèle avait lu le prompt dès la sélection, ou dès le premier ⌃.
        let prepared: Bool
        /// La lecture du texte avait commencé au premier ⌃.
        let startedAtFirstTap: Bool
        let readMs: Double
        let firstWordMs: Double?
        let totalMs: Double
        let promptTokens: Int?
        let generatedTokens: Int?
        let promptMs: Double?
        let generateMs: Double?
        let switches: [String]
    }

    static func record(
        capture: Capture, explanation: Explanation, startedAtFirstTap: Bool, read: Duration, firstWord: Duration?,
        total: Duration
    ) {
        let stats = explanation.stats
        LocalFile.append(
            Entry(
                date: .now, method: capture.method.rawValue, termLength: capture.term.count,
                contextLength: capture.context.count, contextFromSelection: capture.contextFromSelection,
                hasTitle: capture.title != nil,
                source: explanation.source.rawValue, uncertain: explanation.uncertain,
                prepared: explanation.wasPrepared, startedAtFirstTap: startedAtFirstTap,
                readMs: read.milliseconds, firstWordMs: firstWord?.milliseconds, totalMs: total.milliseconds,
                promptTokens: stats?.promptTokens, generatedTokens: stats?.generatedTokens,
                promptMs: stats.map { $0.promptTime * 1000 }, generateMs: stats.map { $0.generateTime * 1000 },
                switches: Switches.active),
            to: "mesures.jsonl")
    }
}

/// Les vrais cas de l'utilisateur, ajoutés automatiquement en mode test, au format du banc d'essai, dans
/// ~/Library/Application Support/Hoova/cas-perso.jsonl. Ils restent sur le Mac ; le sens attendu est à remplir.
enum BenchCases {
    /// Le dernier cas enregistré : un même ⌃⌃ répété sur la même sélection ne l'ajoute qu'une fois.
    private static var lastKey: String?

    private struct Case: Encodable {
        let id: String
        let source: String
        let term: String
        let context: String
        let title: String?
        let textLanguage: String?
        let readerLanguage: String
        let expected: String
        let difficulty: String
        let method: String
        let hoovaAnswer: String
    }

    static func save(_ capture: Capture, answer: String) {
        let key = "\(capture.term)|\(capture.context)"
        guard key != lastKey else { return }
        lastKey = key
        LocalFile.append(
            Case(
                id: "perso-\(Int(Date.now.timeIntervalSince1970))", source: "perso", term: capture.term,
                context: capture.context, title: capture.title,
                textLanguage: NLLanguageRecognizer.dominantLanguage(for: capture.context)?.rawValue,
                readerLanguage: "fr", expected: "", difficulty: "", method: capture.method.rawValue,
                hoovaAnswer: answer),
            to: "cas-perso.jsonl")
    }
}

/// Ajoute une ligne JSON à un fichier de ~/Library/Application Support/Hoova, hors du fil principal.
private enum LocalFile {
    static func append(_ value: some Encodable, to name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? encoder.encode(value) else { return }
        line.append(0x0A)
        let data = line
        Task.detached(priority: .utility) { write(data, to: name) }
    }

    nonisolated private static func write(_ line: Data, to name: String) {
        do {
            let folder = URL.applicationSupportDirectory.appending(path: "Hoova", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: name)
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            Logger(subsystem: "com.teayouness.hoova", category: "mesures")
                .error("Écriture de \(name, privacy: .public) impossible : \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}
