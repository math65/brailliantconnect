import XCTest

@testable import BrailliantKit

/// The decisions taken before a move touches the display.
///
/// Both refusals guard against a loss: a move to the item's own folder ended by
/// deleting the copy it had just written over the original, and a folder moved
/// into itself recursed with no end.
final class MoveSafetyTests: XCTestCase {

    // MARK: Containment

    func testAPathIsInsideItself() {
        XCTAssertTrue(RemotePath.isSameOrInside("/a", "/a"))
        XCTAssertTrue(RemotePath.isSameOrInside("/a/b", "/a"))
        XCTAssertTrue(RemotePath.isSameOrInside("/a/b/c", "/a"))
    }

    func testContainmentComparesWholeSegments() {
        XCTAssertFalse(RemotePath.isSameOrInside("/ab", "/a"))
        XCTAssertFalse(RemotePath.isSameOrInside("/a", "/a/b"))
        XCTAssertFalse(RemotePath.isSameOrInside("/b", "/a"))
    }

    func testContainmentNormalisesFirst() {
        XCTAssertTrue(RemotePath.isSameOrInside("/a/./b/", "a/"))
        XCTAssertTrue(RemotePath.isSameOrInside("/c/../a/b", "/a"))
    }

    func testEverythingIsInsideTheRoot() {
        XCTAssertTrue(RemotePath.isSameOrInside("/a", "/"))
        XCTAssertTrue(RemotePath.isSameOrInside("/", "/"))
    }

    // MARK: Move plans

    func testMoveToTheCurrentFolderIsANoOp() {
        XCTAssertEqual(
            RemotePath.planMove(of: "/documents/novel.txt", named: "novel.txt", into: "/documents"),
            .alreadyThere)
        XCTAssertEqual(
            RemotePath.planMove(
                of: "/documents/novel.txt", named: "novel.txt", into: "/documents/"),
            .alreadyThere)
        XCTAssertEqual(
            RemotePath.planMove(of: "/novel.txt", named: "novel.txt", into: "/"),
            .alreadyThere)
    }

    func testFolderCannotMoveIntoItself() {
        XCTAssertEqual(
            RemotePath.planMove(of: "/a", named: "a", into: "/a"), .intoItself)
        XCTAssertEqual(
            RemotePath.planMove(of: "/a", named: "a", into: "/a/b"), .intoItself)
        XCTAssertEqual(
            RemotePath.planMove(of: "/a", named: "a", into: "/a/b/c"), .intoItself)
    }

    func testOrdinaryMovesGoThrough() {
        XCTAssertEqual(
            RemotePath.planMove(of: "/a", named: "a", into: "/ab"), .to("/ab/a"))
        XCTAssertEqual(
            RemotePath.planMove(of: "/documents/novel.txt", named: "novel.txt", into: "/"),
            .to("/novel.txt"))
        XCTAssertEqual(
            RemotePath.planMove(of: "/a/b", named: "b", into: "/"), .to("/b"))
        XCTAssertEqual(
            RemotePath.planMove(of: "/a/b", named: "b", into: "/c"), .to("/c/b"))
    }

    // MARK: Messages

    func testNewMessagesAreTranslated() {
        for key in [
            "(unknown)",
            "storage %@",
            "Cannot move \"%@\" into \"%@\": that folder is inside the item being moved.",
            "The contents of \"%@\" could not be read from the display.",
        ] {
            XCTAssertNotNil(L.table[key], "no French translation for \"\(key)\"")
        }
    }

    func testListingFailureWithoutDetailIsOneLine() {
        let message = MTPError.listingFailed(path: "/documents", detail: "").description
        XCTAssertFalse(message.contains("\n"))
        XCTAssertTrue(message.contains("/documents"))
    }
}
