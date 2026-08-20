---
name: extension
description: Rebuild, reinstall and verify the Finder extension end to end. Use whenever anything under App/ changes — the reinstall sequence has four mandatory steps, and skipping one silently tests a stale build.
---

# Rebuild and verify the Finder extension

macOS caches which extension bundle it loads and where it lives. Editing code
and rebuilding is **not** enough: without the full sequence below, the system
keeps serving the previous build and you debug a version that no longer exists.

Run every step. Report what each one produced.

## 1. Build

```bash
cd "$(git rev-parse --show-toplevel)/App"
xcodebuild -project BrailliantConnect.xcodeproj -scheme BrailliantConnect \
  -configuration Debug -allowProvisioningUpdates build 2>&1 \
  | grep -E "error:|BUILD" | head -5
```

`xcodebuild` exits through a pipe here, so its own status is lost: read the
`** BUILD` line, never `$?`.

A source file added on disk but never added to the project is invisible to the
build, and the error says `cannot find '<Type>' in scope` for code that is
plainly there. Files are added in Xcode; `project.pbxproj` is what decides.

## 2. Stop what is running

```bash
cd "$(git rev-parse --show-toplevel)"
./.build/release/brailliant finder off 2>/dev/null
pkill -f "BrailliantConnect.app/Contents/MacOS" 2>/dev/null
```

## 3. Reinstall and re-register

```bash
SRC=$(find ~/Library/Developer/Xcode/DerivedData/BrailliantConnect-*/Build/Products/Debug \
  -maxdepth 1 -name "BrailliantConnect.app" | head -1)
pluginkit -r /Applications/BrailliantConnect.app/Contents/PlugIns/FileProviderExtension.appex 2>/dev/null
rm -rf /Applications/BrailliantConnect.app
ditto "$SRC" /Applications/BrailliantConnect.app
pluginkit -a /Applications/BrailliantConnect.app/Contents/PlugIns/FileProviderExtension.appex
pluginkit -e use -i com.mathieumartin.BrailliantConnect.FileProvider
```

The copy into `/Applications` is not optional: the system refuses to load an
extension from `DerivedData`. The `-r` before `-a` matters too — otherwise
`pluginkit` keeps pointing at the old path.

**Never** run `codesign --deep` on the app to fix a signing complaint. It strips
the extension's entitlements, which then fails to load with *"Extension must
have `com.apple.security.app-sandbox` entitlement"*. Libraries are signed
individually by a build phase.

## 4. Verify

```bash
./.build/release/brailliant finder on
sleep 8
ls ~/Brailliant/
```

Expect the display's real folders (`books`, `documents`, `notes`…).

If it is empty or hangs, read the extension's own log rather than guessing:

```bash
log show --last 2m --predicate 'subsystem == "com.mathieumartin.BrailliantConnect"' \
  --style compact | tail -10
```

## When it fails

- **"Aucune plage braille HumanWare détectée"** while `ioreg` shows the device —
  the display is asleep. It stays enumerated on USB but stops exposing its MTP
  interface. Ask the user to wake it; do not report a fault.
- **`libusb_claim_interface = -3`** — something else holds the session. MTP
  allows only one at a time, so the CLI and the extension cannot both talk to
  the display.
- **`providerNotFound` (-2001)** or **"Extension not registered" (-2014)** —
  do not suspect signing first, the message misleads. Check the traps listed in
  `CLAUDE.md`, then compare against Apple's sample project.
