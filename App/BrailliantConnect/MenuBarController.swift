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
            menu.addItem(disabled(L.t("Display in braille terminal mode")))
            menu.addItem(disabled(L.t("Switch it to file transfer mode")))
        case .absent:
            menu.addItem(disabled(L.t("No display connected")))
        }

        menu.addItem(.separator())

        let startup = add(menu, L.t("Open at Login"), #selector(toggleStartup))
        startup.state = Installer.isRegistered ? .on : .off

        menu.addItem(.separator())

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
        let shortcut = FinderLocation.shortcut(home: home)
        // Prefer the home-folder shortcut: that is the path the user can find
        // again on their own afterwards, without going through this menu.
        let target =
            FileManager.default.fileExists(atPath: shortcut.path)
            ? shortcut : FinderLocation.domainLocation(home: home)
        NSWorkspace.shared.open(target)
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
        if let transfer = transfers.state, confirmInterruption(transfer) == false { return }

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
        // Quitting mid-transfer leaves a truncated file on the display and no
        // way to finish it, so it is worth one question.
        if let transfer = transfers.state, confirmInterruption(transfer) == false { return }
        NSApp.terminate(nil)
    }

    /// Asks before cutting a transfer short. Returns whether to go ahead.
    private func confirmInterruption(_ transfer: TransferMonitor.State) -> Bool {
        let alert = NSAlert()
        alert.messageText = L.t("A transfer is still running")
        // The sent figure is only meaningful once a file has landed whole, so
        // the wording drops it rather than reporting "less than 1 MB of 3 GB".
        alert.informativeText =
            transfer.sent > 0
            ? L.t(
                "%@ of %@ have been sent. Stopping now leaves the file incomplete "
                    + "on the display.", humanBytes(transfer.sent), humanBytes(transfer.total))
            : L.t(
                "%@ are still on their way. Stopping now leaves the file incomplete "
                    + "on the display.", humanBytes(transfer.total))
        alert.addButton(withTitle: L.t("Wait"))
        alert.addButton(withTitle: L.t("Stop anyway"))
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        // "Wait" is the first button, so Return — the reflex answer — is the
        // safe one.
        return alert.runModal() == .alertSecondButtonReturn
    }
}
