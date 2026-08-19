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
/// Raised when something would be written at the root of the domain.
///
/// Its own type because the extension has to answer this case differently from
/// a failure: refusing an import means returning no item **and no error**, so
/// that the system removes its local copy. Reporting an error instead leaves a
/// file the Finder shows and the display never received.
struct RootNotWritable: Error {}

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
    /// Top level of each storage, kept apart: a storage identifier and an
    /// object identifier are both plain numbers and would collide in one
    /// dictionary.
    private var storageContents: [UInt32: (entries: [Entry], read: Date)] = [:]
    /// The list of storages, which changes the moment a stick is plugged in.
    private var storageList: (storages: [Storage], read: Date)?

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
            storageContents.removeAll()
            storageList = nil
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
        storageContents.removeAll()
        storageList = nil
    }

    // MARK: - Reading

    private func mtpIdentifier(_ identifier: NSFileProviderItemIdentifier) -> UInt32 {
        identifier == .rootContainer ? Self.root : UInt32(identifier.rawValue) ?? Self.root
    }

    /// What an identifier designates.
    ///
    /// Three kinds of container exist, and conflating them is what previously
    /// left everything but the internal memory unreachable.
    private enum Container {
        /// The root, which holds one folder per storage and nothing else.
        case root
        /// The top level of a storage.
        case storage(UInt32)
        /// A folder inside a storage.
        case folder(Entry)
    }

    /// Callers must already hold `queue`.
    private func container(for identifier: NSFileProviderItemIdentifier) throws -> Container {
        if identifier == .rootContainer { return .root }
        if let storageID = StorageIdentifier.parse(identifier) { return .storage(storageID) }
        let itemID = mtpIdentifier(identifier)
        if itemID == Self.root { return .root }
        return .folder(try entry(withID: itemID, identifier: identifier.rawValue))
    }

    /// Points the connection at a storage before acting on it.
    ///
    /// Every path is relative to its own storage, so the same "/documents"
    /// exists on the internal memory and on a stick. Without this the second
    /// one would silently resolve against the first.
    ///
    /// Callers must already hold `queue`.
    private func target(_ storageID: UInt32?) throws -> Brailliant {
        let display = try connection()
        display.useStorage(storageID)
        return display
    }

    /// The storages, cached as briefly as a folder listing: plugging a stick in
    /// changes this list and nothing signals it.
    ///
    /// Callers must already hold `queue`.
    private func storages() throws -> [Storage] {
        if let cache = storageList, Date().timeIntervalSince(cache.read) < Self.freshness {
            return cache.storages
        }
        let found = try target(nil).storages(refresh: true)
        storageList = (found, Date())
        return found
    }

    func contents(ofFolder identifier: NSFileProviderItemIdentifier) throws -> [NSFileProviderItem]
    {
        try queue.sync {
            do {
                switch try container(for: identifier) {
                case .root:
                    return try storages().map { DisplayItem(storage: $0) }
                case .storage(let storageID):
                    return try list(
                        "/", on: storageID,
                        cached: storageContents[storageID],
                        store: { self.storageContents[storageID] = $0 })
                case .folder(let entry):
                    return try list(
                        entry.path, on: entry.storageID,
                        cached: contents[entry.itemID],
                        store: { self.contents[entry.itemID] = $0 })
                }
            } catch {
                Self.log.error("enumeration failed: \(String(describing: error))")
                reset()
                throw error
            }
        }
    }

    /// Lists one folder of one storage, through its cache.
    ///
    /// Callers must already hold `queue`.
    private func list(
        _ path: String, on storageID: UInt32,
        cached: (entries: [Entry], read: Date)?,
        store: ((entries: [Entry], read: Date)) -> Void
    ) throws -> [NSFileProviderItem] {
        if let cached, Date().timeIntervalSince(cached.read) < Self.freshness {
            return cached.entries.map { DisplayItem(entry: $0) }
        }
        let entries = try target(storageID).listDirectory(path)
            .filter { !MacJunk.matches($0.name) }
        for entry in entries { index[entry.itemID] = entry }
        store((entries, Date()))
        return entries.map { DisplayItem(entry: $0) }
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
        // Every storage, not just the default one: an item on a plugged-in
        // stick would otherwise be unreachable for no reason other than the
        // process having been recycled since it was listed.
        for storage in try storages() {
            for entry in try target(storage.id).walk("/") { index[entry.itemID] = entry }
            if let entry = index[itemID] { return entry }
        }
        throw MTPError.notFound(path: identifier)
    }

    func item(for identifier: NSFileProviderItemIdentifier) throws -> NSFileProviderItem {
        if identifier == .rootContainer { return DisplayItem(root: true) }
        return try queue.sync {
            if let storageID = StorageIdentifier.parse(identifier) {
                guard let storage = try storages().first(where: { $0.id == storageID }) else {
                    // The stick was pulled out: saying so is what makes the
                    // folder disappear rather than hang.
                    throw MTPError.notFound(path: identifier.rawValue)
                }
                return DisplayItem(storage: storage)
            }
            return DisplayItem(
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
                let display = try target(entry.storageID)
                _ = try display.download(entry.path, to: destination.path, progress: progress)
                return (destination, DisplayItem(entry: entry))
            } catch {
                reset()
                throw error
            }
        }
    }

    // MARK: - Writing

    /// Remote path of the folder designated by an identifier, and the storage
    /// it belongs to.
    ///
    /// Callers must already hold `queue`.
    private func folder(
        for identifier: NSFileProviderItemIdentifier
    ) throws -> (
        path: String, storageID: UInt32
    ) {
        switch try container(for: identifier) {
        case .root:
            // The root lists storages and holds nothing of its own: a file put
            // there names no storage to go to.
            throw RootNotWritable()
        case .storage(let storageID):
            return ("/", storageID)
        case .folder(let entry):
            return (entry.path, entry.storageID)
        }
    }

    /// Forgets what was cached about a folder, so the next listing is read again.
    ///
    /// Callers must already hold `queue`.
    private func invalidate(folder itemID: UInt32) {
        contents.removeValue(forKey: itemID)
    }

    /// Same, for a container named by its identifier — which may be a storage.
    ///
    /// Callers must already hold `queue`.
    private func invalidate(container identifier: NSFileProviderItemIdentifier) {
        if let storageID = StorageIdentifier.parse(identifier) {
            storageContents.removeValue(forKey: storageID)
            // Free space changed, and that is part of what the root shows.
            storageList = nil
            return
        }
        invalidate(folder: mtpIdentifier(identifier))
    }

    /// Creates a file or a folder.
    func create(
        name: String,
        inParent parent: NSFileProviderItemIdentifier,
        isFolder: Bool,
        localContents: URL?,
        progress: @escaping (UInt64, UInt64) -> Void
    ) throws -> NSFileProviderItem {
        try queue.sync {
            guard RemotePath.isSafeComponent(name) else {
                throw MTPError.unsafeRemoteName(name)
            }
            let (parentPath, storageID) = try folder(for: parent)
            let destination = RemotePath.join(parentPath, name)
            let display = try target(storageID)

            let created: Entry
            if isFolder {
                created = try display.createDirectory(destination)
            } else {
                guard let localContents else {
                    throw MTPError.localFileMissing(path: name)
                }
                created = try display.upload(
                    localContents.path, to: destination, progress: progress)
            }
            index[created.itemID] = created
            invalidate(container: parent)
            return DisplayItem(entry: created)
        }
    }

    /// Renames an item, moves it, or replaces its contents.
    func modify(
        _ identifier: NSFileProviderItemIdentifier,
        newName: String?,
        newParent: NSFileProviderItemIdentifier?,
        localContents: URL?,
        progress: @escaping (UInt64, UInt64) -> Void
    ) throws -> NSFileProviderItem {
        try queue.sync {
            let itemID = mtpIdentifier(identifier)
            var current = try entry(withID: itemID, identifier: identifier.rawValue)
            let originalParent = current.parentID
            let originalStorage = current.storageID
            let display = try target(originalStorage)

            // Contents first: replacing them goes through a temporary name, so
            // doing it after a rename would undo that rename.
            if let localContents {
                current = try display.upload(
                    localContents.path, to: current.path, progress: progress)
            }
            if let newParent {
                let (parentPath, destinationStorage) = try folder(for: newParent)
                if destinationStorage == current.storageID {
                    current = try display.move(current.path, toFolder: parentPath)
                } else {
                    // MTP cannot move across storages: dragging from the stick
                    // to the internal memory has to go through the Mac.
                    current = try relocate(
                        current, toFolder: parentPath, onStorage: destinationStorage,
                        progress: progress)
                }
            }
            if let newName, newName != current.name {
                current = try target(current.storageID).rename(current.path, to: newName)
            }

            index[current.itemID] = current
            invalidate(parent: originalParent, on: originalStorage)
            invalidate(parent: current.parentID, on: current.storageID)
            return DisplayItem(entry: current)
        }
    }

    /// Deletes an item, folders included.
    /// Moves an item to another storage, by way of the Mac.
    ///
    /// The original is removed only once the copy has landed, so an interrupted
    /// move loses nothing: at worst the file exists twice.
    ///
    /// Callers must already hold `queue`.
    private func relocate(
        _ entry: Entry, toFolder folder: String, onStorage storageID: UInt32,
        progress: @escaping (UInt64, UInt64) -> Void
    ) throws -> Entry {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }

        _ = try target(entry.storageID).download(
            entry.path, to: scratch.path, progress: progress)
        let copied = try target(storageID).upload(
            scratch.path, to: RemotePath.join(folder, entry.name), progress: progress)
        try target(entry.storageID).remove(entry.path)
        index.removeValue(forKey: entry.itemID)
        return copied
    }

    /// Forgets the cached listing of a parent, whether it is a folder or the
    /// top level of a storage.
    ///
    /// Callers must already hold `queue`.
    private func invalidate(parent parentID: UInt32, on storageID: UInt32) {
        if parentID == 0 || parentID == Self.root {
            storageContents.removeValue(forKey: storageID)
            storageList = nil
        } else {
            contents.removeValue(forKey: parentID)
        }
    }

    func delete(_ identifier: NSFileProviderItemIdentifier) throws {
        try queue.sync {
            let itemID = mtpIdentifier(identifier)
            let doomed = try entry(withID: itemID, identifier: identifier.rawValue)
            // The display has no trash: the Finder asking for a deletion means
            // the item goes for good.
            try target(doomed.storageID).remove(doomed.path, recursive: true)
            index.removeValue(forKey: itemID)
            invalidate(parent: doomed.parentID, on: doomed.storageID)
            invalidate(folder: itemID)
        }
    }
}
