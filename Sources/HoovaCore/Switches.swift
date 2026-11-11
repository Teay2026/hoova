import Foundation

/// Les interrupteurs des essais du plan (`docs/plan.md`) : une variable d'environnement `HOOVA_<NOM>=1` active une
/// idée sans recompiler. Le banc d'essai et l'app les lisent de la même façon. Aucun essai en cours.
public enum Switches {
    /// Les interrupteurs actifs, recopiés dans les rapports et les mesures. Jamais la clé API.
    public static var active: [String] {
        ProcessInfo.processInfo.environment
            .filter { $0.key.hasPrefix("HOOVA_") && !["HOOVA_DEBUG", "HOOVA_API_KEY"].contains($0.key) }
            .map { "\($0.key.dropFirst(6))=\($0.value)" }
            .sorted()
    }

    /// Lit un interrupteur : `isOn("NOM")` vaut vrai quand `HOOVA_NOM=1`.
    static func isOn(_ name: String) -> Bool {
        ProcessInfo.processInfo.environment["HOOVA_\(name)"] == "1"
    }
}
