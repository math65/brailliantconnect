import AppKit
import WebKit

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
    ///
    /// Marked as seen only once a window is actually on screen. Marking first
    /// was the obvious order and is wrong: anything that stops the window from
    /// appearing then spends its one chance in silence, and the user never sees
    /// it — not on this launch, and not on any other.
    static func showIfFirstLaunch(shortcut: URL?) {
        guard !UserDefaults.standard.bool(forKey: seenKey) else { return }
        show(shortcut: shortcut)
        guard current?.window?.isVisible == true else { return }
        UserDefaults.standard.set(true, forKey: seenKey)
        // Written now rather than whenever the system feels like it: the agent
        // may be killed at logout without a chance to flush.
        UserDefaults.standard.synchronize()
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
        // A web view: VoiceOver navigates a page by headings and lists, which
        // plain text does not offer.
        //
        // What it must not do is bury that page under a container. A stack view
        // is announced as a group first, so the reader hears "group, web
        // content" before reaching anything — the layout is done by hand
        // instead, and every view above the page is taken out of the
        // accessibility tree.
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 540, height: 380))
        web.loadHTMLString(Welcome.page(shortcut: shortcut), baseURL: nil)

        let done = NSButton(title: L.t("Done"), target: self, action: #selector(close))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 452))
        // The container carries no information of its own.
        content.setAccessibilityElement(false)
        content.setAccessibilityRole(.unknown)
        web.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(web)
        content.addSubview(done)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            web.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            done.topAnchor.constraint(equalTo: web.bottomAnchor, constant: 14),
            done.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 452),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L.t("BrailliantConnect is installed")
        window.contentView = content
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        // An accessory app never comes to the front by itself; without this the
        // window would open behind everything else on first launch.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // The page first, so a screen reader lands in the text rather than on
        // the button that dismisses it.
        window.makeFirstResponder(web)
    }

    @objc private func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        Welcome.current = nil
    }

    // MARK: - What it says

    private static func page(shortcut: URL?) -> String {
        // Not always "~/Brailliant": that name may be taken by a folder of the
        // user's, in which case the shortcut steps aside — and this must name
        // the one that exists.
        let path = "~/" + (shortcut?.lastPathComponent ?? "Brailliant")
        return """
            <!doctype html>
            <html lang="\(L.isFrench ? "fr" : "en")">
            <head><meta charset="utf-8">
            <title>\(L.t("Getting started with BrailliantConnect"))</title>
            <style>
              :root { color-scheme: light dark; }
              body {
                font: 14px/1.55 -apple-system, system-ui, sans-serif;
                margin: 0; padding: 2px 6px;
              }
              h2 { font-size: 1.12em; margin: 1.5em 0 0.35em; }
              h2:first-of-type { margin-top: 0.4em; }
              p { margin: 0.45em 0; }
              ul { margin: 0.45em 0; padding-left: 1.3em; }
              li { margin: 0.25em 0; }
              code {
                font: 0.95em ui-monospace, monospace;
                padding: 0.05em 0.3em; border-radius: 4px;
                background: rgba(127,127,127,0.2);
              }
            </style></head>
            <body>
            <p>\(L.t(
                "Your braille display now appears in the Finder when you plug it in, "
                    + "and disappears when you unplug it. There is nothing to launch: "
                    + "a background program takes care of it and comes back at every login."))</p>

            <h2>\(L.t("1. Check that MTP is on"))</h2>
            <p>\(L.t(
                "Only once, and probably already done: MTP is on by default since "
                    + "version 2.5 of the display's software. On the display, press O "
                    + "from the main menu for Options, then User settings, then MTP."))</p>
            <p>\(L.t(
                "It is what lets the computer see the files. The display stays usable "
                    + "as a braille terminal at the same time — the two work together, "
                    + "and nothing has to be switched off."))</p>

            <h2>\(L.t("2. Your files are in %@", "<code>" + path + "</code>"))</h2>
            <p>\(L.t("Inside, one folder per storage:"))</p>
            <ul>
              <li>\(L.t(
                "mémoire interne — the display's own storage, holding your documents, "
                    + "notes and books."))</li>
              <li>\(L.t("usb — a stick plugged into the display, when there is one."))</li>
            </ul>
            <p>\(L.t(
                "So your documents are one level down. The top level holds these "
                    + "storages and accepts no files of its own."))</p>

            <h2>\(L.t("3. Wait before unplugging"))</h2>
            <p>\(L.t(
                "The Finder hands control back immediately, long before a copy is "
                    + "finished. Three gigabytes take about seven minutes, during which "
                    + "everything looks done. A notification announces the end, and the "
                    + "menu bar says \"Do not unplug the display\" until then. Deleting, "
                    + "on the other hand, is immediate."))</p>

            <h2>\(L.t("4. Everything else is in the menu bar"))</h2>
            <p>\(L.t(
                "The menu bar item is the only visible part of the app. It reports the "
                    + "state of the display, opens the location in the Finder, and "
                    + "uninstalls everything — including itself — leaving the braille "
                    + "display untouched."))</p>
            </body></html>
            """
    }
}
