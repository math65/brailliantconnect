import XCTest

@testable import BrailliantKit

/// The display renumbers its objects at every session (measured 17 Nov 2026);
/// these numbers are what the Finder holds instead.
final class ItemIdentitiesTests: XCTestCase {

    private let internalMemory: UInt32 = 0xFFFF_0001
    private let stick: UInt32 = 0xFFFF_0002

    private func at(_ path: String, _ storage: UInt32? = nil) -> ItemLocation {
        ItemLocation(storageID: storage ?? internalMemory, path: path)
    }

    func testSameLocationSameNumber() {
        var table = ItemIdentities()
        let first = table.number(for: at("/books/a.epub"))
        XCTAssertEqual(table.number(for: at("/books/a.epub")), first)
        XCTAssertEqual(table.location(of: first), at("/books/a.epub"))
    }

    /// The display gave the stick and the internal memory the same handles;
    /// the same path on two storages must not share a number.
    func testStoragesDoNotShareNumbers() {
        var table = ItemIdentities()
        let inside = table.number(for: at("/documents"))
        let onStick = table.number(for: at("/documents", stick))
        XCTAssertNotEqual(inside, onStick)
        XCTAssertEqual(table.location(of: onStick)?.storageID, stick)
    }

    /// Listing order changed the display's handles; it must not change ours.
    func testNumbersDoNotDependOnListingOrder() {
        var forwards = ItemIdentities()
        let a = forwards.number(for: at("/a"))
        _ = forwards.number(for: at("/b"))
        XCTAssertEqual(forwards.number(for: at("/a")), a)
        XCTAssertEqual(forwards.location(of: a), at("/a"))
    }

    func testNumbersAreNeverReused() {
        var table = ItemIdentities()
        let old = table.number(for: at("/a"))
        table.forget(at("/a"))
        XCTAssertNil(table.location(of: old))
        XCTAssertNotEqual(table.number(for: at("/a")), old)
    }

    func testRenameKeepsNumbersBelow() {
        var table = ItemIdentities()
        let folder = table.number(for: at("/notes"))
        let child = table.number(for: at("/notes/a.txt"))
        let deep = table.number(for: at("/notes/x/y.txt"))
        let sibling = table.number(for: at("/notes2/z.txt"))
        table.move(from: at("/notes"), to: at("/archive"))
        XCTAssertEqual(table.location(of: folder), at("/archive"))
        XCTAssertEqual(table.location(of: child), at("/archive/a.txt"))
        XCTAssertEqual(table.location(of: deep), at("/archive/x/y.txt"))
        // "/notes2" only starts like "/notes".
        XCTAssertEqual(table.location(of: sibling), at("/notes2/z.txt"))
        XCTAssertNil(table.existingNumber(for: at("/notes/a.txt")))
    }

    func testMoveAcrossStorages() {
        var table = ItemIdentities()
        let folder = table.number(for: at("/a"))
        let child = table.number(for: at("/a/b"))
        table.move(from: at("/a"), to: at("/backup/a", stick))
        XCTAssertEqual(table.location(of: folder), at("/backup/a", stick))
        XCTAssertEqual(table.location(of: child), at("/backup/a/b", stick))
        XCTAssertNil(table.existingNumber(for: at("/a/b")))
    }

    /// What held a number at the destination is gone: one location, one number.
    func testMoveReplacesWhatWasAtTheDestination() {
        var table = ItemIdentities()
        let stale = table.number(for: at("/b"))
        let staleChild = table.number(for: at("/b/old"))
        let moving = table.number(for: at("/a"))
        table.move(from: at("/a"), to: at("/b"))
        XCTAssertNil(table.location(of: stale))
        XCTAssertNil(table.location(of: staleChild))
        XCTAssertEqual(table.number(for: at("/b")), moving)
    }

    func testForgetTakesTheSubtree() {
        var table = ItemIdentities()
        let kept = table.number(for: at("/ab"))
        _ = table.number(for: at("/a"))
        _ = table.number(for: at("/a/b/c"))
        let elsewhere = table.number(for: at("/a/b/c", stick))
        table.forget(at("/a"))
        XCTAssertEqual(table.count, 2)
        XCTAssertNotNil(table.location(of: kept))
        XCTAssertNotNil(table.location(of: elsewhere))
    }

    func testKeepOnlyDropsWhatAListingNoLongerShows() {
        var table = ItemIdentities()
        let stays = table.number(for: at("/books/a"))
        _ = table.number(for: at("/books/gone"))
        _ = table.number(for: at("/books/gone/inner"))
        let grandchild = table.number(for: at("/books/a/inner"))
        let top = table.number(for: at("/books"))
        table.keepOnly(["a"], in: at("/books"))
        XCTAssertEqual(table.count, 3)
        XCTAssertNotNil(table.location(of: stays))
        XCTAssertNotNil(table.location(of: grandchild))
        XCTAssertNotNil(table.location(of: top))
    }

    func testKeepOnlyAtTheTopOfAStorage() {
        var table = ItemIdentities()
        _ = table.number(for: at("/gone"))
        let stays = table.number(for: at("/books"))
        let other = table.number(for: at("/gone", stick))
        table.keepOnly(["books"], in: at("/"))
        XCTAssertEqual(table.count, 2)
        XCTAssertNotNil(table.location(of: stays))
        XCTAssertNotNil(table.location(of: other))
    }

    func testSurvivesEncoding() throws {
        var table = ItemIdentities()
        _ = table.number(for: at("/a"))
        let b = table.number(for: at("/b é", stick))
        table.forget(at("/a"))
        let decoded = try JSONDecoder().decode(
            ItemIdentities.self, from: JSONEncoder().encode(table))
        XCTAssertEqual(decoded, table)
        XCTAssertEqual(decoded.location(of: b), at("/b é", stick))
        // The counter came back too: a new item never takes a retired number.
        var next = decoded
        XCTAssertGreaterThan(next.number(for: at("/c")), b)
    }
}
