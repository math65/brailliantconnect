import XCTest
@testable import BrailliantKit

final class RemotePathTests: XCTestCase {

    func testNormalisation() {
        XCTAssertEqual(RemotePath.normalize("/"), "/")
        XCTAssertEqual(RemotePath.normalize(""), "/")
        XCTAssertEqual(RemotePath.normalize("documents"), "/documents")
        XCTAssertEqual(RemotePath.normalize("/documents/"), "/documents")
        XCTAssertEqual(RemotePath.normalize("//documents///a//"), "/documents/a")
        XCTAssertEqual(RemotePath.normalize("/documents/./a"), "/documents/a")
    }

    func testNormalisationResoutLesRemontees() {
        XCTAssertEqual(RemotePath.normalize("/documents/../notes"), "/notes")
        XCTAssertEqual(RemotePath.normalize("/documents/a/../b"), "/documents/b")
        // Une remontée au-delà de la racine reste à la racine.
        XCTAssertEqual(RemotePath.normalize("/../../.."), "/")
    }

    func testJointure() {
        XCTAssertEqual(RemotePath.join("/", "documents"), "/documents")
        XCTAssertEqual(RemotePath.join("", "documents"), "/documents")
        XCTAssertEqual(RemotePath.join("/documents", "a.txt"), "/documents/a.txt")
    }

    func testDecoupage() {
        var resultat = RemotePath.split("/documents/roman.txt")
        XCTAssertEqual(resultat.parent, "/documents")
        XCTAssertEqual(resultat.name, "roman.txt")

        resultat = RemotePath.split("/roman.txt")
        XCTAssertEqual(resultat.parent, "/")
        XCTAssertEqual(resultat.name, "roman.txt")

        resultat = RemotePath.split("/")
        XCTAssertEqual(resultat.parent, "/")
        XCTAssertEqual(resultat.name, "")
    }

    func testComposants() {
        XCTAssertEqual(RemotePath.components("/documents/a/b.txt"), ["documents", "a", "b.txt"])
        XCTAssertEqual(RemotePath.components("/"), [])
    }

    func testFichiersParasitesMacOS() {
        for nom in [".DS_Store", "._.DS_Store", "._roman.txt", ".Spotlight-V100"] {
            XCTAssertTrue(MacJunk.matches(nom), "« \(nom) » devrait être reconnu comme parasite")
        }
        for nom in ["roman.txt", ".cache", "notes.md"] {
            XCTAssertFalse(MacJunk.matches(nom), "« \(nom) » ne devrait pas être filtré")
        }
    }
}

final class FormattingTests: XCTestCase {

    func testTaillesLisibles() {
        XCTAssertEqual(humanSize(0), "0 o")
        XCTAssertEqual(humanSize(901), "901 o")
        XCTAssertEqual(humanSize(1_718), "1,7 ko")
        XCTAssertEqual(humanSize(29_512_874), "29,5 Mo")
        XCTAssertEqual(humanSize(30_390_000_000), "30,4 Go")
    }

    func testVirguleDecimaleFrancaise() {
        XCTAssertTrue(humanSize(1_500).contains(","))
        XCTAssertFalse(humanSize(1_500).contains("."))
    }

    func testStockageCalculeLUtilisation() {
        let stockage = Storage(id: 1, description: "interne",
                               capacity: 1_000, free: 250)
        XCTAssertEqual(stockage.used, 750)
        XCTAssertEqual(stockage.usedPercent, 75)
    }

    func testStockageSansCapaciteNeDivisePasParZero() {
        let stockage = Storage(id: 1, description: "vide", capacity: 0, free: 0)
        XCTAssertEqual(stockage.usedPercent, 0)
        XCTAssertEqual(stockage.used, 0)
    }
}
