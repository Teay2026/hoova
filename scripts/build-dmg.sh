#!/bin/zsh
# Fabrique build/Hoova.dmg à partir de build/Hoova.app (lance d'abord scripts/build-app.sh) : une fenêtre avec Hoova et
# un raccourci vers Applications, où le glisser. Le .dmg est signé avec le même certificat que l'app, et son empreinte
# SHA-256 est écrite à côté, pour la page des versions de GitHub (docs/decisions.md, 10 novembre 2026).
set -euo pipefail
cd "${0:A:h}/.."

[[ -d build/Hoova.app ]] || { print -u2 "Il manque build/Hoova.app : lance d'abord ./scripts/build-app.sh"; exit 1 }
# Le certificat qui a signé l'app, pour signer le .dmg pareil. Rien pour une app signée sans identité (« - »).
IDENTITY=$(codesign -dvv build/Hoova.app 2>&1 | sed -n 's/^Authority=//p' | head -1)

rm -rf build/dmg build/Hoova.dmg build/Hoova.dmg.sha256
mkdir -p build/dmg
ditto build/Hoova.app build/dmg/Hoova.app
ln -s /Applications build/dmg/Applications
hdiutil create -volname Hoova -srcfolder build/dmg -ov -format UDZO -quiet build/Hoova.dmg
rm -rf build/dmg

if [[ $IDENTITY == "Developer ID Application:"* ]]; then
  # A secure timestamp, Apple's notary service, then its ticket stapled to the .dmg: macOS opens the .dmg, and Hoova
  # inside it, without blocking them, even offline. The credentials are in the keychain under the profile
  # hoova-notary (NOTARY_PROFILE picks another one), saved once with `xcrun notarytool store-credentials`.
  NOTARY=(--keychain-profile "${NOTARY_PROFILE:-hoova-notary}")
  codesign --force --sign "$IDENTITY" --timestamp build/Hoova.dmg
  RESULT=$(xcrun notarytool submit build/Hoova.dmg $NOTARY --wait --output-format json) || true
  if [[ $(print -r -- $RESULT | plutil -extract status raw -o - - 2>/dev/null) != Accepted ]]; then
    print -u2 -r -- "Notarization failed: $RESULT"
    xcrun notarytool log "$(print -r -- $RESULT | plutil -extract id raw -o - - 2>/dev/null)" $NOTARY >&2 || true
    exit 1
  fi
  xcrun stapler staple -q build/Hoova.dmg
  spctl --assess -v --type open --context context:primary-signature build/Hoova.dmg
elif [[ -n $IDENTITY ]]; then
  codesign --force --sign "$IDENTITY" build/Hoova.dmg
fi
(cd build && shasum -a 256 Hoova.dmg > Hoova.dmg.sha256)
echo "→ build/Hoova.dmg (${IDENTITY:-sans signature}) · SHA-256 $(cut -d' ' -f1 build/Hoova.dmg.sha256)"
