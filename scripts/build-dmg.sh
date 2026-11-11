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

[[ -n $IDENTITY ]] && codesign --force --sign "$IDENTITY" build/Hoova.dmg
(cd build && shasum -a 256 Hoova.dmg > Hoova.dmg.sha256)
echo "→ build/Hoova.dmg (${IDENTITY:-sans signature}) · SHA-256 $(cut -d' ' -f1 build/Hoova.dmg.sha256)"
