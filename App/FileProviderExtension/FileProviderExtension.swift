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
            completionHandler(nil, NSFileProviderError(.noSuchItem))
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
            completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
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
        do {
            let item = try access.create(
                name: itemTemplate.filename,
                inParent: itemTemplate.parentItemIdentifier,
                isFolder: itemTemplate.contentType == .folder,
                localContents: url,
                progress: { sent, total in
                    Self.report(sent, of: total, to: progress)
                })
            // No field is left pending and nothing remains to upload: the
            // display holds the definitive copy already.
            completionHandler(item, [], false, nil)
        } catch let refusal as RootNotWritable {
            // No item and no error: Apple's documented way of refusing an
            // import. The system then deletes what it wrote locally, instead of
            // keeping a file it will never manage to send — but it deletes it
            // without saying anything, hence the notification.
            RootRefusal.announce(storages: refusal.storages)
            completionHandler(nil, [], false, nil)
        } catch {
            completionHandler(nil, [], false, translate(error))
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
        do {
            let modified = try access.modify(
                item.itemIdentifier,
                newName: changedFields.contains(.filename) ? item.filename : nil,
                newParent: changedFields.contains(.parentItemIdentifier)
                    ? item.parentItemIdentifier : nil,
                localContents: changedFields.contains(.contents) ? newContents : nil,
                progress: { sent, total in
                    Self.report(sent, of: total, to: progress)
                })
            completionHandler(modified, [], false, nil)
        } catch {
            completionHandler(nil, [], false, translate(error))
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
        do {
            try access.delete(identifier)
            completionHandler(nil)
        } catch {
            completionHandler(translate(error))
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

    /// Maps a protocol error onto what the Finder understands.
    ///
    /// The Finder only acts sensibly on NSFileProviderError values: anything
    /// else surfaces as an opaque failure, so the cases worth distinguishing
    /// are mapped explicitly.
    private func translate(_ error: Error) -> Error {
        guard let mtp = error as? MTPError else {
            return NSFileProviderError(.serverUnreachable)
        }
        switch mtp {
        case .notFound:
            return NSFileProviderError(.noSuchItem)
        case .alreadyExists:
            return NSFileProviderError(.filenameCollision)
        case .notEnoughSpace:
            return NSFileProviderError(.insufficientQuota)
        case .unsafeRemoteName, .pathEscapesDestination, .invalidRemotePath:
            return NSFileProviderError(.noSuchItem)
        default:
            // Display unplugged, asleep, or held by another program.
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
            // Display unplugged, or busy with another program: MTP only
            // accepts one session at a time.
            observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
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
