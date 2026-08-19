import Foundation

/// User-facing strings, in English and French.
///
/// `NSLocalizedString` is not usable here: it resolves strings against a bundle,
/// and neither a SwiftPM executable nor a File Provider extension offers the
/// bundle layout it expects. A plain table keeps the same text available to the
/// CLI, the agent and the extension alike, with no packaging step.
///
/// English is the base language; French is provided because the tool exists for
/// a French-speaking author and audience, and an error message nobody
/// understands is an error message twice over.
public enum L {

    /// True when the user's preferred language is French.
    ///
    /// Read once: the language cannot change during a process's lifetime, and
    /// the extension queries it on every enumeration.
    public static let isFrench: Bool = {
        let preferred =
            Locale.preferredLanguages.first
            ?? Locale.current.identifier
        return preferred.lowercased().hasPrefix("fr")
    }()

    /// Returns the localized string for `english`, falling back to English when
    /// no translation exists.
    public static func t(_ english: String) -> String {
        guard isFrench, let french = table[english] else { return english }
        return french
    }

    /// Formats a localized string with positional arguments.
    ///
    /// Placeholders use `%@`, so a translation may reorder them where the
    /// grammar requires it.
    public static func t(_ english: String, _ arguments: CVarArg...) -> String {
        String(format: t(english), arguments: arguments)
    }

    /// English → French. Keys are the exact English strings used in the code,
    /// which keeps the source readable without a layer of opaque identifiers.
    static let table: [String: String] = [

        // MARK: Device detection

        "No HumanWare braille display detected.":
            "Aucune plage braille HumanWare détectée.",
        "Check that the USB cable is connected, the display is switched on, and it is in file transfer mode (MTP) rather than braille terminal mode.":
            "Vérifiez que le câble USB est branché, que la plage est allumée, et qu'elle est en mode « transfert de fichiers » (MTP) et non en mode terminal braille.",
        "The display was detected but the MTP connection failed.":
            "La plage a été détectée mais la connexion MTP a échoué.",
        "Common causes: the display is in braille terminal mode instead of file transfer mode, or another application is already using it.":
            "Causes fréquentes : la plage est en mode terminal braille au lieu du mode transfert de fichiers, ou une autre application occupe déjà le périphérique.",
        "It is probably a phone or a music player. To avoid acting on the wrong device, such devices are ignored by default.":
            "Il s'agit sans doute d'un téléphone ou d'un baladeur. Pour éviter d'agir sur le mauvais appareil, ils sont ignorés par défaut.",
        "If one of them really is your display, run again with --any-device.":
            "Si l'un d'eux est bien votre plage, relancez avec --any-device.",

        // MARK: Files and transfers

        "Not found on the display: %@": "Introuvable sur la plage : %@",
        "\"%@\" is a file, not a folder.": "« %@ » est un fichier, pas un dossier.",
        "\"%@\" already exists on the display.": "« %@ » existe déjà sur la plage.",
        "Local file not found: %@": "Fichier local introuvable : %@",
        "Transfer of \"%@\" failed (code %@).": "Échec du transfert de « %@ » (code %@).",
        "Deletion of \"%@\" failed (code %@).": "Échec de la suppression de « %@ » (code %@).",
        "No storage available on the display.": "Aucun stockage disponible sur la plage.",
        "Not enough space on the display: %@ needed, %@ available.":
            "Espace insuffisant sur la plage : %@ nécessaires, %@ disponibles.",

        // MARK: Safety

        "The display returned an unusable file name: \"%@\".":
            "La plage a renvoyé un nom de fichier inutilisable : « %@ ».",
        "Such a name would allow writing outside the destination folder; the operation was stopped as a precaution.":
            "Un tel nom permettrait d'écrire hors du dossier de destination ; l'opération a été interrompue par précaution.",
        "Write refused: the computed destination falls outside the requested folder.":
            "Écriture refusée : la destination calculée sort du dossier demandé.",
        "The transfer succeeded but the file could not be renamed.":
            "Le transfert a réussi mais le fichier n'a pas pu être renommé.",
        "Your data is intact: it is on the display under the name \"%@\". Rename it to \"%@\", or send it again.":
            "Vos données sont intactes : elles se trouvent sur la plage sous le nom « %@ ». Renommez-le en « %@ », ou relancez l'envoi.",

        // MARK: Finder integration

        "Watching enabled.": "Surveillance activée.",
        "The display appears in \"~/Brailliant\" as soon as it is connected, and disappears when it is unplugged.":
            "La plage apparaît dans « ~/Brailliant » dès qu'elle est branchée, et disparaît quand elle est retirée.",
        "The agent will restart on its own at every login.":
            "L'agent redémarrera tout seul à chaque ouverture de session.",
        "Watching disabled. The agent will no longer restart.":
            "Surveillance désactivée. L'agent ne redémarrera plus.",
        "Location published. Reachable in \"~/Brailliant\".":
            "Emplacement publié. Accessible dans « ~/Brailliant ».",
        "Location removed from the Finder.": "Emplacement retiré du Finder.",
        "published": "publié",
        "not published": "non publié",
        "display connected": "plage branchée",
        "no display connected": "aucune plage branchée",
        "BrailliantConnect.app cannot be found; it is the app that carries the Finder extension.":
            "BrailliantConnect.app est introuvable ; c'est elle qui porte l'extension Finder.",

        // MARK: Listings

        "(empty folder: %@)": "(dossier vide : %@)",
        "Sent: %@ (%@)": "Envoyé : %@ (%@)",
        "Received: %@ (%@)": "Reçu : %@ (%@)",
        "Deleted: %@": "Supprimé : %@",
        "Folder ready: %@": "Dossier prêt : %@",
        "[unusable name — cannot be copied]": "[nom inutilisable — non copiable]",
        "No macOS clutter files found.": "Aucun fichier parasite macOS trouvé.",
        "Everything works. No macFUSE and no kernel extension is involved.":
            "Tout fonctionne. Aucun macFUSE ni extension noyau n'est utilisé.",
    ]
}
