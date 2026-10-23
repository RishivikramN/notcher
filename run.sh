#!/bin/zsh
# Builds Notcher, assembles build/Notcher.app, signs it and (re)launches it.
#   ./run.sh            debug build + launch
#   ./run.sh release    release build + launch
#   ./run.sh --no-open  build only
# NOTCHER_SIGN_IDENTITY picks the certificate. A "Developer ID" identity signs for
# distribution: Hardened Runtime, a secure timestamp and Support/Notcher.entitlements.
set -euo pipefail

ROOT="${0:A:h}"
CONFIG="debug"
OPEN=1
for arg in "$@"; do
  case "$arg" in
    release) CONFIG="release" ;;
    --no-open) OPEN=0 ;;
  esac
done

SIGN_IDENTITY="${NOTCHER_SIGN_IDENTITY:-Apple Development}"
APP="$ROOT/build/Notcher.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Notcher"

pkill -x Notcher 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Notcher"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"

# Resources are used exactly as shipped. The Defaults/Vortex bundles are produced by
# their packages when those are added, so they are not copied by hand.
rsync -a \
  --exclude ".DS_Store" \
  --exclude "Defaults_Defaults.bundle" \
  --exclude "Vortex_Vortex.bundle" \
  "$ROOT/Resources/" "$APP/Contents/Resources/"
xattr -cr "$APP"

# MediaRemote adapter, loaded into /usr/bin/perl at runtime (see SystemMediaSource).
xcrun clang -dynamiclib -fobjc-arc -arch arm64 -mmacosx-version-min=15.0 \
  -framework Foundation -framework AppKit \
  -o "$APP/Contents/Resources/MediaRemoteAdapter.dylib" \
  "$ROOT/Sources/MediaRemoteAdapter/adapter.m"
SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" == "Developer ID"* ]]; then
  SIGN_FLAGS+=(--options runtime --timestamp)
fi
# Inside out: the nested dylib first, then the app with its entitlements.
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Resources/MediaRemoteAdapter.dylib" >/dev/null
codesign "${SIGN_FLAGS[@]}" --entitlements "$ROOT/Support/Notcher.entitlements" "$APP" >/dev/null
echo "Built $APP ($CONFIG)"

if (( OPEN )); then
  open "$APP"
fi
