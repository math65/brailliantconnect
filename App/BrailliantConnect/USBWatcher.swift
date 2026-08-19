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

    /// Number of HumanWare displays currently connected and awake.
    ///
    /// Devices are enumerated and then filtered by reading their "idVendor"
    /// property. Filtering directly in the matching dictionary would be more
    /// concise, but it depends on the encoding IOKit expects and turns out to
    /// silently do nothing at the slightest deviation.
    ///
    /// A sleeping display is not counted: it stays enumerated on USB but stops
    /// exposing its interfaces, and MTP is then unreachable. Counting it would
    /// publish a Finder location the extension cannot serve — the user would
    /// see a folder that hangs instead of an absent one.
    static func connectedDisplayCount() -> Int {
        guard let criteria = IOServiceMatching(usbClass) else { return 0 }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(mainPort, criteria, &iterator) == KERN_SUCCESS
        else { return 0 }
        defer { IOObjectRelease(iterator) }

        var total = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            if vendorID(of: service) == humanwareVendorID, hasInterfaces(service) { total += 1 }
            IOObjectRelease(service)
        }
        return total
    }

    /// Number of HumanWare displays plugged in, awake or not.
    ///
    /// Lets the agent tell "no display" from "a display that is asleep", which
    /// are the same thing to MTP but not to the person holding it.
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

    /// True if the device currently publishes any child in the IOKit registry.
    ///
    /// An awake display hangs a composite device — and its interfaces — under
    /// itself. Asleep, it drops them all while remaining enumerated, which is
    /// exactly what makes it look present but answer nothing.
    private static func hasInterfaces(_ device: io_service_t) -> Bool {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &children) == KERN_SUCCESS
        else { return false }
        defer { IOObjectRelease(children) }

        let first = IOIteratorNext(children)
        guard first != 0 else { return false }
        IOObjectRelease(first)
        return true
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
