#!/bin/bash
# Creates a self-signed code-signing identity "SecondBrain Dev" in the login keychain (idempotent).
#
# Why: macOS ties Microphone / Screen Recording permissions to the app's code signature. An ad-hoc
# signature changes on every build, so permissions would be lost each time. A stable self-signed
# identity keeps them across rebuilds. Don't delete it: releases signed with another one (or ad-hoc) leave the
# permissions of everyone who updates switched on but not applied (the app then offers "Reparar permiso").
#
# Optional:
#   SB_KEYCHAIN_PASSWORD=<login password>  lets the script authorize codesign to use the key without
#                                          the "codesign wants to access key" dialog.
#   --trust                                also mark the certificate as trusted for code signing
#                                          (macOS asks for your password in a dialog; not required
#                                          for signing to work).
set -euo pipefail

NAME="SecondBrain Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TRUST=0
[[ "${1:-}" == "--trust" ]] && TRUST=1

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
    echo "OK: la identidad \"$NAME\" ya existe / identity already exists."
    exit 0
fi

if [[ ! -f "$KEYCHAIN" ]]; then
    echo "ERROR: no se encontró el llavero de inicio de sesión ($KEYCHAIN)." >&2
    exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sb-cert.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = SecondBrain
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -config "$WORK/openssl.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

P12_PASS="sb-$(openssl rand -hex 12)"
LEGACY=""
openssl version | grep -q '^OpenSSL 3' && LEGACY="-legacy"   # Keychain can't read OpenSSL 3's default p12 cipher
# shellcheck disable=SC2086
openssl pkcs12 -export $LEGACY -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/id.p12" -passout "pass:$P12_PASS"

# Fails instead of prompting if the keychain is locked (e.g. over SSH).
if ! security show-keychain-info "$KEYCHAIN" >/dev/null 2>&1; then
    echo "ERROR: el llavero de inicio de sesión está bloqueado. Desbloquéalo con:" >&2
    echo "  security unlock-keychain \"$KEYCHAIN\"" >&2
    echo "y vuelve a correr este script. / The login keychain is locked; unlock it and re-run." >&2
    exit 1
fi

security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$P12_PASS" -f pkcs12 \
    -T /usr/bin/codesign -T /usr/bin/security </dev/null

if [[ -n "${SB_KEYCHAIN_PASSWORD:-}" ]]; then
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "$NAME" \
        -k "$SB_KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
else
    echo "Nota: si al firmar macOS pregunta si \"codesign\" puede usar la llave, elige \"Permitir siempre\"."
    echo "Note: if macOS asks whether codesign may use the key, choose \"Always Allow\"."
fi

if [[ $TRUST == 1 ]]; then
    if [[ -t 0 ]]; then
        echo "macOS pedirá tu contraseña para confiar en el certificado... / macOS will ask for your password..."
        security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"
    else
        echo "ERROR: --trust necesita una terminal interactiva (macOS pide la contraseña en un diálogo)." >&2
        echo "Corre: scripts/make-dev-cert.sh --trust  desde Terminal. / Run it from an interactive Terminal." >&2
        exit 2
    fi
fi

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
    echo "OK: identidad \"$NAME\" creada / identity created."
else
    echo "ERROR: la identidad no aparece tras importarla / identity not found after import." >&2
    exit 1
fi
