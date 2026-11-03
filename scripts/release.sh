#!/bin/bash
# Publishes a release:  scripts/release.sh [<version>]     (default: the version in VERSION)
#
# Builds the .app + zip + dmg (build-app.sh --release), makes sure the public GitHub repo exists,
# pushes the current branch and the tag v<version>, and creates the GitHub release (marked latest) with
# the zip, the dmg, SHA256SUMS.txt and appcast.xml — or, if it already exists, re-uploads them (--clobber)
# and refreshes the notes. Once releases/latest/download/appcast.xml serves this version, every other
# release (and its tag, remote and local) is deleted: the repo keeps only the newest one. Older
# dist/SecondBrain-*.{zip,dmg} are pruned too.
#
# Auto-updates (Sparkle): the zip is the update payload, signed with the EdDSA key of
# scripts/make-update-key.sh (login keychain; SB_ED_KEY_FILE=<file> uses an exported key instead). The
# appcast (scripts/make-appcast.py) holds that single item and is signed too. The dmg is for a first install.
# Safe to re-run. Needs a clean git tree (commit first) and `gh auth login`.
#
# Prerequisites for the first auto-updating release (both checked below, neither done for you):
#   1. scripts/make-update-key.sh, then commit scripts/sparkle-public-ed-key.txt (build-app.sh embeds it).
#   2. The repo must be PUBLIC: installed apps fetch releases/latest/download/appcast.xml anonymously. Making
#      it public exposes all source and history, so it is the owner's call (or host the feed elsewhere).
#
# Version guard: a version older than the newest release is refused (it would become "latest" and the prune
# would delete the newer one). Re-publishing the newest version (e.g. to fix an asset) needs SB_REPUBLISH=1.
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
# Installed apps download updates anonymously from releases/latest: the repo has to be public. Flipping an
# existing repo is the owner's decision, never done here.
if VISIBILITY="$(gh repo view "$REPO" --json visibility -q .visibility 2>/dev/null)" && [[ "$VISIBILITY" != PUBLIC ]]; then
    die "$REPO es privado ($VISIBILITY): las actualizaciones automáticas no podrían descargarse. Hazlo público con"$'\n'"   gh repo edit $REPO --visibility public --accept-visibility-change-consequences"$'\n'"   y vuelve a correr este script."
fi

# Never publish over a newer release: it would be marked latest and then the newer one pruned below.
if gh repo view "$REPO" >/dev/null 2>&1; then
    EXISTING="$(gh release list --repo "$REPO" --limit 100 --json tagName -q '.[].tagName')" \
        || die "no se pudo listar las releases de $REPO"
    NEWEST="$(sed -n 's/^v//p' <<<"$EXISTING" | sort -V | tail -1)"
    if [[ -n "$NEWEST" ]]; then
        if [[ "$(printf '%s\n%s\n' "$VERSION" "$NEWEST" | sort -V | tail -1)" != "$VERSION" ]]; then
            die "$VERSION es más vieja que la release más nueva (v$NEWEST); publicarla borraría v$NEWEST"
        elif [[ "$VERSION" == "$NEWEST" && "${SB_REPUBLISH:-}" != 1 ]]; then
            die "v$VERSION ya está publicada. Sube VERSION (o pasa la versión nueva), o usa SB_REPUBLISH=1 para volver a publicarla"
        fi
    fi
fi

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

# --- Update signature (Sparkle) ------------------------------------------------------------------
step "Firmando la actualización"
SPARKLE_BIN="${SB_SCRATCH:-app/.build}/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE_BIN/sign_update" ]] || swift package --package-path app resolve >/dev/null
[[ -x "$SPARKLE_BIN/sign_update" ]] || die "no se encontró $SPARKLE_BIN/sign_update"
PUBLIC_KEY="$(tr -d '[:space:]' < scripts/sparkle-public-ed-key.txt)"
# The app trusts only the key in its Info.plist: sign with that one, or every installed copy rejects the update.
[[ "$(plutil -extract SUPublicEDKey raw build/SecondBrain.app/Contents/Info.plist)" == "$PUBLIC_KEY" ]] \
    || die "la app compilada no lleva la clave de scripts/sparkle-public-ed-key.txt"
KEY_ARGS=()
if [[ -n "${SB_ED_KEY_FILE:-}" ]]; then
    KEY_ARGS=(--ed-key-file "$SB_ED_KEY_FILE")
else
    KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null | tr -d '[:space:]')" \
        || die "no hay clave de actualizaciones en el llavero; corre scripts/make-update-key.sh"
    [[ "$KEYCHAIN_KEY" == "$PUBLIC_KEY" ]] || die "la clave del llavero no es la de scripts/sparkle-public-ed-key.txt"
fi
ED_ATTRS="$("$SPARKLE_BIN/sign_update" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} "$ZIP")"   # sparkle:edSignature="…" length="…"
[[ "$ED_ATTRS" =~ sparkle:edSignature=\"([^\"]+)\"\ length=\"([0-9]+)\" ]] || die "sign_update devolvió: $ED_ATTRS"
ED_SIGNATURE="${BASH_REMATCH[1]}"
ED_LENGTH="${BASH_REMATCH[2]}"
"$SPARKLE_BIN/sign_update" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} --verify "$ZIP" "$ED_SIGNATURE" >/dev/null || die "la firma del zip no se verifica"
SUMS="dist/SHA256SUMS.txt"
( cd dist && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" ) > "$SUMS"

# --- Repo + push ---------------------------------------------------------------------------------
step "Publicando en github.com/$REPO"
if ! gh repo view "$REPO" >/dev/null 2>&1; then
    gh repo create "$REPO" --public --description "SecondBrain: graba tus reuniones y deja que Claude mantenga tu wiki. Todo local."
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
- **Actualizaciones automáticas:** instalas una vez y la app se mantiene al día sola; se instala al cerrarla, nunca a mitad de una grabación o transcripción. Ya no hace falta bajar un DMG por versión.
- **Transcripción estable:** se corrigió un cierre inesperado al transcribir reuniones con palabras repetidas (por ejemplo "y y y") y otro al transcribir varios fragmentos a la vez.
- **Sin bucles de cierre:** si un trabajo hace que la app se cierre, ya no se reintenta en cada arranque; tras dos cierres seguidos queda como **Con problema** con **Reintentar**, y el audio se conserva.
- **Una sola ventana:** abrir secondbrain otra vez trae al frente la que ya está abierta en lugar de arrancar una segunda copia.

### Actualizaciones automáticas
Desde esta versión SecondBrain se actualiza solo: busca versiones nuevas al abrirse y cada 6 horas, las
descarga en segundo plano y las instala al cerrar la app (o cuando pulses **Reiniciar y actualizar**).
Nunca interrumpe una grabación ni una transcripción. Puedes apagarlo en **Ajustes › General ›
Actualizaciones**. El DMG solo hace falta para la primera instalación (o si vienes de 0.7.2 o anterior).

### Instalar (solo la primera vez)
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
- **Automatic updates:** install once and the app keeps itself up to date; updates install when you quit, never in the middle of a recording or transcription. No more downloading a DMG for every version.
- **Stable transcription:** fixed a crash when transcribing meetings with repeated words (e.g. "y y y") and another when several chunks were transcribed at once.
- **No crash loops:** a job that makes the app quit is no longer retried on every launch; after two crashes in a row it shows as **Problem** with **Retry**, and the audio is kept.
- **One window:** opening secondbrain again brings the running copy to the front instead of starting a second one.

### Automatic updates
From this version on, SecondBrain updates itself: it checks at launch and every 6 hours, downloads in the
background and installs when you quit (or when you click **Restart and Update**). It never interrupts a
recording or a transcription. Turn it off in **Settings › General › Updates**. The DMG is only needed for
the first install (or when coming from 0.7.2 or earlier).

### Install (first time only)
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

# One item, this release; the feed is signed too (the app sets SURequireSignedFeed).
APPCAST="dist/appcast.xml"
python3 -I scripts/make-appcast.py "$APPCAST" "$VERSION" "$REPO" "$ED_SIGNATURE" "$ED_LENGTH" "$NOTES"
xmllint --noout "$APPCAST" || die "$APPCAST no es XML válido"
"$SPARKLE_BIN/sign_update" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} "$APPCAST" >/dev/null
"$SPARKLE_BIN/sign_update" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} --verify "$APPCAST" >/dev/null || die "la firma de $APPCAST no se verifica"

ASSETS=("$ZIP" "$DMG" "$SUMS" "$APPCAST")
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "${ASSETS[@]}" --repo "$REPO" --clobber
    gh release edit "$TAG" --repo "$REPO" --title "SecondBrain $VERSION" --notes-file "$NOTES" --latest
else
    gh release create "$TAG" "${ASSETS[@]}" --repo "$REPO" --verify-tag --latest --title "SecondBrain $VERSION" --notes-file "$NOTES"
fi

# --- Only the latest release stays ---------------------------------------------------------------
# Installed apps read releases/latest/download/appcast.xml: prune only once it serves this version.
step "Comprobando el feed de actualizaciones"
FEED="https://github.com/$REPO/releases/latest/download/appcast.xml"
FEED_OK=0
for _ in 1 2 3 4 5 6; do
    if curl -sfL "$FEED" | grep -qF "<sparkle:version>$VERSION</sparkle:version>"; then FEED_OK=1; break; fi
    sleep 10
done
[[ $FEED_OK == 1 ]] || die "$FEED aún no sirve $VERSION; no se borran las releases anteriores (vuelve a correr el script)"
echo "   ok: $FEED → $VERSION"

step "Borrando las releases anteriores"
# Listed on its own: a gh failure (network, auth, rate limit) must stop the script, not look like "nothing to prune".
ALL_TAGS="$(gh release list --repo "$REPO" --limit 100 --json tagName -q '.[].tagName')" \
    || die "no se pudo listar las releases; las anteriores siguen publicadas (vuelve a correr el script)"
OLD_TAGS="$(grep -vxF "$TAG" <<<"$ALL_TAGS" || true)"
for old in $OLD_TAGS; do
    gh release delete "$old" --repo "$REPO" --yes --cleanup-tag
    git tag -d "$old" >/dev/null 2>&1 || true
    echo "   borrada: $old"
done
[[ -n "$OLD_TAGS" ]] || echo "   (no había otras)"
# Local release tags with no GitHub release left (older runs, deleted by hand) would be re-pushed later.
for old in $(git tag -l 'v*' | grep -vxF "$TAG" || true); do
    git tag -d "$old" >/dev/null && echo "   tag local borrado: $old"
done

# Old builds pile up in dist/ (hundreds of MB each): keep only this version's zip and dmg.
step "Limpiando dist/"
shopt -s nullglob
for f in dist/SecondBrain-*.zip dist/SecondBrain-*.dmg; do
    [[ "$f" == "$ZIP" || "$f" == "$DMG" ]] && continue
    rm -f -- "$f" && echo "   borrado: $f"
done
shopt -u nullglob

echo
echo "Listo: https://github.com/$REPO/releases/tag/$TAG"
