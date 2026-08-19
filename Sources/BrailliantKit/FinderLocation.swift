import Foundation

/// Paths and decisions behind the Finder location.
///
/// The agent that owns this behaviour is a top-level script, which cannot be
/// exercised by a test target. The parts that do not touch the hardware live
/// here instead, so they can be verified without a display plugged in — and
/// they are exactly the parts where a mistake is expensive: a wrong path, or a
/// deletion aimed at the wrong thing.
public enum FinderLocation {

    /// Identifier of the published domain. Changing it would orphan any
    /// location already registered with the system.
    public static let domainIdentifier = "brailliant-principal"

    /// Name shown in the Finder sidebar, and used for the home-folder shortcut.
    public static let displayName = "Brailliant"

    /// Prefix the system gives the folder it creates for our domain.
    static let folderPrefix = "BrailliantConnect-"

    /// Real location of the domain, under the user's Library.
    public static func domainLocation(home: URL) -> URL {
        home.appendingPathComponent("Library/CloudStorage")
            .appendingPathComponent(folderPrefix + displayName)
    }

    /// Shortcut sitting directly in the home folder.
    ///
    /// Without it, reaching the files would depend on the Finder sidebar —
    /// which can be hidden — or on a path under ~/Library, a folder macOS hides
    /// by default.
    public static func shortcut(home: URL) -> URL {
        home.appendingPathComponent(displayName)
    }

    /// True if `target` is a symlink we created, and therefore ours to delete.
    ///
    /// A user may well have a real folder named "Brailliant" in their home
    /// directory. Removing it would be unforgivable, so the check is on where
    /// the link points, never on its name.
    public static func isOurShortcut(pointingAt target: String) -> Bool {
        target.contains(folderPrefix)
    }

    /// What the agent should do, given the hardware and the published state.
    public enum Action: Equatable {
        case publish
        case unpublish
        case nothing
    }

    /// Decides how to reconcile the published location with what is plugged in.
    ///
    /// Kept deliberately dumb and total: every combination has an answer, and
    /// the two idle cases are spelled out rather than left to a default branch.
    public static func action(displayConnected: Bool, locationPublished: Bool) -> Action {
        switch (displayConnected, locationPublished) {
        case (true, false): return .publish
        case (false, true): return .unpublish
        case (true, true): return .nothing
        case (false, false): return .nothing
        }
    }
}
