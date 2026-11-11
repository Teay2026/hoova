import Foundation
import HoovaCore
import MLXLMCommon

// Banc d'essai : explique les cas d'un fichier, mesure chaque étape et écrit un rapport JSON.
//
// Usage : HoovaBench [--cases fichier]… [--model identifiant] [--runs N] [--cold N] [--label nom] [--out fichier]
//   --cases  fichier de cas, .json (une liste) ou .jsonl (un cas par ligne), à répéter pour en lire plusieurs ;
//            par défaut bench/cas.json
//   --model  identifiant Hugging Face du modèle (par défaut : Gemma 4 E4B, 4 bits)
//   --runs   nombre de passages sur tous les cas (par défaut 1)
//   --cold   ne lance que les N premiers cas, une fois, chacun sur un Mac « froid » : avant chacun, on remplit
//            la mémoire, comme après une longue pause
//   --cold-free  part de mémoire libre visée en remplissant la mémoire, en % (par défaut 25)
//   --prepare MS  prépare chaque réponse comme au moment de la sélection, puis attend MS millisecondes (le temps
//                 du geste) avant de la demander
//   --pause MS  attend MS millisecondes entre deux cas (les offres gratuites des modèles externes limitent les
//            demandes par minute)
//   --label  nom de la série, recopié dans le rapport
//   --out    rapport JSON (par défaut bench/resultats/<date>.json)
// Fermer Hoova avant : le banc charge son propre exemplaire du modèle.

/// Un cas du banc d'essai. Les champs en plus (par exemple la réponse de Hoova) sont ignorés.
struct BenchCase: Codable {
    var id: String
    var source: String?
    var term: String
    var context: String
    var title: String?
    var document: String?
    /// Le texte autour du passage : le début du document, le texte juste avant et juste après.
    var beginning: String?
    var before: String?
    var after: String?
    var textLanguage: String?
    var readerLanguage: String?
    /// Le sens attendu, en une phrase : il sert à noter la réponse.
    var expected: String?
    var difficulty: String?
}

struct Row: Codable {
    var id: String
    var run: Int
    var cold: Bool
    var term: String
    var expected: String?
    var answer: String
    var source: String
    var uncertain: Bool
    var firstWordMs: Double
    var totalMs: Double
    var promptTokens: Int?
    var generatedTokens: Int?
    var promptMs: Double?
    var generateMs: Double?
    /// Le temps passé à remplir la mémoire avant ce cas, sur un Mac « froid ».
    var squeezeMs: Double?
    /// La réponse avait été préparée (option `--prepare`) et le modèle n'a eu qu'à écrire.
    var prepared: Bool
    /// La langue demandée au modèle, celle que macOS reconnaît dans sa réponse, et celle du texte du cas.
    var language: String
    var answerLanguage: String?
    var textLanguage: String?
}

struct Spread: Codable {
    var p50: Double
    var p95: Double
}

struct Report: Codable {
    var label: String?
    /// Les interrupteurs d'essai actifs (variables d'environnement `HOOVA_…`).
    var switches: [String]
    var model: String
    var date: Date
    var machine: String
    var loadMs: Double
    var memoryGB: Double?
    var firstWord: Spread
    var total: Spread
    var rows: [Row]
}

/// Les options de la ligne de commande ; un argument sans option est l'identifiant du modèle (ancienne forme).
func options() -> [String: [String]] {
    var result: [String: [String]] = [:]
    var pending: String?
    for argument in CommandLine.arguments.dropFirst() {
        if argument.hasPrefix("--") {
            pending = String(argument.dropFirst(2))
        } else {
            result[pending ?? "model", default: []].append(argument)
            pending = nil
        }
    }
    return result
}

func loadCases(_ path: String) throws -> [BenchCase] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let decoder = JSONDecoder()
    guard path.hasSuffix(".jsonl") else { return try decoder.decode([BenchCase].self, from: data) }
    return try String(decoding: data, as: UTF8.self)
        .split(separator: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .map { try decoder.decode(BenchCase.self, from: Data($0.utf8)) }
}

/// Deux codes de langue désignent la même langue : « zh-Hans » et « zh », « pt » et « pt ».
func sameLanguage(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return a.prefix(2) == b.prefix(2)
}

func ms(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

/// La médiane et le 95e centile (le pire cas courant).
func spread(_ values: [Double]) -> Spread {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return Spread(p50: 0, p95: 0) }
    let p95 = min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)
    return Spread(p50: sorted[(sorted.count - 1) / 2], p95: sorted[max(0, p95)])
}

/// Mémoire réellement occupée par le processus (modèle compris).
func memoryGB() -> Double? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1e9 : nil
}

func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buffer, &size, nil, 0)
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func sysctlInt(_ name: String) -> Int64 {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    sysctlbyname(name, &value, &size, nil, 0)
    return value
}

/// La part de mémoire libre selon macOS, en pourcentage (celle qu'affiche `memory_pressure -Q`).
func freeMemoryPercent() -> Int64 { sysctlInt("kern.memorystatus_level") }

let clock = ContinuousClock()

/// Remplit la mémoire jusqu'à n'en laisser que `freePercent` % de libre, puis la rend : comme après une longue
/// pause, une partie des poids du modèle est alors compressée ou dans le swap. Premier mot mesuré sur le M3 de
/// 16 Go : 1,2 s à 30 %, 5,7 s à 25 %, 15,5 s à 20 %, 26,6 s à 10 %. En vrai, après une pause, on a mesuré
/// 2 à 6,5 s : d'où 25 % par défaut.
func squeezeMemory(freePercent: Int64) async throws -> Duration {
    let start = clock.now
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/memory_pressure")
    process.arguments = ["-p", String(freePercent)]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
        process.terminate()
        process.waitUntilExit()
    }
    while freeMemoryPercent() > freePercent + 2, clock.now - start < .seconds(90) {
        try await Task.sleep(for: .milliseconds(500))
    }
    try await Task.sleep(for: .seconds(3))
    return clock.now - start
}

let settings = options()
let casePaths = settings["cases"] ?? ["bench/cas.json"]
let allCases = try casePaths.flatMap(loadCases)
let coldCount = Int(settings["cold"]?.first ?? "") ?? 0
let cold = coldCount > 0
// Chaque cas « froid » commence par remplir la mémoire (plusieurs secondes) : on s'en tient aux premiers cas.
let cases = cold ? Array(allCases.prefix(coldCount)) : allCases
let runs = cold ? 1 : Int(settings["runs"]?.first ?? "") ?? 1
let coldFree = Int64(settings["cold-free"]?.first ?? "") ?? 25
let prepareDelay = settings["prepare"]?.first.flatMap { Int($0) }
// `--reload` : le modèle est déchargé avant chaque cas, comme après une pause ; le premier mot compte le rechargement.
let reloads = CommandLine.arguments.contains("--reload")
let label = settings["label"]?.first
let pause = settings["pause"]?.first.flatMap { Int($0) }

// `HOOVA_ENGINE=fournisseur` et `HOOVA_API_KEY=…` : un modèle externe, dont `--model` donne alors le nom.
let explainer: any Engine =
    if let provider = Provider.chosen {
        RemoteExplainer(provider: provider, model: settings["model"]?.first ?? provider.model, apiKey: provider.apiKey ?? "")
    } else {
        settings["model"]?.first.map { Explainer(configuration: ModelConfiguration(id: $0), cachesAnswers: false) }
            ?? Explainer(cachesAnswers: false)
    }
let machine = "\(sysctlString("machdep.cpu.brand_string")), \(sysctlInt("hw.memsize") / 1_073_741_824) Go, \(ProcessInfo.processInfo.operatingSystemVersionString)"

print("Modèle : \(explainer.modelName) · \(cases.count) cas · \(runs) passage(s)\(cold ? " à froid" : "") · \(machine)")
print("Essais actifs : \(Switches.active.isEmpty ? "aucun" : Switches.active.joined(separator: ", "))")
let loading = clock.now
try await explainer.prepare()
let loadTime = clock.now - loading
print("Prêt en \(Int(ms(loadTime))) ms · mémoire \(memoryGB().map { String(format: "%.1f Go", $0) } ?? "?")\n")

var rows: [Row] = []
for run in 1...runs {
    for benchCase in cases {
        if reloads { await explainer.unload() }
        let squeeze = cold ? try await squeezeMemory(freePercent: coldFree) : nil

        var capture = Capture(term: benchCase.term, context: benchCase.context, documentText: benchCase.document)
        capture.title = benchCase.title
        (capture.beginning, capture.before, capture.after) = (benchCase.beginning, benchCase.before, benchCase.after)
        let language = ExplanationLanguage.code(for: capture)
        if let prepareDelay {
            await explainer.prepare(for: capture)
            try await Task.sleep(for: .milliseconds(prepareDelay))
        }
        let start = clock.now
        var first: Duration?
        var last: Explanation?
        for try await explanation in explainer.explain(capture) {
            if first == nil, !explanation.text.isEmpty { first = clock.now - start }
            last = explanation
        }
        let total = clock.now - start
        let stats = last?.stats
        let row = Row(
            id: benchCase.id, run: run, cold: cold, term: benchCase.term, expected: benchCase.expected,
            answer: last?.text ?? "", source: last?.source.rawValue ?? "?", uncertain: last?.uncertain ?? false,
            firstWordMs: ms(first ?? total), totalMs: ms(total),
            promptTokens: stats?.promptTokens, generatedTokens: stats?.generatedTokens,
            promptMs: stats.map { $0.promptTime * 1000 }, generateMs: stats.map { $0.generateTime * 1000 },
            squeezeMs: squeeze.map(ms), prepared: last?.wasPrepared ?? false, language: language,
            answerLanguage: ExplanationLanguage.recognize(last?.text ?? ""), textLanguage: benchCase.textLanguage)
        rows.append(row)
        if let pause { try await Task.sleep(for: .milliseconds(pause)) }
        let tokens = stats.map { " · prompt \($0.promptTokens) jetons, écrit \($0.generatedTokens)" } ?? ""
        let written = sameLanguage(row.answerLanguage, language) ? "" : " (réponse en \(row.answerLanguage ?? "?"))"
        print("▸ \(benchCase.id)\(cold ? " (froid)" : "") — premier mot \(Int(row.firstWordMs)) ms, total \(Int(row.totalMs)) ms [\(row.source)]\(tokens) · langue \(language)\(written)")
        print("  → \(row.answer)\n")
    }
}

let report = Report(
    label: label, switches: Switches.active, model: explainer.modelName, date: .now, machine: machine, loadMs: ms(loadTime),
    memoryGB: memoryGB(), firstWord: spread(rows.map(\.firstWordMs)), total: spread(rows.map(\.totalMs)), rows: rows)
let stamp = ISO8601DateFormatter.string(from: .now, timeZone: .current, formatOptions: [.withFullDate, .withTime])
let outPath = settings["out"]?.first ?? "bench/resultats/\(stamp).json"
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
encoder.dateEncodingStrategy = .iso8601
let outURL = URL(fileURLWithPath: outPath)
try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try encoder.encode(report).write(to: outURL)

let inLanguage = rows.filter { sameLanguage($0.answerLanguage, $0.language) }.count
let known = rows.filter { $0.textLanguage != nil }
let recognized = known.filter { sameLanguage($0.textLanguage, $0.language) }.count
print(
    "Langue : \(inLanguage) réponses sur \(rows.count) dans la langue demandée"
        + (ExplanationLanguage.setting == ExplanationLanguage.text
            ? " · langue du texte reconnue \(recognized) fois sur \(known.count)" : ""))
print(
    "Premier mot : médiane \(Int(report.firstWord.p50)) ms, pire cas courant \(Int(report.firstWord.p95)) ms · "
        + "réponse complète : médiane \(Int(report.total.p50)) ms, pire cas courant \(Int(report.total.p95)) ms · "
        + "mémoire \(report.memoryGB.map { String(format: "%.1f Go", $0) } ?? "?")")
print("Rapport : \(outPath)")
