// Duel du « système 1 » (vague 3), candidat « encodeur intégré à macOS » : les plongements de phrases de
// NaturalLanguage comparent le passage à chaque sens candidat, et le plus proche est le choix. Rien à télécharger :
// les modèles font partie de macOS, pour une partie des langues seulement.
//
// Usage : swift scripts/sens-nl.swift [bench/cas-sens.json]
import Foundation
import NaturalLanguage

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

let path = CommandLine.arguments.dropFirst().first ?? "bench/cas-sens.json"
let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
let languages: [String: NLLanguage] = [
    "en": .english, "es": .spanish, "fr": .french, "de": .german, "pt": .portuguese, "it": .italian,
    "zh": .simplifiedChinese, "ja": .japanese,
]

var results: [String: (correct: Int, total: Int)] = [:]
var missing: Set<String> = []
var times: [Double] = []
var chance = 0.0
for item in cases {
    guard let language = languages[item.textLanguage],
        let embedding = NLEmbedding.sentenceEmbedding(for: language)
    else {
        missing.insert(item.textLanguage)
        continue
    }
    let start = ContinuousClock.now
    let distances = item.senses.map { embedding.distance(between: item.context, and: $0.description, distanceType: .cosine) }
    let elapsed = ContinuousClock.now - start
    times.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
    let choice = distances.indices.min { distances[$0] < distances[$1] }!
    var score = results[item.textLanguage] ?? (0, 0)
    score.total += 1
    if choice == item.answer { score.correct += 1 }
    results[item.textLanguage] = score
    chance += 1 / Double(item.senses.count)
}

let correct = results.values.map(\.correct).reduce(0, +)
let total = results.values.map(\.total).reduce(0, +)
times.sort()
print("Plongements de phrases de macOS : \(correct)/\(total) bons sens (\(Int(100 * Double(correct) / Double(max(total, 1)))) %), hasard \(Int(100 * chance / Double(max(total, 1)))) %")
print("Temps par cas : médiane \(Int(times[times.count / 2])) ms, pire cas courant \(Int(times[Int(0.95 * Double(times.count - 1))])) ms")
for (language, score) in results.sorted(by: { $0.key < $1.key }) {
    print("  \(language) : \(score.correct)/\(score.total)")
}
if !missing.isEmpty { print("Pas de modèle pour : \(missing.sorted().joined(separator: ", "))") }
