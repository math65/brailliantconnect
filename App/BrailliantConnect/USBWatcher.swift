import Foundation
import IOKit
import IOKit.usb

/// Surveille l'arrivée et le retrait des plages braille sur le bus USB.
///
/// La détection est événementielle : IOKit prévient dès qu'un appareil USB
/// apparaît ou disparaît. Aucune interrogation périodique, donc aucune
/// consommation tant que rien ne bouge.
final class USBWatcher {

    /// Identifiant USB du fabricant HumanWare.
    static let humanwareVendorID = 0x1C71

    /// Classe IOKit des périphériques USB.
    ///
    /// Le stack moderne de macOS publie les appareils sous « IOUSBHostDevice ».
    /// La constante kIOUSBDeviceClassName vaut « IOUSBDevice », héritée de
    /// l'ancien stack, et ne correspondrait à rien.
    static let classeUSB = "IOUSBHostDevice"

    private var portNotification: IONotificationPortRef?
    private var itérateurArrivée: io_iterator_t = 0
    private var itérateurDépart: io_iterator_t = 0

    private let surChangement: () -> Void

    init(surChangement: @escaping () -> Void) {
        self.surChangement = surChangement
    }

    private static var portPrincipal: mach_port_t {
        if #available(macOS 12.0, *) { return kIOMainPortDefault }
        return kIOMasterPortDefault
    }

    /// Nombre de plages HumanWare actuellement branchées.
    ///
    /// Les appareils sont énumérés puis filtrés en lisant leur propriété
    /// « idVendor ». Filtrer directement dans le dictionnaire de recherche
    /// serait plus concis, mais dépend de l'encodage attendu par IOKit et se
    /// révèle silencieusement inopérant au moindre écart.
    static func nombreDePlagesBranchées() -> Int {
        guard let critères = IOServiceMatching(classeUSB) else { return 0 }
        var itérateur: io_iterator_t = 0
        guard IOServiceGetMatchingServices(portPrincipal, critères, &itérateur) == KERN_SUCCESS
        else { return 0 }
        defer { IOObjectRelease(itérateur) }

        var total = 0
        while case let service = IOIteratorNext(itérateur), service != 0 {
            if vendorID(de: service) == humanwareVendorID { total += 1 }
            IOObjectRelease(service)
        }
        return total
    }

    /// Lit l'identifiant fabricant d'un service IOKit.
    private static func vendorID(de service: io_service_t) -> Int? {
        guard let valeur = IORegistryEntryCreateCFProperty(
            service, "idVendor" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? NSNumber else { return nil }
        return valeur.intValue
    }

    func démarrer() {
        portNotification = IONotificationPortCreate(Self.portPrincipal)
        guard let portNotification,
              let source = IONotificationPortGetRunLoopSource(portNotification)?
                  .takeUnretainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)

        let contexte = Unmanaged.passUnretained(self).toOpaque()

        // Le rappel C ne peut rien capturer : l'instance transite par le
        // pointeur de contexte.
        let rappel: IOServiceMatchingCallback = { contexte, itérateur in
            guard let contexte else { return }
            Unmanaged<USBWatcher>.fromOpaque(contexte)
                .takeUnretainedValue()
                .traiter(itérateur)
        }

        // On écoute tous les périphériques USB plutôt que de filtrer par
        // fabricant : le tri se fait ensuite en lisant idVendor, seule méthode
        // qui ne dépende pas de l'encodage attendu par IOKit.
        for type in [kIOMatchedNotification, kIOTerminatedNotification] {
            guard let critères = IOServiceMatching(Self.classeUSB) else { continue }
            var it: io_iterator_t = 0
            IOServiceAddMatchingNotification(portNotification, type, critères,
                                             rappel, contexte, &it)
            if type == kIOMatchedNotification { itérateurArrivée = it }
            else { itérateurDépart = it }
            // Vider l'itérateur une première fois arme la notification : sans
            // cela, IOKit ne signalerait jamais les événements suivants.
            vider(it)
        }
    }

    /// Consomme les services en attente et signale un changement éventuel.
    private func traiter(_ itérateur: io_iterator_t) {
        guard vider(itérateur) else { return }
        // Un branchement met un instant à devenir exploitable en MTP.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.surChangement()
        }
    }

    /// Vide l'itérateur ; renvoie vrai si une plage HumanWare y figurait.
    @discardableResult
    private func vider(_ itérateur: io_iterator_t) -> Bool {
        var concerné = false
        while case let service = IOIteratorNext(itérateur), service != 0 {
            if Self.vendorID(de: service) == Self.humanwareVendorID { concerné = true }
            IOObjectRelease(service)
        }
        return concerné
    }

    deinit {
        if itérateurArrivée != 0 { IOObjectRelease(itérateurArrivée) }
        if itérateurDépart != 0 { IOObjectRelease(itérateurDépart) }
        if let portNotification { IONotificationPortDestroy(portNotification) }
    }
}
