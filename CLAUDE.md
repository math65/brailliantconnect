# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

macOS tooling that exposes a HumanWare Brailliant braille display over MTP —
without macFUSE. Three parts:

- `BrailliantKit` — the MTP layer. Compiled into **both** the CLI and the
  Finder extension.
- `brailliant` — the command-line tool. It is an instrument for probing the
  protocol and driving the agent, **not** the product shipped to end users.
- `App/` — a background agent plus a File Provider extension. The extension
  exists in an app bundle because it must be, and because only that bundle may
  register a File Provider domain.

Opening the app registers the agent with launchd and **exits**; the resident
copy is the one launchd starts, with `--watch`. Keeping the double-clicked
process alive instead makes launchd's copy find it, exit, and be restarted by
KeepAlive forever. The resident copy owns the single piece of UI: a menu bar
item (state, open in Finder, open at login, uninstall).

`Installer.uninstall` removes everything the app wrote — `ownedPaths` is the
list, and it is the same list installing works from. Two exceptions, both real:
`~/Library/Containers/…` is owned by containermanagerd and cannot be deleted by
anyone, root included; and `pluginkit -r` takes one path at a time, so the
registrations are listed first and removed individually.

## Language conventions

Decided 19 Aug 2026, as the project targets an international (mostly English)
audience:

- **Identifiers and comments: English.** Much of the existing code is still in
  French (`AccèsPlage`, `créerRaccourci`, `nombreDePlagesBranchées`). A
  migration is planned — write anything new in English, and translate what you
  touch.
- **User-facing strings: localised**, French and English, via the standard
  macOS mechanism. Error messages in `MTPError` are currently French-only.
- **Commit messages: English**, subject plus a body explaining *why*. The nine
  existing commits are in French; do not rewrite them.

## Build

```bash
swift build -c release        # CLI — run from the repo root
swift test                    # 32 tests
```

`Package.swift` links libmtp through the **relative** path
`Vendor/libmtp.9.dylib`, so builds must run from the repository root.

The Xcode project is a build artifact, ignored by git. `App/project.yml` is the
source of truth — **regenerate after editing it**, or the build will fail on
files it cannot see:

```bash
xcodegen generate --spec App/project.yml
xcodebuild -project App/BrailliantConnect.xcodeproj -scheme BrailliantConnect \
  -configuration Debug -allowProvisioningUpdates build
```

`./tools/make-dist.sh` produces the distributable bundle. It runs the test suite
first and refuses to package if anything fails. `CODESIGN_IDENTITY="Developer ID
Application: NAME (TEAMID)"` adds the hardened runtime for notarisation.

`./tools/build-vendor.sh` rebuilds libmtp and libusb as universal binaries into
`Vendor/`. Rarely needed — only to change versions. Neither script touches
`App/`.

## Testing the Finder extension

Use `/extension`. Every step is required — skipping one silently tests a stale
build:

1. rebuild via `xcodegen` + `xcodebuild`
2. copy the app to `/Applications` — the system will not load an extension from
   `DerivedData`
3. `pluginkit -r <old .appex>` then `-a <new>`, then `-e use -i <bundle id>`
4. `killall fileproviderd` if it still serves a cached verdict

## Traps

Each of these produces an error that points somewhere other than its cause.

- **Never run `codesign --deep`** on the app afterwards: it overwrites the
  extension's entitlements, which then refuses to load with *"Extension must
  have `com.apple.security.app-sandbox` entitlement"*. Embedded libraries are
  copied and signed **individually** by a build phase.
- `ENABLE_DEBUG_DYLIB: NO` is mandatory. Xcode 16+ otherwise moves all code into
  a side dylib and leaves only a launcher in the binary; the system looks for
  the principal class **inside the binary** and answers `providerNotFound`
  (-2001).
- `NSExtensionFileProviderSupportsEnumeration` belongs **inside** the
  `NSExtension` dictionary, not at the plist root.
- The extension's App Group is deliberately an **empty array**, matching
  Apple's sample. Forcing a value makes the system discard the extension.
- USB detection must match `IOUSBHostDevice` (not `kIOUSBDeviceClassName`,
  which is the old stack) and filter by **reading each device's `idVendor`
  property** — filtering through the matching dictionary fails silently.
- A `main.swift`, even empty, is required in the extension target as its entry
  point.
- `UNUserNotificationCenter.requestAuthorization` called **before**
  `NSApplication.shared` exists is dropped without an error: the status stays
  *not determined* and nothing is ever delivered. The agent logs the resulting
  status at every start, because a refused permission and a working one are
  otherwise indistinguishable until a transfer ends in silence.
- Reading a permission or a notification status from a second executable
  dropped into `Contents/MacOS/` reports the wrong answer — it is not the
  application, whatever its path suggests. Measure from the agent itself.

## Hardware behaviour

- **MTP allows one session at a time.** While the extension holds the
  connection, the CLI fails with `libusb_claim_interface = -3`, and vice versa.
- **A visible display is not a reachable one.** Three states are told apart by
  `USBWatcher.availability()`, by inspecting the device's child interfaces on
  the **IOService plane** (`ioreg -p IOUSB` shows a different tree and will not
  answer this):
  - no interfaces → asleep, a keypress brings it back;
  - HID interfaces only → braille terminal mode, the user must switch it to
    file transfer;
  - an interface of class 6, or vendor-specific and named `MTP` → reachable.

  Only the last one publishes the location. "Has children" was the first
  criterion here and was wrong: in braille terminal mode the device publishes
  two HID interfaces, so it looked connected and the Finder showed a folder
  that hung.
- **MTP emits no change notifications.** Anything edited on the display itself
  goes unnoticed until re-enumeration.

## Storages

The root of the domain holds **one folder per storage**, never files: the
extension used to call `defaultStorage()` everywhere, which left a USB stick
plugged into the display invisible with no way to reach it. Consequences:

- storage folders carry a `storage:<id>` identifier. MTP object identifiers are
  plain numbers, so the prefix is what keeps the two from being confused.
- every path is relative to its own storage — `/documents` exists on both — so
  `DisplayAccess.target(_:)` points the connection at the right one before each
  operation. Nothing calls `connection()` directly any more.
- rebuilding the index after the extension is recycled walks **every** storage,
  or an item on the stick becomes unreachable for having been listed by a
  previous process.
- MTP cannot move across storages: that case downloads and re-uploads, and only
  deletes the original once the copy has landed.
- **nothing is created at the root.** Refusing an import means calling the
  completion handler with **no item and no error** — the system then deletes
  what it wrote locally. Passing an error instead leaves a file the Finder
  shows and the display never received, which is the trap here: the refusal
  looks handled and silently is not. `allowsAddingSubItems` alone does not
  stop it; the Finder still copies into the root, and the Terminal always
  did. Both barriers are needed. The refusal is also silent, so the extension
  posts a notification — it inherits the host app's permission, measured on
  the device (`authorization = 2`, `add: accepted`).

**No log from the extension reaches `log show`**, at any level, for any
predicate. Diagnosing it means writing to a file in its own container, which
is sandbox-writable and readable from outside.

## Deleting is not slow

Measured: ~13 ms per object, independent of size — 100 files in 1,46 s, one
file in 0,19 s including connection. Uploading is ~43 ms per object plus
~7 MB/s. Deletion therefore needs none of the "do not unplug" machinery that
copying does; there is no window in which unplugging can truncate anything.

## Transfers

Writing is asynchronous and the Finder hides it: `cp` into the location returns
in 0,02 s whatever the size, and the upload follows at ~7 MB/s. The agent reads
`NSFileProviderManager.globalProgress(for: .uploading)` — available from macOS
11.3, and readable by the host app, which avoids an App Group the extension
cannot have. Two traps in it:

- the aggregate is credited **one whole file at a time**. The bytes our
  extension reports are ignored, so a single large file shows no movement at
  all. The menu shows the size alone in that case rather than a counter stuck
  at zero.
- it emits no reliable final change when the last file lands, so a one-second
  timer is armed **only while a transfer runs** to catch the end.

## Security properties

Worth preserving deliberately, since a change elsewhere can quietly undo them:

- **The code that parses device data is the code that is confined.** libmtp is
  C, fed by whatever the USB device sends. The extension links it and **is
  sandboxed**; the agent is *not* sandboxed and **does not link libmtp** at
  all. `brailliant` links it outside any sandbox — that is the exposed surface,
  and one more reason it is an instrument rather than the product.
- **Names from the device are not path components.** `sanitizedForDisplay`
  removes control characters and leaves `..`, `.`, `a/b` intact; only
  `RemotePath.safeComponent` yields something a file system may be handed.
  Storage names go through it too — a storage calling itself `..` would
  otherwise become a folder of that name in the user's home.
- **Never delete what was not created here.** `createShortcut` overwrote
  `~/Brailliant` unconditionally, which would have destroyed a real folder of
  that name, recursively and without a Trash. Both the creation and the removal
  now check the symlink target.
- `make-dist.sh` refuses to package a bundle carrying `get-task-allow`: a debug
  build would ship an agent any process could attach to.

## Accessibility

The author uses a braille display with a screen reader, and so do the intended
users. CLI output is one fact per line — no ASCII tables, no meaning carried by
colour, progress in 10 % steps and suppressed outside a terminal. Keep it that
way.

## Documentation drift

`Vendor/README.txt` claims the libraries are loaded "par ctypes" — a leftover
from the retired Python prototype.

The `usage` string in `Sources/brailliant/main.swift` is a single translation
key: **editing it without editing the matching key in `Localization.swift`
silently drops the whole help back to English.** That is exactly how the French
help was lost when `mv` was added.
