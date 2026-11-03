#!/bin/bash
# Creates the EdDSA key that signs auto-updates (Sparkle) and writes its public half to
# scripts/sparkle-public-ed-key.txt, which build-app.sh embeds as SUPublicEDKey (idempotent: an existing key is reused).
#
# The private key lives in the login keychain (item "https://sparkle-project.org", account "ed25519"); scripts/release.sh
# signs each update with it. A backup copy goes to secrets/sparkle-ed-private.key (git-ignored): keep it offline too.
#
# Don't lose it. An installed app accepts an update only if it is signed with this key AND with the same code-signing
# identity ("SecondBrain Dev", scripts/make-dev-cert.sh); one of the two can be rotated while the other still matches.
# Losing both means every installed copy has to be updated by hand from the DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/app"
PUBLIC="$ROOT/scripts/sparkle-public-ed-key.txt"
BACKUP="$ROOT/secrets/sparkle-ed-private.key"
TOOLS="$PKG/.build/artifacts/sparkle/Sparkle/bin"

if [[ ! -x "$TOOLS/generate_keys" ]]; then
    echo "==> Descargando Sparkle (swift package resolve)"
    swift package --package-path "$PKG" resolve
fi
[[ -x "$TOOLS/generate_keys" ]] || { echo "ERROR: no se encontró $TOOLS/generate_keys" >&2; exit 1; }

# Creates the key only if the keychain has none; otherwise prints the existing public key.
"$TOOLS/generate_keys" >/dev/null
KEY="$("$TOOLS/generate_keys" -p | tr -d '[:space:]')"
[[ -n "$KEY" ]] || { echo "ERROR: generate_keys no devolvió la clave pública" >&2; exit 1; }

if [[ -f "$PUBLIC" && "$(tr -d '[:space:]' < "$PUBLIC")" != "$KEY" ]]; then
    echo "ERROR: $PUBLIC tiene otra clave pública que la del llavero." >&2
    echo "   Las apps instaladas solo aceptan actualizaciones firmadas con la clave de ese archivo. Importa la clave" >&2
    echo "   privada que le corresponde (generate_keys -f <respaldo>) en vez de reemplazarla." >&2
    exit 1
fi
echo "$KEY" > "$PUBLIC"
echo "OK: clave pública en $PUBLIC (haz commit de este archivo)"

if [[ ! -f "$BACKUP" ]]; then
    mkdir -p "$(dirname "$BACKUP")"
    ( umask 077; "$TOOLS/generate_keys" -x "$BACKUP" >/dev/null )
    echo "OK: respaldo de la clave privada en $BACKUP (git lo ignora; guárdalo también fuera de esta Mac)"
fi

echo
echo "AVISO: si pierdes esta clave Y el certificado \"SecondBrain Dev\", las copias instaladas ya no podrán"
echo "actualizarse solas. / If both this key and the signing certificate are lost, users must reinstall by hand."
