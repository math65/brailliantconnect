# BrailliantConnect

Use a **Brailliant** braille display (HumanWare) on macOS — **no macFUSE, no
kernel extension, nothing to install**.

Connect the display and it appears in the Finder. Unplug it and it disappears.

Written in Swift. Tested on a Brailliant BI 40X (firmware 2.6.0), macOS 26,
Apple Silicon. Universal binary: Apple Silicon and Intel.

## The problem

The Brailliant exposes itself over **MTP** (Media Transfer Protocol), Android's
protocol. macOS cannot mount an MTP volume: nothing appears in the Finder when
you plug the display in.

The official utility therefore stacks two layers: a driver to reach the
hardware, then **macFUSE** to present the display as a mountable volume. macFUSE
is good software, actively maintained (5.3.3, July 2026), and its FSKit backend
even avoids the kernel extension on macOS 26. The problem is not macFUSE — it is
the stack. In practice several users end up with an empty folder and no mounted
volume, and HumanWare announced in April 2026 that it could no longer support
this route.

## The approach

Those layers are **removed rather than replaced**. Transferring a file over MTP
does not require mounting a volume: the protocol runs entirely in user space
over USB, and `libmtp` talks to the display directly.

A File Provider extension — Apple's own mechanism, the one behind iCloud Drive
and Dropbox — then makes the display appear in the Finder. It runs in user
space, needs no kernel extension, and works from macOS 11.

## Install

Download the archive, unpack it, then:

```bash
./brailliant finder on
```

That is all. The display now shows up in `~/Brailliant` whenever it is
connected, and a background agent keeps that in step with what is plugged in —
including across restarts.

Nothing else is required: no Homebrew, no macFUSE, no Python, no runtime.
`libmtp` and `libusb` ship inside the bundle as universal binaries (600 KB to
download, 1.9 MB unpacked).

To type `brailliant` from anywhere:

```bash
sudo ln -s "$PWD/brailliant" /usr/local/bin/brailliant
```

The symlink works: the program finds its libraries through its own path, not the
current directory.

## Use

Connect the display over USB and put it in **file transfer mode** (not braille
terminal mode).

| Command | What it does |
|---|---|
| `brailliant finder on\|off\|status` | watch the display and show it in the Finder |
| `brailliant info` | model, serial number, free space |
| `brailliant ls [path]` | list a folder (`-l` for sizes) |
| `brailliant tree [path]` | show the tree (`-d` to limit depth) |
| `brailliant get <remote> [local]` | copy from the display (file or folder) |
| `brailliant put <local> [remote]` | copy to the display (file or folder) |
| `brailliant rm <path>` | delete (`-r` for a folder and its contents) |
| `brailliant mkdir <path>` | create a folder |
| `brailliant clean` | remove macOS clutter files (`.DS_Store`…) |
| `brailliant doctor` | check that everything works |
| `brailliant bench` | measure protocol latency (diagnostics) |

```bash
brailliant put ~/Documents/novel.txt /documents
```

```bash
brailliant get /notes ~/Desktop
```

A display usually exposes **several storage areas**: internal memory, plus a USB
stick or memory card when one is present. Commands act on the first one unless
told otherwise:

```bash
brailliant -s usb ls /
```

`-s` takes the number shown by `brailliant info` or part of the name, ignoring
case and accents (`-s 2`, `-s usb`, `-s memoire`).

The default remote folder for `put` is `/documents`. Missing folders are created
automatically. macOS clutter files (`.DS_Store`, `._*`) are skipped during
transfers and hidden from listings (`-a` to see them).

## Accessibility

The author uses a braille display with a screen reader, and so do the intended
users. Output is built for that: one fact per line, no ASCII tables, no meaning
carried by colour, and progress reported in 10 % steps rather than a
continuously refreshing bar — suppressed entirely outside an interactive
terminal.

## Security

Data coming from the display is treated as **untrusted**: MTP places no
constraint on file names, and a device can return whatever it likes.

- **Path confinement.** A name containing `..` or `/` would, once joined to the
  destination folder, allow writing anywhere — as far as dropping a file into
  `~/Library/LaunchAgents`. Two independent barriers prevent it: non-conforming
  names are rejected on read, and the final target is checked to remain under
  the requested folder. Affected items are flagged in `ls` and skipped when
  copying, with a warning.
- **Sanitised output.** Names may contain ANSI escape sequences able to clear
  the screen or hide lines already printed, and so conceal what a command
  actually did. Control characters are neutralised before display.
- **Atomic overwrite.** MTP cannot replace a file in place. Rather than deleting
  the old one before the transfer — which would destroy data if the cable were
  pulled — the new file is sent under a temporary name; the old one is removed
  only once the transfer completes, then the temporary is renamed. Free space is
  checked beforehand.
- **Vendor filtering.** An Android phone is an MTP device like any other, so
  only HumanWare devices (`0x1C71`) are considered by default. `--any-device`
  lifts the restriction.
- **No external execution.** The program never calls `system`, `exec`, or any
  third-party process: there is no command-injection surface.
- **No privileges.** No setuid, no entitlements beyond USB access for the
  extension, no network access. PIE and stack protections enabled.

Memory behaviour was verified under **AddressSanitizer** across every operation:
no errors.

## Build

```bash
swift build -c release   # CLI — run from the repository root
swift test               # 32 tests
```

`Package.swift` links libmtp through a **relative** path, so builds must run
from the repository root.

The Finder integration lives in `App/`. Its Xcode project is generated, not
committed — `App/project.yml` is the source of truth:

```bash
xcodegen generate --spec App/project.yml
xcodebuild -project App/BrailliantConnect.xcodeproj -scheme BrailliantConnect \
  -configuration Debug -allowProvisioningUpdates build
```

`tools/make-dist.sh` produces the distributable bundle. It runs the tests first
and refuses to package if any fail. For public distribution:

```bash
CODESIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" ./tools/make-dist.sh
```

`tools/build-vendor.sh` rebuilds libmtp and libusb from upstream sources as
universal binaries — only needed to change versions.

Code is formatted with `swift-format`, which ships with Xcode:

```bash
swift format --in-place --recursive --configuration .swift-format Sources App
```

No external dependencies: no Swift package to fetch, no library to install.
Xcode is required for the Finder app; the CLI alone only needs the Command Line
Tools.

## How it works

Three parts:

- **`BrailliantKit`** — the MTP layer, compiled into both the CLI and the
  extension.
- **The agent** (`BrailliantConnect.app`, no interface) — watches USB through
  IOKit and publishes or removes the Finder location. It exists only because an
  extension must be hosted by an app bundle, and only that bundle may register a
  File Provider domain. `brailliant finder on` installs it as a LaunchAgent.
- **The extension** — serves the content to the Finder. Sandboxed, with USB
  access.

Notable details:

- The Brailliant (VID `0x1C71`, PID `0xC131`) is not listed in libmtp 1.1.23. It
  does not matter: **generic** detection takes over, because the USB interface
  declares the string `MTP`. The device identifies as Android — the display runs
  on an Android base.
- Accented file names require a UTF-8 locale in the process: libmtp converts
  names through `iconv`, keyed on `nl_langinfo(CODESET)`. A binary launched
  outside a login shell does not necessarily inherit `$LANG`, so the locale is
  forced — without it every accent would be lost.
- libmtp writes harmless chatter straight to file descriptors 1 and 2 from C
  code. It is captured and filtered, which matters for clean screen-reader
  output and for redirecting to another program (`--debug` shows everything).
- `LIBMTP_destroy_file_t` frees **one link** of the chain returned by
  `LIBMTP_Get_Files_And_Folders`, not the whole list: the next pointer must be
  saved before freeing the current one.
- Measured throughput: **~17.5 MB/s** reading (29.5 MB in 1.7 s). Enumeration
  costs about **0.2 ms per item** and scales linearly, so on-demand enumeration
  stays responsive without an elaborate cache.

## Known limitations

- **The display sleeps.** It stays enumerated on USB but stops exposing its MTP
  interface, so the location is published while the extension cannot serve it.
  Wake the display and it works again.
- **Read-only in the Finder.** Writing to the display goes through
  `brailliant put`.
- **One session at a time.** MTP allows a single connection: while the extension
  holds it, the CLI reports `libusb_claim_interface = -3`, and the other way
  round.
- **No change notifications.** Anything edited on the display itself goes
  unnoticed by the Finder until the folder is re-read.

## Bundled libraries

`Vendor/` holds `libmtp` 1.1.23 and `libusb` 1.0.30, built as universal
**arm64 + x86_64** binaries from unmodified upstream sources.

They depend only on libraries shipped with macOS (`libSystem`, `libiconv`,
`IOKit`, `CoreFoundation`, `Security`) and contain **no reference to Homebrew** —
a check enforced by the build scripts.

Both are **LGPL-2.1**. Redistribution is permitted here because linking stays
**dynamic**, users can **replace** the libraries by substituting the `.dylib`
files, and both the licence texts (`Vendor/LICENSE-*.txt`) and the rebuild
script are included.

## Contributing

Code, comments and commit messages are in English. User-facing strings live in
`Sources/BrailliantKit/Localization.swift`, with English as the base language
and French translations alongside.

If you own a Brailliant that is **not** a BI 40X, running `brailliant doctor`
and reporting the output would genuinely help: nothing in the code is tied to a
model, but that has yet to be verified on other hardware.
