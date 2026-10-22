# Release notes

## v1.2.2 — 22/10/2026

When the app cannot start, it now says why — and repairs the most common
cause by itself.

### A folder left to the system is given back
- Another app's installer can leave one of your folders — LaunchAgents, in
  your Library — belonging to the system instead of to you. BrailliantConnect
  then could not set itself up to start at login, whatever its version, and
  never started at all. It now notices, asks for an administrator's password,
  and gives the folder back to your account, without touching anything inside
  it. If you would rather not give the password, the message shows the two
  Terminal commands that do the same.

### A failed installation explains itself
- The message shown when the installation failed never took the focus:
  VoiceOver could not reach it, and the app seemed not to respond. It is now
  an alert drawn by macOS, which comes to the front and is read at once.
- Opened for the first time, the app sets itself up to start in the
  background at every login. When macOS refused, the app said "Make sure the
  app is in the Applications folder" — even when it was there, which it had
  already checked. It now shows what macOS actually answered, and keeps it in
  its log.
- If macOS had switched the app's background agent off, the app could not
  start at all, and nothing said so. Opening it now switches the agent back
  on: opening the app is asking for it to run. If macOS still refuses, the
  message says where the setting is — in System Settings, search for
  "App Background Activity" and turn BrailliantConnect on.

## v1.2.1 — 15/10/2026

Pages documents now reach the display.

### Pages, Keynote and Numbers documents are copied
- A Pages document copied to the display never arrived: the Finder kept
  trying to send it, and never managed. The same went for every document macOS
  keeps as a package — Keynote and Numbers files, TextEdit documents with
  pictures (.rtfd), and others.
- They are now sent whole, and come back to the Mac intact: copied back from
  the display, a Pages document is exactly the one that was sent. Editing it
  on the Mac updates the copy on the display.
- The display's own apps do not open these documents. To read one in braille,
  export it from Pages as a Word or text file first.

### An item that cannot be sent is no longer tried again and again
- When an item cannot go to the display at all — a symbolic link, which the
  display has no way to store — the Finder no longer keeps retrying it every
  few seconds.

### Clearer reports
- When a copy fails, Report a Problem now says what kind of item it was,
  never its name.

## v1.2.0 — 15/10/2026

BrailliantConnect now updates itself. This is the last version you will have to
download by hand.

It also comes out of a report titled "file not copied". The file had been
copied; what the Finder showed said otherwise. Following that thread through
the whole app turned up more of the same: things that worked and said they had
failed, things that failed and said nothing.

### Updates install themselves
- About once a day, BrailliantConnect checks for a new version and installs it
  by itself, then tells you with a notification. It never checks or restarts
  while a file is on its way to the display.
- "Check for Updates…" in the menu bar shows what a new version brings and
  lets you choose when to install it. The notes read as a web page, with
  headings and lists.
- If notifications are switched off, the menu says which version was installed,
  until you have opened it once.

### No more error on a folder that received a file
- After a copy, the Finder showed an Error button beside the storage folder,
  saying the file did not exist — although the file had arrived. The system
  then tried again every few minutes, reading the whole display each time. It
  no longer happens.

### Every transfer is announced, small files included
- "Transfer complete — you can unplug the display" used to come for large files
  only: a small document arrived without a word. Every file is now announced,
  and several files copied together give a single notification.
- When a file does not reach the display, a notification says so, with how
  many did not arrive.
- If the display is unplugged during a transfer, the app no longer says you can
  unplug it.

### Dates are right
- Files on the display showed a time two hours early in summer, one hour in
  winter. They now show the Mac's time. A copied file shows when it reached the
  display, not its date on the Mac: the display records that itself.

### Your files are safer
- Moving an item into the folder it was already in could delete it.
- Copying a file onto one of the same name added on the display since the
  folder was last shown replaced it without asking.
- Deleting a folder that looked empty on the Mac also deleted what had been put
  into it on the display.
- Renaming a folder and then saving into it could recreate the old folder.
- Moving a folder from a USB stick to the internal memory failed, and was tried
  again forever.
- All of these are fixed. The hidden files macOS leaves everywhere, such as
  .DS_Store, are no longer sent to the display.

### Switched-off notifications are no longer silent
- When notifications are refused for BrailliantConnect, nothing told you, and
  every message the app has for you went nowhere. The menu now says so, with an
  item that opens the settings.

### The Report a Problem window
- Copy, Paste, Select All and Undo work in its fields; they did nothing before.
- Tab moves on from the message instead of typing a tab.
- The window opens on the subject, VoiceOver says what changes when you pick
  one, and says "Sending…" once you have pressed Send.
- The report now carries the last error the Finder extension met and whether
  notifications are on.

### News from the developer reaches you
- The channel meant for announcements never showed a single one, in any
  version. It now does.

### Uninstalling
- When the app cannot be moved to the Trash, it now says so instead of
  vanishing from the menu bar. Its settings no longer come back after a
  reinstall.

Nothing on the braille display itself is touched.

## v1.1.1 — 29/09/2026

Four things the app used to do silently, it now says out loud — and one it
could not do at all on macOS 13, it now does.

A report arrived from a BI 40X running macOS 13: the display connected, file
transfer on, cables checked — and nothing in the Finder. Choosing "Open in
Finder" from the menu bar did nothing at all. The description was exact.
Reproducing it took a virtual Mac running that same macOS, and the cause turned
out to be two things the app had never met on newer systems. The person who
reported it now has the display in the Finder, on that same Mac.

### The location publishes on macOS 13
- On macOS 13, the system service behind Finder locations is not allowed to
  read an app installed in the Applications folder — and reading ours was how
  it identified it. It answered "The application cannot be used right now"
  every time, whatever the display did; Apple's own sample project fails the
  same way there. The app now carries its identity in its signature, the way
  Dropbox and Google Drive do, and the service no longer needs to read
  anything.
- On a Mac that has never seen it, macOS creates the new location switched
  off and asks you to enable it once — on macOS 13, and on 14, 15 and 26 alike:
  in the Finder sidebar, under Locations, select BrailliantConnect, then
  activate Enable. The app cannot do that for you — it is your consent — but
  it now tells you: the menu bar says it is waiting, a notification says where
  the button is, "Open in Finder" opens the window that has it, the Getting
  Started window makes it its second step, and the app notices the moment you
  have done it. Once is enough; unplugging the display
  and plugging it back in does not ask again.

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
  you press Send, along with everything else the report contains. The report
  also says whether the location has been enabled.

### The app says when it is not in Applications
- Opened from where it was unzipped, the app ran from a temporary copy macOS
  makes of it, and set itself to start at login from there. That copy is gone
  after a restart, and the menu bar icon with it, without a word. The app now
  asks to be moved into the Applications folder first, and does nothing else
  until it is.

### macOS 12 or later
- macOS 11 is no longer supported: the tools that build the app no longer
  produce anything for it.

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
