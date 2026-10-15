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
swift build -c release 2>&1 | tail -1
./.build/release/brailliant finder off
pkill -f "BrailliantConnect.app/Contents/MacOS" 2>/dev/null
```

The CLI is built first: `finder off` here and `finder on` in step 4 run
whatever sits in `.build/release`, which may be missing or older than the
sources. `finder off` boots the agent out of launchd
(`gui/$UID/com.mathieumartin.BrailliantConnect.agent`), removes its plist and
unpublishes the location. Without the bootout, `KeepAlive` restarts the old copy
from `/Applications` while it is being replaced.

## 3. Reinstall and re-register

```bash
cd "$(git rev-parse --show-toplevel)"
SRC="$(xcodebuild -project App/BrailliantConnect.xcodeproj -scheme BrailliantConnect \
  -configuration Debug -showBuildSettings 2>/dev/null \
  | awk '$1 == "BUILT_PRODUCTS_DIR" { print $3; exit }')/BrailliantConnect.app"
[ -d "$SRC" ] || { echo "No build at $SRC — run step 1"; exit 1; }
pluginkit -r /Applications/BrailliantConnect.app/Contents/PlugIns/FileProviderExtension.appex 2>/dev/null
rm -rf /Applications/BrailliantConnect.app
ditto "$SRC" /Applications/BrailliantConnect.app
pluginkit -a /Applications/BrailliantConnect.app/Contents/PlugIns/FileProviderExtension.appex
pluginkit -e use -i com.mathieumartin.BrailliantConnect.FileProvider
```

`SRC` is asked of the project, not found by searching DerivedData: every
checkout and worktree has its own folder there, and a `find` picks whichever
comes first — or nothing, and `rm -rf` then removes the installed app before
`ditto` fails. The guard stops before anything is deleted.

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

Expect one folder per storage (`mémoire interne`, and `usb` when a stick is
plugged into the display), with the display's real folders one level down
(`books`, `documents`, `notes`…).

If it is empty or hangs:

- `fileproviderd` may still serve a cached verdict about the previous build:
  `killall fileproviderd` (launchd restarts it), then list again;
- a location that has never been enabled lists nothing: the Finder sidebar
  shows an **Enable** button under Locations until it is clicked once;
- do not reach for `log show` — no log from the extension reaches it, at any
  level, for any predicate. Read the files instead: the agent's log,
  `~/Library/Logs/BrailliantConnect.log`, and what the extension writes into
  its own container,
  `~/Library/Containers/com.mathieumartin.BrailliantConnect.FileProvider/Data/Library/Application Support/BrailliantConnect/`
  (`last-device.json` is written as it connects to the display).

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
