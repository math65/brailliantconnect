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

    /// Where the shortcut can actually go, given what already occupies the
    /// home folder.
    ///
    /// Somebody who owns a braille display may well already keep a folder
    /// called "Brailliant". Refusing to create the shortcut at all was the
    /// first answer and is unpredictable: it works on one machine and silently
    /// does nothing on the next. The Finder's own convention is used instead —
    /// "Brailliant 2", "Brailliant 3" — so there is always a shortcut, and the
    /// guide can name the one that was actually created.
    ///
    /// - Parameter exists: whether something occupies a path. Injected so the
    ///   choice can be tested without touching the file system.
    /// - Returns: the free path, or nil if even the alternatives are taken.
    public static func availableShortcut(
        home: URL, upTo limit: Int = 9, exists: (URL) -> Bool
    ) -> URL? {
        let preferred = shortcut(home: home)
        if !exists(preferred) { return preferred }
        for suffix in 2...max(2, limit) {
            let candidate = home.appendingPathComponent("\(displayName) \(suffix)")
            if !exists(candidate) { return candidate }
        }
        return nil
    }

    /// True if `url` is a symlink of ours, whatever name it goes by.
    public static func isOurShortcut(at url: URL) -> Bool {
        guard
            let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        else { return false }
        return isOurShortcut(pointingAt: target)
    }

    /// Every shortcut of ours in the home folder, under any of its names.
    ///
    /// Removal has to find them all: a shortcut left behind under "Brailliant 2"
    /// after the original name freed up would point at a location that no
    /// longer exists.
    public static func existingShortcuts(home: URL) -> [URL] {
        var found: [URL] = []
        for suffix in 0...9 {
            let name = suffix == 0 ? displayName : "\(displayName) \(suffix + 1)"
            let candidate = home.appendingPathComponent(name)
            if isOurShortcut(at: candidate) { found.append(candidate) }
        }
        return found
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
