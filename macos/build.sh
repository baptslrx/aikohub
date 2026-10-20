#!/bin/bash
# Compile AikoHub.app
#   ./build.sh             → build/AikoHub.app (architecture de ce Mac)
#   ./build.sh --install   → l'installe dans /Applications et la lance
#   UNIVERSAL=1 ./build.sh → binaire universel Apple Silicon + Intel (pour partager)
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Il manque les outils de développement d'Apple."
  echo "Lance : xcode-select --install   (puis relance ce script)"
  exit 1
fi

APP="build/AikoHub.app"
BIN="$APP/Contents/MacOS/AikoHub"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() {  # $1 = arm64 | x86_64
  xcrun swiftc -O -parse-as-library -swift-version 5 \
    -target "$1-apple-macos13.0" Sources/*.swift -o "$2"
}

if [ "${UNIVERSAL:-0}" = "1" ]; then
  echo "→ Compilation universelle (arm64 + x86_64)…"
  compile arm64 build/AikoHub-arm64
  compile x86_64 build/AikoHub-x86_64
  lipo -create build/AikoHub-arm64 build/AikoHub-x86_64 -output "$BIN"
  rm build/AikoHub-arm64 build/AikoHub-x86_64
else
  echo "→ Compilation ($(uname -m))…"
  compile "$(uname -m)" "$BIN"
fi

cp Info.plist "$APP/Contents/Info.plist"
# Adresse du serveur de licences et clé publique (créées par le déploiement du serveur)
[ -f ../server/url.txt ] && /usr/libexec/PlistBuddy -c "Add :AikoServer string $(cat ../server/url.txt)" "$APP/Contents/Info.plist"
[ -f ../server/public-key.txt ] && /usr/libexec/PlistBuddy -c "Add :AikoPublicKey string $(cat ../server/public-key.txt)" "$APP/Contents/Info.plist"

ICON="../assets/icon.png"
if [ -f "$ICON" ]; then
  ICONSET="build/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$ICON" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

# Signature : « exigence » fixée sur l'identifiant de l'appli, pour que macOS garde les autorisations
# (Accessibilité…) d'une version à l'autre au lieu de les redemander à chaque mise à jour.
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Info.plist)
codesign --force --sign - --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP" >/dev/null 2>&1 \
  || codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "✓ $APP prêt"

if [ "${1:-}" = "--install" ]; then
  pkill -x AikoHub 2>/dev/null || true
  rm -rf /Applications/AikoHub.app
  cp -R "$APP" /Applications/
  open /Applications/AikoHub.app
  echo "✓ Installé dans /Applications et lancé"
fi
