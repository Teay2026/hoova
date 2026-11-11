# Hoova

*[Read in English](README.md)*

Sélectionne un mot ou une phrase que tu ne comprends pas (ou survole simplement un mot), puis **tape deux fois sur ⌃ (Control)** : un pop-up t'explique ce qu'il veut dire **dans ce contexte**, en une ou deux phrases simples. Avec le modèle intégré, tout reste sur ton Mac.

## Comment ça marche

1. **Double ⌃** (`Sources/Hoova/DoubleTap.swift`). Deux appuis brefs sur ⌃ seule, à moins de 0,4 s d'écart, sans autre touche ni clic entre les deux. Les raccourcis avec ⌃ (⌃C, ⌃ + clic…) restent intacts. Le double ⌥ n'est pas utilisé : il ouvre l'app Claude. Si la dictée de macOS est réglée sur « Appuyer deux fois sur Contrôle », change l'un des deux.
2. **Lecture du texte** (`Sources/HoovaCore/TextReader.swift`). La sélection d'abord, où que soit la souris, dans cet ordre :
   1. l'**accessibilité** de macOS : dans l'app au premier plan, puis dans le contenu sous la souris ;
   2. la sélection **mémorisée** au moment du geste (glisser, double clic, ⇧ + clic, ⌘A, ⇧ + flèches), pour les sites qui l'effacent dès qu'on appuie sur une touche ;
   3. **⌘C**, puis le presse-papiers est remis comme avant ;
   4. la sélection **surlignée à l'écran** (OCR + couleur de sélection de macOS), qui marche partout.

   Sans sélection récente (moins de 30 s), le mot sous la souris : accessibilité (texte exact, quelques ms) ou OCR de Vision (≈ 0,4 s, marche partout). Les captures d'écran ne contiennent jamais les fenêtres de Hoova.

   Le contexte envoyé au modèle : le passage du terme, le texte juste avant et juste après lui, et le titre de la page ou du document. Jusqu'à 3 000 caractères autour du passage pour le modèle intégré, et 12 000 pour un modèle externe, début du document compris.
3. **Sources fiables** (`Sources/HoovaCore/Grounding.swift`). Avant l'IA : la définition d'un sigle dans le document (« Banque centrale européenne (BCE) »), puis le dictionnaire intégré de macOS (~1 ms).
4. **IA locale** (`Sources/HoovaCore/Explainer.swift`). Gemma 4 E4B en 4 bits via MLX, dans une version fixée de Hugging Face. Le modèle lit les consignes une seule fois au démarrage : leur cache est copié pour chaque explication, qui n'a plus qu'à lire le passage (premier mot en ~0,5 s au lieu de ~2,3 s pour un passage court, ~2 s avec 3 000 caractères autour). Le pop-up indique la source : **Document**, **Dictionnaire** ou **IA** (et « à vérifier » quand le modèle n'est pas sûr). On peut aussi choisir, dans l'accueil ou dans les réglages, un modèle externe (`Sources/HoovaCore/RemoteExplainer.swift`) : OpenAI, Anthropic, Gemini ou Mistral avec sa clé API, ou Ollama sur ce Mac. Au premier ⌃, Hoova ouvre déjà la connexion au fournisseur, sans rien envoyer. L'explication est écrite dans la langue du texte autour du mot, jamais dans celle du mot lui-même, ou dans celle choisie dans les réglages.

## Prérequis

- Mac Apple Silicon, macOS 27, Xcode 27 et son Metal Toolchain : `xcodebuild -downloadComponent MetalToolchain`.
- Le modèle (5,2 Go), à la version qu'utilise Hoova : `hf download mlx-community/gemma-4-e4b-it-4bit --revision 475b9088d29754a3379866cf5aeb6b41acd313c2`. Sinon, Hoova le télécharge quand on le choisit dans l'accueil, et reprend le téléchargement là où il s'était arrêté s'il est coupé.

## Construire et lancer

```bash
./scripts/build-app.sh
open build/Hoova.app
```

Le script signe l'app avec le certificat de distribution de Hoova s'il est dans le trousseau, sinon avec ton certificat de développement Apple : macOS garde ainsi les autorisations d'un build à l'autre. Sans certificat, `SIGN_IDENTITY=- ./scripts/build-app.sh` la signe sans identité, et macOS redemande les autorisations à chaque build. Pour une version, `./scripts/build-dmg.sh` fabrique ensuite `build/Hoova.dmg`, signé pareil, avec son empreinte SHA-256.

Au premier lancement, l'accueil guide l'installation : il fait autoriser Hoova dans **Réglages Système → Confidentialité et sécurité**, puis choisir le modèle et la langue, et propose d'essayer le geste. `open --env HOOVA_SETUP=1 build/Hoova.app` le rouvre depuis le début.
- **Accessibilité** : obligatoire (double ⌃ et lecture du texte) ;
- **Enregistrement de l'écran** : pour lire partout grâce à l'OCR. Il ne compte qu'après une relance de Hoova.

## Journal et mode test

Les temps de chaque étape (lecture, premier mot, réponse complète) sont dans le journal système ; le texte lu, lui, y reste masqué :

```bash
/usr/bin/log stream --info --predicate 'subsystem == "com.teayouness.hoova"'
```

Lancée avec `open --env HOOVA_DEBUG=1 build/Hoova.app`, Hoova accepte aussi une notification distribuée `com.teayouness.hoova.explain` (objet `"x,y"`, en coordonnées d'écran) qui déclenche une explication sans faire le geste. Quand l'OCR ne trouve aucun mot sous la souris, la capture est gardée dans `~/Library/Application Support/Hoova/derniere-capture-ratee.png`, avec les mots lus et la souris marqués ; elle reste sur le Mac.

Le modèle est préparé au premier lancement dans `~/Library/Application Support/Hoova/Modèles` : sans ses parties son et image, avec sa grande table dans un fichier à part, lue sans être chargée (4,2 Go sur le disque, 2,7 Go en mémoire). Après 10 minutes sans usage, il quitte la mémoire et revient au geste suivant, en 1,4 s environ ; `HOOVA_IDLE_SECONDS` change ce délai pour les essais. Les notes que le modèle tire de ses consignes sont gardées dans `~/Library/Application Support/Hoova/Cache`, pour ne pas les recalculer à chaque chargement.

Les vidéos protégées contre la copie (Udemy, Netflix…) ne peuvent pas être lues : le navigateur les retire des captures d'écran. Hoova le signale ; leurs sous-titres et leur transcription restent lisibles.

## Banc d'essai

Les cas sont dans `bench/cas.json` (écrits à la main) et `bench/cas-wikipedia.json` (fabriqués par `python3 scripts/cas-wikipedia.py` : dans les 8 langues, chaque lien de Wikipédia donne un terme, sa phrase et, par l'article visé, le sens attendu) : passage, terme, sens attendu, langues et difficulté. Le banc les explique, mesure chaque étape (premier mot, réponse complète, jetons lus et écrits) et écrit un rapport JSON dans `bench/resultats/`, que git ignore. Fermer Hoova avant : le banc charge son propre modèle.

```bash
./scripts/bench.sh                                            # 3 passages sur Mac « chaud », puis 3 cas sur Mac « froid »
./scripts/bench.sh --model mlx-community/gemma-4-e2b-it-4bit  # un autre modèle
```

Sur Mac « froid », la mémoire est remplie avant chaque cas (`memory_pressure`), comme après une longue pause.

Chaque explication de l'app ajoute aussi ses temps, sans aucun texte lu, à `~/Library/Application Support/Hoova/mesures.jsonl`, et ses étapes apparaissent dans Instruments (Points of Interest). En mode test, chaque explication est aussi ajoutée automatiquement, au format du banc d'essai, à `cas-perso.jsonl`, dans le même dossier ; elle reste sur le Mac.

## Contribuer, sécurité et licence

- Pour contribuer : [CONTRIBUTING.md](CONTRIBUTING.md). Pour signaler une faille, en privé : [SECURITY.md](SECURITY.md).
- Le code est sous licence MIT ([LICENSE](LICENSE)), © 2026 Youness Tahiri El Alaoui. Le nom, le logo, la mascotte et l'icône de Hoova n'en font pas partie : voir [TRADEMARKS.md](TRADEMARKS.md).
- Les crédits sont dans « À propos de Hoova », et les licences complètes des bibliothèques dans l'app (`Contents/Resources/Licenses`). Gemma 4 est de Google, sous licence Apache 2.0.
- `bench/cas-wikipedia.json` reprend des textes de Wikipédia, sous licence CC BY-SA 4.0.
