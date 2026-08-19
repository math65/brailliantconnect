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
    public static func isSafeComponent(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        guard !name.contains("/"), !name.contains("\\") else { return false }
        // A null byte would truncate the name on its way into the C APIs.
        guard !name.unicodeScalars.contains(where: { $0.value == 0 }) else { return false }
        return true
    }
}

/// Junk files macOS creates on external volumes.
public enum MacJunk {
    static let names: Set<String> = [
        ".DS_Store", "._.DS_Store", ".Spotlight-V100", ".Trashes",
        ".fseventsd", ".TemporaryItems", ".apDisk",
    ]

    public static func matches(_ name: String) -> Bool {
        names.contains(name) || name.hasPrefix("._")
    }
}
