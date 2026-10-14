import Foundation

/// Remote path handling (always Unix style, with "/" as the separator).
///
/// The display's paths are independent of the Mac's: they are normalized
/// separately so that the two namespaces never get confused with one another.
public enum RemotePath {

    /// Normalizes a path: drops empty segments and ".", and resolves "..".
    public static func normalize(_ path: String) -> String {
        var stack: [String] = []
        for part in path.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            switch part {
            case "", ".":
                continue
            case "..":
                if !stack.isEmpty { stack.removeLast() }
            default:
                stack.append(String(part))
            }
        }
        return stack.isEmpty ? "/" : "/" + stack.joined(separator: "/")
    }

    /// Joins a folder and an item name.
    public static func join(_ base: String, _ name: String) -> String {
        (base == "/" || base.isEmpty) ? "/" + name : base + "/" + name
    }

    /// Splits a path into (parent folder, name).
    public static func split(_ path: String) -> (parent: String, name: String) {
        let norm = normalize(path)
        guard norm != "/" else { return ("/", "") }
        guard let index = norm.lastIndex(of: "/") else { return ("/", norm) }
        let parent = norm[norm.startIndex..<index]
        let name = String(norm[norm.index(after: index)...])
        return (parent.isEmpty ? "/" : String(parent), name)
    }

    /// Breaks a path down into its segments.
    public static func components(_ path: String) -> [String] {
        normalize(path).split(separator: "/").map(String.init)
    }

    /// True if `name` can be used as the name of a single item.
    ///
    /// Names come from the device and are therefore untrusted: MTP forbids
    /// neither "..", nor "/", nor control characters. Such a name, concatenated
    /// onto a destination folder, would make it possible to write outside that
    /// folder.
    /// Turns any name into one usable as a single path component.
    ///
    /// `sanitizedForDisplay` neutralizes control characters, which is enough to
    /// print a name and not enough to hand it to a file system: it leaves "..",
    /// ".", "a/b" and "a\\b" untouched. Anything shown to the system as a file
    /// or folder name must go through here instead.
    ///
    /// Separators are replaced rather than rejected, so a name stays
    /// recognisable; only names that are entirely unusable fall back.
    public static func safeComponent(
        _ name: String, fallback: @autoclosure () -> String
    )
        -> String
    {
        var result = name.sanitizedForDisplay
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // "." and ".." name a directory rather than an entry in one.
        if result.isEmpty || result == "." || result == ".." { return fallback() }
        return result
    }

    public static func isSafeComponent(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        guard !name.contains("/"), !name.contains("\\") else { return false }
        // A null byte would truncate the name on its way into the C APIs.
        guard !name.unicodeScalars.contains(where: { $0.value == 0 }) else { return false }
        return true
    }

    /// True if `path` is `ancestor` itself or lies anywhere below it.
    ///
    /// The comparison is on whole segments: "/ab" is not inside "/a".
    public static func isSameOrInside(_ path: String, _ ancestor: String) -> Bool {
        let path = normalize(path)
        let ancestor = normalize(ancestor)
        if path == ancestor || ancestor == "/" { return true }
        return path.hasPrefix(ancestor + "/")
    }

    /// What moving the item at `path`, called `name`, into `folder` amounts to.
    enum MovePlan: Equatable {
        /// The item is already in that folder: there is nothing to do.
        case alreadyThere
        /// The folder is the item itself or lies inside it.
        case intoItself
        /// The item would end up at this path.
        case to(String)
    }

    /// Decides a move before anything touches the display.
    ///
    /// Both cases were found by reading the code, not on a display. A move to
    /// the item's own folder skipped the collision check, the Brailliant
    /// refuses MoveObject, and the copying fallback uploaded over the original
    /// before deleting "the original" — that is, the fresh copy. A folder
    /// moved inside itself was copied child by child into a destination that
    /// had itself become one of the children, with no end.
    static func planMove(of path: String, named name: String, into folder: String) -> MovePlan {
        let destination = join(normalize(folder), name)
        if destination == normalize(path) { return .alreadyThere }
        if isSameOrInside(folder, path) { return .intoItself }
        return .to(destination)
    }
}

/// Junk files macOS creates on external volumes.
public enum MacJunk {
    static let names: Set<String> = [
        ".DS_Store", "._.DS_Store", ".Spotlight-V100", ".Trash", ".Trashes",
        ".fseventsd", ".TemporaryItems", ".apDisk",
    ]

    public static func matches(_ name: String) -> Bool {
        names.contains(name) || name.hasPrefix("._")
    }
}
