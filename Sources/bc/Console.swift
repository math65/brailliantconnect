import Foundation

/// Sorties du programme, isolées de celles de libmtp.
///
/// libmtp écrit des messages parfaitement bénins (« Android device detected »,
/// « … is UNKNOWN in libmtp ») directement sur les descripteurs 1 et 2 depuis
/// le code C. Ils pollueraient une sortie destinée à être lue par un lecteur
/// d'écran ou redirigée vers un autre programme.
///
/// On détourne donc les descripteurs 1 et 2 vers un fichier temporaire pendant
/// toute la session, en conservant des copies des originaux sur lesquelles le
/// programme écrit ses propres sorties. À la fermeture, seules les lignes non
/// reconnues comme bénignes sont réémises.
final class Console {

    static let shared = Console()

    /// Messages de libmtp sans valeur pour l'utilisateur.
    private static let benign = [
        "is UNKNOWN in libmtp",
        "Please report this VID/PID",
        "Android device detected, assigning default bug flags",
        "libmtp version:",
        "Unable to open ~/.mtpz-data",
        "PTP_ERROR_IO: Trying to reset",
    ]

    private var realOut: Int32 = 1
    private var realErr: Int32 = 2
    private var captureFD: Int32 = -1
    private var capturePath: String?
    private var active = false

    /// Vrai si la sortie est un terminal interactif.
    private(set) var isInteractive = isatty(1) == 1

    private init() {}

    /// Met en place le détournement. `debug` laisse tout passer tel quel.
    func begin(debug: Bool) {
        guard !debug, !active else { return }
        isInteractive = isatty(1) == 1

        // Nom imprévisible et création exclusive : un nom dérivé du PID
        // serait devinable, et sans O_EXCL le programme suivrait un lien
        // symbolique déposé à l'avance si TMPDIR venait à être partagé.
        let path = NSTemporaryDirectory()
            + "bc-libmtp-\(getpid())-\(UUID().uuidString).log"
        let fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }

        realOut = dup(1)
        realErr = dup(2)
        guard realOut >= 0, realErr >= 0 else { close(fd); return }

        dup2(fd, 1)
        dup2(fd, 2)
        captureFD = fd
        capturePath = path
        active = true
    }

    /// Restaure les descripteurs et réémet les messages non bénins.
    func end() {
        guard active else { return }
        active = false

        // La libc tamponne ses écritures : sans ce vidage, les messages
        // ressortiraient sur le terminal une fois les descripteurs restaurés.
        fflush(nil)

        dup2(realOut, 1)
        dup2(realErr, 2)
        close(realOut)
        close(realErr)
        realOut = 1
        realErr = 2

        if let capturePath {
            let captured = (try? String(contentsOfFile: capturePath, encoding: .utf8)) ?? ""
            for line in captured.split(separator: "\n", omittingEmptySubsequences: true) {
                let text = String(line)
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty,
                      !Console.benign.contains(where: text.contains) else { continue }
                write(text + "\n", to: 2)
            }
            try? FileManager.default.removeItem(atPath: capturePath)
        }
        if captureFD >= 0 { close(captureFD) }
        captureFD = -1
        capturePath = nil
    }

    private func write(_ text: String, to fd: Int32) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { buffer in
                Darwin.write(fd, buffer.baseAddress, buffer.count)
            }
            if written <= 0 { break }
            offset += written
        }
    }

    /// Écrit une ligne sur la sortie standard réelle.
    func out(_ text: String = "") { write(text + "\n", to: realOut) }

    /// Écrit une ligne sur la sortie d'erreur réelle.
    func error(_ text: String) { write(text + "\n", to: realErr) }

    /// Écrit sans passer à la ligne (progression).
    func partial(_ text: String) { write(text, to: realOut) }
}

/// Raccourcis.
func say(_ text: String = "") { Console.shared.out(text) }
func complain(_ text: String) { Console.shared.error(text) }
