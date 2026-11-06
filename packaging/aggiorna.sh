#!/bin/bash
# Aggiorna il progetto da GitHub (git pull) e ricostruisce l'installer. Da eseguire su macOS dalla cartella clonata con git.
# Uso: packaging/aggiorna.sh
set -euo pipefail
cd "$(dirname "$0")/.."
BRANCH="claude/teostackxt-macos-app-lea8qk"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Questa cartella non è un clone di git (forse è uno ZIP): usa «git clone» come da istruzioni."; exit 1
fi
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "Ci sono file modificati a mano in questa cartella: il pull potrebbe fallire."
    git status --short --untracked-files=no
    echo "Per scartare le modifiche locali: git checkout -- .   (poi rilancia questo script)"; exit 1
fi

echo "== Aggiornamento da GitHub"
git fetch origin "$BRANCH"
git checkout "$BRANCH"
git pull --ff-only origin "$BRANCH"
echo "== Ultimo commit: $(git log -1 --format='%h %cs %s')"

echo "== Costruzione dell'installer"
UNIVERSAL="${UNIVERSAL:-0}" packaging/build-installer.sh
open dist
