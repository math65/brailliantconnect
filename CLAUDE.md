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

That same KeepAlive is why **terminating is not quitting**: a process that exits
on its own is back ten seconds later, and the menu bar item with it. *Quit*
therefore unpublishes the location and calls `Installer.stopAgent()`
(`launchctl bootout`) — the pair the CLI's `disable` has always used. The plist
is left alone: whether the agent returns at the next login stays the business of
*Open at Login*, which is also why `unregister()` only deletes that file.

`Installer.uninstall` removes everything the app wrote — `ownedPaths` is the
list, and it is the same list installing works from. Three things it is easy to
get wrong:

- `~/Library/Containers/…` refuses `removeItem` with "Operation not permitted",
  even as root. It was documented here as impossible; it is not. The Finder
  moves those folders to the Trash without difficulty, and `trashItem` takes
  the same privileged route — hence the fallback.
- the app also writes outside the obvious places: `~/Library/WebKit/<bundle id>`
  (200 KB, from the welcome window's web view) and **two** Group Containers,
  with and without the team prefix. None of them were in the list until a user
  found them by hand.
- `pluginkit -r` takes one path at a time, so the registrations are listed
  first and removed individually.

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
swift test                    # 51 tests
```

`Package.swift` links libmtp through the **relative** path
`Vendor/libmtp.9.dylib`, so builds must run from the repository root.

The Xcode project is **committed**: cloning the repository is enough to open it
and build. Nothing to install, nothing to generate.

```bash
xcodebuild -project App/BrailliantConnect.xcodeproj -scheme BrailliantConnect \
  -configuration Debug -allowProvisioningUpdates build
```

`./tools/make-dist.sh` produces the distributable bundle. It runs the test suite
first and refuses to package if anything fails. `CODESIGN_IDENTITY="Developer ID
Application: NAME (TEAMID)"` adds the hardened runtime for notarisation.

`./tools/build-vendor.sh` rebuilds libmtp and libusb as universal binaries into
`Vendor/`. Rarely needed — only to change versions. Neither script touches
`App/`.

## Xcode project settings

The project was described by an `App/project.yml` until 20 Aug 2026, and
XcodeGen turned that into the `.xcodeproj`. The YAML is gone. What it could
carry and a `project.pbxproj` cannot is a comment beside each setting saying why
it is there, so those reasons live here — every one of them is a setting whose
loss produces an error pointing somewhere other than its cause.

**Two targets.** `BrailliantConnect` — the app, which is also the agent —
embeds `FileProviderExtension` **without signing it**: "Embed Without Signing",
as Apple's own sample does. Re-signing the extension as it is embedded replaces
its entitlements with the host app's, and it then refuses to load. Same cause as
the `codesign --deep` trap below, at a different moment.

**The agent compiles two files out of `BrailliantKit`**, not the whole of it:
`FinderLocation.swift` and `Localization.swift`. It shares the location paths
and the translation table with the extension and nothing else — which is what
keeps libmtp out of the process that is not sandboxed (see **Security
properties**).

**The extension:**

- `ENABLE_APP_SANDBOX: YES` — mandatory for an extension, and worth re-checking
  after Xcode has touched the project: it sometimes drops it while propagating
  the host app's entitlements.
- `ENABLE_DEBUG_DYLIB: NO` — see **Traps**.
- `GENERATE_INFOPLIST_FILE: NO`, with an explicit `INFOPLIST_FILE`, because the
  `NSExtension` dictionary is written by hand (see **Traps**).
- `SWIFT_INCLUDE_PATHS: $(SRCROOT)/../Sources/CMTP` — headers of the C shim that
  exposes libmtp to Swift.
- `OTHER_LDFLAGS: $(SRCROOT)/../Vendor/libmtp.9.dylib` — the library is linked
  by its path: its file name does not follow the `-lmtp` convention the linker
  expects.
- `LD_RUNPATH_SEARCH_PATHS: @executable_path/../../../../Frameworks` — four
  levels up, because the libraries travel in the *app's* `Contents/Frameworks`
  and the extension sits inside the app.

**Both targets** run a post-build script that copies `libmtp.9.dylib` and
`libusb-1.0.0.dylib` into `Contents/Frameworks` and signs each one
**separately**, never the bundle as a whole.

**The app** is `LSUIElement: YES` — a menu bar item, no Dock icon, no window.
Both targets are hardened-runtime, automatically signed, team `633EG76YX5`,
deployment target macOS 11.0.

Adding a source file now means adding it in Xcode, which writes it into
`project.pbxproj`. A file dropped into the folder alone is invisible to the
build, and the error says `cannot find '<Type>' in scope` for code that is
plainly there.

## Testing the Finder extension

Use `/extension`. Every step is required — skipping one silently tests a stale
build:

1. rebuild via `xcodebuild`
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
  - HID interfaces only → file transfer is not turned on, and the user has to
    turn it on from the display's own menu;
  - an interface of class 6, or vendor-specific and named `MTP` → reachable.

  The braille side and file transfer are **not exclusive**: an available
  display publishes its two HID interfaces *and* the MTP one at once, and stays
  usable as a braille terminal throughout. Wording that asks the user to
  "switch to file transfer mode" is wrong — nothing is switched off.

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
