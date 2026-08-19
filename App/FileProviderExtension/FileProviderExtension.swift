import FileProvider
import UniformTypeIdentifiers

/// Extension File Provider — étape de validation.
///
/// Elle sert pour l'instant une arborescence factice, sans toucher à la plage.
/// L'objectif est de confirmer que la plomberie système fonctionne — App Group,
/// entitlements, enregistrement du domaine, apparition dans le Finder — avant
/// d'y brancher BrailliantKit. Diagnostiquer un problème d'entitlements à
/// travers du code MTP serait inutilement pénible.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    private let domain: NSFileProviderDomain

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    func invalidate() {
        // Rien à libérer tant qu'aucune connexion MTP n'est ouverte.
    }

    // MARK: - Lecture

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if let item = FakeTree.item(for: identifier) {
            completionHandler(item, nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void)
    -> Progress {
        guard let item = FakeTree.item(for: itemIdentifier),
              let contents = FakeTree.contents(for: itemIdentifier) else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }

        // Le contenu doit être remis sous forme de fichier temporaire, que le
        // système recopie puis supprime.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try contents.write(to: url)
            completionHandler(url, item, nil)
        } catch {
            completionHandler(nil, nil, error)
        }
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        Enumerator(container: containerItemIdentifier)
    }

    // MARK: - Écriture (non prise en charge à ce stade)

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields,
                                                  Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated))
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
        completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated))
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(NSFileProviderError(.notAuthenticated))
        return Progress()
    }
}

// MARK: - Énumération

private final class Enumerator: NSObject, NSFileProviderEnumerator {

    private let container: NSFileProviderItemIdentifier

    init(container: NSFileProviderItemIdentifier) {
        self.container = container
        super.init()
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        observer.didEnumerate(FakeTree.children(of: container))
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from syncAnchor: NSFileProviderSyncAnchor) {
        // MTP n'émet aucune notification de changement : il n'y aura jamais de
        // modification poussée par l'appareil. Le rafraîchissement devra être
        // déclenché explicitement.
        observer.finishEnumeratingChanges(upTo: syncAnchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("0".utf8)))
    }
}

// MARK: - Arborescence factice

/// Contenu de démonstration, remplacé par BrailliantKit une fois la plomberie
/// validée. Reproduit la forme réelle d'une plage : des dossiers à la racine,
/// des fichiers dedans.
private enum FakeTree {

    struct Node {
        let identifier: String
        let parent: String
        let name: String
        let isFolder: Bool
        let text: String?
    }

    static let nodes: [Node] = [
        Node(identifier: "documents", parent: NSFileProviderItemIdentifier.rootContainer.rawValue,
             name: "documents", isFolder: true, text: nil),
        Node(identifier: "notes", parent: NSFileProviderItemIdentifier.rootContainer.rawValue,
             name: "notes", isFolder: true, text: nil),
        Node(identifier: "essai", parent: "documents",
             name: "essai-éàç.txt", isFolder: false,
             text: "Si vous lisez ceci depuis le Finder, la plomberie fonctionne.\n"),
    ]

    static func item(for identifier: NSFileProviderItemIdentifier) -> NSFileProviderItem? {
        if identifier == .rootContainer { return Item(root: true) }
        guard let node = nodes.first(where: { $0.identifier == identifier.rawValue }) else {
            return nil
        }
        return Item(node: node)
    }

    static func children(of container: NSFileProviderItemIdentifier) -> [NSFileProviderItem] {
        let key = container == .rootContainer
            ? NSFileProviderItemIdentifier.rootContainer.rawValue
            : container.rawValue
        return nodes.filter { $0.parent == key }.map { Item(node: $0) }
    }

    static func contents(for identifier: NSFileProviderItemIdentifier) -> Data? {
        nodes.first { $0.identifier == identifier.rawValue }?.text.map { Data($0.utf8) }
    }
}

private final class Item: NSObject, NSFileProviderItem {

    private let node: FakeTree.Node?
    private let isRoot: Bool

    init(node: FakeTree.Node) {
        self.node = node
        self.isRoot = false
        super.init()
    }

    init(root: Bool) {
        self.node = nil
        self.isRoot = true
        super.init()
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        isRoot ? .rootContainer : NSFileProviderItemIdentifier(node!.identifier)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        isRoot ? .rootContainer : NSFileProviderItemIdentifier(node!.parent)
    }

    var filename: String { isRoot ? "Brailliant" : node!.name }

    var contentType: UTType {
        (isRoot || node!.isFolder) ? .folder : .plainText
    }

    var capabilities: NSFileProviderItemCapabilities {
        // Lecture seule à ce stade : l'écriture viendra avec BrailliantKit.
        (isRoot || node!.isFolder) ? [.allowsContentEnumerating, .allowsReading]
                                   : [.allowsReading]
    }

    var documentSize: NSNumber? {
        guard let text = node?.text else { return nil }
        return NSNumber(value: text.utf8.count)
    }

    var itemVersion: NSFileProviderItemVersion {
        // Versions constantes : le contenu factice ne change jamais.
        NSFileProviderItemVersion(contentVersion: Data("1".utf8),
                                  metadataVersion: Data("1".utf8))
    }
}
