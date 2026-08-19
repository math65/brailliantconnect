import XCTest

@testable import BrailliantKit

/// Tests for the paths and decisions behind the Finder location.
///
/// None of this needs a display: it is pure computation, and precisely where a
/// mistake is costly — a wrong path leaves the user with nothing, and a wrong
/// deletion takes a real folder with it.
final class FinderLocationTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/test")

    // MARK: Paths

    func testDomainLocationSitsUnderCloudStorage() {
        XCTAssertEqual(
            FinderLocation.domainLocation(home: home).path,
            "/Users/test/Library/CloudStorage/BrailliantConnect-Brailliant")
    }

    func testShortcutSitsDirectlyInHome() {
        XCTAssertEqual(FinderLocation.shortcut(home: home).path, "/Users/test/Brailliant")
    }

    func testShortcutIsNotBuriedUnderLibrary() {
        // The whole point of the shortcut is to be reachable without unhiding
        // ~/Library, so it must not live there.
        XCTAssertFalse(FinderLocation.shortcut(home: home).path.contains("Library"))
    }

    // MARK: Deleting the shortcut safely

    func testRecognisesItsOwnShortcut() {
        let ours = FinderLocation.domainLocation(home: home).path
        XCTAssertTrue(FinderLocation.isOurShortcut(pointingAt: ours))
    }

    func testRefusesToClaimSomethingElse() {
        // A user may legitimately keep a folder called "Brailliant" in their
        // home directory. It must never be mistaken for our link.
        for target in [
            "/Users/test/Documents/Brailliant",
            "/Volumes/Backup/Brailliant",
            "/Users/test/Library/CloudStorage/Dropbox",
            "",
        ] {
            XCTAssertFalse(
                FinderLocation.isOurShortcut(pointingAt: target),
                "\"\(target)\" must not be treated as ours")
        }
    }

    // MARK: Reconciling with the hardware

    func testPublishesWhenDisplayArrives() {
        XCTAssertEqual(
            FinderLocation.action(displayConnected: true, locationPublished: false),
            .publish)
    }

    func testUnpublishesWhenDisplayLeaves() {
        XCTAssertEqual(
            FinderLocation.action(displayConnected: false, locationPublished: true),
            .unpublish)
    }

    func testDoesNothingWhenAlreadyInTheRightState() {
        XCTAssertEqual(
            FinderLocation.action(displayConnected: true, locationPublished: true),
            .nothing)
        XCTAssertEqual(
            FinderLocation.action(displayConnected: false, locationPublished: false),
            .nothing)
    }

    func testDecisionIsStable() {
        // Called on every USB event, so it must not drift between calls.
        for _ in 0..<3 {
            XCTAssertEqual(
                FinderLocation.action(displayConnected: true, locationPublished: false),
                .publish)
        }
    }

    // MARK: Identifiers

    func testDomainIdentifierIsStable() {
        // Changing this orphans any location already registered with the
        // system, leaving the user with a dead entry in the Finder.
        XCTAssertEqual(FinderLocation.domainIdentifier, "brailliant-principal")
    }
}
