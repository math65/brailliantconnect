# Release notes

## v1.1.1 — 08/09/2026

Three things the app used to do silently, it now says out loud.

A report arrived from a BI 40X: the display connected, file transfer on, cables
checked — and nothing in the Finder. Choosing "Open in Finder" from the menu bar
did nothing at all. The description was exact, and the fault was the app's: not
that it failed, but that it failed without a word.

### "Open in Finder" says what happened
- When the location has not been published, the item used to open a folder that
  was not there, and macOS answers that with silence. It now tries to publish
  the location again — the remedy wherever there is one — and when that does not
  work, it shows you the error macOS gives instead of leaving you to guess.

### "Open at Login" can be switched back on
- Turning it off and on again used to take the menu bar icon away until the next
  login. The setting is now written without stopping the program that is already
  running, so the icon stays where it is.

### A problem report carries the app's log
- Reports said whether the Finder location was published. None of them could say
  what the system answered when the app asked to publish it, because that line
  lives in a log that was never sent. It travels with every report now — the end
  of it, the part describing what just happened — and the window says so before
  you press Send, along with everything else the report contains.

Nothing on the braille display is touched, and nothing else changes.

## v1.1.0 — 26/08/2026

Reporting a problem no longer requires a Terminal.

Version 1.0.0 was built and tested on one model, a BI 40X, and said so. The
answers came back within the week: someone tried it on a Mantis, the menu said
the display was connected, and the Finder showed nothing. There was no way for
them to say more than that, and no way for me to ask — the diagnosis lives
behind a command-line tool that nobody should have to open.

The app now produces it on their behalf.

### Report a Problem…
- **A new item in the menu bar** opens a window: you say what it is about, write
  a line or two, and give an address for the answer. Suggestions and questions
  go through the same window.
- **The window often answers before you send.** A display that is plugged in but
  asleep, or answering as a braille terminal with file transfer switched off, is
  something the app can see for itself — it says so, and names the remedy. It
  never stops you from sending anyway.
- **A report carries a diagnosis, and says so before you press Send:** the
  version of the app and of macOS, what the USB bus says about the display,
  whether the Finder location is published, and the model, serial number and
  storage areas of the display as they were last read. Nothing else leaves your
  machine.
- **The diagnosis works even while the Finder is using the display.** MTP allows
  a single connection at a time, so nothing can question the display while the
  Finder holds it. What the Finder side sees as it connects is written down as
  it goes, and the report picks it up from there.

### Announcements
- **The app can now receive a message from its author at startup** — a version
  worth skipping, a firmware that breaks file transfer. There is no update
  mechanism and no account here, and until now someone who installed this had no
  way of hearing anything again.

### Fixed
- **The welcome window described a BI 40X and nothing else.** It named the two
  storage folders literally — `mémoire interne` and `usb` — when those names come
  from the display itself and vary from one model to the next, and it assumed the
  removable storage was a USB stick, which it is not on a display that takes a
  microSD card.
- **Wording throughout the app was gone over.** The menu said "MTP is off on the
  display", naming a protocol nobody plugs a display in for; it now says file
  transfer is off, and points at the setting.

## v1.0.0 — 20/08/2026

First public release.

A braille display has a memory, and that memory is meant to hold books and
documents. Reaching it from a Mac used to mean fitting an extension into the
heart of the system. BrailliantConnect fits nothing: it goes into Applications,
you open it once, and from then on the display behaves like a USB stick —
plugged in, it is there; unplugged, it is gone.

The author uses a Brailliant with a screen reader. Everything the app says is
written to be read in braille: one fact per line, and never a state carried by
colour or by an icon alone.

### Installing
- **Drag the app into Applications and open it once.** That is the whole
  installation. The app registers itself with the system so it comes back at
  every login, then exits: what runs afterwards is not the copy you
  double-clicked.
- **A welcome window opens on first launch** and names the two or three things
  nobody can guess — first among them the setting to turn on, on the display
  itself.

### On the display: MTP
- **File transfer has to be on**, once, and it probably already is: it has been
  on by default since version 2.5 of the display's software. Otherwise, on the
  display: Options, User settings, MTP.
- **Nothing is switched off or swapped.** A display the Mac can reach publishes
  its braille interfaces *and* the file-transfer one at the same time, and stays
  usable as a braille terminal throughout a copy.

### The display in the Finder
- **A "Brailliant" folder appears in your home folder** as soon as the display is
  plugged in, and goes away when you unplug it.
- **It holds one folder per storage, never a file directly.** The display's own
  memory is one; a USB stick plugged into the display is another, and it shows up
  alongside rather than staying invisible. Your documents are therefore one level
  down.
- **Nothing can be created at the top level**, because that place belongs to no
  storage. A copy dropped there is refused, and the app says so rather than
  leaving a file the Finder shows and the display never received.

### Transfers
- **The Finder hands control back immediately, long before a copy is finished.**
  Three gigabytes return in a fraction of a second and keep going for seven
  minutes, at roughly 7 MB per second.
- **So the app tells you when not to unplug**, in the menu bar, and tells you
  when the transfer is done. Without that, nothing on screen would tell a
  finished copy from one that has just started.
- **Deleting, by contrast, is immediate** — about thirteen milliseconds per item
  whatever its size. There is no window in which unplugging could truncate
  anything.

### The menu bar
- **A menu bar item is the only visible part.** It says whether the display is
  there, opens its folder, and tells apart the cases where it is plugged in but
  answering nothing: asleep, or MTP turned off — each with the gesture that
  fixes it.
- **Quit really quits.** The location leaves the Finder and the agent stops for
  good; opening the app again brings it straight back, and it returns on its own
  at the next login as long as *Open at Login* stays ticked.

### Uninstalling
- **One menu entry removes everything the app wrote** — the location, the
  shortcut, the agent, preferences, containers, logs — and moves the app to the
  Trash. Nothing on the braille display is touched.

### What this version does not do
- **One connection at a time.** The protocol allows no more: while the Finder
  holds the display, the `brailliant` command cannot reach it, and the other way
  round.
- **Anything you change on the display itself goes unnoticed** until the folder
  is read again: the display does not announce its own changes.

### Reporting a problem
- **`brailliant --version` says which version you have**, and `brailliant doctor`
  repeats it at the top of its report. It is the first thing to include when
  something goes wrong: without it, a described behaviour belongs to no
  particular build.

### Hardware
Built and verified on a **Brailliant BI 40X**. Nothing in the code depends on the
model, but that remains to be confirmed on the others. If you own a different
one, `brailliant doctor` and its output would genuinely help.
