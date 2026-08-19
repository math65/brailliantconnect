import Foundation

/// The program's own output, kept isolated from libmtp's.
///
/// libmtp writes perfectly benign messages ("Android device detected",
/// "… is UNKNOWN in libmtp") straight to file descriptors 1 and 2 from its C
/// code. They would pollute output that is meant to be read by a screen reader
/// or piped into another program.
///
/// Descriptors 1 and 2 are therefore redirected to a temporary file for the
/// whole session, while copies of the originals are kept for the program to
/// write its own output to. On shutdown, only the lines that are not recognised
/// as benign are re-emitted.
final class Console {

    static let shared = Console()

    /// libmtp messages that carry no value for the user.
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

    /// True when the output is an interactive terminal.
    private(set) var isInteractive = isatty(1) == 1

    private init() {}

    /// Sets up the redirection. `debug` lets everything through untouched.
    func begin(debug: Bool) {
        guard !debug, !active else { return }
        isInteractive = isatty(1) == 1

        // Unpredictable name and exclusive creation: a name derived from the
        // PID would be guessable, and without O_EXCL the program would follow
        // a symbolic link planted ahead of time should TMPDIR ever be shared.
        let path =
            NSTemporaryDirectory()
            + "brailliant-libmtp-\(getpid())-\(UUID().uuidString).log"
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

    /// Restores the descriptors and re-emits the messages that are not benign.
    func end() {
        guard active else { return }
        active = false

        // libc buffers its writes: without this flush, the messages would
        // resurface on the terminal once the descriptors are restored.
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
                    !Console.benign.contains(where: text.contains)
                else { continue }
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

    /// Writes a line to the real standard output.
    func out(_ text: String = "") { write(text + "\n", to: realOut) }

    /// Writes a line to the real standard error.
    func error(_ text: String) { write(text + "\n", to: realErr) }

    /// Writes without a trailing newline (progress).
    func partial(_ text: String) { write(text, to: realOut) }
}

/// Shorthands.
func say(_ text: String = "") { Console.shared.out(text) }
func complain(_ text: String) { Console.shared.error(text) }
