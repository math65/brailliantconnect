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

    private var progress: Progress?
    private var following = false

    /// Called once each time a run of transfers finishes, with the total size.
    var onCompletion: ((Int64) -> Void)?

    private var observation: NSKeyValueObservation?
    private var fallback: Timer?
    /// Largest total seen during the current run, kept because the progress
    /// object is gone by the time there is something to announce.
    private var runningTotal: Int64 = 0

    /// Starts reading the progress of the published domain.
    ///
    /// Called whenever the location is published, and again on every
    /// reconciliation: an agent that starts up while the location is already
    /// published never goes through publishing, and would otherwise never know
    /// a transfer was running. Repeat calls are ignored — the progress object
    /// belongs to the domain, and only a domain removed and re-added needs a
    /// new one.
    func follow(domain identifier: NSFileProviderDomainIdentifier) {
        guard !following else { return }
        following = true
        // `globalProgress` arrived in 11.3, three months after the replicated
        // extension itself. On 11.0 to 11.2 the menu simply says nothing about
        // transfers rather than saying something wrong.
        guard #available(macOS 11.3, *) else { return }
        NSFileProviderManager.getDomainsWithCompletionHandler { [weak self] domains, _ in
            guard let domain = domains.first(where: { $0.identifier == identifier }),
                let manager = NSFileProviderManager(for: domain)
            else { return }
            guard let self else { return }
            let progress = manager.globalProgress(for: .uploading)
            self.progress = progress
            // KVO rather than a timer: the agent must stay asleep when nothing
            // is moving. A one-second timer is armed only while a transfer is
            // actually running, because the aggregate does not reliably emit a
            // final change when the last file lands.
            self.observation = progress.observe(\.fractionCompleted, options: [.new]) {
                [weak self] _, _ in
                DispatchQueue.main.async { self?.evaluate() }
            }
        }
    }

    /// Notices a run starting and, more importantly, finishing.
    private func evaluate() {
        if let current = state {
            runningTotal = max(runningTotal, current.total)
            if fallback == nil {
                fallback = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
                    [weak self] _ in
                    self?.evaluate()
                }
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
        observation = nil
        fallback?.invalidate()
        fallback = nil
        // Deliberately not announcing: reaching here means the display went
        // away, so whatever was in flight did not arrive.
        runningTotal = 0
        progress = nil
        following = false
    }

    /// The current transfer, or nil when nothing is in flight.
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
