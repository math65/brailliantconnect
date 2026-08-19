import BrailliantKit
import Foundation

// Analyse des arguments faite à la main : aucune dépendance externe, donc rien
// à télécharger pour compiler et rien à installer pour exécuter.

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
        case "--debug":       options.debug = true
        case "--progress":    options.showProgress = true
        case "--no-progress": options.showProgress = false
        case "-a", "--all":   options.showAll = true
        case "-l", "--long":  options.long = true
        case "-r", "--recursive": options.recursive = true
        case "-n", "--dry-run":   options.dryRun = true
        case "-f", "--force":     options.force = true
        case "--any-device":      options.anyDevice = true
        case "--scale":
            // Valeur facultative : « --scale » seul monte jusqu'à 200.
            if index + 1 < arguments.count, let n = Int(arguments[index + 1]) {
                index += 1
                options.scale = n
            } else {
                options.scale = 200
            }
        case "--no-overwrite":    options.noOverwrite = true
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
                FileHandle.standardError.write(Data("Erreur : option inconnue « \(argument) ».\n".utf8))
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

    // Vérifie la commande avant d'ouvrir la connexion : inutile de réveiller
    // la plage pour une faute de frappe.
    let known = ["info", "ls", "tree", "get", "put", "rm", "mkdir", "clean",
             "doctor", "bench", "finder"]
    guard known.contains(command) else {
        FileHandle.standardError.write(
            Data("Erreur : commande inconnue « \(command) ».\nUtilisez « brailliant --help ».\n".utf8))
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

    // Cette commande agit sur le système, pas sur la plage : inutile d'exiger
    // qu'elle soit branchée.
    if command == "finder" {
        do {
            switch rest.first ?? "status" {
            case "on":     try Finder.activer()
            case "off":    try Finder.désactiver()
            case "status": try Finder.état()
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
        // Filtrer sur HumanWare par défaut : un téléphone Android est un
        // appareil MTP comme un autre, et une commande destructive
        // s'appliquerait à lui sans que rien ne le signale.
        let plage = try Brailliant(vendorID: options.anyDevice ? nil : humanwareVendorID)
        defer { plage.close() }

        if let selector = options.storage {
            try plage.selectStorage(matching: selector)
        }

        switch command {
        case "info":   try Commands.info(plage, options)
        case "ls":     try Commands.list(plage, options, path: rest.first ?? "/")
        case "tree":   try Commands.tree(plage, options, path: rest.first ?? "/")
        case "get":    try Commands.get(plage, options, remote: rest[0],
                                        local: rest.count > 1 ? rest[1] : nil)
        case "put":    try Commands.put(plage, options, local: rest[0],
                                        remote: rest.count > 1 ? rest[1] : nil)
        case "rm":     try Commands.remove(plage, options, paths: rest)
        case "mkdir":  try Commands.makeDirectory(plage, options, paths: rest)
        case "clean":  try Commands.clean(plage, options)
        case "doctor": try Commands.doctor(plage, options)
        case "bench":
            if options.scale > 0 {
                try Benchmark.scale(plage, options, maximum: options.scale)
            } else {
                try Benchmark.run(plage, options, path: rest.first ?? "/")
            }
        default:       break
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
