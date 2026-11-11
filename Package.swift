// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Hoova",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.32.3")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "1.0.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        // Les modèles externes (OpenAI, Anthropic, Gemini, Ollama…), sans ses options lourdes (MLX, llama.cpp).
        .package(url: "https://github.com/huggingface/AnyLanguageModel", from: "1.1.1"),
        // Le raccourci classique des réglages (enregistreur, conflits avec les raccourcis de macOS).
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.1.0"),
        // Les mises à jour de l'app, depuis les versions publiées sur GitHub (docs/decisions.md, 10 novembre 2026).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        // Tout ce qui ne dépend pas de l'interface : lecture du texte, sources fiables, IA.
        .target(
            name: "HoovaCore",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
            ]
        ),
        // L'app de la barre des menus : triple clic droit, pop-up.
        .executableTarget(
            name: "Hoova",
            dependencies: [
                "HoovaCore", .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // Banc d'essai en ligne de commande : justesse et vitesse du modèle.
        .executableTarget(
            name: "HoovaBench",
            dependencies: ["HoovaCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
