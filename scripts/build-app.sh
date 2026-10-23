#!/bin/bash
# macOS ties the Full Disk Access / folder grants to the signing identity: an ad-hoc signature changes on
# every build and would drop them, so we sign with a stable self-signed identity kept in a project-local keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="ProperFinder Local Signing"
KEYCHAIN="$PWD/.signing/properfinder.keychain-db"
KEYCHAIN_PASSWORD="properfinder"

if [ ! -f "$KEYCHAIN" ]; then
    mkdir -p .signing
    work=$(mktemp -d)
    cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$IDENTITY
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
EOF
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/key.pem" -out "$work/cert.pem" -days 3650 -config "$work/cert.cnf" 2>/dev/null
    openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/id.p12" -passout pass:x 2>/dev/null \
        || openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/id.p12" -passout pass:x
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security import "$work/id.p12" -k "$KEYCHAIN" -P x -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
    rm -rf "$work"
fi

# The Command Line Tools ship the macOS 27 SDK, whose @State is a macro, without the SwiftUIMacros plugin that expands it.
CLT_SDK26=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
if [ -z "${SDKROOT:-}" ] && [ -d "$CLT_SDK26" ] && [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools* ]]; then
    export SDKROOT="$CLT_SDK26"
fi

swift build -c release

APP="build/ProperFinder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ProperFinder "$APP/Contents/MacOS/ProperFinder"
# SwiftPM records the deployment target as the SDK version (15.0), and macOS 26+ then draws the app in its
# pre-Liquid Glass compatibility look: a sidebar that stops under the toolbar, misaligned toolbar items.
vtool -set-build-version macos 15.0 26.0 -replace -output "$APP/Contents/MacOS/ProperFinder" "$APP/Contents/MacOS/ProperFinder" 2>/dev/null
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Localizations live in the main bundle: SwiftPM's Bundle.module lookup does not find its bundle in a hand-assembled .app.
mkdir -p "$APP/Contents/Resources"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" "$APP"

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/ProperFinder.app"
cp -R "$APP" "$HOME/Applications/ProperFinder.app"
echo "Installed $HOME/Applications/ProperFinder.app"
