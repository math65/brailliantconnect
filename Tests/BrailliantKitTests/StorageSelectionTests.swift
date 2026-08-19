import XCTest
@testable import BrailliantKit

/// Tests de la désignation d'un stockage.
///
/// Une plage expose plusieurs stockages (mémoire interne, clé USB, carte SD) :
/// sans sélection possible, tout ce qui n'est pas le premier reste invisible.
final class StorageSelectionTests: XCTestCase {

    private let stockages = [
        Storage(id: 0xFFFF0001, description: "1- mémoire interne",
                capacity: 30_390_000_000, free: 29_990_000_000),
        Storage(id: 0xFFFF0002, description: "3- usb",
                capacity: 511_600_000, free: 21_100_000),
    ]

    // MARK: Désignation par rang

    func testRangPremier() throws {
        let choisi = try StorageSelection.resolve(selector: "1", among: stockages)
        XCTAssertEqual(choisi.id, 0xFFFF0001)
    }

    func testRangSecond() throws {
        let choisi = try StorageSelection.resolve(selector: "2", among: stockages)
        XCTAssertEqual(choisi.id, 0xFFFF0002)
    }

    func testRangHorsBornesRejete() {
        for selecteur in ["0", "3", "9", "-1"] {
            XCTAssertThrowsError(
                try StorageSelection.resolve(selector: selecteur, among: stockages),
                "« \(selecteur) » devrait être refusé")
        }
    }

    // MARK: Désignation par nom

    func testNomPartiel() throws {
        XCTAssertEqual(try StorageSelection.resolve(selector: "usb", among: stockages).id,
                       0xFFFF0002)
        XCTAssertEqual(try StorageSelection.resolve(selector: "interne", among: stockages).id,
                       0xFFFF0001)
    }

    func testNomInsensibleALaCasse() throws {
        XCTAssertEqual(try StorageSelection.resolve(selector: "USB", among: stockages).id,
                       0xFFFF0002)
    }

    func testNomInsensibleAuxAccents() throws {
        // « memoire » sans accent doit retrouver « mémoire » : le nom est
        // tapé au clavier, souvent sans diacritiques.
        XCTAssertEqual(try StorageSelection.resolve(selector: "memoire", among: stockages).id,
                       0xFFFF0001)
    }

    func testEspacesIgnores() throws {
        XCTAssertEqual(try StorageSelection.resolve(selector: "  usb  ", among: stockages).id,
                       0xFFFF0002)
    }

    func testNomInconnuRejete() {
        XCTAssertThrowsError(try StorageSelection.resolve(selector: "carte", among: stockages)) {
            guard case MTPError.storageNotFound(_, let disponibles) = $0 else {
                return XCTFail("erreur attendue : storageNotFound, obtenue : \($0)")
            }
            // Le message doit énumérer les choix possibles.
            XCTAssertEqual(disponibles.count, 2)
            XCTAssertTrue(disponibles[0].contains("mémoire interne"))
        }
    }

    func testAmbiguiteSignalee() {
        let ambigus = [
            Storage(id: 1, description: "carte SD avant", capacity: 100, free: 50),
            Storage(id: 2, description: "carte SD arrière", capacity: 100, free: 50),
        ]
        XCTAssertThrowsError(try StorageSelection.resolve(selector: "carte", among: ambigus)) {
            guard case MTPError.ambiguousStorage(_, let correspondances) = $0 else {
                return XCTFail("erreur attendue : ambiguousStorage, obtenue : \($0)")
            }
            XCTAssertEqual(correspondances.count, 2)
        }
    }

    func testListeVideRejetee() {
        XCTAssertThrowsError(try StorageSelection.resolve(selector: "1", among: []))
    }
}
