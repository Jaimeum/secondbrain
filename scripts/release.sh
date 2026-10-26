#!/bin/bash
# Publishes a release: scripts/release.sh <version>   (e.g. 0.1.0)
# Writes VERSION, builds the .app + zip + dmg, makes sure the private GitHub repo exists, pushes
# and creates (or updates) the GitHub release v<version> with both files attached.
set -euo pipefail

REPO="Jaimeum/secondbrain"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] || { echo "Uso: $0 <version>  (ej. 0.1.0)" >&2; exit 64; }
TAG="v$VERSION"
cd "$ROOT"

command -v gh >/dev/null || { echo "ERROR: falta gh (brew install gh)" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: corre 'gh auth login' primero" >&2; exit 1; }

echo "$VERSION" > VERSION
scripts/build-app.sh --release
ZIP="dist/SecondBrain-$VERSION.zip"
DMG="dist/SecondBrain-$VERSION.dmg"

if [[ ! -d .git ]]; then
    git init -q -b main
fi
# Never publish build outputs or the author's own vault/data (they live under ~/secondbrain too).
for pattern in .DS_Store build/ dist/ app/.build/ 'app/.build-*/' app/.swiftpm/ /vault/ /data/; do
    grep -qxF "$pattern" .gitignore 2>/dev/null || echo "$pattern" >> .gitignore
done
git add -A
git diff --cached --quiet || git commit -q -m "Release $TAG"

if ! gh repo view "$REPO" >/dev/null 2>&1; then
    gh repo create "$REPO" --private --description "SecondBrain: graba tus reuniones y deja que Claude mantenga tu wiki. Todo local."
fi
git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$REPO.git"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git push -u origin "$BRANCH"

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag -a "$TAG" -m "SecondBrain $VERSION"
git push origin "$TAG"

NOTES="$(mktemp "${TMPDIR:-/tmp}/sb-notes.XXXXXX")"
trap 'rm -f "$NOTES"' EXIT
cat > "$NOTES" <<EOF
## SecondBrain $VERSION

Graba tus reuniones (audio de la computadora + tu micrófono), las transcribe **en tu Mac** y Claude
mantiene un wiki por proyecto con todo lo que se habló. Nada sale de tu computadora salvo lo que
Claude lee con tu propia cuenta.

### Instalar
1. Descarga **SecondBrain-$VERSION.dmg**, ábrelo y arrastra SecondBrain a **Aplicaciones**.
2. La primera vez macOS dirá que no puede verificar la app (no está notarizada por Apple):
   abre **Ajustes del Sistema → Privacidad y seguridad**, baja hasta el aviso de SecondBrain y
   pulsa **Abrir de todos modos**. Solo se hace una vez.
3. Sigue los pasos de bienvenida: permisos, conectar Claude y descarga de modelos (~1.6 GB).

Requisitos: macOS 15 o posterior, Mac con Apple Silicon, y una suscripción de Claude (Pro o Max).

---

Records your meetings (computer audio + your mic), transcribes them **on your Mac**, and Claude keeps a
per-project wiki of everything discussed.

**Install:** open the .dmg and drag SecondBrain to Applications. The first time, macOS will say it
can't verify the app (it isn't notarized): go to **System Settings → Privacy & Security** and click
**Open Anyway**. Requires macOS 15+, Apple Silicon and a Claude subscription.
EOF

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "$ZIP" "$DMG" --repo "$REPO" --clobber
    gh release edit "$TAG" --repo "$REPO" --notes-file "$NOTES"
else
    gh release create "$TAG" "$ZIP" "$DMG" --repo "$REPO" --title "SecondBrain $VERSION" --notes-file "$NOTES"
fi
echo "Listo: https://github.com/$REPO/releases/tag/$TAG"
