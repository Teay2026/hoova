# Contributing to Hoova

Thanks for helping. Bug reports, ideas, fixes and new bench cases are all welcome.

## Before you start

- **A bug or an idea**: open an [issue](https://github.com/Teay2026/hoova/issues/new/choose), or start a [discussion](https://github.com/Teay2026/hoova/discussions).
- **A bigger change**: open an issue first, so we can agree on it before you write the code.
- **A vulnerability**: don't open an issue. Follow [SECURITY.md](SECURITY.md).

Never paste an API key, and never attach a screenshot with private text, in an issue, a pull request or a bench case.

## Build Hoova

You need a Mac with Apple Silicon, macOS 27, Xcode 27 and its Metal Toolchain:

```bash
xcodebuild -downloadComponent MetalToolchain
./scripts/build-app.sh
open build/Hoova.app
```

The script signs the app with your Apple Development certificate, so macOS keeps Hoova's permissions from one build to the next. Without one, sign it ad hoc. macOS then asks for the permissions again after each build:

```bash
SIGN_IDENTITY=- ./scripts/build-app.sh
```

`open --env HOOVA_SETUP=1 build/Hoova.app` shows the welcome screens again, from the start.

## Check your change

- **It builds without new warnings.**
- **Reading, prompts or models**: run the bench before and after your change, and put both results in your pull request. Quit Hoova first, because the bench loads its own model.

  ```bash
  ./scripts/bench.sh
  ```

  The cases are in `bench/`. A new case shows the passage, the term, the expected meaning and the languages.
- **Speed**: the timing of each step is in the system log. The text Hoova reads stays hidden there.

  ```bash
  /usr/bin/log stream --info --predicate 'subsystem == "com.teayouness.hoova"'
  ```

## The code

- Code and comments are written in English. Some older comments are still in French, and will move to English over time.
- The app's text is in `Resources/Localizable.xcstrings`. French is the source language. The English is rewritten for English readers, never translated word for word. A new text needs both.
- Match the code around yours: its names, its comments and its style.

## License

By contributing, you agree that your contribution is under the MIT license, like the rest of the code ([LICENSE](LICENSE)). Hoova's name, logo, mascot and icon are not under it: see [TRADEMARKS.md](TRADEMARKS.md).
