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
item (state, open in Finder, open at login, report a problem, check for
updates, uninstall).

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

Sparkle adds little to the list: its downloads, installations and URL cache
all live under `~/Library/Caches/<bundle id>/` (already there — the agent's
lock sits in the same folder), its `SU*` settings and the handover keys go
with the preferences domain, and its URLSession, which uses the default
configuration, writes `~/Library/HTTPStorages/<bundle id>` (both spellings are
listed). Its installer and progress agent are one-shot launchd jobs that
remove themselves. Whether anything else appears after a real update is on
the list of things to measure (see **Updates**).

## Language conventions

Decided 19 Aug 2026, as the project targets an international (mostly English)
audience:

- **Identifiers and comments: English.** Much of the existing code is still in
  French (`AccèsPlage`, `créerRaccourci`, `nombreDePlagesBranchées`). A
  migration is planned — write anything new in English, and translate what you
  touch.
- **User-facing strings: localised**, French and English — **not** through
  `NSLocalizedString` and `.lproj` folders, which neither a SwiftPM executable
  nor the extension can use, but through a table of our own:
  `L.t("English text")` in `Sources/BrailliantKit/Localization.swift` returns
  the French entry when the user is French (`LC_ALL`/`LC_MESSAGES`/`LANG`
  first, then `Locale.preferredLanguages`), and the English key otherwise. A
  string missing from the table is shown in English, silently. `MTPError`'s
  messages go through it too.
- **Commit messages: English**, subject plus a body explaining *why*. The nine
  existing commits are in French; do not rewrite them.

## Build

```bash
swift build -c release        # CLI — run from the repo root
swift test                    # 86 tests
```

`Package.swift` links libmtp through the **relative** path
`Vendor/libmtp.9.dylib`, so builds must run from the repository root.

The Xcode project is **committed**: cloning the repository is enough to open it
and build. Nothing to install, nothing to generate. Its one dependency,
Sparkle, is a Swift Package pinned to an **exact** version (2.10.0), and
`project.xcworkspace/xcshareddata/swiftpm/Package.resolved` — committed too —
records the commit of that tag; Xcode fetches it on the first build.

```bash
xcodebuild -project App/BrailliantConnect.xcodeproj -scheme BrailliantConnect \
  -configuration Debug -allowProvisioningUpdates build
```

`./tools/make-dist.sh --notarize` produces the distributable bundle, and
**`--notarize` is required**: the script refuses to run without it. The ad-hoc
mode it used to offer could not produce a working bundle — Xcode's automatic
signing gives the extension `get-task-allow` in Release as in Debug (measured
15 Oct 2026), which the script refuses since it never re-signs the extension,
and ad-hoc libraries fail library validation in the hardened extension. To try
a change locally, use `/extension`.

Before building, the script checks that the keychain's Developer ID
certificate is among those in `BrailliantConnect.provisionprofile` (by SHA-1),
prints the **certificate's** expiry (not the profile's, which outlives it by
years), and refuses to start without `AppBackendSecret.plist` — then checks
the built bundle carries it. It runs the test suite and refuses to package if
anything fails. The CLI's path is asked of SwiftPM (`--show-bin-path`) and
both architectures are checked: Xcode 27 moved the product, and 1.1.1 shipped
a stale CLI found at the old path. Long steps log into `dist/*.log` and print
their tail on failure. The identity and the notary profile are constants at the
top of the script — there is no `CODESIGN_IDENTITY` variable, whatever this
file said until 20 Aug 2026.

`./tools/build-vendor.sh` rebuilds libmtp and libusb as universal binaries into
`Vendor/`, refusing any tarball whose SHA-256 differs from the one pinned beside
its version. Rarely needed — only to change versions, and the one script here that
leaves `App/` alone: `make-dist.sh` builds the app through `xcodebuild` and
signs it against the entitlements in the tree.

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

**The agent compiles three files out of `BrailliantKit`**, not the whole of it:
`FinderLocation.swift`, `Localization.swift` and `UpdateHandover.swift`. It
shares the location paths and the translation table with the extension, and
the update handover's decisions with the tests, and nothing else — which is
what keeps libmtp out of the process that is not sandboxed (see **Security
properties**).

**The agent, and only the agent, links Sparkle** (the package product is in
the app target's Frameworks phase; Xcode embeds `Sparkle.framework` in
`Contents/Frameworks` on its own). Its Info.plist is still generated, and
`INFOPLIST_FILE = BrailliantConnect/Info.plist` adds the `SU*` keys the
generator has no setting for — Xcode merges the two. Lose that setting and the
app builds, starts, and has no feed and no key; `make-dist.sh` checks the
bundle for both.

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

**The app target** runs a build phase ("Embed libmtp and libusb", `set -eu`)
that copies `libmtp.9.dylib` and `libusb-1.0.0.dylib` into the **app's**
`Contents/Frameworks` and signs each one **separately**, never the bundle as a
whole; the same phase copies `AppBackendSecret.plist` when it exists. It also
re-signs Sparkle's nested executables (XPC services, `Autoupdate`,
`Updater.app`, then the framework) with the build's identity: they arrive
signed ad hoc and Xcode only re-signs the framework around them, and Sparkle's
installer swaps the bundle atomically only when `Autoupdate` carries the
update's team (see **Updates**). `make-dist.sh` does the same for a release,
with the timestamp. The
extension target used to run a copy of it into its own `Contents/Frameworks`,
which nothing loaded — its only rpath points at the app's — and was removed on
15 Oct 2026.

**The app** is `LSUIElement: YES` — a menu bar item, no Dock icon, no window.
Both targets are hardened-runtime, automatically signed, team `633EG76YX5`,
deployment target macOS 12.0 — raised from 11.0 on 29 Sep 2026, because
Xcode 27 refuses anything lower and stops the build with an error on the
project, not on any file.

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
- `Installer.register()` boots the job out before bootstrapping it, and
  `bootout` **terminates the process running that line** when the caller is the
  agent itself. The `bootstrap` after it never happens: the plist is on disk,
  no job is loaded, and the menu bar item is gone until the next login. That is
  what turning *Open at Login* back on used to do, so the menu passes
  `loadNow: false` — the agent is already running, and writing the registration
  is the whole of what it needs.
- `launchctl bootstrap` refuses a job launchd holds as **disabled** with
  "5: Input/output error", which says nothing of the cause (measured 17 Oct
  2026 with a throwaway label; a world-writable plist gives the same code).
  `register()` therefore reads `print-disabled` first and runs `enable`, and
  `--install` shows and logs launchctl's answer — 1.2.1 and older showed
  "make sure the app is in Applications", a check that had already passed.
- `~/Library/LaunchAgents` can **belong to root**, and then the plist cannot
  be written: "You don't have permission to save the file". HumanWare's Mac
  transfer package (0.1.3, `Mac-Mass-transfer-software.zip` on its support
  pages, read 22 Oct 2026 without running it) creates the folder with
  `mkdir -p` from a postinstall script running as root, so any Mac where the
  folder did not exist yet ends up that way — a user's new Mac did, and no
  version of the app could start there. `register()` therefore checks the
  folder first (`prepareAgentFolder`): owned by someone else, it asks for an
  administrator's password through `do shell script … with administrator
  privileges` and gives back **the folder alone** (`chown`, `chmod u+rwx`),
  never its contents. Declined or failed, the alert gives the two Terminal
  commands with the real path. Measured 22 Oct 2026 on the author's Mac
  (folder set to `root:wheel` by hand): declined, the alert and the log line;
  accepted, the folder back to the user, the five other plists untouched, the
  agent running.
- **An `NSAlert` from a process with no window never gets the focus** on
  macOS 14 and later: `activate(ignoringOtherApps:)` is ignored. `--install`
  showed its failures that way — the alert was on screen, VoiceOver never
  reached it, and the process waited on it forever (measured 22 Oct 2026).
  `refuse()` therefore uses `CFUserNotificationDisplayAlert`, drawn by the
  system, which takes the focus. Alerts opened from the menu are not
  affected: the click has already made the agent active.

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
- **The display's clock reads UTC, and libmtp reads its dates as local time.**
  Measured 15 Oct 2026 on a BI 40X: every date came back early by the Mac's
  offset from UTC — two hours in summer, one in winter, because libmtp's
  `mktime` applies daylight saving per date. `DisplayClock` (end of
  `Brailliant.swift`) undoes `mktime` and subtracts the display's own offset,
  assumed zero and recalibrated from each fresh upload, which the display
  stamps with its clock (libmtp sends no date). A copied file therefore shows
  when it reached the display, never its date on the Mac.

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
is sandbox-writable and readable by the agent. Not by everyone: from a Claude
Code shell, macOS's app-data protection answers "Operation not permitted",
sandbox or not, and so does the Finder driven through `osascript` (measured
15 Oct 2026). What reached the display is better read on the display itself:
`brailliant finder off`, then `brailliant tree`.

## Packages

Measured 15 Oct 2026 (macOS 27.0.1, BI 40X), after a user's Pages document
failed to copy:

- a package — Pages, Keynote, RTFD, anything conforming to
  `com.apple.package` — reaches `createItem` as **one item**: its
  `contentType` is the package type, not `.folder`, and its contents URL is
  the package directory. Its files are never created on their own;
  `fileproviderctl evaluate` knows none of them.
- tested with `== .folder`, it was taken for a file sent without contents:
  `localFileMissing`, mapped to "server unreachable" and retried. Creating
  the folder alone, the first fix, was worse: an empty folder on the display,
  and `isUploaded = 1` on the Mac.
- so the extension sends the tree itself (`uploadContents`), replaces it
  through a temporary name when it changes (`replaceFolder`), and answers
  `fetchContents` with a directory (`downloadContents`) — which the system
  accepts for a package, although the SDK header asks for a regular file.
  The listing gives a folder whose extension is a *declared* package type that
  type back, or it would return to the Mac as a plain folder.
- an RTFD and a real Pages document went there and back with `diff -r`
  empty and their type intact; editing a file inside the package on the Mac
  replaced it on the display.
- `NSExtensionFileProviderSupportsUnzippedPackages`, an undocumented key found
  in the system's shared cache, changed nothing.
  `NSExtensionFileProviderWantsFlattenedPackages` was not tried.
- around them: a symbolic link fails with `cannotSynchronize` (MTP stores
  none), which the SDK says is not retried until the item or the extension
  changes; an alias and an empty file go through as files;
  an iCloud document not downloaded is downloaded by the Finder before the
  copy, and arrives whole.

## Deleting is not slow

Measured: ~13 ms per object, independent of size — 100 files in 1,46 s, one
file in 0,19 s including connection. Uploading is ~43 ms per object plus
~7 MB/s. Deletion therefore needs none of the "do not unplug" machinery that
copying does; there is no window in which unplugging can truncate anything.

## Transfers

Writing is asynchronous and the Finder hides it: `cp` into the location returns
in 0,02 s whatever the size, and the upload follows at ~7 MB/s. The agent reads
`NSFileProviderManager.globalProgress(for: .uploading)` — readable by the host app, which avoids an App Group the extension
cannot have. Two traps in it:

- the aggregate is credited **one whole file at a time**. The bytes our
  extension reports are ignored, so a single large file shows no movement at
  all. The menu shows the size alone in that case rather than a counter stuck
  at zero.
- it emits no reliable final change when the last file lands, so a one-second
  timer is armed **only while a transfer runs** to catch the end.
- it **misses short transfers altogether**. Measured 15 Oct 2026: a 12 KB file
  landed and the agent logged nothing, even after the monitor learned to read
  old values. The extension sends a file in full before returning its
  `Progress`, so a small one is over before the system counts it in flight.

So the progress only says what is **in flight** (the menu, `isIdle` for
Sparkle). What **arrived** comes from the extension's own account:
`UploadLedger` (in `TransferMonitor.swift`) watches `events.log` beside
`last-device.json` through kernel events — no polling — and counts `create` and
`modify` lines: `ok` arrived, `error` with a `size=` failed to send; refusals
are told by the extension itself. A run is announced once the file has been
quiet for two seconds and nothing is in flight: one 12 KB file, then five at
once, gave one "Transfer complete" each (measured the same day). Only when the
ledger cannot be watched does the progress still announce, as every release
before 1.2 did.

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
- **Updates are code from the network, run unsandboxed.** Sparkle lives in the
  agent only — `make-dist.sh` refuses an extension that links it — reads its
  feed over HTTPS, and installs nothing that lacks a valid EdDSA signature
  from the author's key *and* a valid Apple code signature. The public key in
  `Info.plist` is the whole trust anchor: `make-dist.sh` refuses the
  placeholder, and a release with a wrong key could never be updated again.

## macOS 13

Measured on 9 September 2026 on a pristine Ventura 13.2.1 virtual machine,
after a user's report; every statement here comes with its control.

- **`fileproviderd` cannot read a third-party bundle under `/Applications`.**
  Its sandbox profile (`/System/Library/Sandbox/Profiles/com.apple.fileproviderd.sb`)
  lists no such path, and the kernel logs
  `Sandbox: fileproviderd deny(1) file-read-data /Applications/BrailliantConnect.app`
  at the second every publication fails. To learn which app is calling, the
  daemon first reads the caller's `com.apple.application-identifier`
  entitlement and only then falls back to reading the bundle from disk. Apps
  that carry the entitlement (Dropbox, Google Drive) never touch the disk. Ours
  did not, so `NSFileProviderManager.add` answered `providerNotFound` (-2001,
  "The application cannot be used right now") — from `--publish`, from `open`,
  from the resident agent, and for Apple's own FruitBasket sample alike. The
  same bundle in `~/Desktop` or `~/Applications` publishes; moved back to
  `/Applications`, it fails again. Hence the Developer ID provisioning profile
  and the distribution entitlements in `make-dist.sh`: with them, the same
  build publishes from `/Applications`. Without a profile the claim gets the
  app killed at launch ("Code has restricted entitlements, but the validation
  of its code signature failed").
- **A new location starts disabled.** `Domains.plist` says `Enabled = false`,
  every read answers -2011, and the extension is never launched. The Finder
  shows the location in its sidebar with the banner "“BrailliantConnect” is
  not enabled. To access “BrailliantConnect”, click Enable"; after the click
  the extension starts and the folder lists. The agent reads `userEnabled`
  and says so (menu, notification, welcome page, report, `--publish`). Not a
  macOS 13 trait: the probe workflow reads `Enabled` from `Domains.plist`, and
  fresh 14.8.9, 15.7.9 and 26.6.2 runners all answer `false` after a
  publication, list nothing from the location (`ls` hangs, as on 13) and never
  launch the extension until someone clicks. The key persists once set, which
  is why the author's Mac never asks: the click was made once, in August.
- **The extension is registered on its own.** `pluginkit` lists it right
  after the first launch, so the agent's line "the system holds no record of
  the Finder extension" is wrong on this version, and its `pluginkit -a` does
  nothing useful there.
- The VM, its tooling and every measurement are described in the auto-memory
  note `vm-ventura-tart`.

## The backend

The app talks to `app-backend` (the Go service behind `mathieumartin.ovh`),
registered there as `brailliantconnect`. Two things come from it: the feedback
routes behind *Report a Problem…*, and an announcement checked once per agent
start — the only channel back to people still on 1.1.1 or older, which have no
updater, and for anything release notes cannot carry (see **Updates**).

The Bearer key is **not in this repository**, which is public:
`App/BrailliantConnect/AppBackendSecret.plist` is git-ignored and copied into
`Contents/Resources` by the same build phase that embeds the libraries. Without
it `AppBackendClient.isConfigured` is false, the menu item is not added, and
nothing else changes — a contributor who clones this gets a working app, not a
build error. The key is an app identifier and an anti-spam gate, not a
credential: it grants posting to three routes as this app, and nothing else.

**Only the agent compiles those files.** The extension parses what the device
sends and is sandboxed for it; a network client there would widen the one
surface this project keeps narrow (see **Security properties**).

`Diagnostics.swift` is split on a hardware boundary, and that is the point:

- what the agent answers alone — app, macOS, `USBWatcher.availability()`,
  whether the domain is published, where the shortcut points — is **always**
  there, because none of it needs the display;
- model, serial and storages the agent **cannot ask for at all**. Measured 26
  Aug 2026, not assumed: with the location published, `brailliant doctor` run
  beside it fails with `libusb_claim_interface = -3`, and still failed a minute
  later. The lock is not transient — MTP allows a single session, and the
  extension holds it.

  So the extension writes what it sees as it connects (`writeSnapshot`, in
  `DisplayAccess.connection()`) into its own container —
  `…/Containers/<appex id>/Data/Library/Application Support/BrailliantConnect/last-device.json`,
  sandbox-writable there and readable by the agent, which is not sandboxed. No
  App Group is involved; the extension's is deliberately empty. The snapshot
  carries the date it was written, because one from last week may describe a
  different display.

  `brailliant doctor` remains the fallback for the case with no snapshot — no
  location published, extension never run — and there its failure is attached
  rather than dropped.

  One text file travels with the report, and **the agent's own log leads it**:
  the sections say *that* the location is not published, and only
  `~/Library/Logs/BrailliantConnect.log` says what the system answered when it
  was asked to publish it. The first report to arrive had every section and no
  log, and the one question worth asking was the one it could not answer. Only
  the last 64 KB go — the file has no rotation. The backend takes a single
  `log_file`, so the doctor's output, when there is one, is appended to the
  same file under its own heading rather than sent beside it.

The **subject** picked in the window (`Feedback.Subject`) drives the report: it
names the email, leads the first section, and decides what the window says
before anything is sent. Three of the four states a plugged display can be in
have a remedy the agent can already name, so it says so. It never blocks the
send — a Mantis reading as "reachable" while the Finder shows nothing is
exactly the report worth receiving.

## Updates

Sparkle 2, from 1.2.0. **1.1.1 and older have no updater**: their users must
download 1.2.0 once by hand (the announcement channel and the AppleVis thread
are how they hear of it); everything after arrives on its own.

- **Sparkle 2.10.0, exact.** The latest release when this was added (published
  13 Sep 2026, tag commit `eef1a539`), the first to require macOS 12 —
  exactly this project's floor since Xcode 27 — and it carries the 2.9.6
  security fixes to the installer. `Package.resolved` pins the commit and
  SwiftPM checks the binary's checksum. Moving to a newer one is a deliberate
  edit of the pin, read with its changelog.
- **Feed:** `appcast.xml` at the repository root, served from
  `raw.githubusercontent.com/math65/brailliantconnect/main/appcast.xml`; the
  zips are the GitHub release assets. Items are added by the release skill
  (step 8), only once the asset exists.
- **Key:** the author's existing EdDSA key, the one the author's other apps use — the
  keychain item under Sparkle's **default** account, so no `--account`
  anywhere. Its public half is `SUPublicEDKey` in
  `App/BrailliantConnect/Info.plist`, pasted from `generate_keys -p` on 15 Oct
  2026 (`DSDUNhrN…j/to=`). Replace it only together with the private key: a
  release carrying a key that matches nothing can never be updated again.
  Without a valid key Sparkle refuses to start, the agent logs "updates
  disabled", *Check for Updates…* is absent, and `make-dist.sh` refuses to
  package.
- **Scheduled checks** about once a day (`SUScheduledCheckInterval`), on from
  the start (`SUEnableAutomaticChecks`, so no permission prompt), and
  **refused while a transfer runs** (`updater(_:mayPerform:)` — the
  non-deprecated form of `updaterMayCheckForUpdates`). A refused check waits
  for the next interval.
- **Scheduled updates install themselves** (`SUAutomaticallyUpdate`). Sparkle
  downloads, prepares, then offers to install "on quit" — never, for an agent.
  `willInstallUpdateOnQuit` returns true and runs the immediate installation
  as soon as `transfers.isIdle`, polling every 5 s only while one waits.
- **Manual path:** *Check for Updates…* opens Sparkle's standard window
  (release notes, Install / Later). Its "Install" goes through
  `shouldPostponeRelaunchForUpdate`, held there while a transfer runs.
- **Never mid-transfer, even at the last moment:** a transfer can start
  between Sparkle's go-ahead and its quit event; `applicationShouldTerminate`
  then answers `.terminateCancel` (Sparkle sends a quit *event* precisely so it
  can be refused) and asks again when idle, with the handler kept from
  `shouldPostponeRelaunch` — Sparkle allows invoking it again.
- **Saying it:** at the first start of a new build (compared with
  `LastRunBuild`, so an update installed at logout counts too) the agent logs
  it, posts "BrailliantConnect X installed" once the notification permission
  is known, and the menu carries "Updated to X on <date>" until it has been
  opened once (`menuWillOpen`, not `menuNeedsUpdate`, which AppKit also calls
  for key equivalents). A scheduled update that needs someone — an app the
  user cannot write to, a major or informational update — opens Sparkle's
  window and posts "BrailliantConnect X is available": gentle reminders are on,
  because a window appearing by itself is not announced by VoiceOver. Do not
  set `sparkle:minimumAutoupdateVersion`, `criticalUpdate` or
  `informationalUpdate` casually: each turns the silent install into a wait.

### The handover — launchd and Sparkle

What Sparkle's installer does, read in its source (2.10.0): it asks the app to
quit with an Apple **quit event** sent to every `NSRunningApplication` of the
bundle; waits for **that one process** to terminate (KVO on `isTerminated`);
swaps the bundle **atomically** (`renamex_np` swap) — but only when
`Autoupdate` is signed by the update's team, otherwise it moves the old app
away and the new one in, with a moment where the path is empty; then relaunches
with `NSWorkspace openURL` on the bundle, **only if the installation
succeeded**. Its docs say plainly that an instance launched meanwhile is not
handled.

The resident agent is a `KeepAlive` job. An agent that has run longer than ten
seconds is restarted by launchd **at once** when it exits — before the swap,
most of the time: the old binary, starting from a bundle about to be replaced.
Sparkle's relaunch would then find an instance running and only activate it.

The approaches considered, and why not:

- **Let Sparkle's relaunch start the agent** — a plain launch is `--install`,
  i.e. `register()`: bootout and bootstrap. It converges, but only if the
  relaunch is a *new* process (not if the respawned old agent is already
  registered with LaunchServices), and `register()` rewrites the plist, which
  turns *Open at Login* back on for someone who had turned it off.
- **Quit by `bootout`** (what *Quit* does) — no respawn race, but Sparkle does
  not relaunch after a **failed** installation, so a failure would leave no
  agent until the next login; and the relaunch still rewrites the plist.
- **`updaterShouldRelaunchApplication` → false** — Sparkle then aborts the
  installation altogether (`mayUpdateAndRestart`).
- **`KeepAlive = {SuccessfulExit = false}`** — would end "terminating is not
  quitting" for every exit, not just this one.

What it does instead — **launchd stays the only thing that starts the resident
agent**:

1. `willInstallUpdate` writes a handover marker (`UpdateHandover` in the
   defaults: build that is quitting, version coming, date).
2. The quit event arrives; `AgentApplicationDelegate` unpublishes the location
   (as *Quit* does, 5 s cap — no folder left pointing at an extension about
   to be replaced) and lets the process exit 0. No bootout.
3. launchd restarts the job. `--watch` calls
   `AgentHandover.awaitNewVersionIfInstalling()` **before the lock**: with a
   fresh marker it compares the **inode of the file it was started from** —
   the kernel keeps it mapped, `proc_pidinfo(PROC_PIDREGIONPATHINFO)` on the
   main image names it — with what `stat` finds at the path now, and reads
   `CFBundleVersion` from disk (never `Bundle.main`, which after the swap
   describes the new bundle whichever binary asks). Old binary, swap pending:
   wait (≤ 90 s, no menu, no location). Old binary, swap done: `execv` the new
   executable with `--watch` — same process, same job, no ten-second
   throttle. New binary: carry on. Timeout: log, clear the marker, carry on as
   the old version — the only recovery from a failed install.
   `UpdateHandover.step` is the pure decision, tested.
4. Sparkle's relaunch is a launch without arguments; `--install` sees the
   fresh marker and **exits without touching launchd**. The marker is left to
   expire (10 min) rather than cleared, since the relaunch may come after the
   new agent has started.
5. The new agent sees a new build (`UpdateNotice.recordStart`), runs
   `Installer.registerExtension()` (`pluginkit -a` the new appex, `-e use`)
   **before** its first reconciliation, then publishes the location as usual —
   which is what makes `fileproviderd` start the extension from the new
   bundle.

Not covered: an agent that **crashes** while an update waits for a transfer.
Sparkle installs on any termination, launchd restarts the old binary first,
and no marker was written: the old code keeps running from the replaced bundle
until the agent next starts, when the update is noticed and announced.

### On the device

**Measured 15 Oct 2026** on the author's Mac (macOS 27.0.1, BI 40X), three
updates in a row from a local feed — 1.2.0 → 1.2.1 scheduled, 1.2.1 → 1.2.2
and 1.2.2 → 1.2.3 chosen from *Check for Updates…*:

- the scheduled one ran at the agent's first start (Sparkle checks then, no
  forcing needed): found, downloaded and installing in the same second, the
  new build running eight seconds later;
- each time: one agent, the launchd job's pid, the inode of the installed
  binary; the extension registered once, at the new version, from
  `/Applications`; the location republished; no `killall fileproviderd`;
- the notification arrived, the menu line showed once and was gone the next
  time the menu opened;
- with VoiceOver and a braille display, Sparkle's window read well and its
  buttons were reachable. Release notes as Markdown rendered as styled text,
  which the author found awkward; as HTML they show as a web page, which the author
  preferred — hence `tools/release-notes-html.py` and the release skill's
  step 8c;
- going back to an older build by hand was announced as an update, until
  `wasUpdated` required a newer build.

Still to measure: the quit refused when a transfer starts at the last moment;
updates with notifications refused; *Open at Login* off; what Sparkle writes
under `~/Library`. How, with a
local feed (the test plan is in the report that introduced this; in short:
two Debug builds with the real key, the higher one zipped and signed, served by
`python3 -m http.server`, the feed redirected with
`defaults write com.mathieumartin.BrailliantConnect SUFeedURL http://127.0.0.1:8000/appcast.xml`
— Sparkle reads a `SUFeedURL` from the defaults before the Info.plist):

- that launchd's restart comes before the swap (the log line "waiting for
  version X") or after it — both must end with one agent, the new build, its
  pid in `launchctl print gui/$UID/com.mathieumartin.BrailliantConnect.agent`;
- that `proc_pidinfo` gives the old inode in the stale process, and `execv`
  keeps the job's pid;
- that Sparkle's relaunch lands in `--install` and exits (no second agent, no
  bootout in the log, the plist untouched — try with *Open at Login* off);
- that the extension serving the location is the new one (`pluginkit -m -v -i
  com.mathieumartin.BrailliantConnect.FileProvider` shows the new version; the
  snapshot in its container is rewritten), and whether `killall
  fileproviderd` is ever needed — the `/extension` loop sometimes needs it;
- the quit refused while a transfer starts at the last moment, then the
  install once it ends;
- with notifications refused: the menu line alone;
- what Sparkle writes under `~/Library` (compare before and after; extend
  `ownedPaths`);
- the update notification and the menu line, read by VoiceOver.

A Debug build in `/Applications` carrying the real key checks the real feed:
it will update itself to the latest release. Use the `SUFeedURL` override, or
`defaults write … SUEnableAutomaticChecks -bool false`, while testing.

**VoiceOver, manual path:** Sparkle's window is its own AppKit UI. Check that
it takes the focus when *Check for Updates…* is chosen from the menu bar (the
agent activates itself first), that the release notes — HTML, shown by
Sparkle as a web page — are reachable and read in the user's language, that *Install*,
*Later* and *Skip This Version* are buttons VoiceOver names, and what
"Up to date" sounds like. Report what is wrong upstream rather than
re-implementing the window.

## Accessibility

The author uses a braille display with a screen reader, and so do the intended
users. CLI output is one fact per line — no ASCII tables, no meaning carried by
colour, progress in 10 % steps and suppressed outside a terminal. Keep it that
way.

## Documentation drift

`Vendor/README.txt` is written by hand. `build-vendor.sh` used to regenerate
it from a heredoc with older wording on every run; it now leaves it alone and
only warns when the versions it names differ from the ones it built.

The `usage` string in `Sources/brailliant/main.swift` is a single translation
key: **editing it without editing the matching key in `Localization.swift`
silently drops the whole help back to English.** That is exactly how the French
help was lost when `mv` was added.
