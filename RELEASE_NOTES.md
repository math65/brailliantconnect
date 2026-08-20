# Release notes

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

### Hardware
Built and verified on a **Brailliant BI 40X**. Nothing in the code depends on the
model, but that remains to be confirmed on the others. If you own a different
one, `brailliant doctor` and its output would genuinely help.
