#!/bin/bash
#
# Builds the distributable app: the Finder extension, the background agent and
# the command-line tool, in one signed and notarized bundle.
#
# Usage:
#   ./tools/make-dist.sh --notarize   # Developer ID, notarized and stapled
#
# --notarize is required. There used to be an ad-hoc mode without it, and it
# could not produce a bundle that works anywhere:
#   - Xcode's automatic signing gives the extension get-task-allow, in Release
#     as in Debug (measured 15 Oct 2026). The extension is deliberately not
#     re-signed here, so the check below refused every ad-hoc bundle;
#   - the hardened extension, signed by a team, enforces library validation,
#     and the libraries the ad-hoc mode re-signed with "-" would not load in it.
# To try a change on this machine, use the /extension loop (a Debug build
# installed into /Applications); this script only makes what ships.
#
# Everything ships inside the .app on purpose. A bare command-line executable
# cannot carry a stapled notarization ticket, whereas an app can — so a user
# who downloads this gets a bundle Gatekeeper accepts offline, with the CLI
# inside it rather than as a second, unstapled file.
#
# Prerequisites:
#   - "Developer ID Application: Mathieu Martin (633EG76YX5)" in the keychain,
#     and the same certificate inside App/BrailliantConnect/
#     BrailliantConnect.provisionprofile (checked below — a renewed certificate
#     means a regenerated profile);
#   - notarytool profile $NOTARY_PROFILE registered. Check with:
#       xcrun notarytool history --keychain-profile "$NOTARY_PROFILE"
#     Profiles are not tied to an app, hence reusing the ttaccessible one;
#   - App/BrailliantConnect/AppBackendSecret.plist (git-ignored): without it
#     the shipped app has no Report a Problem and no announcements;
#   - the real SUPublicEDKey in App/BrailliantConnect/Info.plist, in place of
#     the placeholder (`generate_keys -p` prints it): without it the shipped
#     app can never be updated, and Sparkle refuses to start at all.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
DIST="$ROOT/dist"
APP_NAME="BrailliantConnect"
SIGN_IDENTITY="Developer ID Application: Mathieu Martin (633EG76YX5)"
NOTARY_PROFILE="ttaccessible-notary"
TEAM_ID="633EG76YX5"
PROFILE="$ROOT/App/BrailliantConnect/BrailliantConnect.provisionprofile"
BACKEND_KEY="$ROOT/App/BrailliantConnect/AppBackendSecret.plist"
APP_INFO="$ROOT/App/BrailliantConnect/Info.plist"
FEED_URL="https://math65.github.io/brailliantconnect/appcast.xml"
# A certificate closer than this to its end gets a warning, so that renewing
# it and regenerating the profile is planned rather than discovered.
CERT_WARNING_DAYS=60

NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --notarize) NOTARIZE=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [ "$NOTARIZE" -ne 1 ]; then
  cat >&2 <<'EOF'
ERROR: --notarize is required.
Without it this script used to sign ad hoc, and that bundle could not work:
the extension keeps the get-task-allow that Xcode's automatic signing gives it,
and ad-hoc libraries fail library validation in the hardened extension.
To test on this machine, use the /extension loop instead.
To build what ships: ./tools/make-dist.sh --notarize
EOF
  exit 2
fi

log() { printf '\n=== %s ===\n' "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

# Runs a command with its output in a log file; on failure, shows the end of
# that file instead of nothing at all.
run_logged() {
  local logfile="$1"; shift
  if ! "$@" >"$logfile" 2>&1; then
    echo "ERROR: $1 failed. Last lines of $logfile:" >&2
    tail -n 40 "$logfile" >&2
    exit 1
  fi
}

cd "$ROOT"
mkdir -p "$DIST"

# --- Preflight ----------------------------------------------------------------
# Everything that can be checked before a ten-minute build, is.

log "Signing certificate and provisioning profile"

# The identity codesign will pick: exactly one valid one must carry the name.
SIGN_SHA1="$(security find-identity -v -p codesigning \
  | awk -v name="$SIGN_IDENTITY" 'index($0, "\"" name "\"") { print $2 }' | sort -u)"
[ -n "$SIGN_SHA1" ] || fail "no valid identity \"$SIGN_IDENTITY\" in the keychain."
[ "$(printf '%s\n' "$SIGN_SHA1" | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "several valid identities named \"$SIGN_IDENTITY\": $(echo $SIGN_SHA1)."

# The profile authorises the agent's restricted entitlement for the
# certificates it lists, and no other: signed with a certificate that is not
# among them, the agent is killed at launch. A renewed certificate therefore
# means a regenerated profile.
[ -f "$PROFILE" ] || fail "no provisioning profile at $PROFILE."
PROFILE_PLIST="$DIST/profile.plist"
security cms -D -i "$PROFILE" > "$PROFILE_PLIST" 2>/dev/null \
  || fail "cannot decode $PROFILE."
PROFILE_MATCH=0
i=0
while CERT_B64="$(plutil -extract "DeveloperCertificates.$i" raw -o - "$PROFILE_PLIST" 2>/dev/null)"; do
  CERT_SHA1="$(printf '%s' "$CERT_B64" | base64 -D | shasum -a 1 | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]')"
  [ "$CERT_SHA1" = "$SIGN_SHA1" ] && PROFILE_MATCH=1
  i=$((i + 1))
done
rm -f "$PROFILE_PLIST"
if [ "$PROFILE_MATCH" -ne 1 ]; then
  cat >&2 <<EOF
ERROR: the signing certificate is not in the provisioning profile.
  certificate SHA-1: $SIGN_SHA1
  profile certificates: $i, none of them this one.
The agent would be killed at launch. Regenerate the profile on the developer
portal (Profiles, Developer ID, App ID com.mathieumartin.BrailliantConnect,
with the current certificate) and replace $PROFILE.
EOF
  exit 1
fi
echo "    certificate $SIGN_SHA1 is in the profile"

# The certificate's end date is the one that matters: the profile outlives it
# by years, and is useless without it.
CERT_PEM="$(security find-certificate -a -c "$SIGN_IDENTITY" -Z -p \
  | awk -v sha="$SIGN_SHA1" '
      /^SHA-1 hash:/ { keep = ($3 == sha) }
      keep && /BEGIN CERTIFICATE/ { inside = 1 }
      keep && inside { print }
      /END CERTIFICATE/ { inside = 0 }')"
[ -n "$CERT_PEM" ] || fail "cannot read the certificate $SIGN_SHA1 from the keychain."
CERT_END="$(printf '%s\n' "$CERT_PEM" | /usr/bin/openssl x509 -noout -enddate | cut -d= -f2)"
echo "    certificate expires: $CERT_END"
if ! printf '%s\n' "$CERT_PEM" \
     | /usr/bin/openssl x509 -noout -checkend $((CERT_WARNING_DAYS * 86400)) >/dev/null; then
  echo "    WARNING: less than $CERT_WARNING_DAYS days left. Renew the certificate," >&2
  echo "    then regenerate the provisioning profile with it." >&2
fi

# Without the key the build succeeds and the app quietly loses Report a
# Problem and the announcement channel — the only way back to people who
# installed it. Fine for a contributor's build, never for a release.
[ -f "$BACKEND_KEY" ] \
  || fail "no $BACKEND_KEY: the release would ship without Report a Problem."

log "Update key and feed"

# A release carrying the placeholder could never be updated again: Sparkle
# refuses to start without a valid key, and the only way to fix that would be
# asking every user to download the next version by hand.
ED_KEY="$(plutil -extract SUPublicEDKey raw -o - "$APP_INFO" 2>/dev/null || true)"
case "$ED_KEY" in
  ""|PLACEHOLDER*)
    fail "SUPublicEDKey in $APP_INFO is still the placeholder. Print the public
key with Sparkle's generate_keys -p (default keychain account) and paste it there." ;;
esac
[ "$(printf '%s' "$ED_KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" = "32" ] \
  || fail "SUPublicEDKey in $APP_INFO is not an Ed25519 public key (32 bytes, base64)."
echo "    public key: $ED_KEY"
[ "$(plutil -extract SUFeedURL raw -o - "$APP_INFO" 2>/dev/null || true)" = "$FEED_URL" ] \
  || fail "SUFeedURL in $APP_INFO is not $FEED_URL."
echo "    feed: $FEED_URL"

# --- Tests --------------------------------------------------------------------
# No package may ship if a test fails: they cover path confinement, which is
# what keeps a hostile file name from writing outside its destination.

log "Tests"
TEST_LOG="$DIST/swift-test.log"
if ! swift test >"$TEST_LOG" 2>&1; then
  tail -n 40 "$TEST_LOG" >&2
  fail "the test suite fails, distribution aborted (full output: $TEST_LOG)."
fi
grep -E "Executed [0-9]+ tests" "$TEST_LOG" | tail -1 | sed 's/^[[:space:]]*/    /'

# --- Command-line tool --------------------------------------------------------
# The product path is asked of SwiftPM, never written here: Xcode 27's SwiftPM
# moved it from .build/apple/Products/Release to .build/out/Products/Release,
# and 1.1.1 shipped a CLI left at the old path by an older toolchain. The
# previous product is removed first, so a stale one cannot be picked up again.

log "Building the CLI (arm64 + x86_64)"
CLI_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
CLI="$CLI_DIR/brailliant"
rm -f "$CLI"
run_logged "$DIST/swift-build.log" swift build -c release --arch arm64 --arch x86_64
[ -f "$CLI" ] || fail "CLI not found ($CLI)."
CLI_ARCHS="$(lipo -archs "$CLI")"
for arch in arm64 x86_64; do
  case " $CLI_ARCHS " in
    *" $arch "*) ;;
    *) fail "the CLI lacks $arch (it has: $CLI_ARCHS)." ;;
  esac
done
echo "    $CLI ($CLI_ARCHS)"

# --- App, agent and extension -------------------------------------------------
# Developer ID requires archiving with manual signing, then exporting: an
# identity cannot simply be forced onto an automatically signed build, which
# Xcode rejects as conflicting provisioning settings.
#
# The hardened runtime comes with it, and brings library validation: the
# embedded dylibs must be signed by the same team, which the build phase does.

log "Building the app and the Finder extension"
ARCHIVE="$DIST/$APP_NAME.xcarchive"
EXPORT_DIR="$DIST/export"
rm -rf "$ARCHIVE" "$EXPORT_DIR"

run_logged "$DIST/xcodebuild-archive.log" \
  xcodebuild -project App/BrailliantConnect.xcodeproj -scheme "$APP_NAME" \
    -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" -derivedDataPath "$DIST/DerivedData" \
    archive \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=YES

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

run_logged "$DIST/xcodebuild-export.log" \
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$DIST/ExportOptions.plist"
APP="$EXPORT_DIR/$APP_NAME.app"

[ -d "$APP" ] || fail "app not found ($APP)."

# --- Assembling ---------------------------------------------------------------

log "Assembling"
rm -rf "$DIST/$APP_NAME.app" "$DIST/$APP_NAME.zip"
ditto "$APP" "$DIST/$APP_NAME.app"
APP="$DIST/$APP_NAME.app"

# The build phase copies the key only when it exists, and says nothing when it
# does not: check the bundle, not the source tree.
[ -f "$APP/Contents/Resources/AppBackendSecret.plist" ] \
  || fail "the bundle carries no AppBackendSecret.plist: Report a Problem would be missing."

# Xcode merges App/BrailliantConnect/Info.plist into the generated one; a lost
# INFOPLIST_FILE setting would ship an app with no feed and no key, and nothing
# would fail before a user waited for an update that never comes.
[ "$(plutil -extract SUPublicEDKey raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)" = "$ED_KEY" ] \
  || fail "the bundle's Info.plist does not carry the SUPublicEDKey of $APP_INFO."
[ "$(plutil -extract SUFeedURL raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)" = "$FEED_URL" ] \
  || fail "the bundle's Info.plist does not carry the update feed."
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
[ -d "$SPARKLE" ] || fail "Sparkle.framework is not in the bundle."

# The CLI travels beside the agent, and finds the libraries through the same
# Frameworks folder the extension uses. The development rpaths (…/Vendor,
# relative to the build tree) are removed first: in the bundle they would
# point at /Applications/Vendor or /Vendor, folders nobody controls here.
cp "$CLI" "$APP/Contents/MacOS/brailliant"
chmod 755 "$APP/Contents/MacOS/brailliant"
otool -l "$APP/Contents/MacOS/brailliant" \
  | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }' \
  | grep '/Vendor$' | sort -u \
  | while IFS= read -r rpath; do
      install_name_tool -delete_rpath "$rpath" "$APP/Contents/MacOS/brailliant"
    done
install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "$APP/Contents/MacOS/brailliant"
if otool -l "$APP/Contents/MacOS/brailliant" | grep -q '/Vendor '; then
  fail "the bundled CLI still searches a Vendor folder."
fi

mkdir -p "$APP/Contents/Resources"
cp "$VENDOR/LICENSE-libmtp.txt" "$VENDOR/LICENSE-libusb.txt" "$APP/Contents/Resources/"
# Sparkle is MIT: its notice travels with the copy. Taken from the package
# this build resolved, so it always matches the version inside the bundle.
SPARKLE_LICENSE="$DIST/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/LICENSE"
[ -f "$SPARKLE_LICENSE" ] || fail "Sparkle's licence not found ($SPARKLE_LICENSE)."
cp "$SPARKLE_LICENSE" "$APP/Contents/Resources/LICENSE-Sparkle.txt"

# --- Signing ------------------------------------------------------------------
# Inside out: signing the app seals what it contains, so anything modified
# afterwards would invalidate it. Never use --deep, which would overwrite the
# extension's entitlements and stop it from loading.

log "Signing"
RUNTIME_FLAGS=(--options runtime --timestamp)

# The distributed agent claims its identity (com.apple.application-identifier)
# and carries the Developer ID provisioning profile that authorises the claim.
# macOS 13 needs it: fileproviderd reads that entitlement to learn which app is
# publishing a location, and otherwise reads the bundle from disk, which its
# sandbox refuses under /Applications — every publication then ends in -2001
# "The application cannot be used right now" (measured on a pristine 13.2.1,
# 9 Sep 2026).
APP_ENTITLEMENTS="$ROOT/App/BrailliantConnect/BrailliantConnect-distribution.entitlements"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

# The extension is deliberately not re-signed: Xcode already signed it with its
# entitlements during the build. Re-signing without passing --entitlements
# silently drops them, and the extension then refuses to load with a message
# that blames something else entirely.
for lib in "$APP/Contents/Frameworks"/*.dylib; do
  [ -f "$lib" ] && codesign --force "${RUNTIME_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$lib"
done

# Sparkle carries code of its own inside its framework, each piece signed on
# its own and inside out, as Sparkle documents for Developer ID — never with
# --deep. The XPC services are unused by an app that is not sandboxed, but
# they ship inside the framework and notarization checks every executable.
# The Downloader keeps whatever entitlements Sparkle gave it.
#
# Autoupdate signed with our team is not only for notarization: Sparkle swaps
# the old bundle for the new one atomically only when its installer and the
# update are signed by the same team, and otherwise falls back to moving the
# old app away and the new one in — leaving a moment with no executable at the
# path launchd restarts the agent from.
SPARKLE_B="$SPARKLE/Versions/B"
for xpc in "$SPARKLE_B/XPCServices"/*.xpc; do
  [ -d "$xpc" ] && codesign --force "${RUNTIME_FLAGS[@]}" --preserve-metadata=entitlements \
    --sign "$SIGN_IDENTITY" "$xpc"
done
codesign --force "${RUNTIME_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$SPARKLE_B/Autoupdate"
codesign --force "${RUNTIME_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$SPARKLE_B/Updater.app"
codesign --force "${RUNTIME_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$SPARKLE"

# Only the CLI was added after the build, so only it needs signing.
codesign --force "${RUNTIME_FLAGS[@]}" --sign "$SIGN_IDENTITY" \
  "$APP/Contents/MacOS/brailliant"

# Re-sealing the app must carry its entitlements explicitly, for the same
# reason as above.
codesign --force "${RUNTIME_FLAGS[@]}" \
  --entitlements "$APP_ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" "$APP"

log "Verifying"
codesign --verify --strict --verbose=1 "$APP" 2>&1 | sed 's/^/    /'
# The extension must have kept its own sandbox entitlement: without it the
# system refuses to load it, with a message that points elsewhere.
if ! codesign -d --entitlements - "$APP/Contents/PlugIns/FileProviderExtension.appex" 2>/dev/null \
     | grep -q "app-sandbox"; then
  fail "the extension lost its sandbox entitlement."
fi
echo "    extension: sandbox entitlement present"
# Sparkle belongs to the agent alone: the extension parses what the device
# sends, and must stay without a network client or an installer.
# (Captured first, then matched: `grep -q` leaving a pipe early can make the
# pipeline fail under pipefail, and the check would pass for the wrong reason.)
EXT_LIBS="$(otool -L "$APP/Contents/PlugIns/FileProviderExtension.appex/Contents/MacOS/FileProviderExtension")"
case "$EXT_LIBS" in
  *Sparkle*) fail "the extension links Sparkle." ;;
esac
echo "    extension: does not link Sparkle"
for part in "$SPARKLE_B/XPCServices/Installer.xpc" "$SPARKLE_B/XPCServices/Downloader.xpc" \
            "$SPARKLE_B/Autoupdate" "$SPARKLE_B/Updater.app" "$SPARKLE"; do
  [ -e "$part" ] || continue
  codesign --verify --strict "$part" 2>/dev/null \
    || fail "$(basename "$part") does not verify."
  PART_INFO="$(codesign -dv "$part" 2>&1)"
  case "$PART_INFO" in
    *"TeamIdentifier=$TEAM_ID"*) ;;
    *) fail "$(basename "$part") is not signed by team $TEAM_ID." ;;
  esac
  case "$PART_INFO" in
    *"flags="*runtime*) ;;
    *) fail "$(basename "$part") lacks the hardened runtime." ;;
  esac
done
echo "    Sparkle: every component signed by $TEAM_ID, hardened"
# The distributed agent must claim its identity and carry the profile that
# backs the claim: one without the other is an app that macOS 13 cannot serve,
# or one that macOS kills at launch.
if ! codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "application-identifier"; then
  fail "the agent does not claim com.apple.application-identifier."
fi
[ -f "$APP/Contents/embedded.provisionprofile" ] \
  || fail "no embedded.provisionprofile in the agent."
echo "    agent: identity claimed, profile embedded"
echo "    certificate expires: $CERT_END"
# get-task-allow lets any process attach to ours. Xcode adds it to builds
# signed for development, and a bundle carrying it would ship a debuggable
# agent holding a live MTP session over the user's files.
for target in "$APP" "$APP/Contents/PlugIns/FileProviderExtension.appex"; do
  if codesign -d --entitlements :- "$target" 2>/dev/null | grep -q "get-task-allow"; then
    fail "$(basename "$target") carries get-task-allow — development signature, not distributable."
  fi
done
echo "    no get-task-allow: not debuggable"
lipo -info "$APP/Contents/MacOS/brailliant" | sed 's/^/    /'

# --- Notarization -------------------------------------------------------------

ZIP="$DIST/$APP_NAME.zip"
# ditto preserves signatures and extended attributes, unlike zip.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

log "Notarizing"
# The verdict is read from notarytool's answer ("Accepted"), not inferred from
# its exit code. Anything else fetches Apple's log for the submission, the only
# place that says which file failed and why.
NOTARY_RESULT="$DIST/notary-result.plist"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
  --output-format plist >"$NOTARY_RESULT" 2>"$DIST/notarytool.log" || true
SUBMISSION_ID="$(plutil -extract id raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
NOTARY_STATUS="$(plutil -extract status raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
echo "    submission: ${SUBMISSION_ID:-unknown}"
echo "    status: ${NOTARY_STATUS:-unknown}"
if [ "$NOTARY_STATUS" != "Accepted" ]; then
  if [ -n "$SUBMISSION_ID" ]; then
    echo "Apple's log for this submission:" >&2
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
  else
    tail -n 40 "$DIST/notarytool.log" >&2
  fi
  fail "notarization was not accepted."
fi

log "Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP" | sed 's/^/    /'

log "Gatekeeper"
# A rejection here stops the release: it is what every user would see.
if ! SPCTL_OUT="$(spctl --assess --type execute --verbose=2 "$APP" 2>&1)"; then
  printf '%s\n' "$SPCTL_OUT" | sed 's/^/    /' >&2
  fail "Gatekeeper rejects the bundle."
fi
printf '%s\n' "$SPCTL_OUT" | sed 's/^/    /'

# Re-zip so the archive carries the stapled ticket: without this the user
# would still need a network round trip on first launch.
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

log "Done"
echo "  App     : $APP"
echo "  Archive : $ZIP ($(du -h "$ZIP" | cut -f1))"
# The tool that signs this archive for the appcast came with the package the
# build just resolved; the release skill takes it from here.
echo "  sign_update: $DIST/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
