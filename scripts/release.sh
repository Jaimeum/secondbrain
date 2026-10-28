#!/bin/bash
# Publishes a release:  scripts/release.sh [<version>]     (default: the version in VERSION)
#
# Builds the .app + zip + dmg (build-app.sh --release), makes sure the private GitHub repo exists,
# pushes the current branch and the tag v<version>, and creates the GitHub release with both files
# attached — or, if it already exists, re-uploads them (--clobber) and refreshes the notes.
# Safe to re-run. Needs a clean git tree (commit first) and `gh auth login`.
set -euo pipefail
trap 'echo "ERROR: release.sh falló en la línea $LINENO / failed at line $LINENO" >&2' ERR

REPO="Jaimeum/secondbrain"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${1:-$(tr -d '[:space:]' < VERSION)}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] || { echo "Uso: $0 [<version>]  (ej. 0.1.0)" >&2; exit 64; }
TAG="v$VERSION"
die() { echo "ERROR: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

command -v gh >/dev/null || die "falta gh (brew install gh)"
gh auth status >/dev/null 2>&1 || die "corre 'gh auth login' primero"

# --- Git: never publish build outputs, models or the author's own vault/data -------------------
[[ -d .git ]] || git init -q -b main
for pattern in .DS_Store build/ dist/ 'app/.build*/' app/.swiftpm/ /vault/ /data/; do
    grep -qxF "$pattern" .gitignore 2>/dev/null || echo "$pattern" >> .gitignore
done
for probe in vault/x data/x build/x dist/x app/.build/x app/.build-x/x; do
    git check-ignore -q "$probe" || die "$probe no está ignorado en .gitignore"
done
TRACKED_BAD="$(git ls-files -- vault data build dist 'app/.build*' app/.swiftpm | head -5)"
[[ -z "$TRACKED_BAD" ]] || die "git ya sigue archivos que no deben publicarse (git rm -r --cached …):"$'\n'"$TRACKED_BAD"

if [[ "$(tr -d '[:space:]' < VERSION 2>/dev/null)" != "$VERSION" ]]; then
    echo "$VERSION" > VERSION
fi
# Only VERSION/.gitignore may change here; anything else must be committed by a human first.
DIRTY="$(git status --porcelain --untracked-files=all | grep -vE '^.. (VERSION|\.gitignore)$' || true)"
[[ -z "$DIRTY" ]] || die "hay cambios sin commit; haz commit (o descártalos) antes de publicar:"$'\n'"$DIRTY"
BIG="$(git ls-files -z | xargs -0 stat -f '%z %N' 2>/dev/null | awk '$1 > 50*1024*1024 {print $2}' | head -5 || true)"
[[ -z "$BIG" ]] || die "archivos de más de 50 MB en git (GitHub los rechaza):"$'\n'"$BIG"
git add VERSION .gitignore
git diff --cached --quiet || git commit -q -m "Release $TAG"
BRANCH="$(git symbolic-ref --short -q HEAD)" || die "HEAD no está en una rama"

# --- Build ---------------------------------------------------------------------------------------
step "Compilando $VERSION"
scripts/build-app.sh --release
ZIP="dist/SecondBrain-$VERSION.zip"
DMG="dist/SecondBrain-$VERSION.dmg"
[[ -s "$ZIP" && -s "$DMG" ]] || die "faltan $ZIP o $DMG"

# --- Repo + push ---------------------------------------------------------------------------------
step "Publicando en github.com/$REPO"
if ! gh repo view "$REPO" >/dev/null 2>&1; then
    gh repo create "$REPO" --private --description "SecondBrain: graba tus reuniones y deja que Claude mantenga tu wiki. Todo local."
fi
if ORIGIN="$(git remote get-url origin 2>/dev/null)"; then
    [[ "$ORIGIN" == *"github.com"[:/]"$REPO"* ]] || die "el remoto origin apunta a $ORIGIN, no a $REPO"
else
    git remote add origin "https://github.com/$REPO.git"
fi
# Authenticate https pushes through gh for this command only (no global git config changes).
GIT_PUSH=(git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push)
"${GIT_PUSH[@]}" -u origin "$BRANCH"

# The tag follows the commit being released; re-running after a fix moves it.
HEAD_SHA="$(git rev-parse HEAD)"
if TAG_SHA="$(git rev-parse -q --verify "refs/tags/$TAG^{commit}")"; then
    if [[ "$TAG_SHA" != "$HEAD_SHA" ]]; then
        echo "   $TAG apuntaba a ${TAG_SHA:0:7}; se mueve a ${HEAD_SHA:0:7}"
        git tag -f -a "$TAG" -m "SecondBrain $VERSION"
    fi
else
    git tag -a "$TAG" -m "SecondBrain $VERSION"
fi
"${GIT_PUSH[@]}" --force origin "refs/tags/$TAG"

# --- Release -------------------------------------------------------------------------------------
NOTES="$(mktemp "${TMPDIR:-/tmp}/sb-notes.XXXXXX")"
trap 'rm -f "$NOTES"' EXIT
cat > "$NOTES" <<EOF
## SecondBrain $VERSION

Tu segundo cerebro de todo lo que pasa en el día: correos, notas, documentos, enlaces, repos y
reuniones (que transcribe **en tu Mac**). Claude mantiene un wiki por proyecto con fichas de cada
persona, empresa y tema. El audio nunca sale de tu computadora; lo único que se envía es el texto
que Claude lee con tu propia cuenta.

### Novedades
- **Un diseño más tranquilo.** Menos líneas y cambios bruscos de color, esquinas redondeadas y tonos suaves en toda la app, en claro y en oscuro. La barra de arriba se funde con el contenido y la selección de la barra lateral ya no sale en el azul del sistema.
- **"Agregar" más discreto.** Una cápsula suave con un "+" en lugar del botón gris con flecha azul (en la barra lateral y en los proyectos).
- **Cualquier emoji como ícono de proyecto.** Escribe o pega el que quieras, o abre "Más emojis…"; siguen las sugerencias.
- **Formularios más limpios.** Campos con borde suave y un halo tenue al escribir (sin bordes negros), selectores, casillas y menús con el estilo de la app.
- Incluye todo lo de 0.7: adjuntos de correo, Archivos, "Agregar al proyecto", hilos de correo como unidad, tus respuestas y "Abrir el original".

### Instalar
1. Descarga **SecondBrain-$VERSION.dmg** (abajo, en *Assets*), ábrelo y arrastra **SecondBrain** a la
   carpeta **Aplicaciones**.
2. Abre SecondBrain desde Aplicaciones. La primera vez macOS dirá que no puede verificar la app (no
   está notarizada por Apple). Pulsa **Listo**, abre **Ajustes del Sistema → Privacidad y seguridad**,
   baja hasta el aviso de SecondBrain y pulsa **Abrir de todos modos** (te pedirá tu contraseña).
   Solo se hace una vez.
3. Sigue la bienvenida: conecta tu cuenta de Claude (se abre el navegador) y crea tu primer proyecto.
   Los permisos de **audio de la computadora** y **micrófono** y la descarga del modelo de transcripción
   (~3 GB, una sola vez) se piden la primera vez que grabas.

**Requisitos:** macOS 15 o posterior, Mac con Apple Silicon (M1 o más nuevo), ~5 GB libres y una
suscripción de Claude (Pro o Max).

¿Problemas? Revisa la sección *Si algo no funciona* del README del repositorio.

---

## English

Your second brain for everything that happens in your day: mail, notes, documents, links, repos and
meetings (transcribed **on your Mac**). Claude keeps a per-project wiki with a page for every person,
company and topic. Audio never leaves your computer.

### What's new
- **A calmer design.** Fewer lines and abrupt color changes, rounded corners and soft tones across the app, in light and dark. The top bar blends into the content and the sidebar selection no longer uses the system blue.
- **A quieter "Add".** A soft capsule with a "+" instead of the grey button with a blue arrow (in the sidebar and in projects).
- **Any emoji as a project icon.** Type or paste the one you want, or open "More emoji…"; suggestions are still there.
- **Cleaner forms.** Fields with a soft border and a faint halo while typing (no black borders); pickers, checkboxes and menus in the app's style.
- Includes everything from 0.7: mail attachments, Files, "Add to project", mail threads as a unit, your replies and "Open the original".

### Install
1. Download **SecondBrain-$VERSION.dmg** (under *Assets*), open it and drag **SecondBrain** to
   **Applications**.
2. Open it. The first time, macOS says it can't verify the app (it isn't notarized by Apple). Click
   **Done**, go to **System Settings → Privacy & Security**, scroll to the SecondBrain notice and click
   **Open Anyway** (in Spanish: *Abrir de todos modos*). You only do this once.
3. Follow the welcome steps: connect your Claude account (opens your browser) and create your first project.
   Computer-audio and microphone permissions and the transcription model download (~3 GB, once) are asked
   the first time you record.

**Requires** macOS 15+, Apple Silicon (M1 or newer), ~5 GB free and a Claude Pro or Max subscription.
EOF

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "$ZIP" "$DMG" --repo "$REPO" --clobber
    gh release edit "$TAG" --repo "$REPO" --title "SecondBrain $VERSION" --notes-file "$NOTES"
else
    gh release create "$TAG" "$ZIP" "$DMG" --repo "$REPO" --verify-tag --title "SecondBrain $VERSION" --notes-file "$NOTES"
fi
echo
echo "Listo: https://github.com/$REPO/releases/tag/$TAG"
