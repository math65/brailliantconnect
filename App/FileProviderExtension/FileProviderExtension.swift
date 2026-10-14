import FileProvider
import UniformTypeIdentifiers

/// File Provider extension backed by the braille display.
///
/// It translates the MTP tree into items the Finder knows how to display.
/// The connection is opened on demand and kept: MTP only accepts one session
/// at a time, and reopening it on every request would cost ~130 ms.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    private let domain: NSFileProviderDomain
    private let access = DisplayAccess()

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    func invalidate() {
        access.close()
    }

    // MARK: - Reading

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        do {
            completionHandler(try access.item(for: identifier), nil)
        } catch {
            // Translated rather than always "no such item": the display asleep
            // or held by the CLI said that too, and the system took it as the
            // item having been deleted.
            completionHandler(nil, Self.translate(error, identifier: identifier))
        }
        return Progress()
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    )
        -> Progress
    {
        let progress = Progress(totalUnitCount: 100)
        do {
            let (url, item) = try access.contents(of: itemIdentifier) { transferred, total in
                guard total > 0 else { return }
                progress.completedUnitCount = Int64(transferred * 100 / total)
            }
            completionHandler(url, item, nil)
        } catch {
            Ledger.record(.fetch, .error, error: error)
            completionHandler(nil, nil, Self.translate(error, identifier: itemIdentifier))
        }
        return progress
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        Enumerator(access: access, container: containerItemIdentifier)
    }

    // MARK: - Writing

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler:
            @escaping (
                NSFileProviderItem?, NSFileProviderItemFields,
                Bool, Error?
            ) -> Void
    ) -> Progress {
        let progress = uploadProgress()
        let name = itemTemplate.filename
        // Before anything else, the root check included: the Finder writes a
        // .DS_Store into folders it opens, the root among them, and the root
        // refusal would otherwise post "put the file in a storage" for a file
        // nobody put anywhere. Refused like the root — no item, no error, so
        // the system drops its copy — but silently: nobody asked for it.
        if MacJunk.matches(name) {
            Ledger.record(.create, .refusedJunk)
            completionHandler(nil, [], false, nil)
            return progress
        }
        // A name the display cannot store. Thrown as an error, it was mapped to
        // "no such item" and the file stayed in the Finder, never sent.
        // Refused, it disappears — so the notification says why.
        guard RemotePath.isSafeComponent(name) else {
            Ledger.record(.create, .refusedName)
            NameRefusal.announce(name: name)
            completionHandler(nil, [], false, nil)
            return progress
        }
        do {
            let created = try access.create(
                name: name,
                inParent: itemTemplate.parentItemIdentifier,
                isFolder: itemTemplate.contentType == .folder,
                localContents: url,
                mayAlreadyExist: options.contains(.mayAlreadyExist),
                progress: { sent, total in
                    Self.report(sent, of: total, to: progress)
                })
            if let created, url != nil, !created.isDirectory {
                Ledger.record(.create, .ok, size: created.size)
            }
            // No field is left pending and nothing remains to upload: the
            // display holds the definitive copy already. No item at all is a
            // replayed import that matched nothing, and the system drops it.
            completionHandler(created.map { DisplayItem(entry: $0) }, [], false, nil)
        } catch let refusal as RootNotWritable {
            // No item and no error: Apple's documented way of refusing an
            // import. The system then deletes what it wrote locally, instead of
            // keeping a file it will never manage to send — but it deletes it
            // without saying anything, hence the notification.
            Ledger.record(.create, .refusedRoot)
            RootRefusal.announce(storages: refusal.storages)
            completionHandler(nil, [], false, nil)
        } catch {
            Ledger.record(.create, .error, error: error, size: url.flatMap(Self.size(of:)))
            completionHandler(nil, [], false, Self.translate(error))
        }
        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler:
            @escaping (
                NSFileProviderItem?, NSFileProviderItemFields,
                Bool, Error?
            ) -> Void
    ) -> Progress {
        let progress = uploadProgress()
        // Only the name, the parent and the contents mean anything to the
        // display. Any other field — dates, tags — leaves all three nil, and
        // the item comes back with no device I/O at all.
        let newContents = changedFields.contains(.contents) ? newContents : nil
        do {
            let outcome = try access.modify(
                item.itemIdentifier,
                newName: changedFields.contains(.filename) ? item.filename : nil,
                newParent: changedFields.contains(.parentItemIdentifier)
                    ? item.parentItemIdentifier : nil,
                localContents: newContents,
                echo: item,
                progress: { sent, total in
                    Self.report(sent, of: total, to: progress)
                })
            if let uploaded = outcome.uploaded {
                Ledger.record(.modify, .ok, size: uploaded)
            }
            // A declined move or rename is not an error: the item comes back
            // where and as it was, with nothing pending, and the system puts
            // the Mac's side back to match. As an error, the root refusal was
            // "server unreachable" and retried forever.
            if let refusal = outcome.refusedRoot {
                Ledger.record(.modify, .refusedRoot)
                RootRefusal.announce(storages: refusal.storages)
            }
            if outcome.refusedName {
                Ledger.record(.modify, .refusedName)
                NameRefusal.announce(name: item.filename)
            }
            if outcome.refusedMove {
                Ledger.record(.modify, .error, error: MTPError.moveIntoItself(path: "", destination: ""))
            }
            completionHandler(outcome.item, [], false, nil)
        } catch {
            Ledger.record(
                .modify, .error, error: error, size: newContents.flatMap(Self.size(of:)))
            completionHandler(
                nil, [], false, Self.translate(error, identifier: item.itemIdentifier))
        }
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        // The root and the storages: their capabilities rule deletion out, but
        // the Terminal ignores capabilities. Rejected with the item attached,
        // which is what lets the system restore it rather than guess.
        if identifier == .rootContainer || StorageIdentifier.parse(identifier) != nil {
            let survivor: NSFileProviderItem? =
                identifier == .rootContainer
                ? DisplayItem(root: true) : (try? access.item(for: identifier))
            Ledger.record(.delete, .error, error: MTPError.cannotRemoveRoot)
            completionHandler(
                survivor.map { NSError.fileProviderErrorForRejectedDeletion(of: $0) }
                    ?? NSFileProviderError(.deletionRejected))
            return Progress()
        }
        do {
            try access.delete(identifier, recursive: options.contains(.recursive))
            completionHandler(nil)
        } catch {
            Ledger.record(.delete, .error, error: error)
            completionHandler(Self.translate(error, identifier: identifier))
        }
        return Progress()
    }

    /// A progress object the system can aggregate into the domain's global
    /// upload progress, which is what the menu bar reads.
    ///
    /// Counting in bytes rather than in percent is what makes the aggregate
    /// meaningful: the system sums several transfers, and a percentage carries
    /// no size to sum. Declaring the operation kind is what files it under
    /// "uploading" rather than nowhere.
    private func uploadProgress() -> Progress {
        let progress = Progress(totalUnitCount: 0)
        progress.kind = .file
        progress.fileOperationKind = .uploading
        return progress
    }

    /// Reports transferred bytes, setting the total the first time it is known.
    ///
    /// libmtp only reveals the size once the transfer starts, so the total is
    /// filled in on the first callback rather than up front.
    private static func report(_ sent: UInt64, of total: UInt64, to progress: Progress) {
        guard total > 0 else { return }
        if progress.totalUnitCount != Int64(total) {
            progress.totalUnitCount = Int64(total)
        }
        progress.completedUnitCount = Int64(min(sent, total))
    }

    /// Size of a local file, for the ledger.
    private static func size(of url: URL) -> UInt64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(UInt64.init)
    }

    /// Maps a protocol error onto what the Finder understands.
    ///
    /// The Finder only acts sensibly on NSFileProviderError values: anything
    /// else surfaces as an opaque failure, so the cases worth distinguishing
    /// are mapped explicitly.
    ///
    /// "No such item" is the one to be sparing with: the system takes it as the
    /// item having been deleted, and deletes it on the Mac's side too. Only an
    /// item the display was actually asked about and does not have earns it —
    /// never a display that is asleep, unplugged or held by another program.
    static func translate(
        _ error: Error, identifier: NSFileProviderItemIdentifier? = nil
    ) -> Error {
        guard let mtp = error as? MTPError else {
            return NSFileProviderError(.serverUnreachable)
        }
        switch mtp {
        case .notFound, .notADirectory:
            if let identifier {
                return NSError.fileProviderErrorForNonExistentItem(withIdentifier: identifier)
            }
            return NSFileProviderError(.noSuchItem)
        case .alreadyExists:
            return NSFileProviderError(.filenameCollision)
        case .moveIntoItself:
            // modifyItem answers this one with the unmoved item and never gets
            // here; should another path throw it, a collision at least stops
            // the system retrying the same move as if the display were away.
            return NSFileProviderError(.filenameCollision)
        case .notEnoughSpace:
            return NSFileProviderError(.insufficientQuota)
        case .directoryNotEmpty:
            return NSFileProviderError(.directoryNotEmpty)
        case .cannotRemoveRoot:
            return NSFileProviderError(.deletionRejected)
        case .unsafeRemoteName, .pathEscapesDestination, .invalidRemotePath:
            // A name or a path no retry will make valid. "No such item" here
            // told the system a file still on the display had been deleted.
            return NSFileProviderError(.cannotSynchronize)
        default:
            // Display unplugged, asleep, or held by another program; a listing
            // libmtp could not read (listingFailed) belongs here too.
            return NSFileProviderError(.serverUnreachable)
        }
    }
}

// MARK: - Enumeration

private final class Enumerator: NSObject, NSFileProviderEnumerator {

    private let access: DisplayAccess
    private let container: NSFileProviderItemIdentifier

    init(access: DisplayAccess, container: NSFileProviderItemIdentifier) {
        self.access = access
        self.container = container
        super.init()
    }

    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        do {
            observer.didEnumerate(try access.contents(ofFolder: container))
            observer.finishEnumerating(upTo: nil)
        } catch {
            // Display unplugged, or busy with another program — MTP only
            // accepts one session at a time — is "unreachable". A folder that
            // is really gone from the display is "no such item", which is what
            // makes the Finder drop it rather than retry it forever.
            Ledger.record(.enumerate, .error, error: error)
            observer.finishEnumeratingWithError(
                FileProviderExtension.translate(error, identifier: container))
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from syncAnchor: NSFileProviderSyncAnchor
    ) {
        // MTP emits no notification: nothing will ever be pushed by the
        // device. Refreshing goes through a new enumeration.
        observer.finishEnumeratingChanges(upTo: syncAnchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("1".utf8)))
    }
}

// MARK: - Items

/// Finder item backed by an MTP entry.
final class DisplayItem: NSObject, NSFileProviderItem {

    private let entry: Entry?
    private let storage: Storage?

    init(entry: Entry) {
        self.entry = entry
        self.storage = nil
        super.init()
    }

    init(root: Bool) {
        self.entry = nil
        self.storage = nil
        super.init()
    }

    /// A storage shown as a folder at the root.
    ///
    /// The display exposes its internal memory, and whatever is plugged into
    /// it, as separate storages; a single-storage view would leave a USB stick
    /// invisible with no way to reach it.
    init(storage: Storage) {
        self.entry = nil
        self.storage = storage
        super.init()
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        if let storage { return StorageIdentifier.make(storage.id) }
        guard let entry else { return .rootContainer }
        return NSFileProviderItemIdentifier(String(entry.itemID))
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        if storage != nil { return .rootContainer }
        guard let entry else { return .rootContainer }
        // At the top of a storage the parent is that storage's folder, not the
        // root: the root holds storages and nothing else.
        if entry.parentID == 0xFFFF_FFFF || entry.parentID == 0 {
            return StorageIdentifier.make(entry.storageID)
        }
        return NSFileProviderItemIdentifier(String(entry.parentID))
    }

    var filename: String {
        if let storage { return StorageIdentifier.folderName(for: storage) }
        guard let entry else { return "Brailliant" }
        // A name unusable as a path component is neutralized rather than handed
        // to the file system as is. `displayName` was doing this job and does
        // not do it: it strips control characters and leaves "..", "." and
        // "a/b" exactly as the display sent them.
        return entry.hasSafeName
            ? entry.name
            : RemotePath.safeComponent(entry.name, fallback: "item-\(entry.itemID)")
    }

    var contentType: UTType {
        if storage != nil { return .folder }
        guard let entry else { return .folder }
        if entry.isDirectory { return .folder }
        let fileExtension = (entry.name as NSString).pathExtension
        return UTType(filenameExtension: fileExtension) ?? .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        // A storage folder takes new items but is not itself a real folder:
        // renaming, moving or deleting it has no meaning on the display.
        if storage != nil {
            return [.allowsContentEnumerating, .allowsReading, .allowsAddingSubItems]
        }
        // The root holds storages and nothing else, so it takes no new items.
        // This is what greys out Paste in the Finder; `createItem` refusing the
        // import is the second barrier, for whatever reaches it anyway.
        guard let entry else {
            return [.allowsContentEnumerating, .allowsReading]
        }
        var capabilities: NSFileProviderItemCapabilities = [
            .allowsReading, .allowsRenaming, .allowsReparenting, .allowsDeleting,
        ]
        if entry.isDirectory {
            capabilities.insert(.allowsContentEnumerating)
            capabilities.insert(.allowsAddingSubItems)
        } else {
            capabilities.insert(.allowsWriting)
        }
        // A name the file system cannot represent is left read-only: renaming
        // or moving it would mean writing that name to disk.
        if !entry.hasSafeName {
            capabilities.remove(.allowsRenaming)
            capabilities.remove(.allowsReparenting)
        }
        return capabilities
    }

    var documentSize: NSNumber? {
        guard let entry, !entry.isDirectory else { return nil }
        return NSNumber(value: entry.size)
    }

    var contentModificationDate: Date? { entry?.modified }

    var itemVersion: NSFileProviderItemVersion {
        // MTP provides no version token: the modification date and the size
        // serve as a fingerprint.
        let fingerprint =
            entry.map { "\($0.modified?.timeIntervalSince1970 ?? 0)-\($0.size)" }
            ?? "racine"
        return NSFileProviderItemVersion(
            contentVersion: Data(fingerprint.utf8),
            metadataVersion: Data(fingerprint.utf8))
    }
}

// MARK: - Storage identifiers

/// Identifiers for the storage folders shown at the root.
///
/// They must not be mistaken for an MTP object: those are plain numbers, so a
/// prefix that cannot parse as one keeps the two apart with no ambiguity.
enum StorageIdentifier {

    private static let prefix = "storage:"

    static func make(_ id: UInt32) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(prefix + String(id))
    }

    /// The storage an identifier designates, or nil if it designates an object.
    static func parse(_ identifier: NSFileProviderItemIdentifier) -> UInt32? {
        guard identifier.rawValue.hasPrefix(prefix) else { return nil }
        return UInt32(identifier.rawValue.dropFirst(prefix.count))
    }

    /// Name of the folder standing for a storage.
    ///
    /// The display names its storages "1- mémoire interne" and "3- usb": the
    /// leading number is an internal index that means nothing to the person
    /// reading it, and a slash would break the path outright.
    static func folderName(for storage: Storage) -> String {
        var name = storage.description
        if let range = name.range(of: #"^\s*\d+\s*-\s*"#, options: .regularExpression) {
            name.removeSubrange(range)
        }
        // The name comes from the device, so it is not trusted: a storage
        // announcing itself as ".." would otherwise become a folder called ".."
        // in the user's home.
        return RemotePath.safeComponent(name, fallback: "storage \(storage.id)")
    }
}
