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

Graba tus reuniones (audio de la computadora + tu micrófono), las transcribe **en tu Mac** y Claude
mantiene un wiki por proyecto con todo lo que se habló. El audio nunca sale de tu computadora; lo
único que se envía es el texto que Claude lee con tu propia cuenta.

### Novedades
- **El lugar fija el ámbito.** Dentro de un proyecto, Preguntar, Grafo y Pendientes son solo de ese proyecto; los globales tienen su lugar en la barra lateral (Inicio · Preguntar · Grafo · Pendientes · Personas · Correo · Reuniones · Sin asignar). Se acabó el interruptor "Este proyecto | Todo el cerebro".
- **Proyectos con pestañas** Resumen · Contenido · Preguntar · Grafo · Pendientes · Personas; en Personas agregas o quitas gente a mano.
- **Fichas:** cualquier persona, empresa, tema, decisión o reunión tiene una ficha con lo que sabemos, sus reuniones, correos, decisiones, pendientes y relacionados, filtrada al proyecto cuando la abres dentro de uno. **⌘K** ahora busca en el texto completo.
- **Preguntar guarda tus conversaciones;** las citas se abren al lado sin perder el hilo, y cada respuesta se puede **Guardar como página**.
- **Corrige el cerebro a mano:** edita una página, revisa los cambios que propongo en las demás páginas que decían lo mismo, y queda como hecho confirmado (`facts.md`) que no vuelvo a contradecir.
- **Captura del día a día:** **⌥⌘N** abre la captura rápida (nota, enlace, correo o archivo) desde cualquier app (puedes cambiar el atajo en Ajustes); la barra de menús abre primero la captura; los correos que caen en una regla se guardan solos; y **+ Agregar** vive en la barra lateral. Los permisos de grabación se piden la primera vez que grabas.
- **Empresas** como fichas globales (`orgs/`), y el **Grafo** abre la ficha en un panel al lado.
- Ten en cuenta: las conversaciones guardadas son por cerebro, y **⌥⌘N** reemplaza "Nueva carpeta inteligente" del Finder mientras secondbrain está abierta.
- Incluye todo lo de 0.5.x, con el arreglo de permisos de 0.5.3 (grabar sigue funcionando al actualizar; si no, **Reparar permiso** bajo *Grabar*).

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

Records your meetings (computer audio + your mic), transcribes them **on your Mac**, and Claude keeps a
per-project wiki of everything discussed. Audio never leaves your computer.

### What's new
- **Place sets the scope.** Inside a project, Ask, Graph and Tasks are about that project only; the global ones live in the sidebar (Home · Ask · Graph · Tasks · People · Mail · Meetings · Unassigned). The "This project | Whole brain" switch is gone.
- **Projects with tabs:** Summary · Content · Ask · Graph · Tasks · People; add or remove people by hand under People.
- **Entity pages:** any person, company, topic, decision or meeting has a page with what we know, its meetings, mail, decisions, tasks and related items, filtered to the project when opened inside one. **⌘K** now searches full text.
- **Ask keeps your conversations;** citations open alongside without losing your place, and any answer can be **Saved as a page**.
- **Correct the brain by hand:** edit a page, review the changes I propose on other pages that said the same thing, and it becomes a confirmed fact (`facts.md`) I won't contradict again.
- **Everyday capture:** **⌥⌘N** opens quick capture (note, link, email or file) from any app (rebind it in Settings); the menu bar opens capture first; mail matching a rule is saved automatically; and **+ Add** lives in the sidebar. Recording permissions are asked the first time you record.
- **Companies** as global pages (`orgs/`), and the **Graph** opens the entity page in a side panel.
- Good to know: saved conversations are per brain, and **⌥⌘N** replaces Finder's "New Smart Folder" while secondbrain is running.
- Includes everything from 0.5.x, with the 0.5.3 permission fix (recording keeps working across updates; if not, **Fix permission** under *Record*).

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
