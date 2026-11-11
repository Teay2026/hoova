# Hoova

*[Lire en français](README.fr.md)*

Point at a word you don't get, or select a sentence, then **tap ⌃ (Control) twice**. Hoova tells you what it means **right here**, in one or two plain sentences.

- **It reads the context.** Hoova reads the sentence, the text around it and the page title. "Python" in a care guide is a snake; in a tutorial, it's a language.
- **Private by default.** Its built-in AI, Gemma 4, runs on your Mac. Nothing leaves it.
- **Or your own AI.** OpenAI, Anthropic, Gemini or Mistral, with your API key. Or Ollama, on your Mac.
- **Almost everywhere.** In apps, web pages and PDFs, through macOS Accessibility, or by reading the screen on your Mac when an app keeps its text to itself.
- **Free.** No account, no ads, no tracking.

## What you need

- A Mac with Apple Silicon, on macOS 27 or later.
- For the built-in AI, one download from Hugging Face: 5.2 GB for Gemma 4 E4B, or 3.6 GB for E2B, which is lighter but wrong more often. With your own provider, there's nothing to download.

## Install

1. Download `Hoova.dmg` from the [latest release](https://github.com/Teay2026/hoova/releases/latest), open it, and drag Hoova to Applications.
2. Open it. macOS says it can't check the app: Apple's signature costs $99 a year, and Hoova is free.
3. Open System Settings → Privacy & Security, click **Open Anyway**, then **Open**. You only do this once.

On first launch, Hoova asks for its permissions, one at a time, and lets you pick your AI and try the gesture.

## Permissions

- **Accessibility**: to read the word under your pointer, or the text you select. When an app doesn't share its selection, Hoova copies it with ⌘C, then puts your clipboard back.
- **Screen Recording**: when an app doesn't share its text (Chrome, for one), Hoova reads the screen around your pointer, with on-device OCR. The image is never sent, and never kept.

## Privacy

- With the built-in AI, or with Ollama, nothing leaves your Mac.
- With OpenAI, Anthropic, Gemini or Mistral, the word, the text around it (up to about 12,000 characters, the start of the page included) and the page title go to that provider, under its own terms. Some free plans let the provider use your text. When you press ⌃ once, Hoova already opens a connection to the provider, without sending anything, so the answer comes sooner.
- Your API keys stay in your Mac's keychain.
- Hoova never keeps what it reads. It only keeps timings on your Mac, to measure its speed: how long each step took, never the text.
- To check for updates, Hoova reads the list of versions on GitHub, once a day if you let it: it asks you first. GitHub sees your IP address and Hoova's version, as with any download. Updates are checked against Hoova's own signature before they're installed.
- Hoova has no server and collects nothing.

## Build it yourself

You need Xcode 27 and its Metal Toolchain. An app you build yourself doesn't get the warning on first launch.

```bash
xcodebuild -downloadComponent MetalToolchain
./scripts/build-app.sh
open build/Hoova.app
```

The script signs Hoova with your Apple Development certificate, so macOS keeps its permissions from one build to the next. Without one, `SIGN_IDENTITY=- ./scripts/build-app.sh` signs it ad hoc, and macOS asks for the permissions again after each build.

## How it works

1. **The gesture** (`Sources/Hoova/DoubleTap.swift`): two short taps on ⌃ alone. Shortcuts with ⌃ still work. The card opens on the second tap.
2. **Reading** (`Sources/HoovaCore/TextReader.swift`): your selection, or the word under the pointer. Accessibility first, then on-device OCR with Vision. Hoova also reads the text just before and just after the passage, and the page title.
3. **Reliable sources first** (`Sources/HoovaCore/Grounding.swift`): an acronym defined in the document, then the dictionary built into macOS.
4. **The AI** (`Sources/HoovaCore/Explainer.swift`, `RemoteExplainer.swift`): Gemma 4 in 4 bits with MLX, at a fixed version from Hugging Face. It reads its instructions once, then only the passage, so the first word comes in about half a second for a short passage. The built-in AI gets up to 3,000 characters of context, and an external provider up to 12,000.

Hoova answers in the language of the text around the word, never in the word's own language. You can pick another language in Settings.

## Speed and accuracy

`./scripts/bench.sh` explains the cases in `bench/` and measures each step. Quit Hoova first, because the bench loads its own model.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). To report a vulnerability privately, see [SECURITY.md](SECURITY.md).

## Credits and license

- Hoova's code is under the MIT license ([LICENSE](LICENSE)), © 2026 Youness Tahiri El Alaoui. Its name, logo, mascot and icon are not: see [TRADEMARKS.md](TRADEMARKS.md).
- Gemma 4 is made by Google, under the Apache 2.0 license.
- Hoova is built with MLX, MLX Swift, AnyLanguageModel, swift-transformers and other open-source libraries. They're all listed in "About Hoova", and their full licenses ship inside the app (`Contents/Resources/Licenses`).
- `bench/cas-wikipedia.json` contains text from Wikipedia, under the CC BY-SA 4.0 license.
