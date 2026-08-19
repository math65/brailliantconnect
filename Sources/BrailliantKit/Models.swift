import Foundation

/// Un fichier ou un dossier présent sur la plage.
public struct Entry: Sendable, Equatable {
    public let itemID: UInt32
    public let parentID: UInt32
    public let storageID: UInt32
    public let name: String
    public let size: UInt64
    public let modified: Date?
    public let isDirectory: Bool
    public let path: String

    public var humanSize: String { formatTaille(size) }

    /// Nom débarrassé des caractères de contrôle, sûr à afficher.
    public var displayName: String { name.sanitizedForDisplay }

    /// Chemin complet, sûr à afficher.
    public var displayPath: String { path.sanitizedForDisplay }

    /// Vrai si le nom peut servir de composant de chemin sur le Mac.
    ///
    /// Faux pour un nom contenant « / » ou valant « .. » : de tels noms sont
    /// permis par MTP mais permettraient d'écrire hors du dossier cible.
    public var hasSafeName: Bool { RemotePath.isSafeComponent(name) }
}

/// Un volume de stockage : mémoire interne, carte SD ou clé USB.
public struct Storage: Sendable, Equatable {
    public let id: UInt32
    public let description: String
    public let capacity: UInt64
    public let free: UInt64

    public var used: UInt64 { capacity > free ? capacity - free : 0 }

    public var usedPercent: Int {
        guard capacity > 0 else { return 0 }
        return Int((Double(used) / Double(capacity) * 100).rounded())
    }
}

/// Résolution d'un stockage à partir de ce que l'utilisateur a tapé.
///
/// Isolé de la connexion MTP pour être vérifiable sans matériel branché.
public enum StorageSelection {

    /// Retrouve un stockage par son rang affiché (« 2 ») ou par un fragment de
    /// son nom (« usb », « interne »), sans tenir compte de la casse ni des
    /// accents — un nom de stockage est dicté au clavier, pas copié-collé.
    public static func resolve(selector: String, among storages: [Storage]) throws -> Storage {
        let trimmed = selector.trimmingCharacters(in: .whitespaces)
        let inventory = storages.enumerated().map { describe(index: $0, storage: $1) }

        guard !trimmed.isEmpty, !storages.isEmpty else {
            throw MTPError.storageNotFound(selector: selector, available: inventory)
        }

        if let rank = Int(trimmed) {
            guard rank >= 1, rank <= storages.count else {
                throw MTPError.storageNotFound(selector: trimmed, available: inventory)
            }
            return storages[rank - 1]
        }

        let needle = fold(trimmed)
        let matches = storages.enumerated().filter { fold($1.description).contains(needle) }
        switch matches.count {
        case 0:
            throw MTPError.storageNotFound(selector: trimmed, available: inventory)
        case 1:
            return matches[0].element
        default:
            throw MTPError.ambiguousStorage(
                selector: trimmed,
                matches: matches.map { describe(index: $0, storage: $1) })
        }
    }

    static func describe(index: Int, storage: Storage) -> String {
        "\(index + 1) — « \(storage.description) » (\(humanSize(storage.free)) libres)"
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}

/// Taille lisible, en convention française (virgule décimale, unités « o »).
public func humanSize(_ bytes: UInt64) -> String { formatTaille(bytes) }

/// Implémentation, nommée distinctement pour rester appelable depuis un type
/// qui expose lui-même une propriété « humanSize ».
func formatTaille(_ bytes: UInt64) -> String {
    if bytes < 1000 { return "\(bytes) o" }
    var value = Double(bytes)
    for unit in ["ko", "Mo", "Go", "To"] {
        value /= 1000
        if value < 1000 {
            return String(format: "%.1f %@", value, unit).replacingOccurrences(of: ".", with: ",")
        }
    }
    return String(format: "%.1f To", value).replacingOccurrences(of: ".", with: ",")
}
