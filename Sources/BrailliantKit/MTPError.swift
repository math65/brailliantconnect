import Foundation

/// Erreur remontée par la couche MTP, avec un message en français
/// directement présentable à l'utilisateur.
public enum MTPError: Error, CustomStringConvertible {
    case libraryMissing(triedPaths: [String])
    case localeUnavailable
    case noDeviceFound
    case connectionFailed
    case deviceIndexOutOfRange(requested: Int, found: Int)
    case noStorage
    case notFound(path: String)
    case notADirectory(path: String)
    case alreadyExists(path: String)
    case directoryNotEmpty(path: String, count: Int)
    case localFileMissing(path: String)
    case transferFailed(path: String, code: Int32)
    case createFolderFailed(name: String)
    case deleteFailed(path: String, code: Int32)
    case invalidRemotePath(String)
    case cannotRemoveRoot
    case noHumanwareDevice(otherMTPDevices: [(vendor: UInt16, product: UInt16)])
    case storageNotFound(selector: String, available: [String])
    case ambiguousStorage(selector: String, matches: [String])
    case unsafeRemoteName(String)
    case pathEscapesDestination(attempted: String, root: String)
    case notEnoughSpace(needed: UInt64, available: UInt64)
    case renameFailed(from: String, to: String, code: Int32)
    case interruptedAfterDelete(temporary: String, target: String)

    public var description: String {
        switch self {
        case .libraryMissing(let tried):
            return """
            libmtp est introuvable.

            Une copie devrait être fournie dans le dossier Vendor/ à côté du \
            programme. Si elle manque, régénérez-la avec ./tools/build-vendor.sh

            Chemins essayés :
              \(tried.joined(separator: "\n  "))
            """
        case .localeUnavailable:
            return """
            Impossible d'activer une locale UTF-8 ; les noms de fichiers \
            accentués seraient corrompus.
            """
        case .noDeviceFound:
            return """
            Aucune plage braille détectée.
            Vérifiez que : le câble USB est branché, la plage est allumée, et \
            qu'elle est en mode « transfert de fichiers » (MTP) et non en mode \
            terminal braille.
            """
        case .connectionFailed:
            return """
            La plage a été détectée mais la connexion MTP a échoué.
            Causes fréquentes : la plage est en mode terminal braille au lieu \
            du mode transfert de fichiers, ou une autre application occupe \
            déjà le périphérique.
            """
        case .deviceIndexOutOfRange(let requested, let found):
            return "Appareil n°\(requested) demandé, mais \(found) détecté(s)."
        case .noStorage:
            return "Aucun stockage disponible sur la plage."
        case .notFound(let path):
            return "Introuvable sur la plage : \(path)"
        case .notADirectory(let path):
            return "« \(path) » est un fichier, pas un dossier."
        case .alreadyExists(let path):
            return "« \(path) » existe déjà sur la plage."
        case .directoryNotEmpty(let path, let count):
            return """
            Le dossier « \(path) » n'est pas vide (\(count) élément(s)). \
            Utilisez l'option -r pour le supprimer avec son contenu.
            """
        case .localFileMissing(let path):
            return "Fichier local introuvable : \(path)"
        case .transferFailed(let path, let code):
            return "Échec du transfert de « \(path) » (code \(code))."
        case .createFolderFailed(let name):
            return "Échec de la création du dossier « \(name) »."
        case .deleteFailed(let path, let code):
            return "Échec de la suppression de « \(path) » (code \(code))."
        case .invalidRemotePath(let path):
            return "Chemin distant invalide : « \(path) »"
        case .cannotRemoveRoot:
            return "La racine de la plage ne peut pas être supprimée."
        case .noHumanwareDevice(let others):
            if others.isEmpty {
                return """
                Aucune plage braille HumanWare détectée.
                Vérifiez que : le câble USB est branché, la plage est allumée, et \
                qu'elle est en mode « transfert de fichiers » (MTP) et non en mode \
                terminal braille.
                """
            }
            let liste = others
                .map { String(format: "fabricant 0x%04x, produit 0x%04x", $0.vendor, $0.product) }
                .joined(separator: "\n  ")
            return """
            Aucune plage braille HumanWare détectée, mais \(others.count) autre(s) \
            appareil(s) MTP sont branchés :
              \(liste)

            Il s'agit sans doute d'un téléphone ou d'un baladeur. Pour éviter \
            d'agir sur le mauvais appareil, ils sont ignorés par défaut.
            Si l'un d'eux est bien votre plage, relancez avec --any-device.
            """
        case .storageNotFound(let selector, let available):
            return """
            Aucun stockage ne correspond à « \(selector) ».

            Stockages disponibles :
              \(available.joined(separator: "\n  "))
            """
        case .ambiguousStorage(let selector, let matches):
            return """
            « \(selector) » correspond à plusieurs stockages :
              \(matches.joined(separator: "\n  "))

            Précisez le numéro plutôt que le nom.
            """
        case .unsafeRemoteName(let name):
            return """
            La plage a renvoyé un nom de fichier inutilisable : « \
            \(name.sanitizedForDisplay) ».

            Un tel nom permettrait d'écrire hors du dossier de destination ; \
            l'opération a été interrompue par précaution.
            """
        case .pathEscapesDestination(let attempted, let root):
            return """
            Écriture refusée : la destination calculée sort du dossier demandé.
              demandé : \(root)
              calculé : \(attempted)
            """
        case .notEnoughSpace(let needed, let available):
            return """
            Espace insuffisant sur la plage : \(humanSize(needed)) nécessaires, \
            \(humanSize(available)) disponibles.
            """
        case .renameFailed(let from, let to, let code):
            return "Échec du renommage de « \(from) » en « \(to) » (code \(code))."
        case .interruptedAfterDelete(let temporary, let target):
            return """
            Le transfert a réussi mais le fichier n'a pas pu être renommé.

            Vos données sont intactes : elles se trouvent sur la plage sous le \
            nom « \(temporary) ». Renommez-le en « \(target) », ou relancez \
            l'envoi.
            """
        }
    }
}
