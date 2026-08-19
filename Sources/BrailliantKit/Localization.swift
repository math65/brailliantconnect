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
    /// The environment wins over the system settings: overriding `LANG` or
    /// `LC_ALL` for a single command is the Unix convention, and someone
    /// scripting this tool expects it to be honoured. `Locale.preferredLanguages`
    /// alone would ignore both, since it only reflects System Settings.
    ///
    /// Read once: the language cannot change during a process's lifetime, and
    /// the extension queries it on every enumeration.
    public static let isFrench: Bool = {
        let environment = ProcessInfo.processInfo.environment
        for key in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            guard let value = environment[key], !value.isEmpty else { continue }
            // "C" and "POSIX" ask for untranslated output.
            if value == "C" || value == "POSIX" { return false }
            return value.lowercased().hasPrefix("fr")
        }
        let preferred = Locale.preferredLanguages.first ?? Locale.current.identifier
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
    ///
    /// A few strings are deliberately absent: those that read the same in both
    /// languages ("VERDICT", "OK"), where falling back to English is already the
    /// right answer.
    static let table: [String: String] = [

        // MARK: Device detection

        "No HumanWare braille display detected.":
            "Aucune plage braille HumanWare détectée.",
        "No braille display detected.": "Aucune plage braille détectée.",
        "Check that the USB cable is connected, the display is switched on, and it is in file transfer mode (MTP) rather than braille terminal mode.":
            "Vérifiez que le câble USB est branché, que la plage est allumée, et qu'elle est en mode « transfert de fichiers » (MTP) et non en mode terminal braille.",
        "The display was detected but the MTP connection failed.":
            "La plage a été détectée mais la connexion MTP a échoué.",
        "Common causes: the display is in braille terminal mode instead of file transfer mode, or another application is already using it.":
            "Causes fréquentes : la plage est en mode terminal braille au lieu du mode transfert de fichiers, ou une autre application occupe déjà le périphérique.",
        "No HumanWare braille display detected, but %@ other MTP device(s) are plugged in:":
            "Aucune plage braille HumanWare détectée, mais %@ autre(s) appareil(s) MTP sont branchés :",
        "It is probably a phone or a music player. To avoid acting on the wrong device, such devices are ignored by default.":
            "Il s'agit sans doute d'un téléphone ou d'un baladeur. Pour éviter d'agir sur le mauvais appareil, ils sont ignorés par défaut.",
        "If one of them really is your display, run again with --any-device.":
            "Si l'un d'eux est bien votre plage, relancez avec --any-device.",
        "vendor 0x%04x, product 0x%04x": "fabricant 0x%04x, produit 0x%04x",
        "Device no. %@ requested, but %@ detected.":
            "Appareil n°%@ demandé, mais %@ détecté(s).",

        // MARK: Environment

        "libmtp could not be found.": "libmtp est introuvable.",
        "A copy should ship in the Vendor/ folder next to the program. If it is missing, rebuild it with ./tools/build-vendor.sh":
            "Une copie devrait être fournie dans le dossier Vendor/ à côté du programme. Si elle manque, régénérez-la avec ./tools/build-vendor.sh",
        "Paths tried:": "Chemins essayés :",
        "No UTF-8 locale could be enabled; accented file names would be corrupted.":
            "Impossible d'activer une locale UTF-8 ; les noms de fichiers accentués seraient corrompus.",

        // MARK: Files and transfers

        "Not found on the display: %@": "Introuvable sur la plage : %@",
        "\"%@\" is a file, not a folder.": "« %@ » est un fichier, pas un dossier.",
        "\"%@\" already exists on the display.": "« %@ » existe déjà sur la plage.",
        "The folder \"%@\" is not empty (%@ item(s)). Use the -r option to delete it along with its contents.":
            "Le dossier « %@ » n'est pas vide (%@ élément(s)). Utilisez l'option -r pour le supprimer avec son contenu.",
        "Local file not found: %@": "Fichier local introuvable : %@",
        "Transfer of \"%@\" failed (code %@).": "Échec du transfert de « %@ » (code %@).",
        "Could not create the folder \"%@\".": "Échec de la création du dossier « %@ ».",
        "Deletion of \"%@\" failed (code %@).": "Échec de la suppression de « %@ » (code %@).",
        "Renaming \"%@\" to \"%@\" failed (code %@).":
            "Échec du renommage de « %@ » en « %@ » (code %@).",
        "Invalid remote path: \"%@\"": "Chemin distant invalide : « %@ »",
        "The root of the display cannot be deleted.":
            "La racine de la plage ne peut pas être supprimée.",
        "No storage available on the display.": "Aucun stockage disponible sur la plage.",
        "Not enough space on the display: %@ needed, %@ available.":
            "Espace insuffisant sur la plage : %@ nécessaires, %@ disponibles.",

        // MARK: Storage selection

        "No storage matches \"%@\".": "Aucun stockage ne correspond à « %@ ».",
        "Available storages:": "Stockages disponibles :",
        "%@ — \"%@\" (%@ free)": "%@ — « %@ » (%@ libres)",
        "\"%@\" matches several storages:": "« %@ » correspond à plusieurs stockages :",
        "Give the number rather than the name.": "Précisez le numéro plutôt que le nom.",

        // MARK: Safety

        "The display returned an unusable file name: \"%@\".":
            "La plage a renvoyé un nom de fichier inutilisable : « %@ ».",
        "Such a name would allow writing outside the destination folder; the operation was stopped as a precaution.":
            "Un tel nom permettrait d'écrire hors du dossier de destination ; l'opération a été interrompue par précaution.",
        "Write refused: the computed destination falls outside the requested folder.":
            "Écriture refusée : la destination calculée sort du dossier demandé.",
        "requested: %@": "demandé : %@",
        "computed:  %@": "calculé : %@",
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
        "Locations searched:": "Emplacements examinés :",
        "Watching could not be started: %@": "La surveillance n'a pas pu démarrer : %@",
        "The location can still be published by hand with \"brailliant finder on\" once the problem is fixed.":
            "L'emplacement peut tout de même être publié à la main avec « brailliant finder on » après avoir corrigé le problème.",
        "Location: %@": "Emplacement : %@",
        "state unknown": "état inconnu",
        "Watching: %@": "Surveillance : %@",
        "active, restarted at every login": "active, relancée à chaque session",
        "installed but stopped": "installée mais arrêtée",
        "not installed": "non installée",
        "To enable it: brailliant finder on": "Pour l'activer : brailliant finder on",

        // MARK: The agent's own messages

        "agent started": "agent démarré",
        "display connected — location published, in the Finder sidebar":
            "plage branchée — emplacement publié, dans la barre latérale du Finder",
        "~/%@ is a link to something else — shortcut not created":
            "~/%@ est un lien vers autre chose — raccourci non créé",
        "~/%@ already exists — shortcut not created":
            "~/%@ existe déjà — raccourci non créé",
        "display connected — location published in ~/%@":
            "plage branchée — emplacement publié dans ~/%@",
        "display connected but publishing failed: %@":
            "plage branchée mais publication impossible : %@",
        "display disconnected — location removed": "plage débranchée — emplacement retiré",
        "display in braille terminal mode — location removed until it "
            + "is switched to file transfer":
            "plage en mode terminal braille — emplacement retiré jusqu'au passage "
            + "en mode transfert de fichiers",
        "display disconnected but removal failed: %@":
            "plage débranchée mais retrait impossible : %@",
        "Publishing failed: %@": "Échec de la publication : %@",
        "Removal failed: %@": "Échec du retrait : %@",
        "The system did not answer within the allotted time.":
            "Le système n'a pas répondu dans le délai imparti.",
        "The system did not answer.": "Le système n'a pas répondu.",
        """
        BrailliantConnect — Finder location agent.

          (no argument)     register the agent to start at login, then exit
          --watch           watch the display, publish or remove the location,
                            and hold the menu bar item
          --publish         publish the location
          --unpublish       remove it
          --status          report the current state
          --uninstall       remove every trace of the app

        This agent is normally driven by the "brailliant" command.
        """:
            """
        BrailliantConnect — agent de l'emplacement Finder.

          (sans argument)   installe l'agent au démarrage de la session, puis quitte
          --watch           surveille la plage, publie ou retire l'emplacement,
                            et tient l'élément de la barre des menus
          --publish         publie l'emplacement
          --unpublish       le retire
          --status          indique l'état
          --uninstall       supprime toute trace de l'application

        Cet agent est normalement piloté par la commande « brailliant ».
        """,

        "Installation failed": "Échec de l'installation",
        "BrailliantConnect could not register itself to start automatically. "
            + "Make sure the app is in the Applications folder, then open it again.":
            "BrailliantConnect n'a pas pu s'installer pour démarrer automatiquement. "
            + "Vérifiez que l'application se trouve dans le dossier Applications, "
            + "puis ouvrez-la de nouveau.",

        "BrailliantConnect has been removed. The app is in the Trash.":
            "BrailliantConnect a été supprimé. L'application est dans la corbeille.",
        "BrailliantConnect has been removed, but the app itself could not "
            + "be moved to the Trash. Drag it there by hand:":
            "BrailliantConnect a été supprimé, mais l'application elle-même n'a pas "
            + "pu être placée dans la corbeille. Faites-la glisser à la main :",
        "The app could not be moved to the Trash":
            "L'application n'a pas pu être placée dans la corbeille",
        "Everything else has been removed. Drag the app to the Trash:":
            "Tout le reste a été supprimé. Faites glisser l'application vers la corbeille :",

        // MARK: Menu bar

        "Display connected": "Plage branchée",
        "Display asleep": "Plage en veille",
        "Display in braille terminal mode": "Plage en mode terminal braille",
        "Transferring — %@ of %@": "Transfert en cours — %@ sur %@",
        "Transferring — %@": "Transfert en cours — %@",
        "Do not unplug the display": "Ne débranchez pas la plage",
        "Put the file in a storage": "Rangez le fichier dans un stockage",
        "The top level of the display holds its storages and nothing else. "
            + "Open %@ and drop the file in there.":
            "Le premier niveau de la plage ne contient que ses stockages. "
            + "Ouvrez %@ et déposez le fichier dedans.",
        "a storage": "un stockage",
        " or ": " ou ",
        "Transfer complete": "Transfert terminé",
        "%@ sent. You can unplug the display.":
            "%@ envoyés. Vous pouvez débrancher la plage.",
        "transfer finished — %@": "transfert terminé — %@",
        "less than 1 MB": "moins de 1 Mo",
        "MB": "Mo",
        "GB": "Go",
        "A transfer is still running": "Un transfert est encore en cours",
        "%@ of %@ have been sent. Stopping now leaves the file incomplete "
            + "on the display.":
            "%@ sur %@ ont été envoyés. Arrêter maintenant laisse le fichier "
            + "incomplet sur la plage.",
        "%@ are still on their way. Stopping now leaves the file incomplete "
            + "on the display.":
            "%@ sont encore en cours d'envoi. Arrêter maintenant laisse le fichier "
            + "incomplet sur la plage.",
        "Wait": "Attendre",
        "Stop anyway": "Arrêter quand même",
        "Switch it to file transfer mode": "Passez-la en mode transfert de fichiers",
        "No display connected": "Aucune plage branchée",
        "Open in Finder": "Ouvrir dans le Finder",
        "Press a key on the display to wake it":
            "Appuyez sur une touche de la plage pour la réveiller",
        "Open at Login": "Ouvrir à l'ouverture de session",
        "Uninstall BrailliantConnect…": "Désinstaller BrailliantConnect…",
        "Quit": "Quitter",
        "Uninstall BrailliantConnect?": "Désinstaller BrailliantConnect ?",
        "The Finder location, the background agent, and every file this app "
            + "wrote will be removed, and the app itself moved to the Trash. "
            + "Nothing on the braille display is touched.":
            "L'emplacement Finder, l'agent d'arrière-plan et tous les fichiers "
            + "écrits par cette application seront supprimés, et l'application "
            + "elle-même placée dans la corbeille. "
            + "Rien n'est touché sur la plage braille.",
        "Uninstall": "Désinstaller",
        "Cancel": "Annuler",

        // MARK: Listings

        "(empty folder: %@)": "(dossier vide : %@)",
        "folder": "dossier",
        "%@ item(s), %@ file(s), %@": "%@ élément(s), %@ fichier(s), %@",
        "%@ \"%@\"": "%@ « %@ »",
        "Contents of \"%@\". Other storage(s): %@ — use -s to reach them.":
            "Contenu de « %@ ». Autre(s) stockage(s) : %@ — utilisez -s pour y accéder.",
        "[unusable name — cannot be copied]": "[nom inutilisable — non copiable]",

        // MARK: Transfers in progress

        "%@: %@%%": "%@ : %@ %%",
        "Downloading %@": "Téléchargement de %@",
        "Sending %@": "Envoi de %@",
        "Sent: %@ (%@)": "Envoyé : %@ (%@)",
        "Received: %@ (%@)": "Reçu : %@ (%@)",
        "Deleted: %@": "Supprimé : %@",
        "Folder ready: %@": "Dossier prêt : %@",
        "SKIPPED (unsafe name): %@": "IGNORÉ (nom dangereux) : %@",
        "%@ file(s) received into %@ (%@)": "%@ fichier(s) reçus dans %@ (%@)",
        "%@ item(s) skipped: name unusable on the disk.":
            "%@ élément(s) ignoré(s) : nom incompatible avec le disque.",
        "%@ file(s) sent to %@ (%@)": "%@ fichier(s) envoyés vers %@ (%@)",
        "Skipped (not found): %@": "Ignoré (introuvable) : %@",
        "Delete \"%@\" and its contents (%@ item(s), of which %@ file(s))? [y/N] ":
            "Supprimer « %@ » et son contenu (%@ élément(s), dont %@ fichier(s)) ? [o/N] ",
        // The answers accepted at that prompt, translated with it.
        "y": "o",
        "yes": "oui",
        "Cancelled: nothing was deleted.": "Abandon : rien n'a été supprimé.",

        // MARK: clean

        "No macOS clutter files found.": "Aucun fichier parasite macOS trouvé.",
        "%@ clutter file(s) found:": "%@ fichier(s) parasite(s) trouvé(s) :",
        "(dry run: nothing was deleted — run again without -n)":
            "(simulation : rien n'a été supprimé — relancez sans -n)",
        "%@ file(s) deleted.": "%@ fichier(s) supprimé(s).",

        // MARK: info
        //
        // The padding is part of the translation: the labels do not have the
        // same length in the two languages, and the columns must still line up.

        "Device: %@": "Appareil : %@",
        "Name:   %@": "Nom      : %@",
        "Serial: %@": "Série    : %@",
        "USB:    %@": "USB      : %@",
        "Storage %@ \"%@\"": "Stockage %@ « %@ »",
        "[active]": "[actif]",
        "  capacity: %@": "  capacité   : %@",
        "  used:     %@ (%@%%)": "  utilisé    : %@ (%@ %%)",
        "  free:     %@": "  disponible : %@",
        "To work on another storage: brailliant -s <number or name> …":
            "Pour travailler sur un autre stockage : brailliant -s <numéro ou nom> …",

        // MARK: doctor

        "Connection: OK": "Connexion  : OK",
        "Device:     %@ (serial %@)": "Appareil   : %@ (série %@)",
        "Storages:   %@ detected, active: \"%@\"":
            "Stockages  : %@ détecté(s), actif : « %@ »",
        "Root:       %@ readable item(s)": "Racine     : %@ élément(s) lisibles",
        "libmtp:     %@\n            %@": "libmtp     : %@\n             %@",
        "embedded copy": "copie embarquée",
        "system installation": "installation système",
        "Machine:    %@, macOS %@": "Machine    : %@, macOS %@",
        "Clutter:    %@ macOS file(s) at the root (run \"brailliant clean\" to remove them)":
            "Parasites  : %@ fichier(s) macOS à la racine (commande « brailliant clean » pour les retirer)",
        "Everything works. No macFUSE and no kernel extension is involved.":
            "Tout fonctionne. Aucun macFUSE ni extension noyau n'est utilisé.",

        // MARK: Command line

        "Error: %@": "Erreur : %@",
        "Error: -s expects a storage number or name.":
            "Erreur : -s attend un numéro ou un nom de stockage.",
        "Error: -d expects a number.": "Erreur : -d attend un nombre.",
        "Error: unknown option \"%@\".": "Erreur : option inconnue « %@ ».",
        "Error: unknown command \"%@\".": "Erreur : commande inconnue « %@ ».",
        "Use \"brailliant --help\".": "Utilisez « brailliant --help ».",
        "Error: the \"%@\" command expects at least one argument.":
            "Erreur : la commande « %@ » attend au moins un argument.",
        "Usage: brailliant finder on|off|status": "Usage : brailliant finder on|off|status",
        "This copy of \"brailliant\" is not inside the app; remove it by hand:":
            "Cette copie de « brailliant » n'est pas dans l'application ; "
            + "supprimez-la à la main :",

        // MARK: Help

        """
        brailliant — access Brailliant braille displays from macOS, without macFUSE.

        USAGE
          brailliant <command> [arguments] [options]

        COMMANDS
          info                     model, serial number, free space
          ls [path]                list a folder on the display
          tree [path]              show the folder tree
          get <remote> [local]     copy from the display to the Mac (file or folder)
          put <local> [remote]     copy from the Mac to the display (file or folder)
          rm <path>...             delete from the display
          mkdir <path>...          create a folder on the display
          mv <source> <dest>       rename or move an item on the display
          clean                    remove macOS clutter files from the display
          doctor                   check that everything works
          finder on|off|status     watch the display and show it in the Finder
          uninstall                remove BrailliantConnect entirely
          bench [path]             measure protocol latencies (diagnostic)
          bench --scale [n]        measure how it scales (creates then deletes
                                   test files on the display)

        OPTIONS
          -l, --long               show sizes (ls)
          -a, --all                also show macOS clutter files
          -r, --recursive          delete a folder along with its contents (rm)
          -s, --storage <n|name>   target storage: "2" or "usb" (default: the first)
          -d, --depth <n>          maximum depth (tree)
          -n, --dry-run            simulate without deleting anything (clean)
          -f, --force              delete without asking for confirmation (rm -r)
              --no-overwrite       refuse to overwrite an existing file (put)
              --progress           force the progress display on
              --no-progress        hide the progress display
              --any-device         accept an MTP device from another manufacturer
              --debug              show libmtp's internal messages
          -h, --help               show this help

        EXAMPLES
          brailliant put ~/Documents/novel.txt /documents
          brailliant get /notes ~/Desktop
          brailliant clean --dry-run
          brailliant -s usb ls /
          brailliant finder on

        The default remote folder for "put" is /documents. Missing folders are
        created automatically.
        """:
            """
        brailliant — accès aux plages braille Brailliant depuis macOS, sans macFUSE.

        USAGE
          brailliant <commande> [arguments] [options]

        COMMANDES
          info                     modèle, numéro de série, espace disponible
          ls [chemin]              liste un dossier de la plage
          tree [chemin]            affiche l'arborescence
          get <distant> [local]    copie de la plage vers le Mac (fichier ou dossier)
          put <local> [distant]    copie du Mac vers la plage (fichier ou dossier)
          rm <chemin>...           supprime de la plage
          mkdir <chemin>...        crée un dossier sur la plage
          mv <source> <dest>       renomme ou déplace un élément sur la plage
          clean                    retire les fichiers parasites macOS de la plage
          doctor                   vérifie que tout fonctionne
          finder on|off|status     surveille la plage et l'affiche dans le Finder
          uninstall                supprime entièrement BrailliantConnect
          bench [chemin]           mesure les latences du protocole (diagnostic)
          bench --scale [n]        mesure la montée en charge (crée puis supprime
                                   des fichiers de test sur la plage)

        OPTIONS
          -l, --long               affiche les tailles (ls)
          -a, --all                affiche aussi les fichiers parasites macOS
          -r, --recursive          supprime un dossier avec son contenu (rm)
          -s, --storage <n|nom>    stockage ciblé : « 2 » ou « usb » (défaut : le premier)
          -d, --depth <n>          profondeur maximale (tree)
          -n, --dry-run            simule sans rien supprimer (clean)
          -f, --force              supprime sans demander confirmation (rm -r)
              --no-overwrite       refuse d'écraser un fichier existant (put)
              --progress           force l'affichage de la progression
              --no-progress        masque la progression
              --any-device         accepte un appareil MTP d'un autre fabricant
              --debug              affiche les messages internes de libmtp
          -h, --help               affiche cette aide

        EXEMPLES
          brailliant put ~/Documents/roman.txt /documents
          brailliant get /notes ~/Desktop
          brailliant clean --dry-run
          brailliant -s usb ls /
          brailliant finder on

        Le dossier distant par défaut pour « put » est /documents. Les dossiers
        manquants sont créés automatiquement.
        """,

        // MARK: Benchmark

        "MTP latency measurements — %@": "Mesures de latence MTP — %@",
        "Each figure is what the equivalent Finder operation would cost.":
            "Chaque chiffre indique ce que coûterait l'opération équivalente au Finder.",
        "Display plugged in over USB, no other application connected.":
            "Plage branchée en USB, aucune autre application connectée.",
        "ENUMERATING A FOLDER": "ÉNUMÉRATION D'UN DOSSIER",
        "(the Finder runs it again every time a folder is opened)":
            "(le Finder la relance à chaque ouverture de dossier)",
        "%@ item(s) — first pass %@, second %@":
            "%@ élément(s) — premier passage %@, second %@",
        "that is %@ per item": "soit %@ par élément",
        "caching detected": "mise en cache détectée",
        "no caching: every pass costs the same again":
            "aucune mise en cache : chaque passage recoûte le même prix",
        "RESOLVING A PATH": "RÉSOLUTION D'UN CHEMIN",
        "(performed before every read, write or delete)":
            "(exécutée avant chaque lecture, écriture ou suppression)",
        "depth %@ — %@": "profondeur %@ — %@",
        "resolve() re-enumerates one level per path segment":
            "resolve() ré-énumère un niveau par segment de chemin",
        "FULL RECURSIVE TRAVERSAL": "PARCOURS RÉCURSIF COMPLET",
        "%@ item(s) walked in %@": "%@ élément(s) parcourus en %@",
        "READING A FILE": "LECTURE D'UN FICHIER",
        "smallest": "le plus petit",
        "largest": "le plus gros",
        "first byte after %@": "premier octet après %@",
        "complete transfer %@": "transfert complet %@",
        "throughput %@ Mo/s": "débit %@ Mo/s",
        "Slowest enumeration: %@": "Énumération la plus lente : %@",
        "The Finder would stay responsive even without a cache.":
            "Le Finder resterait fluide même sans cache.",
        "Noticeable but acceptable; an enumeration cache would be enough.":
            "Perceptible mais acceptable ; un cache d'énumération suffirait.",
        "Too slow for on-demand enumeration.":
            "Trop lent pour une énumération à la demande.",
        "The tree will have to be built in the background and served from the cache, refreshed afterwards.":
            "Il faudra construire l'arborescence en tâche de fond et la servir depuis le cache, en rafraîchissant après coup.",
        "Cleaning up…": "Nettoyage…",
        "test folder deleted": "dossier de test supprimé",
        "WARNING: \"%@\" could not be deleted. Remove it with: brailliant rm -r %@":
            "ATTENTION : « %@ » n'a pas pu être supprimé. Retirez-le avec : brailliant rm -r %@",
        "SCALING": "MONTÉE EN CHARGE",
        "(creating test files in %@)": "(création de fichiers de test dans %@)",
        "%@ files: enumeration %@ — %@ per item":
            "%@ fichiers : énumération %@ — %@ par élément",
        "Reading the curve: if the time per item stays flat, the cost is linear and predictable.":
            "Lecture de la courbe : si le temps par élément reste stable, le coût est linéaire et prévisible.",
        "If it grows, enumeration degenerates and a cache becomes indispensable beyond a certain size.":
            "S'il augmente, l'énumération dégénère et un cache devient indispensable au-delà d'une certaine taille.",
        "display asleep — location removed until it wakes up":
            "plage en veille — emplacement retiré jusqu'à son réveil",
        "display asleep":
            "plage en veille",
        "Moved: %@ → %@":
            "Déplacé : %@ → %@",
        "Usage: brailliant mv <source> <destination>":
            "Usage : brailliant mv <source> <destination>",
    ]
}
