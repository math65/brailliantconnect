import AppKit

/// The menu bar item — the only visible part of the app.
///
/// A process that runs all the time should be visible, and stoppable. Without
/// it, the only honest answer to "what is running on my machine?" would be a
/// path under ~/Library that nobody is going to find.
///
/// Everything here is a plain `NSMenuItem` with a title, which VoiceOver reads
/// and navigates natively. State is spelled out in words: the icon says nothing
/// to someone who cannot see it.
final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    /// Called after the user changes something, so the agent can act on it.
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()

        if let button = statusItem.button {
            // A dot grid is the closest thing to a braille cell in the system
            // symbols; the last resort is a text title, which is never missing.
            let symbol = [
                "circle.grid.3x3.fill", "circle.grid.2x2.fill", "dot.radiowaves.left.and.right",
            ]
            .lazy
            .compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            .first
            if let symbol {
                button.image = symbol
            } else {
                button.title = FinderLocation.displayName
            }
            // The glyph alone means nothing to a screen reader.
            button.setAccessibilityLabel(FinderLocation.displayName)
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Rebuilt every time the menu opens: the display may have been plugged,
    /// unplugged or put to sleep since last time, and a menu built once would
    /// then state the wrong thing with full confidence.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let availability = USBWatcher.availability()

        // Before anything else: a transfer still running is the one thing that
        // must not be missed. Dropping a file into the Finder returns at once,
        // so "connected" alone would read as "safe to unplug" when it is not.
        if let transfer = transfers.state {
            // The system only credits a file once it has landed whole, so on a
            // single large file the sent figure stays at zero throughout.
            // Showing "0 MB of 3 GB" for seven minutes reads as "stuck"; the
            // size alone is honest, and the count is added the moment it means
            // something.
            let summary =
                transfer.sent > 0
                ? L.t(
                    "Transferring — %@ of %@", humanBytes(transfer.sent),
                    humanBytes(transfer.total))
                : L.t("Transferring — %@", humanBytes(transfer.total))
            menu.addItem(disabled(summary))
            menu.addItem(disabled(L.t("Do not unplug the display")))
            menu.addItem(.separator())
        }

        switch availability {
        case .ready:
            menu.addItem(disabled(L.t("Display connected")))
            add(menu, L.t("Open in Finder"), #selector(openInFinder))
        case .asleep:
            // Plugged in but answering nothing. The remedy differs from one
            // case to the next, so each says which one it is: this is the menu
            // someone opens precisely because the display did not show up.
            menu.addItem(disabled(L.t("Display asleep")))
            menu.addItem(disabled(L.t("Press a key on the display to wake it")))
        case .brailleTerminal:
            menu.addItem(disabled(L.t("MTP is off on the display")))
            menu.addItem(disabled(L.t("On the display: Options, User settings, MTP")))
        case .absent:
            menu.addItem(disabled(L.t("No display connected")))
        }

        menu.addItem(.separator())

        let startup = add(menu, L.t("Open at Login"), #selector(toggleStartup))
        startup.state = Installer.isRegistered ? .on : .off

        menu.addItem(.separator())

        add(menu, L.t("Getting Started"), #selector(openWelcome))
        add(menu, L.t("Uninstall BrailliantConnect…"), #selector(uninstall))
        add(menu, L.t("Quit"), #selector(quit), key: "q")
    }

    // MARK: - Building

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @discardableResult
    private func add(
        _ menu: NSMenu, _ title: String, _ action: Selector, key: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: - Actions

    @objc private func openInFinder() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Prefer the home-folder shortcut — the path the user can find again on
        // their own afterwards — under whatever name it ended up taking.
        let target =
            FinderLocation.existingShortcuts(home: home).first
            ?? FinderLocation.domainLocation(home: home)
        NSWorkspace.shared.open(target)
    }

    @objc private func openWelcome() {
        Welcome.show(
            shortcut: FinderLocation.existingShortcuts(
                home: FileManager.default.homeDirectoryForCurrentUser
            ).first)
    }

    @objc private func toggleStartup() {
        if Installer.isRegistered {
            Installer.unregister()
        } else {
            Installer.register()
        }
        onChange()
    }

    @objc private func uninstall() {
        let alert = NSAlert()
        alert.messageText = L.t("Uninstall BrailliantConnect?")
        alert.informativeText = L.t(
            "The Finder location, the background agent, and every file this app "
                + "wrote will be removed, and the app itself moved to the Trash. "
                + "Nothing on the braille display is touched.")
        alert.addButton(withTitle: L.t("Uninstall"))
        alert.addButton(withTitle: L.t("Cancel"))
        alert.alertStyle = .warning

        // An accessory app has no windows and never comes to the front by
        // itself; without this the alert would open behind everything else.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let transfer = transfers.state {
            guard confirmInterruption(transfer, then: .uninstall) else { return }
        }

        Installer.uninstall(removeApp: true) { binned in
            DispatchQueue.main.async {
                // Quitting on success would hide a bundle still sitting in
                // Applications, doing nothing, with no way left to remove it
                // from the app itself.
                if !binned {
                    let failure = NSAlert()
                    failure.messageText = L.t("The app could not be moved to the Trash")
                    failure.informativeText =
                        L.t("Everything else has been removed. Drag the app to the Trash:")
                        + "\n\n" + Bundle.main.bundleURL.path
                    failure.alertStyle = .warning
                    NSApp.activate(ignoringOtherApps: true)
                    failure.runModal()
                }
                NSApp.terminate(nil)
            }
        }
    }

    @objc private func quit() {
        // Quitting takes the location down with it, so a transfer still running
        // is cut short: a truncated file on the display, and no way to finish
        // it. Worth one question.
        if let transfer = transfers.state {
            guard confirmInterruption(transfer, then: .quit) else { return }
        }

        // Both paths below end here, and only the first of them may act. The
        // flag is safe to read unguarded because both are funnelled onto the
        // main queue for that single purpose: `unpublish` calls back on a queue
        // of the system's choosing.
        var left = false
        let leave = {
            guard !left else { return }
            left = true
            // Not `NSApp.terminate` alone: KeepAlive would bring the agent back
            // ten seconds later, which is not what anyone means by "Quit".
            // Booting out normally kills us here, so what follows only runs
            // when the agent was started by hand rather than by launchd.
            Installer.stopAgent()
            NSApp.terminate(nil)
        }
        // The location goes with the agent. Left published, it would keep a
        // folder in the Finder with nothing behind it watching the display: the
        // display could be unplugged a minute later and the folder would still
        // be sitting there, hanging on the first click.
        unpublish { _ in DispatchQueue.main.async(execute: leave) }
        // Whichever gets there first wins. Removing a domain has no deadline of
        // its own, and a "Quit" that appears to do nothing while the system
        // thinks it over is worse than a location that leaves a moment late.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: leave)
    }

    /// What the user is about to do, when a transfer is still running.
    ///
    /// Both actions remove the location and cut the transfer, but they do not
    /// leave the same thing behind, and an alert that says "stop" while the
    /// button says "uninstall" makes the reader work out which one is true.
    private enum Interruption {
        case quit
        case uninstall

        var consequence: String {
            switch self {
            case .quit:
                return L.t(
                    "Quitting removes the location from the Finder and leaves the file "
                        + "incomplete on the display.")
            case .uninstall:
                return L.t("Uninstalling leaves the file incomplete on the display.")
            }
        }

        var confirmation: String {
            switch self {
            case .quit: return L.t("Quit anyway")
            case .uninstall: return L.t("Uninstall anyway")
            }
        }
    }

    /// Asks before cutting a transfer short. Returns whether to go ahead.
    private func confirmInterruption(
        _ transfer: TransferMonitor.State, then action: Interruption
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = L.t("A transfer is still running")
        // The sent figure is only meaningful once a file has landed whole, so
        // the wording drops it rather than reporting "less than 1 MB of 3 GB".
        let progress =
            transfer.sent > 0
            ? L.t(
                "%@ of %@ have been sent.", humanBytes(transfer.sent),
                humanBytes(transfer.total))
            : L.t("%@ are still on their way.", humanBytes(transfer.total))
        alert.informativeText = progress + " " + action.consequence
        alert.addButton(withTitle: L.t("Wait"))
        alert.addButton(withTitle: action.confirmation)
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        // "Wait" is the first button, so Return — the reflex answer — is the
        // safe one.
        return alert.runModal() == .alertSecondButtonReturn
    }
}
