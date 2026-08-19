import Foundation

/// Manipulation des chemins distants (toujours en style Unix, séparateur « / »).
///
/// Les chemins de la plage sont indépendants de ceux du Mac : ils sont
/// normalisés séparément pour éviter toute confusion entre les deux espaces
/// de noms.
public enum RemotePath {

    /// Normalise un chemin : supprime les segments vides, « . » et résout « .. ».
    public static func normalize(_ path: String) -> String {
        var stack: [String] = []
        for part in path.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            switch part {
            case "", ".":
                continue
            case "..":
                if !stack.isEmpty { stack.removeLast() }
            default:
                stack.append(String(part))
            }
        }
        return stack.isEmpty ? "/" : "/" + stack.joined(separator: "/")
    }

    /// Concatène un dossier et un nom d'élément.
    public static func join(_ base: String, _ name: String) -> String {
        (base == "/" || base.isEmpty) ? "/" + name : base + "/" + name
    }

    /// Sépare un chemin en (dossier parent, nom).
    public static func split(_ path: String) -> (parent: String, name: String) {
        let norm = normalize(path)
        guard norm != "/" else { return ("/", "") }
        guard let index = norm.lastIndex(of: "/") else { return ("/", norm) }
        let parent = norm[norm.startIndex..<index]
        let name = String(norm[norm.index(after: index)...])
        return (parent.isEmpty ? "/" : String(parent), name)
    }

    /// Découpe un chemin en ses segments.
    public static func components(_ path: String) -> [String] {
        normalize(path).split(separator: "/").map(String.init)
    }

    /// Vrai si `name` est utilisable comme nom d'un élément unique.
    ///
    /// Les noms viennent du périphérique et ne sont donc pas fiables : MTP
    /// n'interdit ni « .. », ni « / », ni les caractères de contrôle. Un tel
    /// nom, concaténé à un dossier de destination, permettrait d'écrire hors
    /// de ce dossier.
    public static func isSafeComponent(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        guard !name.contains("/"), !name.contains("\\") else { return false }
        // Un octet nul tronquerait le nom au passage vers les API C.
        guard !name.unicodeScalars.contains(where: { $0.value == 0 }) else { return false }
        return true
    }
}

/// Fichiers parasites créés par macOS sur les volumes externes.
public enum MacJunk {
    static let names: Set<String> = [
        ".DS_Store", "._.DS_Store", ".Spotlight-V100", ".Trashes",
        ".fseventsd", ".TemporaryItems", ".apDisk",
    ]

    public static func matches(_ name: String) -> Bool {
        names.contains(name) || name.hasPrefix("._")
    }
}
