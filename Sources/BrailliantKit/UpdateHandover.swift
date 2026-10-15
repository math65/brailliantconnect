import Foundation

/// How the resident agent hands over to the version an update has just put in
/// place — the decisions only, so they can be tested without launchd, Sparkle
/// or a bundle being swapped underneath a running process.
///
/// The agent is a launchd job with `KeepAlive`. Sparkle's installer waits for
/// the app to quit, swaps the bundle, then relaunches it — but launchd restarts
/// the job the moment it exits, from the same path, and that restart can land
/// before the swap: the **old** binary, running from a bundle about to be
/// replaced under it. Sparkle's relaunch, a plain launch, would then find an
/// instance running and do nothing. See **Updates** in `CLAUDE.md` for the
/// whole sequence; this file is the part of it that decides.
///
/// Compiled into the agent as well as `BrailliantKit`, like `FinderLocation`:
/// it is pure logic, and keeps libmtp no closer to the agent than before.
public enum UpdateHandover {

    /// Written by the agent just before Sparkle asks it to quit for an
    /// installation, and read by whatever starts next.
    public struct Marker: Equatable {
        /// `CFBundleVersion` of the agent that is quitting.
        public let fromBuild: String
        /// The version being installed, as users see it.
        public let toVersion: String
        public let date: Date

        public init(fromBuild: String, toVersion: String, date: Date) {
            self.fromBuild = fromBuild
            self.toVersion = toVersion
            self.date = date
        }

        /// As stored in the user defaults: a plain dictionary, so that a
        /// marker written by one version is readable by the next.
        public var dictionary: [String: Any] {
            ["fromBuild": fromBuild, "toVersion": toVersion, "date": date]
        }

        public init?(dictionary: [String: Any]?) {
            guard let dictionary,
                let fromBuild = dictionary["fromBuild"] as? String,
                let toVersion = dictionary["toVersion"] as? String,
                let date = dictionary["date"] as? Date
            else { return nil }
            self.init(fromBuild: fromBuild, toVersion: toVersion, date: date)
        }
    }

    /// How long a marker is believed. An installation takes seconds; ten
    /// minutes covers a slow disk without letting a marker left behind by an
    /// installation that never happened make every later start wait.
    public static let lifetime: TimeInterval = 10 * 60

    /// How long a stale agent waits for the new version before giving up and
    /// carrying on as it is. Sparkle does not relaunch after a failed
    /// installation, so giving up is the only way the old version comes back.
    public static let patience: TimeInterval = 90

    /// Whether a marker describes an installation that may still be under way.
    /// A date in the future — a clock set back — is not believed either.
    public static func isFresh(_ marker: Marker?, now: Date) -> Bool {
        guard let marker else { return false }
        let age = now.timeIntervalSince(marker.date)
        return age >= -60 && age < lifetime
    }

    /// What a starting resident agent (`--watch`) does next.
    public enum Step: Equatable {
        /// Start normally: no update in flight, or this process is the new
        /// version.
        case proceed
        /// The bundle on disk is no longer the file this process was started
        /// from: the new version is in place, and this process is the old one.
        case startNewVersion
        /// This process is the old version and the swap has not happened yet.
        case wait
    }

    /// - Parameters:
    ///   - diskBuild: `CFBundleVersion` read from the bundle on disk **now**,
    ///     never from `Bundle.main`, which caches whatever it read first.
    ///   - runningIsOnDisk: whether the executable at the bundle's path is the
    ///     very file this process was started from (same device and inode).
    ///
    /// Read the build first and the inode second: Sparkle swaps the bundle
    /// atomically, so if the swap falls between the two reads, the inode
    /// catches it.
    public static func step(
        marker: Marker?, now: Date, diskBuild: String?, runningIsOnDisk: Bool
    ) -> Step {
        guard let marker, isFresh(marker, now: now) else { return .proceed }
        if !runningIsOnDisk { return .startNewVersion }
        // This process is the file on disk. If that file is no longer the
        // build that was quitting, this process is the new version.
        if let diskBuild, diskBuild != marker.fromBuild { return .proceed }
        return .wait
    }

    /// Whether a launch without arguments — what Sparkle's relaunch is — comes
    /// during a handover, in which case it must leave launchd alone: the job
    /// is already bringing the new version up, and `register()` would boot it
    /// out and rewrite the plist, turning *Open at Login* back on for someone
    /// who had turned it off.
    public static func isRelaunchAfterUpdate(marker: Marker?, now: Date) -> Bool {
        isFresh(marker, now: now)
    }

    /// Whether this start is the first of a different build than the last one
    /// that ran. A first install has no previous build and is not an update.
    public static func wasUpdated(previousBuild: String?, currentBuild: String) -> Bool {
        guard let previousBuild else { return false }
        return previousBuild != currentBuild
    }
}
