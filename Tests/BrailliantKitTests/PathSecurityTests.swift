import XCTest
@testable import BrailliantKit

/// Tests de la barrière qui empêche un nom venant de la plage d'écrire hors
/// du dossier de destination.
///
/// MTP n'impose aucune contrainte sur les noms de fichiers : ni « .. », ni le
/// séparateur « / » ne sont interdits. Ces cas ne sont donc pas théoriques.
final class PathSecurityTests: XCTestCase {

    private let root = "/Users/test/Bureau/documents"

    // MARK: Validation des noms

    func testNomsLegitimesAcceptes() {
        for nom in ["roman.txt", "Interview Soukayna.odt", "éàçùôî.txt",
                    "fichier avec espaces.docx", ".cache", "a"] {
            XCTAssertTrue(RemotePath.isSafeComponent(nom), "« \(nom) » devrait être accepté")
        }
    }

    func testNomsDangereuxRejetes() {
        for nom in ["..", ".", "", "../etc/passwd", "sous/fichier.txt",
                    "dossier\\fichier.txt", "nul\u{0}octet"] {
            XCTAssertFalse(RemotePath.isSafeComponent(nom), "« \(nom) » devrait être rejeté")
        }
    }

    // MARK: Confinement

    func testTraverseeParPointPointRejetee() {
        XCTAssertThrowsError(try LocalPath.confine(root: root,
                                                   relative: "../../../../tmp/evil.txt")) { error in
            guard case MTPError.unsafeRemoteName = error else {
                return XCTFail("erreur attendue : unsafeRemoteName, obtenue : \(error)")
            }
        }
    }

    func testRemonteeSimpleRejetee() {
        XCTAssertThrowsError(try LocalPath.confine(root: root, relative: ".."))
    }

    func testTraverseeEnMilieuDeCheminRejetee() {
        XCTAssertThrowsError(try LocalPath.confine(root: root,
                                                   relative: "sous/../../echappe.txt"))
    }

    func testCibleLegitimeAcceptee() throws {
        let cible = try LocalPath.confine(root: root, relative: "sous/roman.txt")
        XCTAssertEqual(cible, "/Users/test/Bureau/documents/sous/roman.txt")
        XCTAssertTrue(LocalPath.isConfined(cible, under: root))
    }

    func testAccentsPreservesDansLaCible() throws {
        let cible = try LocalPath.confine(root: root, relative: "notes/éàçùôî.txt")
        XCTAssertEqual(cible, "/Users/test/Bureau/documents/notes/éàçùôî.txt")
    }

    func testConfinementDetecteLaSortie() {
        XCTAssertFalse(LocalPath.isConfined("/Users/test/autre", under: root))
        XCTAssertFalse(LocalPath.isConfined("/tmp/evil.txt", under: root))
        // Un dossier voisin dont le nom commence pareil ne doit pas passer.
        XCTAssertFalse(LocalPath.isConfined("/Users/test/Bureau/documents-bis/x",
                                            under: root))
        XCTAssertTrue(LocalPath.isConfined(root, under: root))
        XCTAssertTrue(LocalPath.isConfined(root + "/a/b", under: root))
    }
}

/// Tests de la neutralisation des séquences capables de manipuler le terminal.
final class DisplaySanitizationTests: XCTestCase {

    func testSequenceAnsiNeutralisee() {
        let malveillant = "innocent.txt\u{1B}[2K\u{1B}[Aeffacé"
        let propre = malveillant.sanitizedForDisplay
        XCTAssertFalse(propre.unicodeScalars.contains { $0.value == 0x1B },
                       "l'échappement ANSI doit disparaître")
    }

    func testRetourChariotNeutralise() {
        // « \r » permettrait de réécrire par-dessus la ligne déjà affichée.
        XCTAssertFalse("a\rb".sanitizedForDisplay.contains("\r"))
        XCTAssertFalse("a\nb".sanitizedForDisplay.contains("\n"))
    }

    func testTabulationRemplaceeParEspace() {
        XCTAssertEqual("a\tb".sanitizedForDisplay, "a b")
    }

    func testTexteNormalIntact() {
        for texte in ["roman.txt", "Interview Soukayna.odt", "éàçùôî ÉÀÇ", "日本語.txt"] {
            XCTAssertEqual(texte.sanitizedForDisplay, texte)
        }
    }
}
