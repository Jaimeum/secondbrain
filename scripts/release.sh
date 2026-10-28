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
- **Adjuntos de correo.** Los de correos nuevos se guardan solos; logos, firmas e imágenes decorativas se descartan (Claude decide lo dudoso: guarda la foto del pizarrón y descarta el logo del cliente). Lo descartado queda 30 días en **Descartados** para rescatarlo. Al guardar correos anteriores eliges qué adjuntos con casillas; más de 25 MB no se baja solo. Word, Excel y PowerPoint se leen también.
- **Archivos.** Nuevo en la barra lateral y como pestaña de cada proyecto: todos los PDFs, documentos, hojas y fotos con búsqueda, filtros por tipo, origen y persona, vista previa (Espacio) y de dónde vino cada uno.
- **Agregar al proyecto.** En el Resumen del proyecto, una caja donde tiras archivos o escribes lo que pasó (p. ej. una visita presencial) y lo archivo donde va: reunión presencial, decisión, pendientes, documento… y te digo cómo lo archivé.
- **Hilos de correo como unidad.** Una fila por hilo, la conversación completa en orden con tus correos marcados "Tú", y un solo nodo en el **Grafo**.
- **Tus respuestas.** Todo hilo guardado se sigue solo; tus respuestas y las de los demás se agregan, y lo que prometes queda en tus pendientes con enlace al correo que enviaste.
- **Abrir el original.** "Abrir en Outlook / Gmail / Google Calendar" en correos, hilos, eventos y archivos que vinieron de un correo.
- **Hacia atrás.** Selecciona varios correos y guárdalos juntos; al crear una regla te ofrezco traer los correos anteriores que habría capturado (últimos 90 días) para que elijas.
- Ten en cuenta: la hoja "¿Qué adjuntos guardo?" aparece justo después de guardar un correo; "Traer anteriores" puede incluir de más (la hoja lo marca); en hilos viejos de Outlook el botón "Abrir en Outlook" puede tardar unos segundos la primera vez.
- Incluye todo lo de 0.6: el lugar fija el ámbito, fichas, corregir el cerebro y captura rápida con **⌥⌘N**.

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
- **Mail attachments.** Those on new mail are saved automatically; logos, signatures and decorative images are dropped (Claude decides the doubtful ones: it keeps the whiteboard photo and drops the client's logo). Anything dropped stays 30 days in **Descartados** (Discarded) so you can rescue it. When saving older mail you pick which attachments with checkboxes; anything over 25 MB isn't downloaded on its own. Word, Excel and PowerPoint files are read too.
- **Files.** New in the sidebar and as a tab in every project: all PDFs, documents, sheets and photos with search, filters by type, source and person, preview (Space) and where each one came from.
- **Add to project.** On the project Summary, a box where you drop files or type what happened (say, an in-person visit) and I file it where it belongs: in-person meeting, decision, tasks, document… and tell you how I filed it.
- **Mail threads as a unit.** One row per thread, the whole conversation in order with your own messages marked "You", and a single node in the **Graph**.
- **Your replies.** Every saved thread is followed automatically; your replies and everyone else's are added, and what you promise lands in your tasks with a link to the email you sent.
- **Open the original.** "Open in Outlook / Gmail / Google Calendar" on mail, threads, events and files that came from an email.
- **Looking back.** Select several emails and save them together; when you create a rule I offer to bring in the earlier mail it would have captured (last 90 days) so you can choose.
- Good to know: the "Which attachments do I keep?" sheet appears right after you save an email; "Bring earlier" may include too much (the sheet flags it); on old Outlook threads "Open in Outlook" can take a few seconds the first time.
- Includes everything from 0.6: place sets the scope, entity pages, correcting the brain and quick capture with **⌥⌘N**.

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
