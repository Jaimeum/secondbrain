#!/bin/bash
# Builds build/SecondBrain.app from the SwiftPM package (Command Line Tools only, no Xcode).
#
#   scripts/build-app.sh             release build → build/SecondBrain.app
#   scripts/build-app.sh --release   … plus dist/SecondBrain-<ver>.zip and dist/SecondBrain-<ver>.dmg
#   scripts/build-app.sh --debug     debug build (faster) → build/SecondBrain.app
#
# Env overrides: SB_SIGN_IDENTITY ("-" forces ad-hoc; only then does --release sign ad-hoc), SB_SCRATCH (SwiftPM --scratch-path),
# SB_HARDENED=1 (sign with the hardened runtime), SB_SKIP_BUILD=1 (reuse the last build products).
set -euo pipefail
trap 'echo >&2; echo "ERROR: build-app.sh falló en la línea $LINENO (ver arriba) / build failed at line $LINENO" >&2' ERR

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
PKG="$ROOT/app"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP_NAME="SecondBrain"
DISPLAY_NAME="secondbrain"   # CONTRACT §15.1: the brand is lowercase; executable and .app keep APP_NAME
BUNDLE_ID="app.secondbrain.mac"
APP="$ROOT/build/$APP_NAME.app"
DEV_IDENTITY="SecondBrain Dev"

CONFIG=release
PACKAGE=0
for arg in "$@"; do
    case "$arg" in
        --release) PACKAGE=1 ;;
        --debug) CONFIG=debug ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "Opción desconocida / unknown option: $arg" >&2; exit 64 ;;
    esac
done

step() { printf '\n==> %s\n' "$*"; }

# Runs a command with a timeout so a keychain dialog can never hang the build.
with_timeout() { local secs=$1; shift; perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; }

SWIFT_ARGS=(-c "$CONFIG" --package-path "$PKG")
[[ -n "${SB_SCRATCH:-}" ]] && SWIFT_ARGS+=(--scratch-path "$SB_SCRATCH")

if [[ $PACKAGE == 1 && ( "$CONFIG" != release || "${SB_SKIP_BUILD:-0}" == 1 ) ]]; then
    echo "ERROR: --release siempre compila en modo release (sin --debug ni SB_SKIP_BUILD)" >&2; exit 64
fi
# A release signed ad-hoc has a different signature on every build: macOS keeps the Microphone / Screen Recording
# switches on for whoever updates, but stops applying them (0.4.1–0.5.2 shipped like that). Checked before compiling.
if [[ $PACKAGE == 1 && -z "${SB_SIGN_IDENTITY:-}" ]] \
    && ! security find-identity -p codesigning 2>/dev/null | grep -q "\"$DEV_IDENTITY\""; then
    echo "ERROR: falta la identidad de firma \"$DEV_IDENTITY\"; corre scripts/make-dev-cert.sh. Una release firmada" >&2
    echo "   ad-hoc deja sin efecto los permisos de micrófono y grabación de quien actualiza. Para hacerla de todos" >&2
    echo "   modos: SB_SIGN_IDENTITY=- scripts/build-app.sh --release" >&2
    exit 1
fi
if [[ "${SB_SKIP_BUILD:-0}" != 1 ]]; then
    step "Compilando $APP_NAME $VERSION ($CONFIG)"
    if ! swift build "${SWIFT_ARGS[@]}" --product "$APP_NAME"; then
        echo >&2
        echo "ERROR: la compilación ($CONFIG) falló; no se generó la app. / The $CONFIG build failed." >&2
        exit 1
    fi
fi
BIN="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
[[ -x "$BIN/$APP_NAME" ]] || { echo "ERROR: no existe $BIN/$APP_NAME" >&2; exit 1; }

step "Ensamblando $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# SwiftPM's generated Bundle.module accessor looks in Bundle.main.resourceURL
# (= Contents/Resources) first, so every resource bundle goes there.
shopt -s nullglob
BUNDLES=("$BIN"/*.bundle)
shopt -u nullglob
for b in "${BUNDLES[@]}"; do
    ditto "$b" "$APP/Contents/Resources/$(basename "$b")"
    echo "   recurso: $(basename "$b")"
done
for required in "${APP_NAME}_BrainCore.bundle" "${APP_NAME}_${APP_NAME}.bundle"; do
    [[ -d "$APP/Contents/Resources/$required" ]] || { echo "ERROR: falta $required (Bundle.module fallaría)" >&2; exit 1; }
done

# Bundled dynamic frameworks (none today: SwiftPM links package products statically).
shopt -s nullglob
FRAMEWORKS=("$BIN"/PackageFrameworks/*.framework)
shopt -u nullglob
if (( ${#FRAMEWORKS[@]} )); then
    mkdir -p "$APP/Contents/Frameworks"
    for f in "${FRAMEWORKS[@]}"; do ditto "$f" "$APP/Contents/Frameworks/$(basename "$f")"; done
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
fi

ICON_CACHE="$ROOT/build/AppIcon.icns"
ICONSET="$SCRIPTS/icon/secondbrain.iconset"
# Brand icon (docs/brand/01_icons): rebuilt when any image in the iconset is newer than the cached .icns.
if [[ -d "$ICONSET" && ( ! -f "$ICON_CACHE" || -n "$(find "$ICONSET" -newer "$ICON_CACHE" -print -quit)" ) ]]; then
    step "Generando icono"
    mkdir -p "$(dirname "$ICON_CACHE")"
    iconutil -c icns "$ICONSET" -o "$ICON_CACHE" || echo "   (no se pudo generar el icono; se usa el genérico)"
fi
[[ -f "$ICON_CACHE" ]] && cp "$ICON_CACHE" "$APP/Contents/Resources/AppIcon.icns"

# OAuth app registration (CONTRACT §12.3): the ids are never committed. They live in <repo>/secrets/ (git-ignored),
# else in ~/.config/secondbrain/ (SB_OAUTH_DIR overrides both):
#   google-client.json      the "client_secret_….json" downloaded from Google Cloud (Desktop app client), as is
#   microsoft-client-id.txt the Application (client) ID of the Entra app registration, one line
#   github-client-id.txt    the Client ID of the GitHub OAuth App (Device Flow enabled), one line → "githubClientId"
#   oauth.json              optional: {"microsoftClientId":…,"googleClientId":…,"googleClientSecret":…,"githubClientId":…} (wins)
# They are merged into Contents/Resources/oauth-defaults.json. Values are never printed.
if [[ -n "${SB_OAUTH_DIR:-}" ]]; then OAUTH_DIR="$SB_OAUTH_DIR"
elif [[ -d "$ROOT/secrets" ]]; then OAUTH_DIR="$ROOT/secrets"
else OAUTH_DIR="$HOME/.config/secondbrain"; fi
if [[ -d "$OAUTH_DIR" ]]; then
    step "Registro OAuth (desde $OAUTH_DIR)"
    OAUTH_SUMMARY="$(python3 -I - "$OAUTH_DIR" "$APP/Contents/Resources/oauth-defaults.json" <<'PY'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
out = {}
g = os.path.join(src, "google-client.json")
if os.path.isfile(g):
    d = json.load(open(g))
    d = d.get("installed") or d.get("web") or d
    for src_key, dst_key in (("client_id", "googleClientId"), ("client_secret", "googleClientSecret"),
                             ("project_id", "googleProjectId"), ("auth_uri", "googleAuthURI"), ("token_uri", "googleTokenURI")):
        if d.get(src_key): out[dst_key] = d[src_key]
m = os.path.join(src, "microsoft-client-id.txt")
if os.path.isfile(m):
    v = open(m).read().strip()
    if v: out["microsoftClientId"] = v
# MARK: v0.4 github
gh = os.path.join(src, "github-client-id.txt")
if os.path.isfile(gh):
    v = open(gh).read().strip()
    if v: out["githubClientId"] = v
o = os.path.join(src, "oauth.json")
if os.path.isfile(o):
    for k, v in json.load(open(o)).items():
        if v: out[k] = v
if out:
    json.dump(out, open(dst, "w"))
    os.chmod(dst, 0o644)
print("Google " + ("ok" if out.get("googleClientId") and out.get("googleClientSecret") else "–")
      + " · Microsoft " + ("ok" if out.get("microsoftClientId") else "–")
      + " · GitHub " + ("ok" if out.get("githubClientId") else "–"))
PY
)"
    echo "   $OAUTH_SUMMARY"
else
    echo "   (sin $OAUTH_DIR: la app se compila sin registro OAuth; Conectar mostrará la ayuda)"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>es</string>
	<key>CFBundleLocalizations</key><array><string>es</string><string>en</string></array>
	<key>CFBundleExecutable</key><string>$APP_NAME</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleName</key><string>$DISPLAY_NAME</string>
	<key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>LSMinimumSystemVersion</key><string>15.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSHumanReadableCopyright</key><string>SecondBrain — todo se queda en tu Mac / everything stays on your Mac.</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>SecondBrain usa el micrófono para grabar tu voz en las reuniones. Todo se procesa en tu Mac. / SecondBrain uses the microphone to record your voice in meetings. Everything is processed on your Mac.</string>
	<key>NSAudioCaptureUsageDescription</key>
	<string>SecondBrain graba el audio de tu computadora (la llamada o reunión) para transcribirlo en tu Mac. / SecondBrain records your computer's audio (the call or meeting) to transcribe it on your Mac.</string>
	<key>NSCalendarsFullAccessUsageDescription</key>
	<string>SecondBrain lee tu calendario para mostrarte tus reuniones y grabarlas con su título y asistentes. Solo lectura; todo se queda en tu Mac. / SecondBrain reads your calendar to show your meetings and record them with their title and attendees. Read-only; everything stays on your Mac.</string>
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

step "Firmando"
IDENTITY="${SB_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    if security find-identity -p codesigning 2>/dev/null | grep -q "\"$DEV_IDENTITY\""; then
        IDENTITY="$DEV_IDENTITY"
    else
        IDENTITY="-"
        echo "   Sin identidad \"$DEV_IDENTITY\" → firma ad-hoc. Los permisos de micrófono/grabación"
        echo "   se perderán en cada build; corre scripts/make-dev-cert.sh para evitarlo."
    fi
fi
SIGN_ARGS=(--force --sign "$IDENTITY" --entitlements "$SCRIPTS/SecondBrain.entitlements" --timestamp=none)
[[ "${SB_HARDENED:-0}" == 1 ]] && SIGN_ARGS+=(--options runtime)
if ! with_timeout 60 codesign "${SIGN_ARGS[@]}" "$APP"; then
    if [[ "$IDENTITY" != "-" && $PACKAGE == 1 ]]; then
        echo "ERROR: no se pudo firmar con \"$IDENTITY\" (¿diálogo del llavero? elige «Permitir siempre» y vuelve a" >&2
        echo "   correrlo). La release no se firma ad-hoc." >&2
        exit 1
    elif [[ "$IDENTITY" != "-" ]]; then
        echo "   No se pudo firmar con \"$IDENTITY\" (¿diálogo del llavero?) → firma ad-hoc." >&2
        IDENTITY="-"
        SIGN_ARGS=(--force --sign - --entitlements "$SCRIPTS/SecondBrain.entitlements" --timestamp=none)
        codesign "${SIGN_ARGS[@]}" "$APP"
    else
        exit 1
    fi
fi
codesign --verify --strict "$APP"
echo "   firmado con: $([[ "$IDENTITY" == "-" ]] && echo ad-hoc || echo "$IDENTITY")"

echo
echo "Listo: $APP"

if [[ $PACKAGE == 1 ]]; then
    DIST="$ROOT/dist"
    mkdir -p "$DIST"
    ZIP="$DIST/$APP_NAME-$VERSION.zip"
    DMG="$DIST/$APP_NAME-$VERSION.dmg"

    step "Creando $ZIP"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

    step "Creando $DMG"
    rm -f "$DMG"
    STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sb-dmg.XXXXXX")"
    ditto "$APP" "$STAGE/$APP_NAME.app"
    ln -s /Applications "$STAGE/Applications"
    if ! HDI_OUT="$(hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" 2>&1)"; then
        echo "$HDI_OUT" >&2
        echo "ERROR: no se pudo crear el dmg" >&2; exit 1
    fi
    rm -rf "$STAGE"
    [[ -s "$DMG" ]] || { echo "ERROR: no se pudo crear el dmg" >&2; exit 1; }
    if [[ "$IDENTITY" != "-" ]]; then
        with_timeout 60 codesign --force --sign "$IDENTITY" --timestamp=none "$DMG" || echo "   (dmg sin firmar)"
    fi

    # What the user sees on opening it: the app (validly signed) next to an Applications alias.
    step "Verificando $DMG"
    hdiutil verify -quiet "$DMG"
    MNT="$(mktemp -d "${TMPDIR:-/tmp}/sb-dmg-mnt.XXXXXX")"
    ATTACH_OUT="$(hdiutil attach -nobrowse -readonly -noverify -mountpoint "$MNT" "$DMG" 2>&1)" \
        || { echo "$ATTACH_OUT" >&2; echo "ERROR: no se pudo montar el dmg" >&2; exit 1; }
    DMG_OK=1
    [[ -d "$MNT/$APP_NAME.app" ]] || { echo "ERROR: el dmg no contiene $APP_NAME.app" >&2; DMG_OK=0; }
    [[ -L "$MNT/Applications" && "$(readlink "$MNT/Applications")" == /Applications ]] \
        || { echo "ERROR: el dmg no tiene el alias a Aplicaciones" >&2; DMG_OK=0; }
    codesign --verify --strict "$MNT/$APP_NAME.app" || { echo "ERROR: la app del dmg no pasa codesign --verify" >&2; DMG_OK=0; }
    [[ "$(plutil -extract CFBundleShortVersionString raw "$MNT/$APP_NAME.app/Contents/Info.plist")" == "$VERSION" ]] \
        || { echo "ERROR: la versión de la app del dmg no es $VERSION" >&2; DMG_OK=0; }
    hdiutil detach -quiet "$MNT" || hdiutil detach -force -quiet "$MNT"
    rmdir "$MNT" 2>/dev/null || true
    [[ $DMG_OK == 1 ]] || exit 1
    echo "   ok: $APP_NAME.app + Applications → /Applications"

    echo
    ls -lh "$ZIP" "$DMG"
fi
