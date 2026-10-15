import AppKit

/// The window behind "Report a Problem…".
///
/// It exists because of what the first week of the 1.0.0 release made plain:
/// someone with a model this was never built on plugs it in, the menu says one
/// thing, the Finder does another, and the only route open to them is to write
/// a forum post and wait. The diagnosis they cannot produce is one the app can
/// produce for them.
///
/// Plain AppKit, like every other window here. Each control carries its own
/// accessibility label rather than relying on a neighbouring text field to act
/// as one, and nothing is announced as a group on the way in.
final class Feedback: NSObject, NSWindowDelegate, NSTextViewDelegate {

    /// What the message is about, chosen first.
    ///
    /// Not the same list as the backend's four contact types, and deliberately
    /// so. It names the failures this app actually produces, which does three
    /// things a plain "Problem / Suggestion / Question" cannot: the email
    /// arrives with a subject worth reading rather than "Rapport", the report
    /// says which symptom was meant rather than leaving it to be guessed from
    /// prose, and the window can answer on the spot when the state of the
    /// machine already contradicts — or confirms — what was picked.
    enum Subject: CaseIterable {
        case notDetected
        case folderUnusable
        case transferFailed
        case otherProblem
        case suggestion
        case question

        var label: String {
            switch self {
            case .notDetected: return L.t("The display isn't detected")
            case .folderUnusable: return L.t("The folder is empty or won't open")
            case .transferFailed: return L.t("A file didn't copy to the display")
            case .otherProblem: return L.t("Other problem")
            case .suggestion: return L.t("Suggestion")
            case .question: return L.t("Question")
            }
        }

        /// Problems go to the report route, with the diagnosis attached;
        /// the other two are a message and nothing else.
        var isProblem: Bool {
            switch self {
            case .suggestion, .question: return false
            default: return true
            }
        }

        var contactType: AppBackendClient.ContactType {
            switch self {
            case .suggestion: return .suggestion
            case .question: return .question
            default: return .bug
            }
        }

        /// Names the email and leads the report. **French, always** — never
        /// `label`, which follows the language of whoever is writing.
        ///
        /// A report is read in one mailbox, by one person. Sorting it by
        /// symptom only works if the symptom is written the same way every
        /// time, and a report whose first line changes language with the
        /// sender is one that has to be opened to be understood.
        var reportSubject: String {
            switch self {
            case .notDetected: return "Plage non détectée"
            case .folderUnusable: return "Dossier vide ou impossible à ouvrir"
            case .transferFailed: return "Fichier non copié"
            case .otherProblem: return "Autre problème"
            case .suggestion: return "Suggestion"
            case .question: return "Question"
            }
        }
    }

    private static let savedEmailKey = "FeedbackEmail"
    private static var current: Feedback?

    private var window: NSWindow?
    private let client = AppBackendClient()

    /// Whether the Finder location is published. Read once when the window
    /// opens, since the answer comes from the system asynchronously and the
    /// note cannot wait on it; nil until it arrives, and the note then simply
    /// says nothing about it.
    private var domainPublished: Bool?

    private let typeButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let emailField = NSTextField()
    private let messageView = NSTextView()
    private let noteLabel = NSTextField(labelWithString: "")
    private let sendButton = NSButton()
    private let cancelButton = NSButton()
    private let progress = NSProgressIndicator()

    /// True from Send until the server has answered. Closing is refused
    /// meanwhile: the window is what the answer is shown in, and a report
    /// dropped because its window went away would look sent and never arrive.
    private var busy = false

    /// What the note last said about the subject, so a change of subject only
    /// announces what is actually new.
    private var lastObservation: String?
    private var lastTransparency: String?

    /// Whether the window is on screen — asked by the announcements, which
    /// wait for it to be gone.
    static var isOnScreen: Bool { current?.window?.isVisible == true }

    /// Nothing is offered when the build has no key: a menu item that can only
    /// fail is worse than no menu item.
    static var isAvailable: Bool { AppBackendClient.isConfigured }

    static func show() {
        KeyboardMenu.installIfNeeded()
        // Held for as long as it is on screen: NSWindow does not retain its
        // delegate, and a released controller would take the window with it.
        if let current {
            current.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let feedback = Feedback()
        current = feedback
        feedback.present()
    }

    // MARK: - Building

    private func present() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = L.t("Contact the Developer")
        window.isReleasedWhenClosed = false
        // Nothing to bring back after a restart, and nothing then written to
        // the Saved Application State folder for the uninstaller to chase.
        window.isRestorable = false
        window.delegate = self
        window.center()
        self.window = window

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 500))
        // The container carries no information of its own.
        content.setAccessibilityElement(false)
        content.setAccessibilityRole(.unknown)

        for subject in Subject.allCases {
            typeButton.addItem(withTitle: subject.label)
        }
        typeButton.target = self
        typeButton.action = #selector(typeChanged(_:))
        typeButton.setAccessibilityLabel(L.t("Subject"))

        emailField.placeholderString = L.t("name@example.com")
        emailField.setAccessibilityLabel(L.t("Email address"))

        messageView.isRichText = false
        messageView.font = .systemFont(ofSize: NSFont.systemFontSize)
        messageView.isAutomaticQuoteSubstitutionEnabled = false
        // Off by default in a text view built in code, and ⌘Z then does
        // nothing even with the Edit menu in place.
        messageView.allowsUndo = true
        // For Tab, which a text view otherwise types as a character.
        messageView.delegate = self
        messageView.setAccessibilityLabel(L.t("Message"))
        let scroll = NSScrollView()
        scroll.documentView = messageView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        // The scroll view would otherwise be announced before the text it holds.
        scroll.setAccessibilityElement(false)

        noteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.lineBreakMode = .byWordWrapping
        noteLabel.maximumNumberOfLines = 10

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.setAccessibilityElement(false)

        let cancel = cancelButton
        cancel.title = L.t("Cancel")
        cancel.target = self
        cancel.action = #selector(close)
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        sendButton.title = L.t("Send")
        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.keyEquivalent = "\r"

        let rows: [(String, NSView)] = [
            (L.t("Subject"), typeButton),
            (L.t("Email address"), emailField),
            (L.t("Message"), scroll),
        ]

        var previous: NSView?
        for (title, field) in rows {
            let label = NSTextField(labelWithString: title)
            label.translatesAutoresizingMaskIntoConstraints = false
            field.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(label)
            content.addSubview(field)

            label.topAnchor.constraint(
                equalTo: previous?.bottomAnchor ?? content.topAnchor,
                constant: previous == nil ? 20 : 16
            ).isActive = true
            label.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: 20
            ).isActive = true

            field.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4).isActive = true
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20).isActive =
                true
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20)
                .isActive = true
            if field === scroll {
                field.heightAnchor.constraint(equalToConstant: 150).isActive = true
            }
            previous = field
        }

        for view in [noteLabel, progress, cancel, sendButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            noteLabel.topAnchor.constraint(equalTo: previous!.bottomAnchor, constant: 12),
            noteLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            noteLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            sendButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            sendButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            cancel.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -12),
            cancel.bottomAnchor.constraint(equalTo: sendButton.bottomAnchor),
            progress.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            progress.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
        ])

        window.contentView = content

        // Spelled out rather than left to AppKit, which builds no loop for
        // views added in code: Tab from the message would otherwise go
        // nowhere. Controls that cannot take the focus — buttons, without
        // full keyboard access — are skipped on the way.
        typeButton.nextKeyView = emailField
        emailField.nextKeyView = messageView
        messageView.nextKeyView = cancelButton
        cancelButton.nextKeyView = sendButton
        sendButton.nextKeyView = typeButton
        window.initialFirstResponder = typeButton

        emailField.stringValue = UserDefaults.standard.string(forKey: Self.savedEmailKey) ?? ""
        refreshNote(announce: false)
        isPublished { [weak self] published in
            DispatchQueue.main.async {
                self?.domainPublished = published
                self?.refreshNote(announce: false)
            }
        }
        // The note for "a file didn't copy" says when notifications are off,
        // and that answer may have changed in System Settings since start.
        TransferNotice.refreshAuthorization { [weak self] in
            self?.refreshNote(announce: false)
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // The subject first: it is the first question the window asks, it
        // decides what the note below says, and landing in the message field
        // skipped both — a screen reader started in the middle of the form.
        // A pop-up refuses the focus without full keyboard access; the window
        // then keeps it, and VoiceOver starts from the top all the same.
        window.makeFirstResponder(typeButton)
    }

    // MARK: - Acting

    private var selectedSubject: Subject {
        let subjects = Subject.allCases
        let index = typeButton.indexOfSelectedItem
        return subjects.indices.contains(index) ? subjects[index] : .otherProblem
    }

    /// What the machine says right now about the symptom that was picked.
    ///
    /// Three of the four states a plugged display can be in have a remedy the
    /// user can apply in ten seconds, and the agent can already tell them
    /// apart. Saying so here costs nothing and spares an exchange of emails.
    ///
    /// It never blocks the send, and that is deliberate: a Mantis that reads as
    /// "reachable" while the Finder shows nothing is exactly the report worth
    /// receiving, and a window that talked the user out of sending it would
    /// destroy the one thing this feature exists for.
    private func observation(for subject: Subject) -> String? {
        switch subject {
        case .notDetected:
            switch USBWatcher.availability() {
            case .asleep:
                return L.t("The display is asleep. Press a key on it to wake it.")
            case .brailleTerminal:
                return L.t(
                    "File transfer is turned off on the display. To turn it on: Options, "
                        + "User settings, MTP.")
            case .absent:
                return L.t(
                    "No HumanWare device is connected. Check the cable, or try another "
                        + "port.")
            case .ready:
                return L.t(
                    "The display is detected and reachable. If it still doesn't appear in "
                        + "the Finder, send this report: that case hasn't been seen yet.")
            }
        case .folderUnusable:
            guard let published = domainPublished else { return nil }
            return published
                ? nil
                : L.t("The location isn't published in the Finder, which would explain it.")
        case .transferFailed:
            var notes: [String] = []
            if transfers.state != nil {
                notes.append(L.t("A transfer is in progress. The file may not have arrived yet."))
            }
            // The likeliest reason someone believes a copy failed is that
            // nothing told them it was over.
            if TransferNotice.isDenied {
                notes.append(
                    L.t(
                        "Notifications are turned off for BrailliantConnect, so the end of a "
                            + "transfer is never announced. The menu bar item has an item to "
                            + "turn them back on."))
            }
            return notes.isEmpty ? nil : notes.joined(separator: " ")
        default:
            return nil
        }
    }

    /// Says out loud what a problem report carries — whoever presses Send is
    /// entitled to know that the serial number of their display goes with it —
    /// and, above it, what the machine says about the symptom right now.
    @objc private func typeChanged(_ sender: Any?) {
        refreshNote(announce: true)
    }

    /// Rewrites the note, and says what changed when the user changed it.
    ///
    /// The note sits below the fields, where a screen reader reaches it only
    /// by going past the message field — so a subject picked from the pop-up
    /// gave no sign that the window had just answered it. What is new is read
    /// out instead: the observation if it changed, otherwise the list of what
    /// the report carries when it has just appeared. Not when the window
    /// opens, nor when a late answer from the system rewrites it: those would
    /// talk over whatever the reader is doing.
    private func refreshNote(announce: Bool) {
        let subject = selectedSubject
        let observation = observation(for: subject)
        let transparency = transparency(for: subject)
        noteLabel.stringValue = [observation, transparency]
            .compactMap { $0 }
            .joined(separator: "\n\n")

        defer {
            lastObservation = observation
            lastTransparency = transparency
        }
        guard announce else { return }
        if let observation, observation != lastObservation {
            speak(observation, after: 0.3)
        } else if let transparency, transparency != lastTransparency {
            speak(transparency, after: 0.3)
        }
    }

    /// Hands a sentence to VoiceOver — and to the braille display with it.
    ///
    /// - Parameter delay: lets the pop-up finish closing first. VoiceOver
    ///   reads the newly selected value as the menu goes, and an announcement
    ///   posted in the same instant can be lost under it.
    private func speak(_ text: String, after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let window = self?.window, window.isVisible else { return }
            NSAccessibility.post(
                element: window, notification: .announcementRequested,
                userInfo: [
                    .announcement: text,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
    }

    private func transparency(for subject: Subject) -> String? {
        subject.isProblem
            ? L.t(
                "This report includes a diagnostic: the version of the app and of macOS, "
                    + "whether VoiceOver is on, whether notifications are allowed, the state "
                    + "of the display, whether the location is published, this app's own log "
                    + "and the Finder extension's error log, and — once the display has been "
                    + "read — its model, serial number and storage areas.")
            : nil
    }

    @objc private func send() {
        let email = emailField.stringValue.trimmingCharacters(in: .whitespaces)
        let message = messageView.string.trimmingCharacters(in: .whitespacesAndNewlines)

        // The server validates both properly; this only catches the two cases
        // worth catching before a round trip, and says which one it is.
        guard looksLikeEmail(email) else {
            report(L.t("Enter the email address where you'd like to receive a reply."))
            window?.makeFirstResponder(emailField)
            return
        }
        guard !message.isEmpty else {
            report(L.t("Enter a message."))
            window?.makeFirstResponder(messageView)
            return
        }

        let subject = selectedSubject
        // The contact route keeps the first 2,000 bytes and drops the rest,
        // without a word to either side. Said before sending, while the
        // message can still be shortened, rather than discovered in a reply
        // to half a question.
        if !subject.isProblem, message.utf8.count > AppBackendClient.contactMessageLimit {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L.t("This message is too long to arrive whole")
            alert.informativeText = L.t(
                "Suggestions and questions are cut after 2,000 bytes — about 2,000 "
                    + "characters, fewer with accented letters. The rest would be lost.")
            // The safe answer first, so Return keeps the message.
            alert.addButton(withTitle: L.t("Edit Message"))
            alert.addButton(withTitle: L.t("Send Anyway"))
            alert.beginSheetModal(for: window!) { [weak self] response in
                guard response == .alertSecondButtonReturn else {
                    self?.window?.makeFirstResponder(self?.messageView)
                    return
                }
                self?.transmit(email: email, message: message, subject: subject)
            }
            return
        }
        transmit(email: email, message: message, subject: subject)
    }

    private func transmit(email: String, message: String, subject: Subject) {
        setBusy(true)
        let completion: (Result<Void, AppBackendClient.BackendError>) -> Void = { [weak self] in
            self?.setBusy(false)
            switch $0 {
            case .success:
                // Only remembered once the server has taken it: an address it
                // refused is not one to offer again next time.
                UserDefaults.standard.set(email, forKey: Self.savedEmailKey)
                self?.reportSuccess()
            case .failure(let error):
                self?.report(error.message)
            }
        }

        guard subject.isProblem else {
            client.sendContact(
                email: email, type: subject.contactType, message: message, completion: completion)
            return
        }
        // The symptom leads the report: it is the first row of the first
        // section, and it names the email, so a mailbox full of these can be
        // sorted at a glance instead of opened one by one.
        Diagnostics.collect(symptom: subject.reportSubject) { [weak self] sections, log in
            self?.client.sendReport(
                email: email,
                summary: message,
                subjectHint: "\(subject.reportSubject) — \(AppBackendClient.appVersion)",
                sections: sections,
                // "log.txt", not "doctor.txt": it now carries the agent's
                // log as well, and usually instead.
                logFile: log.map { (name: "log.txt", data: $0) },
                completion: completion)
        }
    }

    private func setBusy(_ busy: Bool) {
        self.busy = busy
        busy ? progress.startAnimation(nil) : progress.stopAnimation(nil)
        // The spinner is silent, and kept out of the accessibility tree; a
        // report takes up to a minute to collect and send, which is a long
        // time to wonder whether Send did anything.
        if busy { speak(L.t("Sending…")) }
        cancelButton.isEnabled = !busy
        sendButton.isEnabled = !busy
        typeButton.isEnabled = !busy
        emailField.isEnabled = !busy
        messageView.isEditable = !busy
    }

    private func looksLikeEmail(_ address: String) -> Bool {
        guard let at = address.firstIndex(of: "@"), !address.contains(" ") else { return false }
        return address[address.index(after: at)...].contains(".")
    }

    private func reportSuccess() {
        let alert = NSAlert()
        alert.messageText = L.t("Message Sent")
        alert.informativeText = L.t("You'll receive a reply at the address you provided.")
        alert.beginSheetModal(for: window!) { _ in self.close() }
    }

    private func report(_ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text
        alert.beginSheetModal(for: window!, completionHandler: nil)
    }

    @objc private func close() {
        window?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The close box and ⌘W, which Cancel being disabled does not cover.
        !busy
    }

    func windowWillClose(_ notification: Notification) {
        Feedback.current = nil
    }

    // MARK: - Tab in the message

    /// Moves the focus on Tab and Shift-Tab instead of typing a tab.
    ///
    /// A text view takes Tab as a character, so the message field was a trap
    /// for anyone moving through the form from the keyboard: in, and no way
    /// out but the mouse. A tab character has no use in a message either.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            textView.window?.selectNextKeyView(nil)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            textView.window?.selectPreviousKeyView(nil)
            return true
        default:
            return false
        }
    }
}
