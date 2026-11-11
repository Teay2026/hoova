import AppKit
import HoovaCore
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    /// Le raccourci classique, en plus du double appui. Aucun par défaut.
    static let explain = Self("explain")
}

/// Ce que montre la fenêtre de réglages. L'app le tient à jour quand le modèle change ou se télécharge.
@Observable
final class SettingsState {
    var triggerKey = Preferences.triggerKey
    var language = ExplanationLanguage.setting
    var launchAtLogin = Preferences.launchAtLogin
    /// Le modèle utilisé : un modèle de Hoova sur ce Mac, ou le nom d'un modèle externe.
    var local: LocalChoice?
    var remote: String?
    /// Les modèles de Hoova téléchargés, avec la place qu'ils prennent.
    var sizes: [LocalChoice: Int64] = [:]
    /// L'avancement d'un téléchargement en cours, de 0 à 1.
    var preparing: Double?

    func refreshSizes() {
        sizes = Dictionary(
            uniqueKeysWithValues: LocalChoice.allCases.filter { LocalModel.isReady($0.rawValue) }
                .map { ($0, LocalModel.size(of: $0.rawValue)) })
    }
}

/// Ce que la fenêtre demande à l'app.
struct SettingsActions {
    var trigger: (TriggerKey) -> Void
    var useLocal: (LocalChoice) -> Void
    var trash: (LocalChoice) -> Void
    var useRemote: (Provider) -> Void
}

/// L'enregistreur de KeyboardShortcuts, à la largeur qu'on lui donne. Celui du paquet reste à 130 points, même dans un
/// cadre plus large : trop étroit pour « Enregistrer le raccourci ».
private struct ShortcutRecorder: NSViewRepresentable {
    let name: KeyboardShortcuts.Name

    func makeNSView(context: Context) -> KeyboardShortcuts.RecorderCocoa {
        KeyboardShortcuts.RecorderCocoa(for: name)
    }

    func updateNSView(_ view: KeyboardShortcuts.RecorderCocoa, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: KeyboardShortcuts.RecorderCocoa, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 190, height: view.intrinsicContentSize.height)
    }
}

/// La fenêtre de réglages : un formulaire natif, sans onglets (`docs/direction-artistique.md`, partie 12).
final class SettingsWindow {
    private var window: NSWindow?

    func show(state: SettingsState, actions: SettingsActions) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(state: state, actions: actions)))
            window.title = String(localized: "Réglages de Hoova")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @Bindable var state: SettingsState
    let actions: SettingsActions
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            // Hoova debout juste à droite du point de « hoova. », comme au réveil de l'accueil, avec la vraie phase de la lune.
            PerchedWordmark(size: 32) { MascotView(moonAge: Mascot.moonAge()).frame(width: 34, height: 34) }
                .padding(.top, 22)
                // Hoova est à droite du logo : le tout reste centré.
                .padding(.trailing, 38)
                .frame(maxWidth: .infinity)

            Section("Raccourci") {
                Picker("Double appui sur", selection: $state.triggerKey) {
                    ForEach(TriggerKey.allCases, id: \.self) { Text($0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: state.triggerKey) { actions.trigger(state.triggerKey) }
                LabeledContent("Ou un raccourci") {
                    ShortcutRecorder(name: .explain).frame(width: 190)
                }
                Text("Le double appui commence à lire dès le premier appui : c'est le plus rapide.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Modèle") {
                ForEach(LocalChoice.allCases, id: \.self) { localRow($0) }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Modèle externe")
                        (state.remote.map { Text($0) } ?? Text("Le texte lu part chez le fournisseur choisi, avec ta clé API."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu("Choisir…") {
                        ForEach(Provider.allCases, id: \.self) { provider in
                            Button(provider.name) { actions.useRemote(provider) }
                        }
                    }
                    .fixedSize()
                }
            }

            Section("Langue des explications") {
                Picker("Langue", selection: $state.language) {
                    Text("Langue du texte").tag(ExplanationLanguage.text)
                    ForEach(ExplanationLanguage.choices, id: \.self) { Text(ExplanationLanguage.nativeName(of: $0)).tag($0) }
                }
                .onChange(of: state.language) {
                    UserDefaults.standard.set(state.language, forKey: ExplanationLanguage.key)
                }
            }

            Section("Démarrage") {
                Toggle("Ouvrir Hoova au démarrage du Mac", isOn: $state.launchAtLogin)
                    .onChange(of: state.launchAtLogin) { Preferences.launchAtLogin = state.launchAtLogin }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Un modèle de Hoova : sa place sur ce Mac (ou à télécharger), et ce qu'on peut en faire. Pendant sa préparation, sa
    /// lune se remplit, à la place d'une barre de progression.
    private func localRow(_ choice: LocalChoice) -> some View {
        let size = state.sizes[choice]
        let preparing = state.local == choice ? state.preparing : nil
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                choice == .e4b ? Text("\(choice.name) (conseillé)") : Text("\(choice.name) (pour les Mac de 8 Go)")
                Group {
                    if let preparing {
                        Text("Se prépare… \(Int((preparing * 100).rounded()))\u{00A0}%")
                    } else if let size {
                        Text("\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) sur ce Mac")
                    } else {
                        Text("\(choice.downloadSize) à télécharger")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let preparing {
                MoonProgress(value: preparing, color: colorScheme == .dark ? Brand.mint : Brand.purple)
                    .frame(width: 18, height: 18)
            } else if state.local == choice {
                Text("Utilisé").foregroundStyle(.secondary)
            } else {
                if size != nil { Button("Mettre à la corbeille") { actions.trash(choice) } }
                Button(size == nil ? "Télécharger…" : "Utiliser") { actions.useLocal(choice) }
            }
        }
    }
}
