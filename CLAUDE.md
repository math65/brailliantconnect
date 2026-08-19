# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

macOS tooling that exposes a HumanWare Brailliant braille display over MTP —
without macFUSE. Three parts:

- `BrailliantKit` — the MTP layer. Compiled into **both** the CLI and the
  Finder extension.
- `brailliant` — the command-line tool. It is an instrument for probing the
  protocol and driving the agent, **not** the product shipped to end users.
- `App/` — a headless agent plus a File Provider extension. The app has no UI;
  it exists only because an extension must be hosted by an app bundle, and only
  that bundle may register a File Provider domain.

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

## Hardware behaviour

- **MTP allows one session at a time.** While the extension holds the
  connection, the CLI fails with `libusb_claim_interface = -3`, and vice versa.
- **The display sleeps.** It stays enumerated on USB but stops exposing its MTP
  interface (`ioreg` shows no child interfaces). Detection currently keys on
  device presence, so the agent publishes a location the extension cannot
  serve. When MTP calls fail while the device is visible, **ask the user to wake
  the display** rather than reporting a fault.
- **MTP emits no change notifications.** Anything edited on the display itself
  goes unnoticed until re-enumeration.

## Accessibility

The author uses a braille display with a screen reader, and so do the intended
users. CLI output is one fact per line — no ASCII tables, no meaning carried by
colour, progress in 10 % steps and suppressed outside a terminal. Keep it that
way.

## Documentation drift

`README.md` predates the current state: it omits the `finder` command, never
mentions `xcodegen` or `App/`, and still presents Finder integration as future
work. `Vendor/README.txt` claims the libraries are loaded "par ctypes" — a
leftover from the retired Python prototype.
