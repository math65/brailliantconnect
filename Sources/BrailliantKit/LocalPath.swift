import Foundation

/// Construction sûre des chemins locaux à partir de données venant de la plage.
///
/// Les noms de fichiers renvoyés par un périphérique MTP sont des chaînes
/// arbitraires : le protocole n'interdit ni « .. », ni le séparateur « / ».
/// Concaténés naïvement à un dossier de destination, ils permettraient d'écrire
/// hors de ce dossier — jusqu'à déposer un fichier dans ~/Library/LaunchAgents.
///
/// Deux barrières indépendantes sont posées :
/// 1. le rejet des noms non conformes dès leur lecture (`RemotePath.isSafeComponent`) ;
/// 2. la vérification que la cible finale reste sous la racine autorisée
///    (`confine`), qui rattrape tout cas non anticipé par la première.
public enum LocalPath {

    /// Normalise un chemin sans toucher au disque (résout « .. », « . », « ~ »).
    public static func standardize(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    /// Vrai si `target` désigne `root` ou un élément situé dessous.
    public static func isConfined(_ target: String, under root: String) -> Bool {
        let normalizedRoot = standardize(root)
        let normalizedTarget = standardize(target)
        if normalizedTarget == normalizedRoot { return true }
        let prefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        return normalizedTarget.hasPrefix(prefix)
    }

    /// Compose `root` + `relative` en garantissant que le résultat reste sous `root`.
    ///
    /// - Parameter relative: chemin relatif dont chaque segment provient de la
    ///   plage et doit donc être considéré comme non fiable.
    public static func confine(root: String, relative: String) throws -> String {
        let segments = relative
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)

        for segment in segments where !RemotePath.isSafeComponent(segment) {
            throw MTPError.unsafeRemoteName(segment)
        }

        var target = standardize(root)
        for segment in segments {
            target = (target as NSString).appendingPathComponent(segment)
        }

        // Défense en profondeur : même si un segment douteux avait franchi le
        // contrôle précédent, la cible ne peut pas sortir du dossier demandé.
        guard isConfined(target, under: root) else {
            throw MTPError.pathEscapesDestination(attempted: target, root: standardize(root))
        }
        return target
    }
}

extension String {

    /// Version affichable d'un texte venant de la plage.
    ///
    /// Les noms de fichiers peuvent contenir des caractères de contrôle ou des
    /// séquences d'échappement ANSI. Affichés bruts dans un terminal, ils
    /// permettraient d'effacer l'écran ou de masquer des lignes déjà écrites —
    /// donc de dissimuler ce qu'une commande vient réellement de faire. Ils
    /// perturbent aussi la restitution par un lecteur d'écran.
    public var sanitizedForDisplay: String {
        var result = ""
        result.reserveCapacity(count)
        for scalar in unicodeScalars {
            switch scalar.value {
            case 0x00...0x08, 0x0A...0x1F, 0x7F,  // contrôles C0 et DEL
                 0x80...0x9F:                     // contrôles C1
                result.append("\u{FFFD}")         // caractère de remplacement
            case 0x09:
                result.append(" ")                // tabulation neutralisée
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
