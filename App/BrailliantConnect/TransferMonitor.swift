import FileProvider
import Foundation

/// Tells whether files are still on their way to the display.
///
/// This matters more here than in most places. Dropping a file into the Finder
/// returns instantly — the system writes a local copy and hands control back
/// long before anything reaches the display. On a few megabytes nobody notices;
/// on three gigabytes that is about seven minutes during which everything
/// *looks* finished. Unplugging then cuts the transfer in half.
///
/// The system publishes the answer through the domain's global upload progress,
/// which the host app may read. That avoids an App Group between the agent and
/// the extension — the extension's must stay empty, or the system discards it.
final class TransferMonitor {

    struct State {
        /// Files still waiting or in flight.
        let filesRemaining: Int
        /// Bytes already sent, and expected in total.
        let sent: Int64
        let total: Int64

        var fraction: Double { total > 0 ? Double(sent) / Double(total) : 0 }
    }

    /// Main queue only, like everything else in this class: `follow` and
    /// `stop` are called from the completion queues of the File Provider
    /// framework, and the KVO callbacks arrive on whatever thread changed the
    /// progress. Every entry point hops onto the main queue before touching
    /// any of this.
    private var progress: Progress?

    /// Called once each time a run of transfers finishes, with the total size.
    /// On the main queue.
    var onCompletion: ((Int64) -> Void)?

    private var observations: [NSKeyValueObservation] = []
    private var fallback: Timer?
    /// Largest total seen during the current run, kept because the progress
    /// object is gone by the time there is something to announce.
    private var runningTotal: Int64 = 0

    /// Bumped by `stop`, so the answer to a `follow` issued before it cannot
    /// attach to a domain that has since been removed.
    private var generation = 0

    /// Starts reading the progress of the published domain.
    ///
    /// Called whenever the location is published, and again on every
    /// reconciliation: an agent that starts up while the location is already
    /// published never goes through publishing, and would otherwise never know
    /// a transfer was running.
    ///
    /// Every call fetches the progress again and compares it with the one
    /// observed. A flag that ignored repeat calls was the first version, and
    /// it assumed the system hands out one object per domain for good —
    /// which nothing documents. The object's address is logged at each call,
    /// so the log will say whether it is stable.
    func follow(domain identifier: NSFileProviderDomainIdentifier) {
        // Always queued rather than run inline when already on main: `stop`
        // is queued the same way, and the two must reach the main queue in
        // the order they were called.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let ticket = self.generation
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
                guard let domain = domains.first(where: { $0.identifier == identifier }),
                    let manager = NSFileProviderManager(for: domain)
                else { return }
                // Fetched here rather than on main: it is a call into the
                // system, and the menu bar should not wait on it.
                let fresh = manager.globalProgress(for: .uploading)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == ticket else { return }
                    let same = fresh === self.progress
                    log(
                        "upload progress \(Unmanaged.passUnretained(fresh).toOpaque())"
                            + (same ? " (unchanged)" : self.progress == nil ? "" : " (new object)"))
                    guard !same else { return }
                    self.observe(fresh)
                }
            }
        }
    }

    /// Main queue only.
    private func observe(_ progress: Progress) {
        observations = []
        self.progress = progress

        // KVO rather than a timer: the agent must stay asleep when nothing is
        // moving. A one-second timer is armed only while a transfer is
        // actually running, because the aggregate does not reliably emit a
        // final change when the last file lands.
        //
        // Three properties, each with its old value. `fractionCompleted` alone
        // misses a single large file entirely — the aggregate credits it whole,
        // so the fraction jumps from 0 to done in one change, or never moves
        // before the progress resets. The old values are what make a run that
        // was never seen in flight still count: a total that was above zero
        // and is now back to zero, or a progress that just became finished,
        // is a run of that old total that has just ended.
        observations = [
            progress.observe(\.fractionCompleted, options: [.initial, .new]) {
                [weak self] _, _ in
                self?.onMain { $0.evaluate() }
            },
            progress.observe(\.totalUnitCount, options: [.initial, .old, .new]) {
                [weak self] _, change in
                guard let old = change.oldValue, let new = change.newValue else {
                    self?.onMain { $0.evaluate() }
                    return
                }
                let ended: Int64? = old > 0 && new == 0 ? old : nil
                self?.onMain { $0.evaluate(endedRunOf: ended) }
            },
            progress.observe(\.isFinished, options: [.initial, .old, .new]) {
                [weak self] progress, change in
                let ended: Int64? =
                    change.oldValue == false && change.newValue == true
                    ? progress.totalUnitCount : nil
                self?.onMain { $0.evaluate(endedRunOf: ended) }
            },
        ]
    }

    /// Runs inline when already on main, so a change is judged against the
    /// state it came with rather than whatever the progress says a turn of the
    /// run loop later — by which time a short run may have come and gone.
    private func onMain(_ body: @escaping (TransferMonitor) -> Void) {
        if Thread.isMainThread {
            body(self)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                body(self)
            }
        }
    }

    /// Notices a run starting and, more importantly, finishing.
    ///
    /// - Parameter ended: the total of a run a KVO change says has just
    ///   ended, when it says so — counted even if no evaluation ever caught
    ///   that run in flight.
    private func evaluate(endedRunOf ended: Int64? = nil) {
        if let ended, ended > 0 { runningTotal = max(runningTotal, ended) }
        if let current = state {
            runningTotal = max(runningTotal, current.total)
            if fallback == nil {
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    self?.evaluate()
                }
                // Common modes, so the end of a transfer is still caught while
                // an alert or the menu is open.
                RunLoop.main.add(timer, forMode: .common)
                fallback = timer
            }
            return
        }
        fallback?.invalidate()
        fallback = nil
        guard runningTotal > 0 else { return }
        let finished = runningTotal
        runningTotal = 0
        onCompletion?(finished)
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.observations = []
            self.fallback?.invalidate()
            self.fallback = nil
            // Deliberately not announcing: reaching here means the display
            // went away, so whatever was in flight did not arrive.
            self.runningTotal = 0
            self.progress = nil
        }
    }

    /// True when nothing is on its way to the display. Main queue only.
    ///
    /// Cheap — it reads the progress already held, and asks the system for
    /// nothing — so anything that must not cut a transfer short (quitting,
    /// installing an update) can ask it as often as it likes. A run the
    /// fallback timer is still following counts as in flight until that timer
    /// has seen it end.
    var isIdle: Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return state == nil && fallback == nil
    }

    /// The current transfer, or nil when nothing is in flight. Main queue only.
    var state: State? {
        guard let progress, !progress.isFinished, !progress.isCancelled else { return nil }
        let remaining = progress.fileTotalCount ?? 0
        let completed = progress.fileCompletedCount ?? 0
        let files = max(0, remaining - completed)
        // A progress object that exists but counts nothing is the idle state,
        // not a transfer of zero bytes.
        guard files > 0 || progress.totalUnitCount > 0 else { return nil }
        return State(
            filesRemaining: files,
            sent: progress.completedUnitCount,
            total: progress.totalUnitCount)
    }
}

/// Formats a byte count for display.
///
/// `ByteCountFormatter` was the obvious choice and produced "Zero KB" inside a
/// French sentence: it follows the process locale, and an agent started by
/// launchd inherits none. Spelled out here instead, in whole units — precision
/// below a megabyte tells the reader nothing about whether it is safe to
/// unplug.
func humanBytes(_ count: Int64) -> String {
    let bytes = Double(max(0, count))
    let megabytes = bytes / 1_000_000
    if megabytes < 1 { return L.t("less than 1 MB") }
    if megabytes < 1000 { return "\(Int(megabytes.rounded())) " + L.t("MB") }
    let gigabytes = (megabytes / 1000).rounded(toPlaces: 1)
    return decimal(gigabytes) + " " + L.t("GB")
}

/// Writes a decimal with the separator the language uses: a comma in French,
/// a point in English. `String(format:)` alone would always give a point.
private func decimal(_ value: Double) -> String {
    let text = String(format: "%.1f", value)
    return L.isFrench ? text.replacingOccurrences(of: ".", with: ",") : text
}

extension Double {
    fileprivate func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
