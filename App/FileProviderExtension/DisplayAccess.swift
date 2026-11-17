import FileProvider
import Foundation
import os.log

/// Raised when something would be written at the root of the domain.
///
/// Its own type because the extension has to answer this case differently from
/// a failure: refusing an import means returning no item **and no error**, so
/// that the system removes its local copy. Reporting an error instead leaves a
/// file the Finder shows and the display never received.
struct RootNotWritable: Error {
    /// Names of the storages, so the message can point at the real ones rather
    /// than at names hard-coded here that the display may not use.
    let storages: [String]
}

/// What a modification did, beyond the item it left behind.
///
/// Two of its parts can be declined without failing the whole call, and the
/// extension answers each of them differently from an error: a move to the
/// root and a name the display cannot store both leave the item where and as
/// it was, which the system then puts back on the Mac's side.
struct Modification {
    let item: NSFileProviderItem
    /// Set when the item was asked to move to the root, and stayed put.
    let refusedRoot: RootNotWritable?
    /// Set when the new name could not be written to the display.
    let refusedName: Bool
    /// Bytes sent, when the contents were replaced.
    let uploaded: UInt64?
    /// Set when a folder was asked into its own subtree, and stayed put.
    var refusedMove = false
}

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

    /// Entries read during this session, under the numbers the Finder knows
    /// them by. The MTP handles inside are this session's only: the display
    /// renumbers everything at the next one, so all of this goes with the
    /// connection (see `ItemIdentities`).
    private var index: [UInt64: Entry] = [:]
    /// Contents of the folders already enumerated, with the date they were read.
    private var contents: [UInt64: (entries: [Entry], read: Date)] = [:]
    /// The identifiers handed to the system, which outlive the session, the
    /// connection and this process.
    private var identities: ItemIdentities
    /// What the file holds: written again only when the table differs. Asking
    /// for a number already given changes nothing, and the Finder lists far
    /// more often than anything new appears.
    private var savedIdentities: ItemIdentities

    init() {
        identities = Self.loadIdentities()
        savedIdentities = identities
    }
    /// Top level of each storage, kept apart: a storage identifier and an
    /// object identifier are both plain numbers and would collide in one
    /// dictionary.
    private var storageContents: [UInt32: (entries: [Entry], read: Date)] = [:]
    /// The list of storages, which changes the moment a stick is plugged in.
    private var storageList: (storages: [Storage], read: Date)?

    // MARK: - Connection

    private func connection() throws -> Brailliant {
        if let display { return display }
        // Only the devices `KnownDevices` accepts: a connected Android phone
        // is an MTP device like any other.
        Self.log.info("opening an MTP session")
        let opened: Brailliant
        do {
            opened = try Brailliant(knownDevicesOnly: true)
        } catch {
            // Its own line in the ledger: the operation that needed the
            // connection logs its failure too, but only this one says the
            // display was never reached — asleep, or held by another program.
            Ledger.record(.connect, .error, error: error)
            throw error
        }
        Self.log.info("session open: \(opened.model, privacy: .public)")
        display = opened
        writeSnapshot(of: opened)
        return opened
    }

    /// Leaves what only the device can tell where the agent can read it.
    ///
    /// The agent has no other way to obtain it. MTP allows one session at a
    /// time, and once the Finder location is published this extension holds it
    /// for good — measured, not assumed: `brailliant doctor` run beside it
    /// fails with `libusb_claim_interface = -3`, and still failed a minute
    /// later. So a problem report would carry no model and no storages exactly
    /// where they are wanted, unless the process that has the connection writes
    /// them down as it goes.
    ///
    /// Our own container: sandbox-writable here, readable from outside by the
    /// agent, which is not sandboxed. Nothing else is shared between the two,
    /// and no App Group is involved — the extension's is deliberately empty.
    ///
    /// Written once per session, best effort: a failure here must never turn
    /// into a failure to serve the Finder.
    private func writeSnapshot(of display: Brailliant) {
        var snapshot: [String: Any] = [
            "written": ISO8601DateFormatter().string(from: Date()),
            "model": display.model,
            "serial": display.serialNumber,
        ]
        if let storages = try? display.storages() {
            snapshot["storages"] = storages.map {
                [
                    "name": $0.description.sanitizedForDisplay,
                    "capacity": $0.capacity,
                    "free": $0.free,
                ]
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot) else { return }
        let directory = Ledger.directory
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("last-device.json"))
    }

    func close() {
        queue.sync {
            saveIdentities()
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

    /// True when an error casts doubt on the connection itself.
    ///
    /// Resetting after every failure threw away the session's cache and
    /// reopened it — ~130 ms and every path resolved again — for an answer as ordinary as "this
    /// file is no longer there". Only what the device or the transfer failed at
    /// warrants it. Unknown cases count as suspect: a reconnection too many
    /// costs a moment, one too few leaves a dead session in place.
    static func leavesConnectionSuspect(_ error: Error) -> Bool {
        guard let mtp = error as? MTPError else {
            // A local file-system error, or a refusal decided here: the
            // display had no part in it.
            return false
        }
        switch mtp {
        case .notFound, .notADirectory, .alreadyExists, .directoryNotEmpty,
            .localFileMissing, .invalidRemotePath, .cannotRemoveRoot,
            .unsafeRemoteName, .pathEscapesDestination, .notEnoughSpace,
            .storageNotFound, .ambiguousStorage, .moveIntoItself:
            return false
        default:
            // listingFailed among them: libmtp could not read a folder, which
            // is the session failing, not the folder being empty.
            return true
        }
    }

    /// Runs an operation on `queue`, dropping the connection when its failure
    /// says the connection is what failed.
    ///
    /// Never call from code already on `queue`.
    private func serialized<T>(_ body: () throws -> T) throws -> T {
        try queue.sync {
            // Whatever the outcome: a failed move may still have renamed.
            defer { saveIdentities() }
            do {
                return try body()
            } catch {
                if Self.leavesConnectionSuspect(error) { reset() }
                throw error
            }
        }
    }

    // MARK: - Reading

    // MARK: Identities

    /// Where the identifiers are kept, beside the ledger: the system keeps
    /// them for as long as the location is published, and recycles this
    /// process freely meanwhile.
    private static var identitiesFile: URL {
        Ledger.directory.appendingPathComponent("identities.json")
    }

    /// An unreadable file starts a new table: the numbers the system still
    /// holds then designate nothing, and are answered "not found", never
    /// another item.
    private static func loadIdentities() -> ItemIdentities {
        guard let data = try? Data(contentsOf: identitiesFile),
            let table = try? JSONDecoder().decode(ItemIdentities.self, from: data)
        else { return ItemIdentities() }
        return table
    }

    /// Best effort, like the snapshot: failing to save must never turn into
    /// failing to serve the Finder. Lost, the table costs the system a new
    /// number for each item it asks about again, nothing worse.
    ///
    /// Callers must already hold `queue`.
    private func saveIdentities() {
        guard identities != savedIdentities,
            let data = try? JSONEncoder().encode(identities)
        else { return }
        try? FileManager.default.createDirectory(
            at: Ledger.directory, withIntermediateDirectories: true)
        if (try? data.write(to: Self.identitiesFile, options: .atomic)) != nil {
            savedIdentities = identities
        }
    }

    private static func location(of entry: Entry) -> ItemLocation {
        ItemLocation(storageID: entry.storageID, path: entry.path)
    }

    /// The identifier of the folder holding `location`: its storage's folder
    /// at the top level, a numbered folder below.
    ///
    /// Callers must already hold `queue`.
    private func parentIdentifier(of location: ItemLocation) -> NSFileProviderItemIdentifier {
        let parent = location.parent
        if parent.path == "/" { return StorageIdentifier.make(location.storageID) }
        return ItemIdentifier.make(identities.number(for: parent))
    }

    /// The Finder item for an entry just read, numbered — and remembered for
    /// the rest of the session under that number.
    ///
    /// Callers must already hold `queue`.
    private func displayItem(for entry: Entry) -> DisplayItem {
        let location = Self.location(of: entry)
        let number = identities.number(for: location)
        index[number] = entry
        return DisplayItem(
            entry: entry, number: number, parent: parentIdentifier(of: location))
    }

    /// The entry behind an identifier, read in this session.
    ///
    /// Anything that is not one of our numbers is not found, without asking
    /// the display: the working set, the trash, a storage folder, and the
    /// plain MTP handles that versions up to 1.3.0 beta 1 handed out — which
    /// designate whatever the display numbered that way this time.
    ///
    /// Callers must already hold `queue`.
    private func object(_ identifier: NSFileProviderItemIdentifier) throws -> (Entry, UInt64) {
        guard let number = ItemIdentifier.parse(identifier) else {
            throw MTPError.notFound(path: identifier.rawValue)
        }
        return (try entry(numbered: number), number)
    }

    /// Looks an entry up by its number, reading its path again in this session
    /// if need be.
    ///
    /// The system stops and restarts the extension freely, and every connection
    /// numbers the display's objects anew. The Finder still refers to items by
    /// an identifier it obtained earlier, so the number leads to a path, and
    /// the path is resolved now — never a handle from an earlier session.
    /// Nothing at that path any more: the item is gone, and so is its number.
    ///
    /// Callers must already hold `queue`.
    private func entry(numbered number: UInt64) throws -> Entry {
        if let entry = index[number] { return entry }
        guard let location = identities.location(of: number) else {
            throw MTPError.notFound(path: "item \(number)")
        }
        guard let found = try target(location.storageID).resolve(location.path) else {
            identities.forget(location)
            throw MTPError.notFound(path: location.path)
        }
        index[number] = found
        return found
    }

    /// Forgets what this session cached at and below a location that has just
    /// moved, been renamed or gone. Its numbers are another matter, settled by
    /// the caller.
    ///
    /// Callers must already hold `queue`.
    private func dropCaches(below location: ItemLocation) {
        for (number, entry) in index where location.contains(Self.location(of: entry)) {
            index.removeValue(forKey: number)
            contents.removeValue(forKey: number)
        }
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
        /// A folder inside a storage, and its number.
        case folder(Entry, UInt64)
    }

    /// Callers must already hold `queue`.
    private func container(for identifier: NSFileProviderItemIdentifier) throws -> Container {
        if identifier == .rootContainer { return .root }
        if let storageID = StorageIdentifier.parse(identifier) { return .storage(storageID) }
        let (entry, number) = try object(identifier)
        return .folder(entry, number)
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
    /// Empty slots are left out (see `Storage.isEmptySlot`): listing one fails,
    /// and that failure resets the connection — when items were still looked
    /// up by walking every storage returned here, one empty USB port made the
    /// whole location reconnect over and over.
    ///
    /// Callers must already hold `queue`.
    private func storages() throws -> [Storage] {
        if let cache = storageList, Date().timeIntervalSince(cache.read) < Self.freshness {
            return cache.storages
        }
        let found = try target(nil).storages(refresh: true).filter { !$0.isEmptySlot }
        storageList = (found, Date())
        return found
    }

    func contents(ofFolder identifier: NSFileProviderItemIdentifier) throws -> [NSFileProviderItem]
    {
        // Neither has anything to do with the display. The working set is
        // where a provider would publish remote changes, and MTP signals none;
        // the trash does not exist, since a deletion here is final. Both used to
        // fall back to the root and list the storages a second time.
        if identifier == .workingSet || identifier == .trashContainer { return [] }
        return try serialized {
            do {
                switch try container(for: identifier) {
                case .root:
                    return try storages().map { DisplayItem(storage: $0) }
                case .storage(let storageID):
                    return try list(
                        ItemLocation(storageID: storageID, path: "/"),
                        cached: storageContents[storageID],
                        store: { self.storageContents[storageID] = $0 })
                case .folder(let entry, let number):
                    return try list(
                        Self.location(of: entry),
                        cached: contents[number],
                        store: { self.contents[number] = $0 })
                }
            } catch {
                Self.log.error("enumeration failed: \(String(describing: error))")
                throw error
            }
        }
    }

    /// Lists one folder of one storage, through its cache.
    ///
    /// Callers must already hold `queue`.
    private func list(
        _ folder: ItemLocation,
        cached: (entries: [Entry], read: Date)?,
        store: ((entries: [Entry], read: Date)) -> Void
    ) throws -> [NSFileProviderItem] {
        if let cached, Date().timeIntervalSince(cached.read) < Self.freshness {
            return cached.entries.map { displayItem(for: $0) }
        }
        let entries = try target(folder.storageID).listDirectory(folder.path)
            .filter { !MacJunk.matches($0.name) }
        // What the folder no longer holds was deleted on the display itself.
        for number in identities.keepOnly(Set(entries.map(\.name)), in: folder) {
            index.removeValue(forKey: number)
            contents.removeValue(forKey: number)
        }
        store((entries, Date()))
        return entries.map { displayItem(for: $0) }
    }

    func item(for identifier: NSFileProviderItemIdentifier) throws -> NSFileProviderItem {
        if identifier == .rootContainer { return DisplayItem(root: true) }
        return try serialized {
            if let storageID = StorageIdentifier.parse(identifier) {
                guard let storage = try storages().first(where: { $0.id == storageID }) else {
                    // The stick was pulled out: saying so is what makes the
                    // folder disappear rather than hang.
                    throw MTPError.notFound(path: identifier.rawValue)
                }
                return DisplayItem(storage: storage)
            }
            return displayItem(for: try object(identifier).0)
        }
    }

    func contents(
        of identifier: NSFileProviderItemIdentifier,
        progress: @escaping (UInt64, UInt64) -> Void
    )
        throws -> (URL, NSFileProviderItem)
    {
        try serialized {
            let (entry, _) = try object(identifier)
            // The system expects a temporary file that it will copy itself.
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            let display = try target(entry.storageID)
            if entry.isDirectory {
                // Only a package is ever fetched: a folder is enumerated.
                try display.downloadContents(of: entry.path, into: destination, progress: progress)
            } else {
                _ = try display.download(entry.path, to: destination.path, progress: progress)
            }
            return (destination, displayItem(for: entry))
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
            // there names no storage to go to. The storage names only dress up
            // the message: failing to read them must not turn the refusal into
            // an ordinary error, which would leave the file at the root, shown
            // and never sent.
            throw RootNotWritable(
                storages: (try? storages())?.map { StorageIdentifier.folderName(for: $0) } ?? [])
        case .storage(let storageID):
            return ("/", storageID)
        case .folder(let entry, _):
            return (entry.path, entry.storageID)
        }
    }

    /// Forgets what was cached about a folder, so the next listing is read again.
    ///
    /// Callers must already hold `queue`.
    private func invalidate(folder number: UInt64) {
        contents.removeValue(forKey: number)
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
        if let number = ItemIdentifier.parse(identifier) { invalidate(folder: number) }
    }

    /// Creates a file or a folder.
    ///
    /// - Parameter mayAlreadyExist: the system replaying an import it may
    ///   already have made — after a crash, or when the location is rebuilt.
    ///   Only then is an existing item on the display taken as this one.
    ///   Otherwise it is a collision: with no change notifications, the Finder
    ///   cannot know about a file created on the display since it last looked,
    ///   and overwriting it would destroy it without a word. Reported, the
    ///   collision makes the system rename the incoming item instead.
    /// - Returns: the created item and the bytes sent, if any; nil when a
    ///   replayed import matches nothing — which tells the system to drop its
    ///   copy.
    func create(
        name: String,
        inParent parent: NSFileProviderItemIdentifier,
        isFolder: Bool,
        localContents: URL?,
        mayAlreadyExist: Bool,
        progress: @escaping (UInt64, UInt64) -> Void
    ) throws -> (item: DisplayItem, sent: UInt64?)? {
        try serialized {
            guard RemotePath.isSafeComponent(name) else {
                throw MTPError.unsafeRemoteName(name)
            }
            let (parentPath, storageID) = try folder(for: parent)
            let destination = RemotePath.join(parentPath, name)
            let display = try target(storageID)

            let created: Entry
            var sent: UInt64?
            if isFolder {
                // createDirectory hands back a folder that already exists:
                // right for a replay, which merges, and a collision otherwise.
                let existed = try display.resolve(destination) != nil
                if !mayAlreadyExist, existed {
                    throw MTPError.alreadyExists(path: destination)
                }
                created = try display.createDirectory(destination)
                // A package comes as one item: its files are never created
                // on their own (measured 15 Oct 2026 — the display received
                // an empty folder, and the system knew none of them). What it
                // holds is behind its contents URL; a plain folder has none.
                if let localContents, Self.isFolder(localContents) {
                    do {
                        sent = try display.uploadContents(
                            of: localContents, into: destination, progress: progress)
                    } catch {
                        // Half a document is worse than none: the retry starts
                        // clean. Only what this call created is removed.
                        if !existed { try? display.remove(destination, recursive: true) }
                        throw error
                    }
                }
            } else if let localContents {
                created = try display.upload(
                    localContents.path, to: destination, progress: progress,
                    overwrite: mayAlreadyExist)
                sent = created.size
            } else if mayAlreadyExist {
                // A replayed import of a file the Mac holds no contents for:
                // the system asks whether the display has it, and only that.
                guard let existing = try display.resolve(destination), !existing.isDirectory
                else { return nil }
                created = existing
            } else {
                throw MTPError.localFileMissing(path: name)
            }
            // A new item gets a new number. One still held for this path
            // belonged to something deleted on the display itself since the
            // Finder last looked; that item is gone, and the number with it.
            // A replay is the same item again, and keeps its own.
            if !mayAlreadyExist { identities.forget(Self.location(of: created)) }
            invalidate(container: parent)
            return (displayItem(for: created), sent)
        }
    }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// Renames an item, moves it, or replaces its contents.
    ///
    /// - Parameter echo: the item as the system passed it, returned as is when
    ///   nothing the display stores has changed.
    func modify(
        _ identifier: NSFileProviderItemIdentifier,
        newName: String?,
        newParent: NSFileProviderItemIdentifier?,
        localContents: URL?,
        echo: NSFileProviderItem,
        progress: @escaping (UInt64, UInt64) -> Void
    ) throws -> Modification {
        // The root and the storage folders are not MTP objects, and their
        // capabilities rule out renaming and moving them. What still reaches
        // here is metadata — the system pushing a storage folder's new
        // modification date after a file landed in it. Looked up as an object,
        // the identifier fell back to the root, walked every storage in search
        // of it, and answered "the file does not exist": an Error badge on the
        // folder for a transfer that had succeeded, retried every few minutes,
        // each retry walking the whole display again. The display keeps no
        // such metadata, so its current state is the answer.
        if identifier == .rootContainer || StorageIdentifier.parse(identifier) != nil {
            return Modification(
                item: try item(for: identifier), refusedRoot: nil, refusedName: false,
                uploaded: nil)
        }
        return try serialized {
            // The same push, for an ordinary file or folder: dates, tags,
            // permissions — nothing MTP can store. Looking the item up would
            // cost a listing per folder of its path whenever the session's
            // cache is cold, for an answer that cannot differ from what the
            // system already holds.
            if newName == nil, newParent == nil, localContents == nil {
                let known = ItemIdentifier.parse(identifier).flatMap { index[$0] }
                return Modification(
                    item: known.map { displayItem(for: $0) } ?? echo,
                    refusedRoot: nil, refusedName: false, uploaded: nil)
            }

            let (original, number) = try object(identifier)
            var current = original

            // The destination is settled before anything is written. A move to
            // the root is declined, and declining it after the new contents had
            // gone out would leave the display changed by a request the
            // extension reports as not carried out.
            var destination: (path: String, storageID: UInt32)?
            var refusedRoot: RootNotWritable?
            // "Moved" into the folder it is already in — the system sends that.
            // The MTP layer treats it as a no-op too, but only after resolving
            // both paths on the display; known here, it costs nothing.
            if let newParent, newParent != parentIdentifier(of: Self.location(of: current)) {
                do {
                    destination = try folder(for: newParent)
                } catch let refusal as RootNotWritable {
                    // `mv` from the Terminal reaches here; the Finder greys
                    // the root out. Thrown on, this became "server
                    // unreachable" and was retried forever. Answered with the
                    // item where it was, it makes the system put it back.
                    refusedRoot = refusal
                }
            }

            // Contents first: replacing them goes through a temporary name, so
            // doing it after a rename would undo that rename.
            var uploaded: UInt64?
            if let localContents {
                let display = try target(current.storageID)
                if current.isDirectory {
                    // A package edited on the Mac: the whole of it again.
                    let replaced = try display.replaceFolder(
                        current.path, with: localContents, progress: progress)
                    current = replaced.entry
                    uploaded = replaced.sent
                } else {
                    current = try display.upload(
                        localContents.path, to: current.path, progress: progress)
                    uploaded = current.size
                }
            }
            var refusedMove = false
            if let destination {
                if destination.storageID == current.storageID {
                    do {
                        current = try target(current.storageID).move(
                            current.path, toFolder: destination.path)
                    } catch MTPError.moveIntoItself {
                        // A folder into its own subtree. The system never sends
                        // that for a change made on the Mac, so the index is
                        // stale or the display changed under it — and no retry
                        // can succeed. Thrown on, any error the system retries
                        // would retry this forever, and "collision" would have
                        // it rename the folder and try the same move again.
                        // Answered like the root, with the item where it is,
                        // the system moves its side back.
                        refusedMove = true
                    }
                } else {
                    // MTP cannot move across storages: dragging from the stick
                    // to the internal memory has to go through the Mac.
                    current = try relocate(
                        current, toFolder: destination.path, onStorage: destination.storageID,
                        progress: progress)
                }
            }
            // A name the display cannot store — a slash, a backslash — is left
            // out rather than failed. Failing it was mapped to "no such item",
            // which told the system the file was gone; returning the item under
            // its old name makes the system rename it back instead.
            var refusedName = false
            if let newName, newName != current.name {
                if RemotePath.isSafeComponent(newName) {
                    current = try target(current.storageID).rename(current.path, to: newName)
                } else {
                    refusedName = true
                }
            }

            // The item keeps its number wherever it went, and so does
            // everything inside it: the system knows them all by number.
            let origin = Self.location(of: original)
            let arrival = Self.location(of: current)
            if arrival != origin {
                dropCaches(below: origin)
                dropCaches(below: arrival)
                identities.move(from: origin, to: arrival)
            }
            invalidate(parentOf: origin)
            invalidate(parentOf: arrival)
            let item = displayItem(for: current)
            // Only possible if the table was lost mid-call; said rather than
            // hidden, since the system would otherwise hold a dead number.
            if item.number != number {
                Self.log.error("item \(number) came back as \(item.number)")
            }
            return Modification(
                item: item, refusedRoot: refusedRoot,
                refusedName: refusedName, uploaded: uploaded, refusedMove: refusedMove)
        }
    }

    /// Moves an item to another storage, by way of the Mac.
    ///
    /// The original is removed only once the copy has landed in full — a whole
    /// folder of it, if a folder is moving — so an interrupted move loses
    /// nothing: at worst the item exists twice.
    ///
    /// Callers must already hold `queue`.
    private func relocate(
        _ entry: Entry, toFolder folder: String, onStorage storageID: UInt32,
        progress: @escaping (UInt64, UInt64) -> Void
    ) throws -> Entry {
        // Checked once, at the top: below it everything is new, and merging
        // into a folder of the same name would overwrite files in it silently.
        let destination = RemotePath.join(folder, entry.name)
        if RemotePath.isSafeComponent(entry.name), try target(storageID).resolve(destination) != nil
        {
            throw MTPError.alreadyExists(path: destination)
        }
        let copied = try copyAcross(
            entry, toFolder: folder, onStorage: storageID, progress: progress)
        try target(entry.storageID).remove(entry.path, recursive: true)
        dropCaches(below: Self.location(of: entry))
        return copied
    }

    /// Copies an item, and everything inside it if it is a folder, to another
    /// storage. Nothing is removed here.
    ///
    /// A folder used to go straight to `download`, which takes files only: the
    /// move failed, the system retried it, and it failed again, for good.
    ///
    /// Callers must already hold `queue`.
    private func copyAcross(
        _ entry: Entry, toFolder folder: String, onStorage storageID: UInt32,
        progress: @escaping (UInt64, UInt64) -> Void
    ) throws -> Entry {
        // Refused rather than repaired: renaming someone's file behind their
        // back during a move is worse than declining the move. The name is the
        // display's, and nothing guarantees it is usable.
        guard RemotePath.isSafeComponent(entry.name) else {
            throw MTPError.unsafeRemoteName(entry.name)
        }
        let destination = RemotePath.join(folder, entry.name)

        if entry.isDirectory {
            let created = try target(storageID).createDirectory(destination)
            // Listed before anything is written to the other storage, and every
            // child copied — Mac junk included: it is on the display, so it is
            // the user's, whatever the Finder chooses to show.
            for child in try target(entry.storageID).listDirectory(entry.path) {
                _ = try copyAcross(
                    child, toFolder: destination, onStorage: storageID, progress: progress)
            }
            return created
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        _ = try target(entry.storageID).download(
            entry.path, to: scratch.path, progress: progress)
        return try target(storageID).upload(
            scratch.path, to: destination, progress: progress, overwrite: false)
    }

    /// Forgets the cached listing of a parent, whether it is a folder or the
    /// top level of a storage.
    ///
    /// Callers must already hold `queue`.
    private func invalidate(parentOf location: ItemLocation) {
        let parent = location.parent
        if parent.path == "/" {
            storageContents.removeValue(forKey: location.storageID)
            storageList = nil
        } else if let number = identities.existingNumber(for: parent) {
            contents.removeValue(forKey: number)
        }
    }

    /// Deletes an item.
    ///
    /// - Parameter recursive: whether the system asked for a folder's contents
    ///   to go with it. Without it, a folder holding anything is refused: the
    ///   system believed it empty, so what it holds was put there from the
    ///   display itself and has never been seen on the Mac.
    func delete(_ identifier: NSFileProviderItemIdentifier, recursive: Bool) throws {
        // The root and the storages are not objects the display can delete.
        // Looked up as one, the root fell back to itself and walked everything.
        if identifier == .rootContainer || StorageIdentifier.parse(identifier) != nil {
            throw MTPError.cannotRemoveRoot
        }
        try serialized {
            let (doomed, _) = try object(identifier)
            let display = try target(doomed.storageID)
            var recursive = recursive
            if doomed.isDirectory && !recursive {
                // Mac junk does not count: the listings hide it, so the system
                // asking for a plain delete of a folder that only holds a
                // .DS_Store is right to think it empty, and refusing would make
                // the folder impossible to delete.
                let held = try display.listDirectory(doomed.path)
                    .filter { !MacJunk.matches($0.name) }
                guard held.isEmpty else {
                    throw MTPError.directoryNotEmpty(path: doomed.path, count: held.count)
                }
                recursive = true
            }
            // The display has no trash: the Finder asking for a deletion means
            // the item goes for good.
            try display.remove(doomed.path, recursive: recursive)
            let location = Self.location(of: doomed)
            dropCaches(below: location)
            identities.forget(location)
            invalidate(parentOf: location)
        }
    }
}

// MARK: - Event ledger

/// One line per failed or refused operation, for problem reports.
///
/// Nothing the extension logs reaches `log show`, at any level — so when a copy
/// fails, the report the agent assembles knows the location is published and
/// nothing about what went wrong inside it. This file is the agent's only
/// window onto that. It sits beside `last-device.json`, in our own container:
/// sandbox-writable here, readable by the agent, which is not sandboxed.
///
/// Format, one line per event, tab-separated, UTF-8:
///
///     <ISO 8601 UTC date> \t <operation> \t <outcome> \t <detail>
///
/// The detail names the error and its codes, then, for a failed import, the
/// type the system declared and what it handed over as contents
/// (`type=com.apple.rtfd contents=none`), and the size when one is known —
/// never a file name. A type names at most the file's extension. A report is
/// sent to someone else; what the user keeps on their display is not part of
/// it.
enum Ledger {

    enum Operation: String {
        case create, modify, delete, fetch, enumerate, connect
    }

    enum Outcome: String {
        case ok
        case refusedRoot = "refused-root"
        case refusedJunk = "refused-junk"
        case refusedName = "refused-name"
        case error
    }

    /// Where the extension leaves what the agent reads: its own container's
    /// Application Support, as `NSHomeDirectory()` resolves inside the sandbox.
    static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/BrailliantConnect")
    }

    /// The file has no rotation of its own: past this size it is cut down to
    /// its most recent part. The agent sends at most this much.
    private static let cap = 64 * 1024
    private static let kept = 48 * 1024

    private static let lock = NSLock()

    /// Appends one event. Never throws, never fails the operation it describes.
    static func record(
        _ operation: Operation, _ outcome: Outcome, error: Error? = nil,
        contents: String? = nil, size: UInt64? = nil
    ) {
        var detail = error.map(describe) ?? ""
        if let contents {
            detail += (detail.isEmpty ? "" : " ") + contents
        }
        if let size {
            detail += (detail.isEmpty ? "" : " ") + "size=\(size)"
        }
        // A tab or a line break inside the detail would split the record.
        detail = detail.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let line =
            [
                ISO8601DateFormatter().string(from: Date()),
                operation.rawValue, outcome.rawValue, detail,
            ].joined(separator: "\t") + "\n"

        lock.lock()
        defer { lock.unlock() }
        append(Data(line.utf8))
    }

    private static func append(_ data: Data) {
        let manager = FileManager.default
        let file = directory.appendingPathComponent("events.log")
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let handle = try? FileHandle(forWritingTo: file) else {
            try? data.write(to: file)
            return
        }
        // The throwing variants: the older write(_:) raises an Objective-C
        // exception on failure, which Swift cannot catch.
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.write(contentsOf: data)
        try? handle.close()

        guard Int(size) + data.count > cap, let whole = try? Data(contentsOf: file) else { return }
        var tail = whole.suffix(kept)
        // Cut at a line boundary, so the first line kept is a whole one.
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: newline)...]
        }
        try? Data(tail).write(to: file, options: .atomic)
    }

    /// The error, by name and code, without what it carries of the user's
    /// files.
    ///
    /// `String(describing:)` would be the obvious choice and is the wrong one:
    /// MTPError's description is the localized message, paths included, and an
    /// NSError's carries its file URL in the user info.
    private static func describe(_ error: Error) -> String {
        if error is RootNotWritable { return "RootNotWritable" }
        guard let mtp = error as? MTPError else {
            let ns = error as NSError
            return "\(ns.domain) \(ns.code)"
        }
        switch mtp {
        case .localeUnavailable: return "localeUnavailable"
        case .noDeviceFound: return "noDeviceFound"
        case .connectionFailed: return "connectionFailed"
        case .noStorage: return "noStorage"
        case .cannotRemoveRoot: return "cannotRemoveRoot"
        case .transferFailed(_, let code): return "transferFailed(code: \(code))"
        case .deleteFailed(_, let code): return "deleteFailed(code: \(code))"
        case .renameFailed(_, _, let code): return "renameFailed(code: \(code))"
        case .moveFailed(_, _, let code): return "moveFailed(code: \(code))"
        case .directoryNotEmpty(_, let count): return "directoryNotEmpty(count: \(count))"
        case .notEnoughSpace(let needed, let available):
            return "notEnoughSpace(needed: \(needed), available: \(available))"
        case .deviceIndexOutOfRange(let requested, let found):
            return "deviceIndexOutOfRange(requested: \(requested), found: \(found))"
        case .noHumanwareDevice(let others):
            let devices = others.map {
                String(format: "%04x:%04x", $0.vendor, $0.product)
            }
            return "noHumanwareDevice(others: [\(devices.joined(separator: ", "))])"
        default:
            // Every other case carries a path or a name: its label alone.
            return Mirror(reflecting: mtp).children.first?.label ?? "MTPError"
        }
    }
}
