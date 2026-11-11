#!/bin/zsh
# Banc d'essai complet : tous les cas en trois passages sur un Mac « chaud », puis les trois premiers sur un
# Mac « froid » (la mémoire est remplie avant chacun, comme après une longue pause). Rapports dans bench/resultats/.
# Les options en plus vont à HoovaBench, par exemple : ./scripts/bench.sh --model mlx-community/gemma-4-e2b-it-4bit
set -euo pipefail
cd "${0:A:h}/.."

if pgrep -x Hoova >/dev/null; then
  echo "Ferme Hoova d'abord (menu Hoova → Quitter Hoova) : le banc d'essai charge son propre modèle."
  exit 1
fi

xcodebuild -scheme HoovaBench -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData -skipMacroValidation -skipPackagePluginValidation -quiet build

BENCH=build/DerivedData/Build/Products/Release/HoovaBench
STAMP=$(date +%Y-%m-%d-%H%M)
"$BENCH" --label chaud --runs 3 --out "bench/resultats/$STAMP-chaud.json" "$@"
"$BENCH" --label froid --cold 3 --out "bench/resultats/$STAMP-froid.json" "$@"
