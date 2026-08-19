import Foundation
import IOKit
import IOKit.usb

/// Watches braille displays arriving on and leaving the USB bus.
///
/// Detection is event-driven: IOKit lets us know as soon as a USB device shows
/// up or goes away. No periodic polling, therefore no power draw as long as
/// nothing moves.
final class USBWatcher {

    /// USB vendor identifier for HumanWare.
    static let humanwareVendorID = 0x1C71

    /// IOKit class of USB devices.
    ///
    /// The modern macOS stack publishes devices under "IOUSBHostDevice".
    /// The kIOUSBDeviceClassName constant is "IOUSBDevice", inherited from the
    /// old stack, and would match nothing.
    static let usbClass = "IOUSBHostDevice"

    /// IOKit class of USB interfaces.
    ///
    /// A display that goes to sleep drops its interfaces without being
    /// unplugged, so these have to be watched to notice it at all.
    static let usbInterfaceClass = "IOUSBHostInterface"

    private var notificationPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    private static var mainPort: mach_port_t {
        if #available(macOS 12.0, *) { return kIOMainPortDefault }
        return kIOMasterPortDefault
    }

    /// How reachable the display is, from MTP's point of view.
    ///
    /// The three failing cases look identical to `libmtp` — nothing answers —
    /// but they call for three different things from the person holding the
    /// display, so they are told apart here rather than collapsed into
    /// "not connected".
    enum Availability {
        /// Nothing plugged in.
        case absent
        /// Enumerated, but publishing no interface at all: the display is
        /// asleep and a keypress brings it back.
        case asleep
        /// Publishing interfaces, none of which speaks MTP: the display is in
        /// braille terminal mode and has to be switched to file transfer.
        case brailleTerminal
        /// An MTP interface is there; the extension can serve the location.
        case ready
    }

    /// USB class of the "Still Image" interface, which is what PTP and MTP are
    /// carried over.
    private static let stillImageInterfaceClass = 6

    /// USB class meaning "the vendor defines it". Android devices — and the
    /// Brailliant runs on an Android base — expose MTP this way, naming the
    /// interface "MTP" rather than declaring a standard class.
    private static let vendorSpecificInterfaceClass = 255

    /// State of the first HumanWare display found on the bus.
    ///
    /// Devices are enumerated and then filtered by reading their "idVendor"
    /// property. Filtering directly in the matching dictionary would be more
    /// concise, but it depends on the encoding IOKit expects and turns out to
    /// silently do nothing at the slightest deviation.
    static func availability() -> Availability {
        guard let criteria = IOServiceMatching(usbClass) else { return .absent }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(mainPort, criteria, &iterator) == KERN_SUCCESS
        else { return .absent }
        defer { IOObjectRelease(iterator) }

        var best = Availability.absent
        while case let service = IOIteratorNext(iterator), service != 0 {
            if vendorID(of: service) == humanwareVendorID {
                let state = availability(of: service)
                // Best case wins: someone with two displays plugged in should
                // get the one that works, not the first one enumerated.
                if state == .ready { IOObjectRelease(service); return .ready }
                if state == .brailleTerminal || best == .absent { best = state }
            }
            IOObjectRelease(service)
        }
        return best
    }

    /// Number of HumanWare displays reachable over MTP.
    ///
    /// A display that is asleep or in braille terminal mode is not counted.
    /// Counting it would publish a Finder location the extension cannot serve,
    /// and the user would get a folder that hangs rather than an absent one.
    static func connectedDisplayCount() -> Int {
        availability() == .ready ? 1 : 0
    }

    /// Number of HumanWare displays plugged in, whatever state they are in.
    ///
    /// Lets the agent tell "no display" from "a display that cannot answer",
    /// which are the same thing to MTP but not to the person holding it.
    static func pluggedDisplayCount() -> Int {
        guard let criteria = IOServiceMatching(usbClass) else { return 0 }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(mainPort, criteria, &iterator) == KERN_SUCCESS
        else { return 0 }
        defer { IOObjectRelease(iterator) }

        var total = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            if vendorID(of: service) == humanwareVendorID { total += 1 }
            IOObjectRelease(service)
        }
        return total
    }

    /// Reads a single device's state from the interfaces it publishes.
    ///
    /// Presence of interfaces was the first criterion tried here, and it was
    /// wrong: in braille terminal mode the display publishes two HID interfaces
    /// and no MTP one. It looked connected, the location was published, and the
    /// Finder showed a folder that hung — the exact failure this is meant to
    /// prevent.
    private static func availability(of device: io_service_t) -> Availability {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &children) == KERN_SUCCESS
        else { return .asleep }
        defer { IOObjectRelease(children) }

        var sawInterface = false
        var sawMTP = false
        while case let child = IOIteratorNext(children), child != 0 {
            if IOObjectConformsTo(child, usbInterfaceClass) != 0 {
                sawInterface = true
                if speaksMTP(child) { sawMTP = true }
            }
            IOObjectRelease(child)
        }
        if sawMTP { return .ready }
        return sawInterface ? .brailleTerminal : .asleep
    }

    /// True if an interface carries MTP.
    ///
    /// Two forms are accepted because two exist: the standard still-image class
    /// used by PTP and MTP, and the vendor-specific interface named "MTP" that
    /// Android exposes — which is also what makes `libmtp`'s generic detection
    /// recognise this display, absent from its device table.
    private static func speaksMTP(_ interface: io_service_t) -> Bool {
        let interfaceClass =
            (IORegistryEntryCreateCFProperty(
                interface, "bInterfaceClass" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? NSNumber)?.intValue

        if interfaceClass == stillImageInterfaceClass { return true }
        guard interfaceClass == vendorSpecificInterfaceClass else { return false }

        var name = [CChar](repeating: 0, count: Int(128))
        guard IORegistryEntryGetName(interface, &name) == KERN_SUCCESS else { return false }
        return String(cString: name).uppercased().contains("MTP")
    }

    /// Reads the vendor identifier of an IOKit service.
    private static func vendorID(of service: io_service_t) -> Int? {
        guard
            let value = IORegistryEntryCreateCFProperty(
                service, "idVendor" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? NSNumber
        else { return nil }
        return value.intValue
    }

    func start() {
        notificationPort = IONotificationPortCreate(Self.mainPort)
        guard let notificationPort,
            let source = IONotificationPortGetRunLoopSource(notificationPort)?
                .takeUnretainedValue()
        else { return }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)

        let context = Unmanaged.passUnretained(self).toOpaque()

        // The C callback cannot capture anything: the instance travels through
        // the context pointer.
        let callback: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            Unmanaged<USBWatcher>.fromOpaque(context)
                .takeUnretainedValue()
                .handle(iterator)
        }

        // We listen to every USB device rather than filtering by vendor: the
        // sorting is done afterwards by reading idVendor, the only method that
        // does not depend on the encoding IOKit expects.
        //
        // Interfaces are watched as well as devices. Falling asleep does not
        // unplug the display — it drops its interfaces while staying
        // enumerated, so watching devices alone would never notice it going to
        // sleep or waking up.
        for watched in [Self.usbClass, Self.usbInterfaceClass] {
            for type in [kIOMatchedNotification, kIOTerminatedNotification] {
                guard let criteria = IOServiceMatching(watched) else { continue }
                var it: io_iterator_t = 0
                IOServiceAddMatchingNotification(
                    notificationPort, type, criteria,
                    callback, context, &it)
                iterators.append(it)
                // Draining the iterator a first time arms the notification:
                // without this, IOKit would never report the following events.
                drain(it)
            }
        }
    }

    /// Consumes the pending services and reports a change if there was one.
    ///
    /// Interface events carry no vendor of their own, so anything USB-related
    /// triggers a re-evaluation. Deciding is cheap; missing a wake-up is not.
    private func handle(_ iterator: io_iterator_t) {
        drain(iterator)
        // A freshly connected device takes a moment to become usable over MTP.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.onChange()
        }
    }

    /// Drains the iterator; returns true if a HumanWare display was among them.
    @discardableResult
    private func drain(_ iterator: io_iterator_t) -> Bool {
        var matched = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            if Self.vendorID(of: service) == Self.humanwareVendorID { matched = true }
            IOObjectRelease(service)
        }
        return matched
    }

    deinit {
        for iterator in iterators where iterator != 0 { IOObjectRelease(iterator) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }
}
