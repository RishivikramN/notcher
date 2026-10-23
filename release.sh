#!/bin/zsh
# Builds a distributable Notcher: Developer ID signed, packaged as a DMG, notarized and stapled.
#   ./release.sh --version 1.1.0   set the version, bump the build number, release, tag v1.1.0
#   ./release.sh                   release the version already in Support/Info.plist
#   ./release.sh --skip-notarize   local test build (no upload, no tag)
#
# One-time setup for notarization (stores an app-specific password in the keychain):
#   xcrun notarytool store-credentials notcher-notary \
#     --apple-id <your Apple ID> --team-id 84NPUG4XHW
# Create the app-specific password at appleid.apple.com → Sign-In and Security.
set -euo pipefail

ROOT="${0:A:h}"
NOTARIZE=1
NEW_VERSION=""
while (( $# )); do
  case "$1" in
    --skip-notarize) NOTARIZE=0 ;;
    --version) NEW_VERSION="$2"; shift ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
  shift
done

PLIST="$ROOT/Support/Info.plist"
if [[ -n "$NEW_VERSION" ]]; then
  [[ "$NEW_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "version must look like 1.2.0" >&2; exit 1; }
  BUILD=$(( $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST") + 1 ))
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"
  echo "Version $NEW_VERSION (build $BUILD)"
fi

IDENTITY="${NOTCHER_RELEASE_IDENTITY:-Developer ID Application: Rishivikram Nandakumar (84NPUG4XHW)}"
PROFILE="${NOTCHER_NOTARY_PROFILE:-notcher-notary}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
APP="$ROOT/build/Notcher.app"
DIST="$ROOT/dist"
DMG="$DIST/Notcher-$VERSION.dmg"

cd "$ROOT"
NOTCHER_SIGN_IDENTITY="$IDENTITY" ./run.sh release --no-open

echo "Verifying signature…"
codesign --verify --strict --verbose=2 "$APP"
codesign --display --entitlements - "$APP" 2>/dev/null | grep -q apple-events

echo "Packaging $DMG…"
mkdir -p "$DIST"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Notcher $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if (( NOTARIZE )); then
  echo "Submitting to Apple for notarization (usually a few minutes)…"
  # Capture the output instead of piping into grep -q: grep exits at the first match, and under
  # pipefail the broken pipe made an accepted submission look like a failure.
  RESULT="$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1)" || true
  echo "$RESULT"
  [[ "$RESULT" == *"status: Accepted"* ]] \
    || { echo "Notarization was not accepted; see: xcrun notarytool log <id> --keychain-profile $PROFILE" >&2; exit 1; }
  # The ticket can take a moment to become available after acceptance.
  for attempt in 1 2 3 4 5; do
    xcrun stapler staple "$DMG" && break
    echo "Staple attempt $attempt failed; retrying in 20 s…"
    sleep 20
  done
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

  # Record the release: commit the version bump (if any) and tag it.
  if [[ -n "$NEW_VERSION" ]]; then
    git add "$PLIST"
    git commit -q -m "Version $VERSION"
  fi
  git tag -f "v$VERSION"
  echo "Tagged v$VERSION"
fi

echo "Done: $DMG"
