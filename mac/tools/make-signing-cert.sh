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

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -config "$WORK/ext.cnf" 2>/dev/null

# `-legacy` matters: OpenSSL 3 defaults to PKCS#12 algorithms macOS's Security
# framework cannot read, and the import fails with a misleading
# "MAC verification failed (wrong password?)".
openssl pkcs12 -export -legacy \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout pass:openboard -name "$NAME" 2>/dev/null

# -T lets codesign use the key without a prompt on every build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P openboard \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Trust for code signing only — not a TLS root, and user-level rather than system.
# Without this the identity imports but never appears as *valid*.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

printf '\n'
security find-identity -v -p codesigning | grep "$NAME" || {
  printf 'the identity did not become valid — check Keychain Access trust settings\n' >&2
  exit 1
}
printf '\nDone. tools/build-app.sh will use it automatically.\n'
printf 'Grant Input Monitoring once more; it will survive every rebuild after that.\n'
