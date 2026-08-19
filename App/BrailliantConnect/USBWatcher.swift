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

    private var notificationPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    private static var mainPort: mach_port_t {
        if #available(macOS 12.0, *) { return kIOMainPortDefault }
        return kIOMasterPortDefault
    }

    /// Number of HumanWare displays currently connected.
    ///
    /// Devices are enumerated and then filtered by reading their "idVendor"
    /// property. Filtering directly in the matching dictionary would be more
    /// concise, but it depends on the encoding IOKit expects and turns out to
    /// silently do nothing at the slightest deviation.
    static func connectedDisplayCount() -> Int {
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
        for type in [kIOMatchedNotification, kIOTerminatedNotification] {
            guard let criteria = IOServiceMatching(Self.usbClass) else { continue }
            var it: io_iterator_t = 0
            IOServiceAddMatchingNotification(
                notificationPort, type, criteria,
                callback, context, &it)
            if type == kIOMatchedNotification { addedIterator = it } else { removedIterator = it }
            // Draining the iterator a first time arms the notification: without
            // this, IOKit would never report the following events.
            drain(it)
        }
    }

    /// Consumes the pending services and reports a change if there was one.
    private func handle(_ iterator: io_iterator_t) {
        guard drain(iterator) else { return }
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
        if addedIterator != 0 { IOObjectRelease(addedIterator) }
        if removedIterator != 0 { IOObjectRelease(removedIterator) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }
}
