import Foundation

/// Error raised by the MTP layer. Its message is localized text that can be
/// shown to the user as is.
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
    case hostApplicationNotFound(searched: [String])
    case agentFailedToStart(detail: String)
    case noHumanwareDevice(otherMTPDevices: [(vendor: UInt16, product: UInt16)])
    case storageNotFound(selector: String, available: [String])
    case ambiguousStorage(selector: String, matches: [String])
    case unsafeRemoteName(String)
    case pathEscapesDestination(attempted: String, root: String)
    case notEnoughSpace(needed: UInt64, available: UInt64)
    case renameFailed(from: String, to: String, code: Int32)
    case moveFailed(from: String, to: String, code: Int32)
    case interruptedAfterDelete(temporary: String, target: String)

    public var description: String {
        switch self {
        case .libraryMissing(let tried):
            return L.t("libmtp could not be found.") + "\n\n"
                + L.t(
                    "A copy should ship in the Vendor/ folder next to the program. "
                        + "If it is missing, rebuild it with ./tools/build-vendor.sh") + "\n\n"
                + L.t("Paths tried:") + "\n  " + tried.joined(separator: "\n  ")
        case .localeUnavailable:
            return L.t(
                "No UTF-8 locale could be enabled; accented file names would be corrupted.")
        case .noDeviceFound:
            return L.t("No braille display detected.") + "\n"
                + L.t(
                    "Check that the USB cable is connected, the display is switched on, "
                        + "and that MTP is enabled on it (Options, User settings, MTP).")
        case .connectionFailed:
            return L.t("The display was detected but the MTP connection failed.") + "\n"
                + L.t(
                    "Common causes: MTP is disabled on the display (Options, User "
                        + "settings, MTP), or another application is already using it.")
        case .deviceIndexOutOfRange(let requested, let found):
            return L.t(
                "Device no. %@ requested, but %@ detected.",
                String(requested), String(found))
        case .noStorage:
            return L.t("No storage available on the display.")
        case .notFound(let path):
            return L.t("Not found on the display: %@", path)
        case .notADirectory(let path):
            return L.t("\"%@\" is a file, not a folder.", path)
        case .alreadyExists(let path):
            return L.t("\"%@\" already exists on the display.", path)
        case .directoryNotEmpty(let path, let count):
            return L.t(
                "The folder \"%@\" is not empty (%@ item(s)). "
                    + "Use the -r option to delete it along with its contents.",
                path, String(count))
        case .localFileMissing(let path):
            return L.t("Local file not found: %@", path)
        case .transferFailed(let path, let code):
            return L.t("Transfer of \"%@\" failed (code %@).", path, String(code))
        case .createFolderFailed(let name):
            return L.t("Could not create the folder \"%@\".", name)
        case .deleteFailed(let path, let code):
            return L.t("Deletion of \"%@\" failed (code %@).", path, String(code))
        case .invalidRemotePath(let path):
            return L.t("Invalid remote path: \"%@\"", path)
        case .cannotRemoveRoot:
            return L.t("The root of the display cannot be deleted.")
        case .hostApplicationNotFound(let searched):
            return L.t(
                "BrailliantConnect.app cannot be found; it is the app that carries "
                    + "the Finder extension.") + "\n\n"
                + L.t("Locations searched:") + "\n  " + searched.joined(separator: "\n  ")
        case .agentFailedToStart(let detail):
            return L.t("Watching could not be started: %@", detail) + "\n\n"
                + L.t(
                    "The location can still be published by hand with "
                        + "\"brailliant finder on\" once the problem is fixed.")
        case .noHumanwareDevice(let others):
            let checkCable = L.t(
                "Check that the USB cable is connected, the display is switched on, "
                    + "and that MTP is enabled on it (Options, User settings, MTP).")
            if others.isEmpty {
                return L.t("No HumanWare braille display detected.") + "\n" + checkCable
            }
            let list =
                others
                .map { L.t("vendor 0x%04x, product 0x%04x", $0.vendor, $0.product) }
                .joined(separator: "\n  ")
            return L.t(
                "No HumanWare braille display detected, but %@ other MTP device(s) "
                    + "are plugged in:", String(others.count)) + "\n  " + list + "\n\n"
                + L.t(
                    "It is probably a phone or a music player. To avoid acting on the "
                        + "wrong device, such devices are ignored by default.") + "\n"
                + L.t("If one of them really is your display, run again with --any-device.")
        case .storageNotFound(let selector, let available):
            return L.t("No storage matches \"%@\".", selector) + "\n\n"
                + L.t("Available storages:") + "\n  " + available.joined(separator: "\n  ")
        case .ambiguousStorage(let selector, let matches):
            return L.t("\"%@\" matches several storages:", selector) + "\n  "
                + matches.joined(separator: "\n  ") + "\n\n"
                + L.t("Give the number rather than the name.")
        case .unsafeRemoteName(let name):
            return L.t(
                "The display returned an unusable file name: \"%@\".",
                name.sanitizedForDisplay) + "\n\n"
                + L.t(
                    "Such a name would allow writing outside the destination folder; "
                        + "the operation was stopped as a precaution.")
        case .pathEscapesDestination(let attempted, let root):
            return L.t(
                "Write refused: the computed destination falls outside the requested folder.")
                + "\n  " + L.t("requested: %@", root)
                + "\n  " + L.t("computed:  %@", attempted)
        case .notEnoughSpace(let needed, let available):
            return L.t(
                "Not enough space on the display: %@ needed, %@ available.",
                humanSize(needed), humanSize(available))
        case .moveFailed(let from, let to, let code):
            return L.t("Moving \"%@\" to \"%@\" failed (code %@).", from, to, String(code))
        case .renameFailed(let from, let to, let code):
            return L.t(
                "Renaming \"%@\" to \"%@\" failed (code %@).",
                from, to, String(code))
        case .interruptedAfterDelete(let temporary, let target):
            return L.t("The transfer succeeded but the file could not be renamed.") + "\n\n"
                + L.t(
                    "Your data is intact: it is on the display under the name \"%@\". "
                        + "Rename it to \"%@\", or send it again.",
                    temporary, target)
        }
    }
}
