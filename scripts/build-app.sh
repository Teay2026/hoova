#!/bin/zsh
# Construit build/Hoova.app et la signe avec ton certificat de développement Apple,
# pour que macOS garde les autorisations (Accessibilité, Enregistrement de l'écran) d'un build à l'autre.
set -euo pipefail
cd "${0:A:h}/.."

CONFIG=${CONFIG:-Release}
DERIVED=build/DerivedData
PRODUCTS="$DERIVED/Build/Products/$CONFIG"
APP=build/Hoova.app

# xcodebuild (et non `swift build`) : lui seul compile les shaders Metal de MLX. Avec SWIFT_EMIT_LOC_STRINGS, le
# compilateur relève aussi les textes traduisibles de chaque fichier (.stringsdata), comme dans Xcode.
xcodebuild -scheme Hoova -configuration "$CONFIG" -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" -skipMacroValidation -skipPackagePluginValidation -quiet SWIFT_EMIT_LOC_STRINGS=YES build

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$PRODUCTS/Hoova" "$APP/Contents/MacOS/Hoova"
# Sparkle, les mises à jour, est la seule bibliothèque dynamique : elle va dans Contents/Frameworks, où le programme
# apprend à la chercher.
mkdir -p "$APP/Contents/Frameworks"
ditto "$PRODUCTS/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Hoova"
# Ressources des paquets Swift, dont la bibliothèque Metal de MLX.
for bundle in "$PRODUCTS"/*.bundle(N); do cp -R "$bundle" "$APP/Contents/Resources/"; done
# Les textes traduisibles (String Catalog). Le catalogue reçoit d'abord ceux que le compilateur a relevés dans Hoova et
# HoovaCore, comme Xcode le fait à chaque build : un texte nouveau y entre sans traduction, un texte disparu y est
# marqué « stale ». Puis il est compilé, une langue par dossier .lproj : SwiftUI et String(localized:) les trouvent
# dans l'app.
xcrun xcstringstool sync Resources/Localizable.xcstrings --stringsdata \
  "$DERIVED"/Build/Intermediates.noindex/Hoova.build/$CONFIG/{Hoova,HoovaCore}-*.build/Objects-normal/arm64/*.stringsdata
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APP/Contents/Resources"
# Le français est la langue source : ses textes sont les clés, et xcstringstool n'en écrit pas la table. Elle doit
# exister, même vide : sinon macOS, qui se replie sur l'anglais (CFBundleDevelopmentRegion), l'afficherait sur un Mac
# en français. Un texte absent d'une table qui existe s'affiche tel quel, donc en français.
FRENCH="$APP/Contents/Resources/fr.lproj/Localizable.strings"
[[ -f $FRENCH ]] || { mkdir -p "${FRENCH:h}" && print '/* Le français est la langue source : ses textes sont les clés. */' > "$FRENCH" }
# Un texte sans anglais s'afficherait en français sur un Mac en anglais : on le signale.
python3 -I - Resources/Localizable.xcstrings <<'EOF'
import json, re, sys
strings = json.load(open(sys.argv[1]))["strings"]
# Les textes sans lettre (« %@ : %@ », « . ») n'ont rien à traduire.
missing = [key for key, entry in strings.items()
           if entry.get("shouldTranslate", True) and entry.get("extractionState") != "stale"
           and "en" not in entry.get("localizations", {})
           and re.search(r"[^\W\d_]", re.sub(r"%(\d+\$)?[-+ #0]*\d*(\.\d+)?(ll|l|h)?[@dDiuUxXoOfFeEgGcCsSp%]", "", key))]
if missing:
    print(f"⚠︎ {len(missing)} texte(s) sans anglais dans Resources/Localizable.xcstrings :", *missing, sep="\n  ", file=sys.stderr)
EOF
# Les crédits, que le panneau « À propos » de macOS affiche tout seul (Credits.html), dans chaque langue. Puis les
# licences complètes de Hoova et des bibliothèques compilées avec lui : les licences MIT et Apache 2.0 demandent de les
# joindre à l'app.
for language in en fr; do cp "Resources/Credits/$language.html" "$APP/Contents/Resources/$language.lproj/Credits.html"; done
LICENSES="$APP/Contents/Resources/Licenses"
mkdir -p "$LICENSES"
cp LICENSE "$LICENSES/Hoova.txt"
find "$DERIVED/SourcePackages/checkouts" -maxdepth 5 -type f \( -iname 'license*' -o -iname 'notice*' \) | while read -r file; do
  relative=${file#$DERIVED/SourcePackages/checkouts/}
  cp "$file" "$LICENSES/${relative//\//-}"
done

# L'icône, au format d'Icon Composer : actool en tire Assets.car (macOS 26 et plus) et AppIcon.icns.
xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$APP/Contents/Resources" --app-icon AppIcon \
  --platform macosx --target-device mac --minimum-deployment-target 27.0 \
  --output-partial-info-plist "$DERIVED/AppIcon.plist" --errors >/dev/null

# Always the same signature, so macOS keeps the permissions from one build to the next: the Developer ID certificate
# if it's in the keychain, otherwise "Apple Development". SIGN_IDENTITY picks another one, and "-" signs without an
# identity. Every piece gets the hardened runtime, and a Developer ID signature also gets a secure timestamp:
# notarization requires both.
if [[ -z ${SIGN_IDENTITY:-} ]] && security find-identity -v -p codesigning | grep -q '"Developer ID Application: '; then
  SIGN_IDENTITY="Developer ID Application"
fi
SIGN_IDENTITY=${SIGN_IDENTITY:-Apple Development}
SIGN=(codesign --force --sign "$SIGN_IDENTITY" --options runtime)
[[ $SIGN_IDENTITY == "Developer ID Application"* ]] && SIGN+=(--timestamp)
# From the inside out, without --deep, as Sparkle's documentation shows: its helpers, Sparkle, then Hoova.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
"${SIGN[@]}" "$SPARKLE"
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "→ $APP ($SIGN_IDENTITY)"
