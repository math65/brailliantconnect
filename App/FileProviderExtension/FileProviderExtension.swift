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
        let progress = Progress(totalUnitCount: 100)
        do {
            let item = try access.create(
                name: itemTemplate.filename,
                inParent: itemTemplate.parentItemIdentifier,
                isFolder: itemTemplate.contentType == .folder,
                localContents: url,
                progress: { sent, total in
                    guard total > 0 else { return }
                    progress.completedUnitCount = Int64(sent * 100 / total)
                })
            // No field is left pending and nothing remains to upload: the
            // display holds the definitive copy already.
            completionHandler(item, [], false, nil)
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
        let progress = Progress(totalUnitCount: 100)
        do {
            let modified = try access.modify(
                item.itemIdentifier,
                newName: changedFields.contains(.filename) ? item.filename : nil,
                newParent: changedFields.contains(.parentItemIdentifier)
                    ? item.parentItemIdentifier : nil,
                localContents: changedFields.contains(.contents) ? newContents : nil,
                progress: { sent, total in
                    guard total > 0 else { return }
                    progress.completedUnitCount = Int64(sent * 100 / total)
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
    private let isRoot: Bool

    init(entry: Entry) {
        self.entry = entry
        self.isRoot = false
        super.init()
    }

    init(root: Bool) {
        self.entry = nil
        self.isRoot = true
        super.init()
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        guard let entry else { return .rootContainer }
        return NSFileProviderItemIdentifier(String(entry.itemID))
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        guard let entry else { return .rootContainer }
        // The MTP root carries a sentinel identifier; the Finder expects its
        // own root container instead.
        return entry.parentID == 0xFFFF_FFFF || entry.parentID == 0
            ? .rootContainer
            : NSFileProviderItemIdentifier(String(entry.parentID))
    }

    var filename: String {
        guard let entry else { return "Brailliant" }
        // A name unusable as a path component is neutralized rather than
        // handed to the file system as is.
        return entry.hasSafeName ? entry.name : entry.displayName
    }

    var contentType: UTType {
        guard let entry else { return .folder }
        if entry.isDirectory { return .folder }
        let fileExtension = (entry.name as NSString).pathExtension
        return UTType(filenameExtension: fileExtension) ?? .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        // The root accepts new items but cannot itself be renamed, moved or
        // deleted — it is the storage, not a folder on it.
        guard let entry else {
            return [.allowsContentEnumerating, .allowsReading, .allowsAddingSubItems]
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
