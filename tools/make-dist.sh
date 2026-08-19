#!/bin/bash
#
# Builds the distributable app: the Finder extension, the background agent and
# the command-line tool, in one signed and notarized bundle.
#
# Usage:
#   ./tools/make-dist.sh              # ad-hoc signature, for local testing
#   ./tools/make-dist.sh --notarize   # Developer ID, notarized and stapled
#
# Everything ships inside the .app on purpose. A bare command-line executable
# cannot carry a stapled notarization ticket, whereas an app can — so a user
# who downloads this gets a bundle Gatekeeper accepts offline, with the CLI
# inside it rather than as a second, unstapled file.
#
# Prerequisites for --notarize (already in place as of 19 Aug 2026):
#   - "Developer ID Application: Mathieu Martin (633EG76YX5)" in the keychain
#   - notarytool profile $NOTARY_PROFILE registered. Check with:
#       xcrun notarytool history --keychain-profile "$NOTARY_PROFILE"
#     Profiles are not tied to an app, hence reusing the ttaccessible one.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
DIST="$ROOT/dist"
APP_NAME="BrailliantConnect"
SIGN_IDENTITY="Developer ID Application: Mathieu Martin (633EG76YX5)"
NOTARY_PROFILE="ttaccessible-notary"
TEAM_ID="633EG76YX5"

NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --notarize) NOTARIZE=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '\n=== %s ===\n' "$*"; }

cd "$ROOT"

# --- Tests --------------------------------------------------------------------
# No package may ship if a test fails: they cover path confinement, which is
# what keeps a hostile file name from writing outside its destination.

log "Tests"
if ! swift test 2>&1 | grep -qE "with 0 failures"; then
  echo "ERROR: the test suite fails, distribution aborted." >&2
  exit 1
fi
swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1

# --- Command-line tool --------------------------------------------------------

log "Building the CLI (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
CLI="$ROOT/.build/apple/Products/Release/brailliant"
[ -f "$CLI" ] || { echo "ERROR: CLI not found ($CLI)" >&2; exit 1; }

# --- App, agent and extension -------------------------------------------------

log "Building the app and the Finder extension"
xcodegen generate --spec App/project.yml >/dev/null

if [ "$NOTARIZE" -eq 1 ]; then
  # Developer ID requires archiving with manual signing, then exporting: an
  # identity cannot simply be forced onto an automatically signed build, which
  # Xcode rejects as conflicting provisioning settings.
  #
  # The hardened runtime comes with it, and brings library validation: the
  # embedded dylibs must be signed by the same team, which the build phase does.
  ARCHIVE="$DIST/$APP_NAME.xcarchive"
  EXPORT_DIR="$DIST/export"
  rm -rf "$ARCHIVE" "$EXPORT_DIR"

  xcodebuild -project App/BrailliantConnect.xcodeproj -scheme "$APP_NAME" \
    -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" -derivedDataPath "$DIST/DerivedData" \
    archive \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=YES >/dev/null

  cat > "$DIST/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>${TEAM_ID}</string>
    <key>signingStyle</key><string>manual</string>
</dict>
</plist>
PLIST

  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$DIST/ExportOptions.plist" >/dev/null
  APP="$EXPORT_DIR/$APP_NAME.app"
else
  xcodebuild -project App/BrailliantConnect.xcodeproj -scheme "$APP_NAME" \
    -configuration Release -allowProvisioningUpdates \
    -derivedDataPath "$DIST/DerivedData" build >/dev/null
  APP="$DIST/DerivedData/Build/Products/Release/$APP_NAME.app"
fi

[ -d "$APP" ] || { echo "ERROR: app not found ($APP)" >&2; exit 1; }

# --- Assembling ---------------------------------------------------------------

log "Assembling"
rm -rf "$DIST/$APP_NAME.app" "$DIST/$APP_NAME.zip"
ditto "$APP" "$DIST/$APP_NAME.app"
APP="$DIST/$APP_NAME.app"

# The CLI travels beside the agent, and finds the libraries through the same
# rpath the agent uses.
cp "$CLI" "$APP/Contents/MacOS/brailliant"
chmod 755 "$APP/Contents/MacOS/brailliant"
install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "$APP/Contents/MacOS/brailliant" 2>/dev/null || true

cp "$VENDOR/LICENSE-libmtp.txt" "$VENDOR/LICENSE-libusb.txt" "$APP/Contents/Resources/" \
  2>/dev/null || {
    mkdir -p "$APP/Contents/Resources"
    cp "$VENDOR/LICENSE-libmtp.txt" "$VENDOR/LICENSE-libusb.txt" "$APP/Contents/Resources/"
  }

# --- Signing ------------------------------------------------------------------
# Inside out: signing the app seals what it contains, so anything modified
# afterwards would invalidate it. Never use --deep, which would overwrite the
# extension's entitlements and stop it from loading.

log "Signing"
IDENTITY="-"
RUNTIME_FLAGS=()
if [ "$NOTARIZE" -eq 1 ]; then
  IDENTITY="$SIGN_IDENTITY"
  RUNTIME_FLAGS=(--options runtime --timestamp)
fi

# The extension is deliberately not re-signed: Xcode already signed it with its
# entitlements during the build. Re-signing without passing --entitlements
# silently drops them, and the extension then refuses to load with a message
# that blames something else entirely.
for lib in "$APP/Contents/Frameworks"/*.dylib; do
  [ -f "$lib" ] && codesign --force ${RUNTIME_FLAGS[@]+"${RUNTIME_FLAGS[@]}"} --sign "$IDENTITY" "$lib"
done

# Only the CLI was added after the build, so only it needs signing.
codesign --force ${RUNTIME_FLAGS[@]+"${RUNTIME_FLAGS[@]}"} --sign "$IDENTITY" \
  "$APP/Contents/MacOS/brailliant"

# Re-sealing the app must carry its entitlements explicitly, for the same
# reason as above.
codesign --force ${RUNTIME_FLAGS[@]+"${RUNTIME_FLAGS[@]}"} \
  --entitlements "$ROOT/App/BrailliantConnect/BrailliantConnect.entitlements" \
  --sign "$IDENTITY" "$APP"

log "Verifying"
codesign --verify --strict --verbose=1 "$APP" 2>&1 | sed 's/^/    /'
# The extension must have kept its own sandbox entitlement: without it the
# system refuses to load it, with a message that points elsewhere.
if ! codesign -d --entitlements - "$APP/Contents/PlugIns/FileProviderExtension.appex" 2>/dev/null \
     | grep -q "app-sandbox"; then
  echo "ERROR: the extension lost its sandbox entitlement." >&2
  exit 1
fi
echo "    extension: sandbox entitlement present"
# get-task-allow lets any process attach to ours. Xcode adds it to debug builds,
# and a debug build reaching this script would ship a debuggable agent holding a
# live MTP session over the user's files.
for target in "$APP" "$APP/Contents/PlugIns/FileProviderExtension.appex"; do
  if codesign -d --entitlements :- "$target" 2>/dev/null | grep -q "get-task-allow"; then
    echo "ERROR: $(basename "$target") carries get-task-allow — debug build, not distributable." >&2
    exit 1
  fi
done
echo "    no get-task-allow: not debuggable"
lipo -info "$APP/Contents/MacOS/brailliant" | sed 's/^/    /'

# --- Notarization -------------------------------------------------------------

ZIP="$DIST/$APP_NAME.zip"
# ditto preserves signatures and extended attributes, unlike zip.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [ "$NOTARIZE" -eq 1 ]; then
  log "Notarizing"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

  log "Stapling the ticket"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP" | sed 's/^/    /'

  log "Gatekeeper"
  spctl --assess --type execute --verbose=2 "$APP" 2>&1 | sed 's/^/    /' || true

  # Re-zip so the archive carries the stapled ticket: without this the user
  # would still need a network round trip on first launch.
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi

log "Done"
echo "  App     : $APP"
echo "  Archive : $ZIP ($(du -h "$ZIP" | cut -f1))"
if [ "$NOTARIZE" -eq 0 ]; then
  echo
  echo "  Ad-hoc signature: fine on this machine, but macOS will warn other"
  echo "  users. Run with --notarize for a distributable build."
fi
