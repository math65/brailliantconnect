import BrailliantKit
import Foundation

// Argument parsing is done by hand: no external dependency, so there is nothing
// to download in order to build and nothing to install in order to run.

let usage = """
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
      clean                    retire les fichiers parasites macOS de la plage
      doctor                   vérifie que tout fonctionne
      finder on|off|status     surveille la plage et l'affiche dans le Finder
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
    """

func run() -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    var options = Options()
    var positional: [String] = []

    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "-h", "--help":
            print(usage)
            return 0
        case "--debug": options.debug = true
        case "--progress": options.showProgress = true
        case "--no-progress": options.showProgress = false
        case "-a", "--all": options.showAll = true
        case "-l", "--long": options.long = true
        case "-r", "--recursive": options.recursive = true
        case "-n", "--dry-run": options.dryRun = true
        case "-f", "--force": options.force = true
        case "--any-device": options.anyDevice = true
        case "--scale":
            // The value is optional: "--scale" on its own goes up to 200.
            if index + 1 < arguments.count, let n = Int(arguments[index + 1]) {
                index += 1
                options.scale = n
            } else {
                options.scale = 200
            }
        case "--no-overwrite": options.noOverwrite = true
        case "-s", "--storage":
            index += 1
            guard index < arguments.count else {
                FileHandle.standardError.write(
                    Data("Erreur : -s attend un numéro ou un nom de stockage.\n".utf8))
                return 2
            }
            options.storage = arguments[index]
        case "-d", "--depth":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]) else {
                FileHandle.standardError.write(Data("Erreur : -d attend un nombre.\n".utf8))
                return 2
            }
            options.depth = value
        default:
            if argument.hasPrefix("-") && argument.count > 1 {
                FileHandle.standardError.write(
                    Data("Erreur : option inconnue « \(argument) ».\n".utf8))
                return 2
            }
            positional.append(argument)
        }
        index += 1
    }

    guard let command = positional.first else {
        print(usage)
        return 2
    }
    let rest = Array(positional.dropFirst())

    // Validate the command before opening the connection: no point waking the
    // display up for a typo.
    let known = [
        "info", "ls", "tree", "get", "put", "rm", "mkdir", "clean",
        "doctor", "bench", "finder",
    ]
    guard known.contains(command) else {
        FileHandle.standardError.write(
            Data(
                "Erreur : commande inconnue « \(command) ».\nUtilisez « brailliant --help ».\n".utf8
            ))
        return 2
    }
    switch command {
    case "get" where rest.isEmpty, "put" where rest.isEmpty,
        "rm" where rest.isEmpty, "mkdir" where rest.isEmpty:
        FileHandle.standardError.write(
            Data("Erreur : la commande « \(command) » attend au moins un argument.\n".utf8))
        return 2
    default: break
    }

    Console.shared.begin(debug: options.debug)
    defer { Console.shared.end() }

    // This command acts on the system, not on the display: there is no reason
    // to require it to be plugged in.
    if command == "finder" {
        do {
            switch rest.first ?? "status" {
            case "on": try Finder.enable()
            case "off": try Finder.disable()
            case "status": try Finder.status()
            default:
                complain("Usage : brailliant finder on|off|status")
                return 2
            }
            return 0
        } catch let error as MTPError {
            complain("Erreur : \(error.description)")
            return 1
        } catch {
            complain("Erreur : \(error.localizedDescription)")
            return 1
        }
    }

    do {
        // Filter on HumanWare by default: an Android phone is an MTP device
        // like any other, and a destructive command would apply to it with
        // nothing to warn about it.
        let display = try Brailliant(vendorID: options.anyDevice ? nil : humanwareVendorID)
        defer { display.close() }

        if let selector = options.storage {
            try display.selectStorage(matching: selector)
        }

        switch command {
        case "info": try Commands.info(display, options)
        case "ls": try Commands.list(display, options, path: rest.first ?? "/")
        case "tree": try Commands.tree(display, options, path: rest.first ?? "/")
        case "get":
            try Commands.get(
                display, options, remote: rest[0],
                local: rest.count > 1 ? rest[1] : nil)
        case "put":
            try Commands.put(
                display, options, local: rest[0],
                remote: rest.count > 1 ? rest[1] : nil)
        case "rm": try Commands.remove(display, options, paths: rest)
        case "mkdir": try Commands.makeDirectory(display, options, paths: rest)
        case "clean": try Commands.clean(display, options)
        case "doctor": try Commands.doctor(display, options)
        case "bench":
            if options.scale > 0 {
                try Benchmark.scale(display, options, maximum: options.scale)
            } else {
                try Benchmark.run(display, options, path: rest.first ?? "/")
            }
        default: break
        }
        return 0
    } catch let error as MTPError {
        complain("Erreur : \(error.description)")
        return 1
    } catch {
        complain("Erreur : \(error.localizedDescription)")
        return 1
    }
}

exit(run())
