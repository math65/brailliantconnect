import FileProvider
import Foundation
import os.log

/// Serialized access to the braille display on behalf of the extension.
///
/// Two constraints dictate this class:
///
/// - MTP only accepts **one session at a time**. The connection is therefore
///   opened once and kept, and every Finder request is serialized on a
///   dedicated queue. Without this, two simultaneous enumerations would fight
///   over the device and both would fail.
/// - The protocol emits **no change notification**. The cache is therefore
///   timestamped: past a short delay, the tree is read again.
final class DisplayAccess {

    /// Log readable with:
    ///   log show --predicate 'subsystem == "com.mathieumartin.BrailliantConnect"'
    private static let log = Logger(
        subsystem: "com.mathieumartin.BrailliantConnect",
        category: "acces")

    /// How long the enumeration cache stays valid.
    ///
    /// An enumeration costs about 0.2 ms per item: reading it again often is
    /// inconsequential. This delay mainly avoids hitting the device several
    /// times a second when the Finder refreshes its window.
    private static let freshness: TimeInterval = 5

    private let queue = DispatchQueue(label: "brailliant.acces", qos: .userInitiated)
    private var display: Brailliant?

    /// Known entries, indexed by MTP identifier.
    private var index: [UInt32: Entry] = [:]
    /// Contents of the folders already enumerated, with the date they were read.
    private var contents: [UInt32: (entries: [Entry], read: Date)] = [:]

    /// Conventional MTP identifier of the root.
    private static let root: UInt32 = 0xFFFF_FFFF

    // MARK: - Connection

    private func connection() throws -> Brailliant {
        if let display { return display }
        // Filter on HumanWare: a connected Android phone is an MTP device like
        // any other.
        Self.log.info("ouverture d'une session MTP")
        let opened = try Brailliant(vendorID: humanwareVendorID)
        Self.log.info("session ouverte : \(opened.model, privacy: .public)")
        display = opened
        return opened
    }

    func close() {
        queue.sync {
            display?.close()
            display = nil
            index.removeAll()
            contents.removeAll()
        }
    }

    /// Closes the connection and empties the caches after an error.
    ///
    /// The display may have been unplugged: the next request will reopen it, or
    /// fail cleanly.
    private func reset() {
        display?.close()
        display = nil
        index.removeAll()
        contents.removeAll()
    }

    // MARK: - Reading

    private func mtpIdentifier(_ identifier: NSFileProviderItemIdentifier) -> UInt32 {
        identifier == .rootContainer ? Self.root : UInt32(identifier.rawValue) ?? Self.root
    }

    /// Remote path of a folder, rebuilt from the index.
    private func path(of itemID: UInt32) -> String {
        itemID == Self.root ? "/" : (index[itemID]?.path ?? "/")
    }

    func contents(ofFolder identifier: NSFileProviderItemIdentifier) throws -> [NSFileProviderItem]
    {
        try queue.sync {
            let itemID = mtpIdentifier(identifier)
            if let cache = contents[itemID],
                Date().timeIntervalSince(cache.read) < Self.freshness
            {
                return cache.entries.map { DisplayItem(entry: $0) }
            }
            do {
                let display = try connection()
                let entries = try display.listDirectory(path(of: itemID))
                    .filter { !MacJunk.matches($0.name) }
                for entry in entries { index[entry.itemID] = entry }
                contents[itemID] = (entries, Date())
                return entries.map { DisplayItem(entry: $0) }
            } catch {
                Self.log.error("enumeration failed: \(String(describing: error))")
                reset()
                throw error
            }
        }
    }

    /// Looks up an entry, re-reading the tree if the index does not know it.
    ///
    /// The system stops and restarts the extension freely, and every instance
    /// starts with an empty index. The Finder still refers to items by an
    /// identifier it obtained earlier, so any lookup has to be able to rebuild
    /// what it needs — failing outright would make a file unreadable purely
    /// because the process was recycled since it was listed.
    ///
    /// Callers must already hold `queue`.
    private func entry(withID itemID: UInt32, identifier: String) throws -> Entry {
        if let entry = index[itemID] { return entry }
        let display = try connection()
        for entry in try display.walk("/") { index[entry.itemID] = entry }
        guard let entry = index[itemID] else {
            throw MTPError.notFound(path: identifier)
        }
        return entry
    }

    func item(for identifier: NSFileProviderItemIdentifier) throws -> NSFileProviderItem {
        if identifier == .rootContainer { return DisplayItem(root: true) }
        return try queue.sync {
            DisplayItem(
                entry: try entry(
                    withID: mtpIdentifier(identifier), identifier: identifier.rawValue))
        }
    }

    func contents(
        of identifier: NSFileProviderItemIdentifier,
        progress: @escaping (UInt64, UInt64) -> Void
    )
        throws -> (URL, NSFileProviderItem)
    {
        try queue.sync {
            let entry = try entry(
                withID: mtpIdentifier(identifier), identifier: identifier.rawValue)
            // The system expects a temporary file that it will copy itself.
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            do {
                let display = try connection()
                _ = try display.download(entry.path, to: destination.path, progress: progress)
                return (destination, DisplayItem(entry: entry))
            } catch {
                reset()
                throw error
            }
        }
    }
}
