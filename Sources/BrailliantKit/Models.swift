import Foundation

/// A file or a folder present on the braille display.
public struct Entry: Sendable, Equatable {
    public let itemID: UInt32
    public let parentID: UInt32
    public let storageID: UInt32
    public let name: String
    public let size: UInt64
    public let modified: Date?
    public let isDirectory: Bool
    public let path: String

    public var humanSize: String { formatSize(size) }

    /// Name stripped of control characters, safe to display.
    public var displayName: String { name.sanitizedForDisplay }

    /// Full path, safe to display.
    public var displayPath: String { path.sanitizedForDisplay }

    /// True if the name can be used as a path component on the Mac.
    ///
    /// False for a name containing "/" or equal to "..": MTP allows such names,
    /// but they would make it possible to write outside the target folder.
    public var hasSafeName: Bool { RemotePath.isSafeComponent(name) }
}

/// A storage volume: internal memory, SD card or USB stick.
public struct Storage: Sendable, Equatable {
    public let id: UInt32
    public let description: String
    public let capacity: UInt64
    public let free: UInt64

    public var used: UInt64 { capacity > free ? capacity - free : 0 }

    public var usedPercent: Int {
        guard capacity > 0 else { return 0 }
        return Int((Double(used) / Double(capacity) * 100).rounded())
    }

    /// True for a slot the device declares with nothing in it.
    ///
    /// An APH Chameleon 20 announces its USB port with no stick plugged in,
    /// at a capacity of 2^63 − 1 bytes and 2^62 free, and every listing of it
    /// fails with PTP error 02fe (measured on a tester's device, 27 Oct 2026).
    /// The Finder extension took that failure for a lost connection and
    /// reconnected each time the Finder looked. No real medium comes anywhere
    /// near 2^60 bytes (an exbibyte), so anything above is no medium at all;
    /// the threshold rather than the exact value also covers a device writing
    /// 2^64 − 1 for the same purpose.
    public var isEmptySlot: Bool { capacity >= 1 << 60 }
}

/// Resolution of a storage from whatever the user typed.
///
/// Kept apart from the MTP connection so it can be tested with no hardware
/// plugged in.
public enum StorageSelection {

    /// Finds a storage by its displayed rank ("2") or by a fragment of its name
    /// ("usb", "interne"), ignoring case and diacritics — a storage name gets
    /// typed out on the keyboard, not copied and pasted.
    public static func resolve(selector: String, among storages: [Storage]) throws -> Storage {
        let trimmed = selector.trimmingCharacters(in: .whitespaces)
        let inventory = storages.enumerated().map { describe(index: $0, storage: $1) }

        guard !trimmed.isEmpty, !storages.isEmpty else {
            throw MTPError.storageNotFound(selector: selector, available: inventory)
        }

        if let rank = Int(trimmed) {
            guard rank >= 1, rank <= storages.count else {
                throw MTPError.storageNotFound(selector: trimmed, available: inventory)
            }
            return storages[rank - 1]
        }

        let needle = fold(trimmed)
        let matches = storages.enumerated().filter { fold($1.description).contains(needle) }
        switch matches.count {
        case 0:
            throw MTPError.storageNotFound(selector: trimmed, available: inventory)
        case 1:
            return matches[0].element
        default:
            throw MTPError.ambiguousStorage(
                selector: trimmed,
                matches: matches.map { describe(index: $0, storage: $1) })
        }
    }

    static func describe(index: Int, storage: Storage) -> String {
        // This line is quoted verbatim inside the storageNotFound and
        // ambiguousStorage messages, so it is localized like them.
        L.t(
            "%@ — \"%@\" (%@ free)",
            String(index + 1), storage.description, humanSize(storage.free))
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}

/// Human-readable size, using French conventions (decimal comma, "o" units).
public func humanSize(_ bytes: UInt64) -> String { formatSize(bytes) }

/// The implementation, given a distinct name so that it stays callable from a
/// type that itself exposes a "humanSize" property.
func formatSize(_ bytes: UInt64) -> String {
    if bytes < 1000 { return "\(bytes) o" }
    var value = Double(bytes)
    for unit in ["ko", "Mo", "Go", "To"] {
        value /= 1000
        if value < 1000 {
            return String(format: "%.1f %@", value, unit).replacingOccurrences(of: ".", with: ",")
        }
    }
    return String(format: "%.1f To", value).replacingOccurrences(of: ".", with: ",")
}
