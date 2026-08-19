import CMTP
import Foundation

/// Progression d'un transfert : (octets transférés, total).
public typealias ProgressHandler = (UInt64, UInt64) -> Void

/// Identifiant USB du fabricant HumanWare.
public let humanwareVendorID: UInt16 = 0x1C71

/// Parent virtuel désignant la racine d'un stockage.
private let filesAndFoldersRoot: UInt32 = 0xFFFF_FFFF

/// Boîte permettant de faire passer une closure Swift à travers le pointeur
/// `void *` d'un callback C, qui ne peut rien capturer.
private final class ProgressBox {
    let handler: ProgressHandler
    init(_ handler: @escaping ProgressHandler) { self.handler = handler }
}

private let progressTrampoline: LIBMTP_progressfunc_t = { sent, total, data in
    guard let data else { return 0 }
    Unmanaged<ProgressBox>.fromOpaque(data).takeUnretainedValue().handler(sent, total)
    return 0  // non nul demanderait l'annulation du transfert
}

/// Connexion MTP à une plage braille.
///
/// Aucune extension noyau n'est utilisée : MTP passe entièrement par USB en
/// espace utilisateur, via libmtp et libusb.
///
///     let plage = try Brailliant()
///     defer { plage.close() }
///     for entree in try plage.listDirectory("/documents") {
///         print(entree.name)
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

    /// Ouvre la première plage détectée.
    /// - Parameters:
    ///   - vendorID: restreint la recherche à un fabricant (nil = tous).
    ///   - index: numéro de l'appareil si plusieurs sont branchés.
    public init(vendorID filter: UInt16? = nil, index: Int = 0) throws {
        try Brailliant.forceUTF8Locale()
        LIBMTP_Init()

        var rawDevices: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        // L'énumération USB peut être momentanément vide : juste après le
        // branchement, ou pendant que la plage remonte son stockage quand on
        // vient d'y insérer une clé. Sans ces quelques tentatives, l'outil
        // annoncerait à tort qu'aucune plage n'est connectée.
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
            let rejected = candidates
                .filter { rawDevices[$0].device_entry.vendor_id != filter }
                .map { (vendor: rawDevices[$0].device_entry.vendor_id,
                        product: rawDevices[$0].device_entry.product_id) }
            candidates = candidates.filter { rawDevices[$0].device_entry.vendor_id == filter }
            // Un téléphone Android est un appareil MTP comme un autre : sans
            // ce filtre, une commande destructive s'appliquerait à lui.
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

    /// Chemin réel de la bibliothèque libmtp chargée par le processus.
    public var libraryPath: String {
        var info = Dl_info()
        let symbol = unsafeBitCast(LIBMTP_Init as @convention(c) () -> Void,
                                   to: UnsafeRawPointer.self)
        guard dladdr(symbol, &info) != 0, let name = info.dli_fname else {
            return "(inconnu)"
        }
        return String(cString: name)
    }

    // MARK: - Stockages

    public func storages(refresh: Bool = false) throws -> [Storage] {
        if let cachedStorages, !refresh { return cachedStorages }
        let device = try requireDevice()
        _ = LIBMTP_Get_Storage(device, Int32(LIBMTP_STORAGE_SORTBY_NOTSORTED))

        var result: [Storage] = []
        var node = device.pointee.storage
        while let current = node {
            let description = current.pointee.StorageDescription.map { String(cString: $0) }
            result.append(Storage(
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

    /// Stockage sur lequel portent les opérations.
    ///
    /// À défaut de sélection explicite, le premier stockage déclaré par la
    /// plage — la mémoire interne sur les modèles testés.
    public func defaultStorage() throws -> Storage {
        let available = try storages()
        guard !available.isEmpty else { throw MTPError.noStorage }
        if let preferred = preferredStorageID,
           let match = available.first(where: { $0.id == preferred }) {
            return match
        }
        return available[0]
    }

    /// Choisit le stockage cible à partir d'un numéro (« 2 ») ou d'un fragment
    /// de son nom (« usb », « interne », « sd »).
    ///
    /// Une plage expose souvent plusieurs stockages — mémoire interne, carte SD,
    /// clé USB — dont un seul serait accessible sans ce choix.
    public func selectStorage(matching selector: String) throws {
        guard !selector.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // Les stockages sont relus : une clé peut avoir été branchée sur la
        // plage depuis la connexion.
        let chosen = try StorageSelection.resolve(selector: selector,
                                                  among: try storages(refresh: true))
        preferredStorageID = chosen.id
    }

    // MARK: - Navigation

    /// Liste le contenu d'un dossier distant.
    public func listDirectory(_ path: String = "/") throws -> [Entry] {
        let (storageID, parentID, base) = try resolveDirectory(path)
        return try children(storageID: storageID, parentID: parentID, base: base)
    }

    /// Parcourt récursivement l'arborescence distante, dossiers inclus.
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
        // La liste est chaînée et LIBMTP_destroy_file_t ne libère qu'un seul
        // maillon : il faut mémoriser le suivant avant de libérer l'actuel,
        // sous peine de fuite mémoire ou d'accès à une zone libérée.
        while let current = node {
            let next = current.pointee.next
            let name = current.pointee.filename.map { String(cString: $0) } ?? ""
            let isDirectory = current.pointee.filetype == LIBMTP_FILETYPE_FOLDER
            let stamp = current.pointee.modificationdate
            entries.append(Entry(
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

    /// Retrouve l'entrée correspondant à un chemin distant, ou nil.
    public func resolve(_ path: String) throws -> Entry? {
        let normalized = RemotePath.normalize(path)
        guard normalized != "/" else { return nil }

        var storageID = try defaultStorage().id
        var parentID = filesAndFoldersRoot
        var base = "/"
        var found: Entry?

        for part in RemotePath.components(normalized) {
            guard let match = try children(storageID: storageID, parentID: parentID, base: base)
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

    // MARK: - Opérations

    /// Crée un dossier distant, en créant les parents manquants.
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
                .first(where: { $0.name == part && $0.isDirectory }) {
                parentID = existing.itemID
                storageID = existing.storageID
                base = existing.path
                continue
            }
            let newID = part.withCString { name in
                LIBMTP_Create_Folder(device, UnsafeMutablePointer(mutating: name),
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

    /// Copie un fichier de la plage vers le Mac. Renvoie le chemin local écrit.
    @discardableResult
    public func download(_ remote: String, to local: String,
                         progress: ProgressHandler? = nil) throws -> String {
        guard let entry = try resolve(remote) else { throw MTPError.notFound(path: remote) }
        guard !entry.isDirectory else { throw MTPError.notADirectory(path: remote) }

        var target = (local as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory),
           isDirectory.boolValue {
            // Le nom vient de la plage : il ne peut pas être concaténé tel quel,
            // sous peine d'écrire hors du dossier demandé.
            target = try LocalPath.confine(root: target, relative: entry.name)
        }
        let parent = (target as NSString).deletingLastPathComponent
        if !parent.isEmpty && !FileManager.default.fileExists(atPath: parent) {
            // Une erreur ici doit remonter : la masquer ferait échouer le
            // transfert plus loin avec un message sans rapport avec la cause.
            try FileManager.default.createDirectory(atPath: parent,
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

    /// Copie un fichier du Mac vers la plage. `remote` est le chemin complet
    /// du fichier distant ; les dossiers manquants sont créés.
    @discardableResult
    public func upload(_ local: String, to remote: String,
                       progress: ProgressHandler? = nil,
                       overwrite: Bool = true) throws -> Entry {
        let source = (local as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
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

        // Vérifier l'espace avant d'écrire évite d'échouer au milieu d'un
        // transfert, et surtout après avoir supprimé la version précédente.
        if let storage = try storages(refresh: true).first(where: { $0.id == storageID }) {
            let recovered = existing?.size ?? 0
            if size > storage.free + recovered {
                throw MTPError.notEnoughSpace(needed: size,
                                              available: storage.free + recovered)
            }
        }

        // MTP ne remplace pas un fichier en place. Écrire directement sous le
        // nom final imposerait de supprimer l'ancien AVANT le transfert : la
        // moindre coupure (câble débranché, plage éteinte) détruirait alors les
        // données sans les remplacer. On envoie donc sous un nom temporaire,
        // et l'ancien n'est retiré qu'une fois le nouveau intégralement écrit.
        let needsSwap = existing != nil
        let temporaryName = needsSwap ? Brailliant.temporaryName(for: name) : name
        let temporaryPath = RemotePath.join(parentPath, temporaryName)

        try sendFile(source: source, name: temporaryName, size: size,
                     parentID: parentID, storageID: storageID,
                     reportedPath: normalized, progress: progress)

        if needsSwap {
            guard let uploaded = try resolve(temporaryPath) else {
                throw MTPError.notFound(path: temporaryPath)
            }
            // Le transfert est terminé : retirer l'ancien ne risque plus rien.
            try remove(normalized)
            let status = temporaryName.isEmpty ? -1 : rename(uploaded.itemID, to: name)
            guard status == 0 else {
                dumpErrorStack()
                // Les données sont sur la plage, seulement mal nommées : on
                // l'indique précisément plutôt que de laisser croire à une perte.
                throw MTPError.interruptedAfterDelete(temporary: temporaryName,
                                                      target: name)
            }
        }

        guard let result = try resolve(normalized) else {
            throw MTPError.notFound(path: normalized)
        }
        return result
    }

    /// Envoie un fichier local sous un nom donné, sans gestion d'écrasement.
    private func sendFile(source: String, name: String, size: UInt64,
                          parentID: UInt32, storageID: UInt32,
                          reportedPath: String,
                          progress: ProgressHandler?) throws {
        let device = try requireDevice()
        guard let metadata = LIBMTP_new_file_t() else {
            throw MTPError.transferFailed(path: reportedPath, code: -1)
        }
        defer {
            // filename pointe sur une chaîne détenue par Swift : la remettre à
            // nil évite que libmtp tente de libérer une mémoire qui ne lui
            // appartient pas.
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

    /// Renomme un objet distant. Renvoie le code de retour de libmtp.
    private func rename(_ itemID: UInt32, to newName: String) -> Int32 {
        guard let device else { return -1 }
        return newName.withCString { cName in
            LIBMTP_Set_Object_Filename(device, itemID, UnsafeMutablePointer(mutating: cName))
        }
    }

    /// Nom temporaire improbable, préfixé d'un point pour rester discret sur
    /// la plage si un incident interrompait l'opération.
    private static func temporaryName(for name: String) -> String {
        let token = UUID().uuidString.prefix(8)
        let candidate = ".bc-\(token)-\(name)"
        // Certains appareils MTP limitent la longueur des noms : on tronque en
        // préservant le jeton, qui garantit l'unicité.
        return candidate.count <= 200 ? candidate : ".bc-\(token)"
    }

    /// Supprime un fichier ou un dossier distant.
    public func remove(_ path: String, recursive: Bool = false) throws {
        guard let entry = try resolve(path) else { throw MTPError.notFound(path: path) }
        if entry.isDirectory {
            let contents = try children(storageID: entry.storageID,
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

    // MARK: - Utilitaires internes

    private func withProgress<T>(_ progress: ProgressHandler?,
                                 _ body: (LIBMTP_progressfunc_t?, UnsafeRawPointer?) -> T) -> T {
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

    /// Récupère une chaîne C allouée par libmtp et libère la mémoire.
    private static func takeCString(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// Force une locale UTF-8 dans le processus.
    ///
    /// libmtp convertit les noms de fichiers avec iconv en s'appuyant sur
    /// `nl_langinfo(CODESET)`. Sans locale UTF-8, tous les accents sont perdus —
    /// rédhibitoire pour des noms de fichiers français. Un binaire lancé hors
    /// d'un shell de connexion n'hérite pas forcément de `$LANG`.
    private static func forceUTF8Locale() throws {
        for candidate in ["fr_FR.UTF-8", "en_US.UTF-8", "C.UTF-8", ""] {
            guard setlocale(LC_ALL, candidate) != nil else { continue }
            let codeset = String(cString: nl_langinfo(CODESET))
                .uppercased().replacingOccurrences(of: "-", with: "")
            if codeset == "UTF8" {
                if !candidate.isEmpty {
                    setenv("LANG", candidate, 0)
                    setenv("LC_ALL", candidate, 1)
                }
                return
            }
        }
        throw MTPError.localeUnavailable
    }
}
