import BrailliantKit
import Foundation

// Argument parsing is done by hand: no external dependency, so there is nothing
// to download in order to build and nothing to install in order to run.

let usage = L.t(
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
    """)

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
                    Data((L.t("Error: -s expects a storage number or name.") + "\n").utf8))
                return 2
            }
            options.storage = arguments[index]
        case "-d", "--depth":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]) else {
                FileHandle.standardError.write(
                    Data((L.t("Error: -d expects a number.") + "\n").utf8))
                return 2
            }
            options.depth = value
        default:
            if argument.hasPrefix("-") && argument.count > 1 {
                FileHandle.standardError.write(
                    Data((L.t("Error: unknown option \"%@\".", argument) + "\n").utf8))
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
        "doctor", "bench", "finder", "mv", "uninstall",
    ]
    guard known.contains(command) else {
        FileHandle.standardError.write(
            Data(
                (L.t("Error: unknown command \"%@\".", command) + "\n"
                    + L.t("Use \"brailliant --help\".") + "\n").utf8
            ))
        return 2
    }
    switch command {
    case "get" where rest.isEmpty, "put" where rest.isEmpty,
        "rm" where rest.isEmpty, "mkdir" where rest.isEmpty:
        FileHandle.standardError.write(
            Data(
                (L.t("Error: the \"%@\" command expects at least one argument.", command)
                    + "\n").utf8))
        return 2
    default: break
    }

    Console.shared.begin(debug: options.debug)
    defer { Console.shared.end() }

    // These commands act on the system, not on the display: there is no reason
    // to require it to be plugged in.
    if command == "uninstall" {
        do {
            try Finder.uninstall()
            return 0
        } catch let error as MTPError {
            complain(L.t("Error: %@", error.description))
            return 1
        } catch {
            complain(L.t("Error: %@", error.localizedDescription))
            return 1
        }
    }

    if command == "finder" {
        do {
            switch rest.first ?? "status" {
            case "on": try Finder.enable()
            case "off": try Finder.disable()
            case "status": try Finder.status()
            default:
                complain(L.t("Usage: brailliant finder on|off|status"))
                return 2
            }
            return 0
        } catch let error as MTPError {
            complain(L.t("Error: %@", error.description))
            return 1
        } catch {
            complain(L.t("Error: %@", error.localizedDescription))
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
        case "mv":
            guard rest.count >= 2 else {
                complain(L.t("Usage: brailliant mv <source> <destination>"))
                return 2
            }
            try Commands.move(display, options, from: rest[0], to: rest[1])
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
        complain(L.t("Error: %@", error.description))
        return 1
    } catch {
        complain(L.t("Error: %@", error.localizedDescription))
        return 1
    }
}

exit(run())
