import BrailliantKit
import Foundation

/// Latency measurements for the MTP protocol.
///
/// The point is to find out whether a Finder integration is viable at all, and
/// with which caching strategy. The Finder enumerates a folder every time it is
/// opened and asks for the attributes of each item; if a single enumeration
/// costs several seconds, no amount of polish will make the experience
/// acceptable.
enum Benchmark {

    /// Monotonic stopwatch, immune to system clock changes.
    private static func duration(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000  // ms
    }

    private static func ms(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
    }

    static func run(_ display: Brailliant, _ options: Options, path: String) throws {
        say(L.t("MTP latency measurements — %@", display.model))
        say(L.t("Each figure is what the equivalent Finder operation would cost."))
        say(L.t("Display plugged in over USB, no other application connected."))
        say()

        // --- Enumeration: the operation the Finder triggers most often ---
        say(L.t("ENUMERATING A FOLDER"))
        say(L.t("(the Finder runs it again every time a folder is opened)"))
        say()

        var folders: [(String, Int)] = []
        for entry in try display.listDirectory(path) where entry.isDirectory {
            let count = (try? display.listDirectory(entry.path).count) ?? 0
            folders.append((entry.path, count))
        }
        folders.insert((RemotePath.normalize(path), try display.listDirectory(path).count), at: 0)

        for (folder, count) in folders {
            var firstPass = 0.0
            var secondPass = 0.0
            firstPass = try duration { _ = try display.listDirectory(folder) }
            secondPass = try duration { _ = try display.listDirectory(folder) }
            let perItem = count > 0 ? firstPass / Double(count) : 0
            say("  \(folder)")
            say(
                "    "
                    + L.t(
                        "%@ item(s) — first pass %@, second %@",
                        String(count), ms(firstPass), ms(secondPass)))
            if count > 0 {
                say("    " + L.t("that is %@ per item", ms(perItem)))
            }
            // A markedly faster second pass would reveal an internal cache;
            // without one, every folder opening pays the full price again.
            if firstPass > 0, secondPass < firstPass * 0.5 {
                say("    → " + L.t("caching detected"))
            } else {
                say("    → " + L.t("no caching: every pass costs the same again"))
            }
        }
        say()

        // --- Path resolution: the hidden cost behind every operation ---
        say(L.t("RESOLVING A PATH"))
        say(L.t("(performed before every read, write or delete)"))
        say()

        let files = try display.walk(path).filter { !$0.isDirectory && !MacJunk.matches($0.name) }
        if let target = files.first {
            let depth = RemotePath.components(target.path).count
            let cost = try duration { _ = try display.resolve(target.path) }
            say("  \(target.displayPath)")
            say("    " + L.t("depth %@ — %@", String(depth), ms(cost)))
            say("    → " + L.t("resolve() re-enumerates one level per path segment"))
        }
        say()

        // --- Full traversal: what copying a folder costs ---
        say(L.t("FULL RECURSIVE TRAVERSAL"))
        say()
        var total = 0
        let walkTime = try duration { total = try display.walk(path).count }
        say("  " + L.t("%@ item(s) walked in %@", String(total), ms(walkTime)))
        say()

        // --- Reading: latency before the first byte, then throughput ---
        say(L.t("READING A FILE"))
        say()
        if let smallest = files.min(by: { $0.size < $1.size }) {
            try measureRead(display, smallest, label: L.t("smallest"))
        }
        if let largest = files.max(by: { $0.size < $1.size }), largest.size > 1_000_000 {
            try measureRead(display, largest, label: L.t("largest"))
        }

        say()
        say(L.t("VERDICT"))
        say()
        let worst =
            folders.map { $0.0 }.compactMap { folder -> Double? in
                try? duration { _ = try display.listDirectory(folder) }
            }.max() ?? 0
        say("  " + L.t("Slowest enumeration: %@", ms(worst)))
        if worst < 200 {
            say("  → " + L.t("The Finder would stay responsive even without a cache."))
        } else if worst < 1000 {
            say(
                "  → "
                    + L.t("Noticeable but acceptable; an enumeration cache would be enough."))
        } else {
            say("  → " + L.t("Too slow for on-demand enumeration."))
            say(
                "    "
                    + L.t(
                        "The tree will have to be built in the background and served "
                            + "from the cache, refreshed afterwards."))
        }
    }

    /// Measures how the cost of an enumeration evolves with the number of items.
    ///
    /// The folders of a brand-new display are small; those of a user who keeps
    /// hundreds of books on it are not. It is this curve, and not the latency
    /// on an empty folder, that decides whether the Finder will hold up.
    ///
    /// The test files are created in a dedicated folder and removed at the end,
    /// including when the measurement fails halfway through.
    static func scale(_ display: Brailliant, _ options: Options, maximum: Int) throws {
        let folder = "/documents/.bench-\(UUID().uuidString.prefix(8))"
        let source = NSTemporaryDirectory() + "brailliant-bench-source.txt"
        // Filler content for the test files; never shown to anyone.
        try "scale measurement\n".write(
            toFile: source, atomically: true,
            encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: source)
            // Cleaning up is mandatory: leave nothing behind on the user's display.
            say()
            say(L.t("Cleaning up…"))
            do {
                try display.remove(folder, recursive: true)
                say("  " + L.t("test folder deleted"))
            } catch {
                complain(
                    "  "
                        + L.t(
                            "WARNING: \"%@\" could not be deleted. "
                                + "Remove it with: brailliant rm -r %@",
                            folder, folder))
            }
        }

        try display.createDirectory(folder)
        say(L.t("SCALING"))
        say(L.t("(creating test files in %@)", folder))
        say()

        let steps = [10, 25, 50, 100, 200, 400].filter { $0 <= maximum }
        var created = 0

        for step in steps {
            while created < step {
                created += 1
                _ = try display.upload(source, to: "\(folder)/fichier-\(created).txt")
            }
            var samples: [Double] = []
            for _ in 0..<3 {
                samples.append(try duration { _ = try display.listDirectory(folder) })
            }
            let median = samples.sorted()[1]
            let perItem = median / Double(step)
            say(
                "  "
                    + L.t(
                        "%@ files: enumeration %@ — %@ per item",
                        String(step), ms(median), ms(perItem)))
        }

        say()
        say(
            L.t(
                "Reading the curve: if the time per item stays flat, "
                    + "the cost is linear and predictable."))
        say(
            L.t(
                "If it grows, enumeration degenerates and a cache becomes "
                    + "indispensable beyond a certain size."))
    }

    private static func measureRead(
        _ display: Brailliant, _ entry: Entry,
        label: String
    ) throws {
        let target = NSTemporaryDirectory() + "brailliant-bench-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: target) }

        var firstByte: Double?
        let start = DispatchTime.now().uptimeNanoseconds
        let total = try duration {
            _ = try display.download(entry.path, to: target) { transferred, _ in
                if firstByte == nil, transferred > 0 {
                    firstByte = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                }
            }
        }
        say("  \(entry.displayName) (\(label), \(entry.humanSize))")
        if let firstByte {
            say("    " + L.t("first byte after %@", ms(firstByte)))
        }
        say("    " + L.t("complete transfer %@", ms(total)))
        if total > 0, entry.size > 100_000 {
            let throughput = Double(entry.size) / 1_000_000 / (total / 1000)
            // Unit and decimal separator are formatting, kept exactly as
            // formatSize does it.
            let rate = String(format: "%.1f", throughput)
                .replacingOccurrences(of: ".", with: ",")
            say("    " + L.t("throughput %@ Mo/s", rate))
        }
    }
}
