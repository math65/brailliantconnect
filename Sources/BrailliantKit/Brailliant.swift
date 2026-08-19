import CMTP
import Foundation

/// Progress of a transfer: (bytes transferred, total).
public typealias ProgressHandler = (UInt64, UInt64) -> Void

/// USB vendor ID of HumanWare.
public let humanwareVendorID: UInt16 = 0x1C71

/// Virtual parent designating the root of a storage.
private let filesAndFoldersRoot: UInt32 = 0xFFFF_FFFF

/// Box used to smuggle a Swift closure through the `void *` pointer of a C
/// callback, which cannot capture anything.
private final class ProgressBox {
    let handler: ProgressHandler
    init(_ handler: @escaping ProgressHandler) { self.handler = handler }
}

private let progressTrampoline: LIBMTP_progressfunc_t = { sent, total, data in
    guard let data else { return 0 }
    Unmanaged<ProgressBox>.fromOpaque(data).takeUnretainedValue().handler(sent, total)
    return 0  // a non-zero value would request cancellation of the transfer
}

/// MTP connection to a braille display.
///
/// No kernel extension is involved: MTP runs entirely over USB in user space,
/// through libmtp and libusb.
///
///     let display = try Brailliant()
///     defer { display.close() }
///     for entry in try display.listDirectory("/documents") {
///         print(entry.name)
///     }
public final class Brailliant {

    private var device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?
    private var cachedStorages: [Storage]?
    private var preferredStorageID: UInt32?

    public private(set) var model = ""
    public private(set) var serialNumber = ""
    public private(set) var friendlyName = ""
    public private(set) var vendorID: UInt16 = 0
    public private(set) var productID: UInt16 = 0

    /// Opens the first display detected.
    /// - Parameters:
    ///   - vendorID: restricts the search to one vendor (nil = all of them).
    ///   - index: which device to pick when several are plugged in.
    public init(vendorID filter: UInt16? = nil, index: Int = 0) throws {
        try Brailliant.forceUTF8Locale()
        LIBMTP_Init()

        var rawDevices: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        // USB enumeration can come back empty for a moment: right after the
        // display is plugged in, or while it is bringing its storage back up
        // after a USB stick has just been inserted into it. Without these few
        // attempts, the tool would wrongly announce that no display is
        // connected.
        for attempt in 0..<3 {
            _ = LIBMTP_Detect_Raw_Devices(&rawDevices, &count)
            if count > 0 { break }
            if rawDevices != nil { free(rawDevices); rawDevices = nil }
            if attempt < 2 { usleep(250_000) }
        }
        defer { free(rawDevices) }

        guard count > 0, let rawDevices else {
            throw MTPError.noHumanwareDevice(otherMTPDevices: [])
        }

        var candidates: [Int] = Array(0..<Int(count))
        if let filter {
            let rejected =
                candidates
                .filter { rawDevices[$0].device_entry.vendor_id != filter }
                .map {
                    (
                        vendor: rawDevices[$0].device_entry.vendor_id,
                        product: rawDevices[$0].device_entry.product_id
                    )
                }
            candidates = candidates.filter { rawDevices[$0].device_entry.vendor_id == filter }
            // An Android phone is an MTP device like any other: without this
            // filter, a destructive command would end up applying to it.
            if candidates.isEmpty {
                throw MTPError.noHumanwareDevice(otherMTPDevices: rejected)
            }
        }
        guard index < candidates.count else {
            throw MTPError.deviceIndexOutOfRange(requested: index, found: candidates.count)
        }

        let slot = candidates[index]
        vendorID = rawDevices[slot].device_entry.vendor_id
        productID = rawDevices[slot].device_entry.product_id

        guard let opened = LIBMTP_Open_Raw_Device_Uncached(rawDevices.advanced(by: slot)) else {
            throw MTPError.connectionFailed
        }
        device = opened

        model = Brailliant.takeCString(LIBMTP_Get_Modelname(opened))
        serialNumber = Brailliant.takeCString(LIBMTP_Get_Serialnumber(opened))
        friendlyName = Brailliant.takeCString(LIBMTP_Get_Friendlyname(opened))
    }

    deinit { close() }

    public func close() {
        if let device {
            LIBMTP_Release_Device(device)
            self.device = nil
        }
    }

    private func requireDevice() throws -> UnsafeMutablePointer<LIBMTP_mtpdevice_t> {
        guard let device else { throw MTPError.connectionFailed }
        return device
    }

    /// Actual path of the libmtp library loaded by the process.
    public var libraryPath: String {
        var info = Dl_info()
        let symbol = unsafeBitCast(
            LIBMTP_Init as @convention(c) () -> Void,
            to: UnsafeRawPointer.self)
        guard dladdr(symbol, &info) != 0, let name = info.dli_fname else {
            return "(inconnu)"
        }
        return String(cString: name)
    }

    // MARK: - Storages

    public func storages(refresh: Bool = false) throws -> [Storage] {
        if let cachedStorages, !refresh { return cachedStorages }
        let device = try requireDevice()
        _ = LIBMTP_Get_Storage(device, Int32(LIBMTP_STORAGE_SORTBY_NOTSORTED))

        var result: [Storage] = []
        var node = device.pointee.storage
        while let current = node {
            let description = current.pointee.StorageDescription.map { String(cString: $0) }
            result.append(
                Storage(
                    id: current.pointee.id,
                    description: description?.isEmpty == false
                        ? description! : "stockage \(current.pointee.id)",
                    capacity: current.pointee.MaxCapacity,
                    free: current.pointee.FreeSpaceInBytes
                ))
            node = current.pointee.next
        }
        cachedStorages = result
        return result
    }

    /// Storage that operations act upon.
    ///
    /// Absent an explicit selection, the first storage the display declares —
    /// internal memory on the models that have been tested.
    public func defaultStorage() throws -> Storage {
        let available = try storages()
        guard !available.isEmpty else { throw MTPError.noStorage }
        if let preferred = preferredStorageID,
            let match = available.first(where: { $0.id == preferred })
        {
            return match
        }
        return available[0]
    }

    /// Chooses the target storage from a number ("2") or from a fragment of its
    /// name ("usb", "interne", "sd").
    ///
    /// A display often exposes several storages — internal memory, SD card, USB
    /// stick — only one of which would be reachable without this choice.
    public func selectStorage(matching selector: String) throws {
        guard !selector.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // Storages are read again: a USB stick may have been plugged into the
        // display since the connection was opened.
        let chosen = try StorageSelection.resolve(
            selector: selector,
            among: try storages(refresh: true))
        preferredStorageID = chosen.id
    }

    // MARK: - Navigation

    /// Lists the contents of a remote folder.
    public func listDirectory(_ path: String = "/") throws -> [Entry] {
        let (storageID, parentID, base) = try resolveDirectory(path)
        return try children(storageID: storageID, parentID: parentID, base: base)
    }

    /// Walks the remote tree recursively, folders included.
    public func walk(_ path: String = "/") throws -> [Entry] {
        var result: [Entry] = []
        for entry in try listDirectory(path) {
            result.append(entry)
            if entry.isDirectory {
                result.append(contentsOf: try walk(entry.path))
            }
        }
        return result
    }

    private func children(storageID: UInt32, parentID: UInt32, base: String) throws -> [Entry] {
        let device = try requireDevice()
        var entries: [Entry] = []

        var node = LIBMTP_Get_Files_And_Folders(device, storageID, parentID)
        // The list is a linked list and LIBMTP_destroy_file_t frees only a
        // single link: the next node must be saved before the current one is
        // freed, otherwise memory leaks or a freed region gets accessed.
        while let current = node {
            let next = current.pointee.next
            let name = current.pointee.filename.map { String(cString: $0) } ?? ""
            let isDirectory = current.pointee.filetype == LIBMTP_FILETYPE_FOLDER
            let stamp = current.pointee.modificationdate
            entries.append(
                Entry(
                    itemID: current.pointee.item_id,
                    parentID: current.pointee.parent_id,
                    storageID: current.pointee.storage_id,
                    name: name,
                    size: current.pointee.filesize,
                    modified: stamp > 0 ? Date(timeIntervalSince1970: TimeInterval(stamp)) : nil,
                    isDirectory: isDirectory,
                    path: RemotePath.join(base, name)
                ))
            LIBMTP_destroy_file_t(current)
            node = next
        }

        return entries.sorted {
            $0.isDirectory != $1.isDirectory
                ? $0.isDirectory
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Finds the entry matching a remote path, or nil.
    public func resolve(_ path: String) throws -> Entry? {
        let normalized = RemotePath.normalize(path)
        guard normalized != "/" else { return nil }

        var storageID = try defaultStorage().id
        var parentID = filesAndFoldersRoot
        var base = "/"
        var found: Entry?

        for part in RemotePath.components(normalized) {
            guard
                let match = try children(storageID: storageID, parentID: parentID, base: base)
                    .first(where: { $0.name == part })
            else { return nil }
            found = match
            parentID = match.itemID
            storageID = match.storageID
            base = match.path
        }
        return found
    }

    public func exists(_ path: String) throws -> Bool {
        try resolve(path) != nil
    }

    private func resolveDirectory(_ path: String) throws -> (UInt32, UInt32, String) {
        let normalized = RemotePath.normalize(path)
        if normalized == "/" {
            return (try defaultStorage().id, filesAndFoldersRoot, "/")
        }
        guard let entry = try resolve(normalized) else {
            throw MTPError.notFound(path: normalized)
        }
        guard entry.isDirectory else { throw MTPError.notADirectory(path: normalized) }
        return (entry.storageID, entry.itemID, normalized)
    }

    // MARK: - Operations

    /// Creates a remote folder, creating any missing parents along the way.
    @discardableResult
    public func createDirectory(_ path: String) throws -> Entry {
        let normalized = RemotePath.normalize(path)
        guard normalized != "/" else { throw MTPError.invalidRemotePath(path) }

        if let existing = try resolve(normalized) {
            guard existing.isDirectory else { throw MTPError.alreadyExists(path: normalized) }
            return existing
        }

        let device = try requireDevice()
        var storageID = try defaultStorage().id
        var parentID = filesAndFoldersRoot
        var base = "/"

        for part in RemotePath.components(normalized) {
            if let existing = try children(storageID: storageID, parentID: parentID, base: base)
                .first(where: { $0.name == part && $0.isDirectory })
            {
                parentID = existing.itemID
                storageID = existing.storageID
                base = existing.path
                continue
            }
            let newID = part.withCString { name in
                LIBMTP_Create_Folder(
                    device, UnsafeMutablePointer(mutating: name),
                    parentID, storageID)
            }
            guard newID != 0 else {
                dumpErrorStack()
                throw MTPError.createFolderFailed(name: part)
            }
            parentID = newID
            base = RemotePath.join(base, part)
        }

        guard let result = try resolve(normalized) else {
            throw MTPError.notFound(path: normalized)
        }
        return result
    }

    /// Copies a file from the display to the Mac. Returns the local path written.
    @discardableResult
    public func download(
        _ remote: String, to local: String,
        progress: ProgressHandler? = nil
    ) throws -> String {
        guard let entry = try resolve(remote) else { throw MTPError.notFound(path: remote) }
        guard !entry.isDirectory else { throw MTPError.notADirectory(path: remote) }

        var target = (local as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            // The name comes from the display: it cannot be concatenated as is,
            // or it could end up writing outside the requested folder.
            target = try LocalPath.confine(root: target, relative: entry.name)
        }
        let parent = (target as NSString).deletingLastPathComponent
        if !parent.isEmpty && !FileManager.default.fileExists(atPath: parent) {
            // An error here must propagate: swallowing it would make the
            // transfer fail later on with a message unrelated to the cause.
            try FileManager.default.createDirectory(
                atPath: parent,
                withIntermediateDirectories: true)
        }

        let device = try requireDevice()
        let status = withProgress(progress) { callback, context in
            target.withCString { path in
                LIBMTP_Get_File_To_File(device, entry.itemID, path, callback, context)
            }
        }
        guard status == 0 else {
            dumpErrorStack()
            throw MTPError.transferFailed(path: remote, code: status)
        }
        return target
    }

    /// Copies a file from the Mac to the display. `remote` is the full path of
    /// the remote file; missing folders are created.
    @discardableResult
    public func upload(
        _ local: String, to remote: String,
        progress: ProgressHandler? = nil,
        overwrite: Bool = true
    ) throws -> Entry {
        let source = (local as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            throw MTPError.localFileMissing(path: source)
        }

        let normalized = RemotePath.normalize(remote)
        let (parentPath, name) = RemotePath.split(normalized)
        guard !name.isEmpty else { throw MTPError.invalidRemotePath(remote) }

        var storageID: UInt32
        var parentID: UInt32
        if parentPath == "/" {
            storageID = try defaultStorage().id
            parentID = filesAndFoldersRoot
        } else {
            let parent = try createDirectory(parentPath)
            storageID = parent.storageID
            parentID = parent.itemID
        }

        let existing = try resolve(normalized)
        if existing != nil && !overwrite {
            throw MTPError.alreadyExists(path: normalized)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: source)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0

        // Checking free space before writing avoids failing in the middle of a
        // transfer, and above all after the previous version has been deleted.
        if let storage = try storages(refresh: true).first(where: { $0.id == storageID }) {
            let recovered = existing?.size ?? 0
            if size > storage.free + recovered {
                throw MTPError.notEnoughSpace(
                    needed: size,
                    available: storage.free + recovered)
            }
        }

        // MTP cannot replace a file in place. Writing straight to the final
        // name would mean deleting the old one BEFORE the transfer: the
        // slightest interruption (cable unplugged, display switched off) would
        // then destroy the data without putting anything in its place. So the
        // file is sent under a temporary name, and the old one is only removed
        // once the new one has been written in full.
        let needsSwap = existing != nil
        let temporaryName = needsSwap ? Brailliant.temporaryName(for: name) : name
        let temporaryPath = RemotePath.join(parentPath, temporaryName)

        try sendFile(
            source: source, name: temporaryName, size: size,
            parentID: parentID, storageID: storageID,
            reportedPath: normalized, progress: progress)

        if needsSwap {
            guard let uploaded = try resolve(temporaryPath) else {
                throw MTPError.notFound(path: temporaryPath)
            }
            // The transfer is finished: removing the old file is now risk-free.
            try remove(normalized)
            let status = temporaryName.isEmpty ? -1 : rename(uploaded.itemID, to: name)
            guard status == 0 else {
                dumpErrorStack()
                // The data is on the display, merely misnamed: say so precisely
                // rather than letting the user believe it has been lost.
                throw MTPError.interruptedAfterDelete(
                    temporary: temporaryName,
                    target: name)
            }
        }

        guard let result = try resolve(normalized) else {
            throw MTPError.notFound(path: normalized)
        }
        return result
    }

    /// Sends a local file under a given name, with no overwrite handling.
    private func sendFile(
        source: String, name: String, size: UInt64,
        parentID: UInt32, storageID: UInt32,
        reportedPath: String,
        progress: ProgressHandler?
    ) throws {
        let device = try requireDevice()
        guard let metadata = LIBMTP_new_file_t() else {
            throw MTPError.transferFailed(path: reportedPath, code: -1)
        }
        defer {
            // filename points at a string owned by Swift: setting it back to
            // nil keeps libmtp from trying to free memory that does not belong
            // to it.
            metadata.pointee.filename = nil
            LIBMTP_destroy_file_t(metadata)
        }

        let status: Int32 = name.withCString { cName in
            metadata.pointee.filename = UnsafeMutablePointer(mutating: cName)
            metadata.pointee.filesize = size
            metadata.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN
            metadata.pointee.parent_id = parentID
            metadata.pointee.storage_id = storageID
            return withProgress(progress) { callback, context in
                source.withCString { path in
                    LIBMTP_Send_File_From_File(device, path, metadata, callback, context)
                }
            }
        }

        guard status == 0 else {
            dumpErrorStack()
            throw MTPError.transferFailed(path: reportedPath, code: status)
        }
    }

    /// Renames a remote object. Returns libmtp's return code.
    private func rename(_ itemID: UInt32, to newName: String) -> Int32 {
        guard let device else { return -1 }
        return newName.withCString { cName in
            LIBMTP_Set_Object_Filename(device, itemID, UnsafeMutablePointer(mutating: cName))
        }
    }

    /// Improbable temporary name, prefixed with a dot so that it stays discreet
    /// on the display should something interrupt the operation.
    private static func temporaryName(for name: String) -> String {
        let token = UUID().uuidString.prefix(8)
        let candidate = ".brailliant-\(token)-\(name)"
        // Some MTP devices cap name length: truncate while preserving the
        // token, which is what guarantees uniqueness.
        return candidate.count <= 200 ? candidate : ".brailliant-\(token)"
    }

    /// Deletes a remote file or folder.
    /// Renames an item, keeping it in place.
    ///
    /// - Returns: the entry as it stands after the rename.
    @discardableResult
    public func rename(_ path: String, to newName: String) throws -> Entry {
        guard RemotePath.isSafeComponent(newName) else {
            throw MTPError.unsafeRemoteName(newName)
        }
        guard let entry = try resolve(path) else { throw MTPError.notFound(path: path) }

        let parent = RemotePath.split(entry.path).parent
        let destination = RemotePath.join(parent, newName)
        if destination != entry.path, try resolve(destination) != nil {
            throw MTPError.alreadyExists(path: destination)
        }

        let status = rename(entry.itemID, to: newName)
        guard status == 0 else {
            dumpErrorStack()
            throw MTPError.renameFailed(from: entry.name, to: newName, code: status)
        }
        guard let renamed = try resolve(destination) else {
            throw MTPError.notFound(path: destination)
        }
        return renamed
    }

    /// Moves an item into another folder, keeping its name.
    ///
    /// MTP moves an object by reparenting it, so nothing is transferred: the
    /// operation is immediate whatever the file's size.
    @discardableResult
    public func move(_ path: String, toFolder folderPath: String) throws -> Entry {
        guard let entry = try resolve(path) else { throw MTPError.notFound(path: path) }

        let destinationFolder = RemotePath.normalize(folderPath)
        let (parentID, storageID): (UInt32, UInt32)
        if destinationFolder == "/" {
            (parentID, storageID) = (filesAndFoldersRoot, try defaultStorage().id)
        } else {
            let folder = try createDirectory(destinationFolder)
            (parentID, storageID) = (folder.itemID, folder.storageID)
        }

        let destination = RemotePath.join(destinationFolder, entry.name)
        if destination != entry.path, try resolve(destination) != nil {
            throw MTPError.alreadyExists(path: destination)
        }

        // Reparenting is the cheap way — nothing is transferred whatever the
        // file's size — but the Brailliant answers "Operation Not Supported",
        // as many MTP devices do. Its failure is not fatal: we fall back to
        // copying through the Mac.
        let status = LIBMTP_Move_Object(try requireDevice(), entry.itemID, storageID, parentID)
        if status == 0, let moved = try resolve(destination) {
            return moved
        }
        clearErrorStack()
        return try relocateByCopying(entry, to: destination)
    }

    /// Moves an item by copying it to its destination and deleting the original.
    ///
    /// Used when the device refuses to reparent objects. A file makes a round
    /// trip through the Mac, so the cost is that of two transfers — unavoidable
    /// here, and the reason a move is not instantaneous on this hardware.
    ///
    /// The original is deleted only once the copy is in place: an interruption
    /// leaves a duplicate, never a loss.
    private func relocateByCopying(_ entry: Entry, to destination: String) throws -> Entry {
        if entry.isDirectory {
            let folder = try createDirectory(destination)
            for child in try children(
                storageID: entry.storageID, parentID: entry.itemID, base: entry.path)
            {
                _ = try relocateByCopying(child, to: RemotePath.join(destination, child.name))
            }
            try remove(entry.path, recursive: true)
            guard let moved = try resolve(folder.path) else {
                throw MTPError.notFound(path: destination)
            }
            return moved
        }

        let scratch =
            NSTemporaryDirectory()
            + "brailliant-move-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        _ = try download(entry.path, to: scratch)
        let copied = try upload(scratch, to: destination)
        try remove(entry.path)
        return copied
    }

    /// Discards a failed operation's errors so they do not surface later.
    private func clearErrorStack() {
        guard let device else { return }
        LIBMTP_Clear_Errorstack(device)
    }

    public func remove(_ path: String, recursive: Bool = false) throws {
        guard let entry = try resolve(path) else { throw MTPError.notFound(path: path) }
        if entry.isDirectory {
            let contents = try children(
                storageID: entry.storageID,
                parentID: entry.itemID, base: entry.path)
            if !contents.isEmpty && !recursive {
                throw MTPError.directoryNotEmpty(path: entry.path, count: contents.count)
            }
            for child in contents { try remove(child.path, recursive: true) }
        }
        let status = LIBMTP_Delete_Object(try requireDevice(), entry.itemID)
        guard status == 0 else {
            dumpErrorStack()
            throw MTPError.deleteFailed(path: path, code: status)
        }
    }

    // MARK: - Internal helpers

    private func withProgress<T>(
        _ progress: ProgressHandler?,
        _ body: (LIBMTP_progressfunc_t?, UnsafeRawPointer?) -> T
    ) -> T {
        guard let progress else { return body(nil, nil) }
        let box = ProgressBox(progress)
        return withExtendedLifetime(box) {
            body(progressTrampoline, UnsafeRawPointer(Unmanaged.passUnretained(box).toOpaque()))
        }
    }

    private func dumpErrorStack() {
        guard let device else { return }
        LIBMTP_Dump_Errorstack(device)
        LIBMTP_Clear_Errorstack(device)
    }

    /// Takes over a C string allocated by libmtp and frees the memory.
    private static func takeCString(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// Forces a UTF-8 locale in the process.
    ///
    /// libmtp converts file names with iconv, relying on `nl_langinfo(CODESET)`.
    /// Without a UTF-8 locale every accented character is lost — a deal-breaker
    /// for French file names. A binary launched outside a login shell does not
    /// necessarily inherit `$LANG`.
    private static func forceUTF8Locale() throws {
        for candidate in ["fr_FR.UTF-8", "en_US.UTF-8", "C.UTF-8", ""] {
            guard setlocale(LC_ALL, candidate) != nil else { continue }
            let codeset = String(cString: nl_langinfo(CODESET))
                .uppercased().replacingOccurrences(of: "-", with: "")
            if codeset == "UTF8" {
                if !candidate.isEmpty {
                    // Read the user's language before overwriting LC_ALL below,
                    // otherwise the locale forced here for libmtp's benefit
                    // would be mistaken for a deliberate choice.
                    _ = L.isFrench
                    setenv("LANG", candidate, 0)
                    setenv("LC_ALL", candidate, 1)
                }
                return
            }
        }
        throw MTPError.localeUnavailable
    }
}
