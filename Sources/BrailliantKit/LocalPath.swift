import Foundation

/// Safe construction of local paths out of data that came from the display.
///
/// The file names an MTP device hands back are arbitrary strings: the protocol
/// forbids neither ".." nor the "/" separator. Concatenated naively onto a
/// destination folder, they would make it possible to write outside that folder
/// — as far as dropping a file into ~/Library/LaunchAgents.
///
/// Two independent barriers are in place:
/// 1. non-conforming names are rejected the moment they are read
///    (`RemotePath.isSafeComponent`);
/// 2. the final target is checked to still sit under the permitted root
///    (`confine`), which catches whatever the first barrier did not anticipate.
public enum LocalPath {

    /// Normalizes a path without touching the disk (resolves "..", ".", "~").
    public static func standardize(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    /// True if `target` is `root` itself or an item located below it.
    public static func isConfined(_ target: String, under root: String) -> Bool {
        let normalizedRoot = standardize(root)
        let normalizedTarget = standardize(target)
        if normalizedTarget == normalizedRoot { return true }
        let prefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        return normalizedTarget.hasPrefix(prefix)
    }

    /// Composes `root` + `relative`, guaranteeing the result stays under `root`.
    ///
    /// - Parameter relative: relative path whose every segment comes from the
    ///   display and must therefore be treated as untrusted.
    public static func confine(root: String, relative: String) throws -> String {
        let segments =
            relative
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)

        for segment in segments where !RemotePath.isSafeComponent(segment) {
            throw MTPError.unsafeRemoteName(segment)
        }

        var target = standardize(root)
        for segment in segments {
            target = (target as NSString).appendingPathComponent(segment)
        }

        // Defense in depth: even if a dubious segment had slipped past the
        // check above, the target cannot escape the requested folder.
        guard isConfined(target, under: root) else {
            throw MTPError.pathEscapesDestination(attempted: target, root: standardize(root))
        }
        return target
    }
}

extension String {

    /// Displayable version of text coming from the display.
    ///
    /// File names can contain control characters or ANSI escape sequences.
    /// Printed raw in a terminal, they could clear the screen or hide lines
    /// already written — and so conceal what a command has actually just done.
    /// They also disrupt how a screen reader renders the output.
    public var sanitizedForDisplay: String {
        var result = ""
        result.reserveCapacity(count)
        for scalar in unicodeScalars {
            switch scalar.value {
            case 0x00...0x08, 0x0A...0x1F, 0x7F,  // C0 controls and DEL
                0x80...0x9F:  // C1 controls
                result.append("\u{FFFD}")  // replacement character
            case 0x09:
                result.append(" ")  // tab neutralized
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
