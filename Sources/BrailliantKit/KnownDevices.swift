import Foundation

/// Which USB devices are HumanWare devices this app should serve.
///
/// Most carry HumanWare's own USB vendor ID, and that alone is enough. Two do
/// not, as measured on a tester's devices (27 Oct 2026):
///
/// - the **StellarTrek** announces Google's vendor ID (`18d1:4ee1`), the one a
///   great many Android phones share, but names "Humanware" as its USB
///   manufacturer — which no phone does;
/// - the **BrailleNote Touch Plus** says nothing of itself over USB:
///   Qualcomm's vendor ID (`05c6:f003`), "Android" as manufacturer and
///   product. Its serial number is what gives it away: `650500000132` on the
///   tester's device, and HumanWare's are all `65040000XXXX` or
///   `65050000XXXX`, he says (the second form measured, the first his word).
///
/// The agent decides from the USB descriptor, which IOKit hands it without a
/// word of MTP — the agent does not link libmtp, on purpose (see "Security
/// properties" in CLAUDE.md). The extension and the command-line tool only
/// get vendor and product IDs from libmtp before opening a device, so they
/// open a lookalike and check what it says over MTP: the StellarTrek's model
/// name, the BrailleNote's serial number (the same over MTP as over USB) or
/// model name.
///
/// Compiled into the agent as well as `BrailliantKit`: keep it free of
/// anything else in the package.
public enum KnownDevices {

    /// HumanWare's USB vendor ID. Anything carrying it is accepted.
    public static let humanwareVendorID: UInt16 = 0x1C71

    /// Google's, which the StellarTrek borrows.
    static let googleVendorID: UInt16 = 0x18D1

    /// Qualcomm's, which the BrailleNote Touch Plus borrows.
    static let qualcommVendorID: UInt16 = 0x05C6

    /// From the USB descriptor: what the agent reads through IOKit.
    public static func recognizes(
        vendorID: UInt16, manufacturer: String?, serialNumber: String?
    ) -> Bool {
        switch vendorID {
        case humanwareVendorID:
            return true
        case googleVendorID:
            return normalized(manufacturer) == "humanware"
        case qualcommVendorID:
            return isBrailleNoteSerial(serialNumber)
        default:
            return false
        }
    }

    /// Whether a device is worth opening to find out, when only its vendor ID
    /// is known.
    public static func mayBeKnown(vendorID: UInt16) -> Bool {
        [humanwareVendorID, googleVendorID, qualcommVendorID].contains(vendorID)
    }

    /// True when the vendor ID settles it, with no need to open the device.
    public static func needsNoConfirmation(vendorID: UInt16) -> Bool {
        vendorID == humanwareVendorID
    }

    /// From what an opened device says over MTP.
    public static func confirms(vendorID: UInt16, model: String, serialNumber: String) -> Bool {
        switch vendorID {
        case humanwareVendorID:
            return true
        case googleVendorID:
            return normalized(model) == "stellartrek"
        case qualcommVendorID:
            return isBrailleNoteSerial(serialNumber)
                || normalized(model).hasPrefix("braillenotetouch")
        default:
            return false
        }
    }

    /// `65040000` or `65050000`, then four digits.
    static func isBrailleNoteSerial(_ serial: String?) -> Bool {
        guard let serial = serial?.trimmingCharacters(in: .whitespaces) else { return false }
        return serial.range(of: #"^650[45]0000[0-9]{4}$"#, options: .regularExpression) != nil
    }

    /// Lowercased, without spaces or hyphens: "Stellar Trek" and
    /// "StellarTrek" are the same name.
    private static func normalized(_ text: String?) -> String {
        (text ?? "").lowercased().filter { !$0.isWhitespace && $0 != "-" }
    }
}
