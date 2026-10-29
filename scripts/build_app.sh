#!/bin/bash
# Builds NX Hub and packs "NX Hub.app" in the project folder: swift build, then the bundle (Info.plist, translations, icon) and an ad-hoc signature.
# Usage: scripts/build_app.sh [--install]   --install also copies the app to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/NX Hub.app"

echo "== $(swift --version 2>&1 | head -1)"
swift build -c release --product NXHub 2>&1
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/NXHub" "$APP/Contents/MacOS/NXHub"
cp Resources/Info.plist "$APP/Contents/Info.plist"
for l in Resources/*.lproj; do cp -R "$l" "$APP/Contents/Resources/"; done
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
# Signature. An ad-hoc one is new on every build, and macOS then asks again for the folders NX Hub reads (Downloads...). The app is signed instead with a
# certificate made once for this Mac and kept in its own keychain in .signing (not added to your keychain list, never committed): macOS keeps its
# permissions from build to build. NXHUB_SIGN=- forces ad-hoc; NXHUB_SIGN="<identity>" uses one of your keychain's
sign_local() {
    local DIR="$ROOT/.signing"
    [ -f "$ROOT/.dev/nxhub-signing.keychain-db" ] && DIR="$ROOT/.dev"   # where development builds made it before
    local KC="$DIR/nxhub-signing.keychain-db" PW="nxhub-local" CN="NX Hub Local Signing" SSL=/usr/bin/openssl H T ok
    mkdir -p "$DIR" || return 1
    if [ ! -f "$KC" ]; then
        # The system's LibreSSL: Homebrew's OpenSSL 3 writes a PKCS#12 that security import cannot read
        T="$(mktemp -d)"
        printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=%s\n[ext]\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\nbasicConstraints=critical,CA:false\n' "$CN" > "$T/cfg"
        # create-keychain also adds the keychain to your search list: the list is put back as it was
        local -a before=()
        while IFS= read -r l; do l="${l//\"/}"; l="${l#"${l%%[![:space:]]*}"}"; [ -n "$l" ] && before+=("$l"); done < <(security list-keychains -d user)
        $SSL req -x509 -newkey rsa:2048 -nodes -keyout "$T/key.pem" -out "$T/cert.pem" -days 3650 -config "$T/cfg" >/dev/null 2>&1 &&
        $SSL pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/id.p12" -passout "pass:$PW" -name "$CN" >/dev/null 2>&1 &&
        security create-keychain -p "$PW" "$KC" &&
        security import "$T/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null &&
        security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
        ok=$?
        [ ${#before[@]} -gt 0 ] && security list-keychains -d user -s "${before[@]}"
        rm -rf "$T"
        if [ $ok -ne 0 ]; then echo "== could not make the local signing certificate"; rm -f "$KC"; return 1; fi
        echo "== made the local signing certificate ($KC)"
    fi
    security unlock-keychain -p "$PW" "$KC" || return 1
    H="$(security find-certificate -c "$CN" -Z "$KC" 2>/dev/null | sed -n 's/^SHA-1 hash: //p' | head -1)"
    [ -n "$H" ] || return 1
    codesign --force --keychain "$KC" --sign "$H" --entitlements Resources/NXHub.entitlements --timestamp=none "$APP" || return 1
    echo "== signed with the local certificate $H"
}
if [ -n "${NXHUB_SIGN:-}" ]; then
    codesign --force --sign "$NXHUB_SIGN" --entitlements Resources/NXHub.entitlements --timestamp=none "$APP" || echo "(codesign failed: the app still runs from this Mac)"
elif ! sign_local; then
    echo "== ad-hoc signature (macOS asks again for the folders NX Hub reads)"
    codesign --force --sign - --entitlements Resources/NXHub.entitlements --timestamp=none "$APP" || echo "(codesign failed: the app still runs from this Mac)"
fi
codesign -dr - "$APP" 2>&1 | sed -n 's/^designated => /== designated requirement: /p'

echo "== built: $APP"

if [ "${1:-}" = "--install" ]; then
    rm -rf "/Applications/NX Hub.app"
    cp -R "$APP" "/Applications/NX Hub.app"
    echo "== installed: /Applications/NX Hub.app"
fi
