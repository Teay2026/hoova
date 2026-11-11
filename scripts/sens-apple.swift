// Duel des modèles (vague 4), candidat « modèle intégré à macOS » : le modèle d'Apple Intelligence choisit le sens
// parmi les candidats, avec une génération guidée qui ne peut rendre qu'un numéro. Rien à télécharger : macOS gère le
// modèle. Le framework ne donne pas les probabilités : pas de mesure de la confiance.
//
// Usage : swift scripts/sens-apple.swift [bench/cas-sens.json]
import Foundation
import FoundationModels

struct Sense: Decodable {
    let title: String
    let description: String
}

struct Case: Decodable {
    let id: String
    let term: String
    let context: String
    let textLanguage: String
    let senses: [Sense]
    let answer: Int
}

@Generable
struct Choice {
    @Guide(description: "Le numéro du sens du terme dans ce passage", .range(1 ... 9))
    let number: Int
}

let model = SystemLanguageModel.default
guard case .available = model.availability else {
    print("Modèle d'Apple indisponible : \(model.availability)")
    exit(1)
}
let path = CommandLine.arguments.dropFirst().first ?? "bench/cas-sens.json"
let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: path)))

func prompt(_ item: Case) -> String {
    let options = item.senses.enumerated().map { "\($0.offset + 1). \($0.element.description)" }.joined(separator: "\n")
    return "Passage : « \(item.context) »\nTerme : « \(item.term) »\nSens possibles :\n\(options)\n\n"
        + "Quel est le sens du terme dans ce passage ? Réponds par le numéro."
}

var results: [String: (correct: Int, total: Int)] = [:]
var times: [Double] = []
var failures = 0
for item in cases {
    let session = LanguageModelSession()
    let start = ContinuousClock.now
    do {
        let choice = try await session.respond(
            to: prompt(item), generating: Choice.self, options: GenerationOptions(sampling: .greedy))
        let elapsed = ContinuousClock.now - start
        times.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        var score = results[item.textLanguage] ?? (0, 0)
        score.total += 1
        if choice.content.number - 1 == item.answer { score.correct += 1 }
        results[item.textLanguage] = score
        print("\(item.id) \(choice.content.number - 1 == item.answer ? "✓" : "✗") \(Int(times.last!)) ms")
    } catch {
        failures += 1
        print("\(item.id) erreur : \(error)")
    }
}

let correct = results.values.map(\.correct).reduce(0, +)
let total = results.values.map(\.total).reduce(0, +)
times.sort()
print("Modèle d'Apple : \(correct)/\(total) bons sens (\(Int((100 * Double(correct) / Double(max(total, 1))).rounded())) %), \(failures) erreurs")
if !times.isEmpty {
    print("Temps par cas : médiane \(Int(times[times.count / 2])) ms, pire cas courant \(Int(times[Int(0.95 * Double(times.count - 1))])) ms")
}
for (language, score) in results.sorted(by: { $0.key < $1.key }) {
    print("  \(language) : \(score.correct)/\(score.total)")
}
