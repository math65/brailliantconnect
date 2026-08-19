import FileProvider
import UniformTypeIdentifiers

/// Extension File Provider adossée à la plage braille.
///
/// Elle traduit l'arborescence MTP en éléments que le Finder sait afficher.
/// La connexion est ouverte à la demande et conservée : MTP n'accepte qu'une
/// session à la fois, et rouvrir à chaque requête coûterait ~130 ms.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    private let domain: NSFileProviderDomain
    private let accès = AccèsPlage()

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    func invalidate() {
        accès.fermer()
    }

    // MARK: - Lecture

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        do {
            completionHandler(try accès.élément(pour: identifier), nil)
        } catch {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void)
    -> Progress {
        let progression = Progress(totalUnitCount: 100)
        do {
            let (url, élément) = try accès.contenu(de: itemIdentifier) { transféré, total in
                guard total > 0 else { return }
                progression.completedUnitCount = Int64(transféré * 100 / total)
            }
            completionHandler(url, élément, nil)
        } catch {
            completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
        }
        return progression
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        Enumerator(accès: accès, conteneur: containerItemIdentifier)
    }

    // MARK: - Écriture (pas encore prise en charge)

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields,
                                                  Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields,
                                                  Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(NSFileProviderError(.noSuchItem))
        return Progress()
    }
}

// MARK: - Énumération

private final class Enumerator: NSObject, NSFileProviderEnumerator {

    private let accès: AccèsPlage
    private let conteneur: NSFileProviderItemIdentifier

    init(accès: AccèsPlage, conteneur: NSFileProviderItemIdentifier) {
        self.accès = accès
        self.conteneur = conteneur
        super.init()
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        do {
            observer.didEnumerate(try accès.contenu(duDossier: conteneur))
            observer.finishEnumerating(upTo: nil)
        } catch {
            // Plage débranchée ou occupée par un autre programme : MTP
            // n'accepte qu'une session à la fois.
            observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from syncAnchor: NSFileProviderSyncAnchor) {
        // MTP n'émet aucune notification : rien ne sera jamais poussé par
        // l'appareil. Le rafraîchissement passe par une nouvelle énumération.
        observer.finishEnumeratingChanges(upTo: syncAnchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("1".utf8)))
    }
}

// MARK: - Éléments

/// Élément du Finder adossé à une entrée MTP.
final class ÉlémentPlage: NSObject, NSFileProviderItem {

    private let entrée: Entry?
    private let estRacine: Bool

    init(entrée: Entry) {
        self.entrée = entrée
        self.estRacine = false
        super.init()
    }

    init(racine: Bool) {
        self.entrée = nil
        self.estRacine = true
        super.init()
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        guard let entrée else { return .rootContainer }
        return NSFileProviderItemIdentifier(String(entrée.itemID))
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        guard let entrée else { return .rootContainer }
        // La racine MTP porte un identifiant sentinelle ; le Finder attend
        // son propre conteneur racine à la place.
        return entrée.parentID == 0xFFFF_FFFF || entrée.parentID == 0
            ? .rootContainer
            : NSFileProviderItemIdentifier(String(entrée.parentID))
    }

    var filename: String {
        guard let entrée else { return "Brailliant" }
        // Un nom inutilisable comme composant de chemin est neutralisé plutôt
        // que présenté tel quel au système de fichiers.
        return entrée.hasSafeName ? entrée.name : entrée.displayName
    }

    var contentType: UTType {
        guard let entrée else { return .folder }
        if entrée.isDirectory { return .folder }
        let extensionFichier = (entrée.name as NSString).pathExtension
        return UTType(filenameExtension: extensionFichier) ?? .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        // Lecture seule : l'écriture viendra dans un second temps.
        guard let entrée else { return [.allowsContentEnumerating, .allowsReading] }
        return entrée.isDirectory
            ? [.allowsContentEnumerating, .allowsReading]
            : [.allowsReading]
    }

    var documentSize: NSNumber? {
        guard let entrée, !entrée.isDirectory else { return nil }
        return NSNumber(value: entrée.size)
    }

    var contentModificationDate: Date? { entrée?.modified }

    var itemVersion: NSFileProviderItemVersion {
        // MTP ne fournit pas de jeton de version : la date de modification et
        // la taille servent d'empreinte.
        let empreinte = entrée.map { "\($0.modified?.timeIntervalSince1970 ?? 0)-\($0.size)" }
            ?? "racine"
        return NSFileProviderItemVersion(contentVersion: Data(empreinte.utf8),
                                         metadataVersion: Data(empreinte.utf8))
    }
}
