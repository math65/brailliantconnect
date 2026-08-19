import AppKit

/// The window shown once, the first time the app is opened.
///
/// A real window rather than an alert: an alert reads its whole message as one
/// block, where a text view lets a screen reader walk it line by line and go
/// back over it. Read-only but selectable, for the same reason — selectable
/// text is navigable text.
///
/// It says the few things nobody can guess, and stops there. The display has to
/// be switched to file transfer mode, the files are one level down, and a copy
/// is not over when the Finder says it is.
final class Welcome: NSObject, NSWindowDelegate {

    private static let seenKey = "WelcomeShown"
    private static var current: Welcome?

    private var window: NSWindow?

    /// Shows the window the first time, and never again on its own.
    static func showIfFirstLaunch(shortcut: URL?) {
        guard !UserDefaults.standard.bool(forKey: seenKey) else { return }
        UserDefaults.standard.set(true, forKey: seenKey)
        show(shortcut: shortcut)
    }

    static func show(shortcut: URL?) {
        // Held for as long as it is on screen: NSWindow does not retain its
        // delegate, and a released controller would take the window with it.
        current?.window?.makeKeyAndOrderFront(nil)
        guard current == nil else { return }
        let welcome = Welcome()
        current = welcome
        welcome.present(shortcut: shortcut)
    }

    private func present(shortcut: URL?) {
        let text = NSTextView(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 4, height: 4)
        text.string = Welcome.body(shortcut: shortcut)
        text.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        text.setAccessibilityLabel(L.t("Getting started with BrailliantConnect"))

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 360))
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        scroll.autohidesScrollers = true

        let done = NSButton(
            title: L.t("Done"), target: self, action: #selector(close))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"

        let stack = NSStackView(views: [scroll, done])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 520),
            scroll.heightAnchor.constraint(equalToConstant: 360),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L.t("BrailliantConnect is installed")
        window.contentView = stack
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        // An accessory app never comes to the front by itself; without this the
        // window would open behind everything else on first launch.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // The text view first, so a screen reader starts on the message rather
        // than on the button that dismisses it.
        window.makeFirstResponder(text)
    }

    @objc private func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        Welcome.current = nil
    }

    // MARK: - What it says

    private static func body(shortcut: URL?) -> String {
        // Not always "~/Brailliant": that name may be taken by a folder of the
        // user's, in which case the shortcut steps aside — and this must name
        // the one that exists.
        let path = "~/" + (shortcut?.lastPathComponent ?? "Brailliant")
        return [
            L.t(
                "Your braille display now appears in the Finder when you plug it in, "
                    + "and disappears when you unplug it. There is nothing to launch: "
                    + "a background program takes care of it and comes back at every login."),
            "",
            L.t("1. Turn on file transfer on the display"),
            L.t(
                "This is the one thing to know. In the display's own menu, turn on "
                    + "file transfer: the location appears within a second or two. You "
                    + "can go on using the display as a braille terminal at the same "
                    + "time — the two work together. Until file transfer is on, the "
                    + "computer only sees the braille side and no files at all."),
            "",
            L.t("2. Your files are in %@", path),
            L.t(
                "Inside, one folder per storage: \"mémoire interne\" for the display "
                    + "itself, and \"usb\" for a stick plugged into it. Your documents are "
                    + "therefore one level down, in \"mémoire interne\". The top level "
                    + "holds only these storages and accepts no files."),
            "",
            L.t("3. Wait before unplugging"),
            L.t(
                "The Finder hands control back immediately, long before a copy is "
                    + "finished. Three gigabytes take about seven minutes, during which "
                    + "everything looks done. A notification announces the end, and the "
                    + "menu bar says \"Do not unplug the display\" until then. Deleting, "
                    + "on the other hand, is immediate."),
            "",
            L.t("4. Everything else is in the menu bar"),
            L.t(
                "The menu bar item is the only visible part of the app. It reports the "
                    + "state of the display, opens the location in the Finder, and "
                    + "uninstalls everything — including itself — leaving the braille "
                    + "display untouched."),
        ].joined(separator: "\n")
    }
}
