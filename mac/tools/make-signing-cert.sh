#!/bin/sh
# Create the local code-signing identity, once per machine.
#
# ## Why this exists
#
# macOS grants Input Monitoring and Accessibility per *application*, and identifies
# the application by its code signature. An ad-hoc signature has no team identity, so
# the system falls back to tracking the CDHash — which changes on every build. The
# result is that each rebuild is a brand new app as far as TCC is concerned, and every
# permission has to be granted again, by hand, in System Settings.
#
# During development that is several trips a day, and the symptom is bad: the app
# looks fine and silently cannot open the pad.
#
# A certificate — even a self-signed one that no other machine would trust — gives the
# signature a stable designated requirement, so grants survive rebuilds.
#
# ## What this is not
#
# Nothing here involves an Apple Developer account, and nothing here makes the app
# distributable. Notarizing for someone else's machine needs a paid Developer ID and
# `notarytool` (which ships with Xcode). This is purely so *this* machine stops asking.
#
# Usage: mac/tools/make-signing-cert.sh
# Undo:  security delete-identity -c "OpenBoard Local Signing"

set -eu

NAME="OpenBoard Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  printf '"%s" already exists — nothing to do.\n' "$NAME"
  exit 0
fi

# Pick a real OpenSSL 3 if the default is LibreSSL. macOS's `/usr/bin/openssl` is
# LibreSSL, which does not recognise `-legacy` and fails the pkcs12 step below —
# and if that stderr is hidden, the whole script silently produces nothing. This
# stumped a fresh install once; do not put the redirect back.
OPENSSL=$(command -v openssl)
LEGACY_FLAG="-legacy"
if "$OPENSSL" version 2>/dev/null | grep -qi libressl; then
  if [ -x /opt/homebrew/bin/openssl ]; then
    OPENSSL=/opt/homebrew/bin/openssl
  elif [ -x /usr/local/opt/openssl@3/bin/openssl ]; then
    OPENSSL=/usr/local/opt/openssl@3/bin/openssl
  else
    # LibreSSL's pkcs12 defaults are already macOS-compatible; the flag is not
    # available and not needed. If a future LibreSSL changes this we will hear
    # about it, which is why the fallback is loud rather than silent.
    LEGACY_FLAG=""
    printf 'note: using LibreSSL for pkcs12 — Homebrew openssl not found, dropping -legacy.\n'
  fi
fi

# The keychain must be unlocked or `security import` fails silently from any
# non-TTY caller (an IDE, a subshell, another script). Check first and give the
# user something to run rather than watching the script fall over.
if ! security show-keychain-info "$KEYCHAIN" >/dev/null 2>&1; then
  printf '\nYour login keychain is locked.\n'
  printf 'Run: security unlock-keychain login.keychain-db\n'
  printf 'Then re-run this script.\n' >&2
  exit 1
fi

printf 'creating a self-signed code-signing certificate…\n'

# codeSigning EKU is required: without it `codesign` refuses the identity even
# though the private key is present, and `find-identity -p codesigning` shows nothing.
cat > "$WORK/ext.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = OpenBoard Local Signing
O  = OpenBoard
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -config "$WORK/ext.cnf" 2>/dev/null

# `-legacy` matters: OpenSSL 3 defaults to PKCS#12 algorithms macOS's Security
# framework cannot read, and the import fails with a misleading
# "MAC verification failed (wrong password?)". LibreSSL does not need it and
# does not know it — see the openssl detection above.
"$OPENSSL" pkcs12 -export $LEGACY_FLAG \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout pass:openboard -name "$NAME"

# -T lets codesign use the key without a prompt on every build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P openboard \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Trust for code signing only — not a TLS root, and user-level rather than system.
# Without this the identity imports but never appears as *valid*.
printf '\nmacOS will now ask for your admin password to trust the self-signed cert.\n'
printf 'If the dialog is hidden, look under other windows.\n\n'
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

printf '\n'
security find-identity -v -p codesigning | grep "$NAME" || {
  printf 'the identity did not become valid — check Keychain Access trust settings\n' >&2
  exit 1
}
printf '\nDone. tools/build-app.sh will use it automatically.\n'
printf 'Grant Input Monitoring once more; it will survive every rebuild after that.\n'
