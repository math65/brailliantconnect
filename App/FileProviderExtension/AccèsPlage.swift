import FileProvider
import Foundation
import os.log

/// Accès sérialisé à la plage braille pour le compte de l'extension.
///
/// Deux contraintes dictent cette classe :
///
/// - MTP n'accepte **qu'une session à la fois**. La connexion est donc ouverte
///   une fois et conservée, et toutes les requêtes du Finder sont sérialisées
///   sur une file dédiée. Sans cela, deux énumérations simultanées se
///   disputeraient le périphérique et échoueraient toutes les deux.
/// - Le protocole n'émet **aucune notification de changement**. Le cache est
///   donc daté : au-delà d'un court délai, l'arborescence est relue.
final class AccèsPlage {

    /// Journal consultable avec :
    ///   log show --predicate 'subsystem == "com.mathieumartin.BrailliantConnect"'
    private static let journal = Logger(subsystem: "com.mathieumartin.BrailliantConnect",
                                        category: "acces")

    /// Durée de validité du cache d'énumération.
    ///
    /// Une énumération coûte environ 0,2 ms par élément : la relire souvent est
    /// sans conséquence. Ce délai évite surtout de solliciter le périphérique
    /// plusieurs fois par seconde quand le Finder rafraîchit sa fenêtre.
    private static let fraîcheur: TimeInterval = 5

    private let file = DispatchQueue(label: "brailliant.acces", qos: .userInitiated)
    private var plage: Brailliant?

    /// Entrées connues, indexées par identifiant MTP.
    private var index: [UInt32: Entry] = [:]
    /// Contenu des dossiers déjà énumérés, avec leur date de lecture.
    private var contenus: [UInt32: (entrées: [Entry], lu: Date)] = [:]

    /// Identifiant MTP conventionnel de la racine.
    private static let racine: UInt32 = 0xFFFF_FFFF

    // MARK: - Connexion

    private func connexion() throws -> Brailliant {
        if let plage { return plage }
        // Filtrer sur HumanWare : un téléphone Android branché est un appareil
        // MTP comme un autre.
        Self.journal.info("ouverture d'une session MTP")
        let nouvelle = try Brailliant(vendorID: humanwareVendorID)
        Self.journal.info("session ouverte : \(nouvelle.model, privacy: .public)")
        plage = nouvelle
        return nouvelle
    }

    func fermer() {
        file.sync {
            plage?.close()
            plage = nil
            index.removeAll()
            contenus.removeAll()
        }
    }

    /// Referme la connexion et vide les caches après une erreur.
    ///
    /// La plage a pu être débranchée : la prochaine requête rouvrira, ou
    /// échouera proprement.
    private func réinitialiser() {
        plage?.close()
        plage = nil
        index.removeAll()
        contenus.removeAll()
    }

    // MARK: - Lecture

    private func identifiantMTP(_ identifier: NSFileProviderItemIdentifier) -> UInt32 {
        identifier == .rootContainer ? Self.racine : UInt32(identifier.rawValue) ?? Self.racine
    }

    /// Chemin distant d'un dossier, reconstruit depuis l'index.
    private func chemin(de identifiant: UInt32) -> String {
        identifiant == Self.racine ? "/" : (index[identifiant]?.path ?? "/")
    }

    func contenu(duDossier identifier: NSFileProviderItemIdentifier) throws -> [NSFileProviderItem] {
        try file.sync {
            let identifiant = identifiantMTP(identifier)
            if let cache = contenus[identifiant],
               Date().timeIntervalSince(cache.lu) < Self.fraîcheur {
                return cache.entrées.map { ÉlémentPlage(entrée: $0) }
            }
            do {
                let plage = try connexion()
                let entrées = try plage.listDirectory(chemin(de: identifiant))
                    .filter { !MacJunk.matches($0.name) }
                for entrée in entrées { index[entrée.itemID] = entrée }
                contenus[identifiant] = (entrées, Date())
                return entrées.map { ÉlémentPlage(entrée: $0) }
            } catch {
                Self.journal.error("énumération impossible : \(String(describing: error))")
                réinitialiser()
                throw error
            }
        }
    }

    func élément(pour identifier: NSFileProviderItemIdentifier) throws -> NSFileProviderItem {
        if identifier == .rootContainer { return ÉlémentPlage(racine: true) }
        return try file.sync {
            let identifiant = identifiantMTP(identifier)
            if let entrée = index[identifiant] { return ÉlémentPlage(entrée: entrée) }
            // Élément inconnu : le Finder a pu le demander après un
            // redémarrage. On relit la racine pour réamorcer l'index.
            let plage = try connexion()
            for entrée in try plage.walk("/") { index[entrée.itemID] = entrée }
            guard let entrée = index[identifiant] else {
                throw MTPError.notFound(path: identifier.rawValue)
            }
            return ÉlémentPlage(entrée: entrée)
        }
    }

    func contenu(de identifier: NSFileProviderItemIdentifier,
                 progression: @escaping (UInt64, UInt64) -> Void)
    throws -> (URL, NSFileProviderItem) {
        try file.sync {
            let identifiant = identifiantMTP(identifier)
            guard let entrée = index[identifiant] else {
                throw MTPError.notFound(path: identifier.rawValue)
            }
            // Le système attend un fichier temporaire qu'il recopiera lui-même.
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            do {
                let plage = try connexion()
                _ = try plage.download(entrée.path, to: destination.path, progress: progression)
                return (destination, ÉlémentPlage(entrée: entrée))
            } catch {
                réinitialiser()
                throw error
            }
        }
    }
}
