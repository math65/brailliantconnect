import XCTest

@testable import BrailliantKit

/// The decisions that keep exactly one agent — the new one — running after an
/// update, and the configuration Sparkle reads from the app's Info.plist.
final class UpdateHandoverTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func marker(
        ageSeconds: TimeInterval, from build: String = "7"
    )
        -> UpdateHandover.Marker
    {
        UpdateHandover.Marker(
            fromBuild: build, toVersion: "1.3.0", date: now.addingTimeInterval(-ageSeconds))
    }

    // MARK: Starting the resident agent

    func testNoMarkerProceeds() {
        XCTAssertEqual(
            UpdateHandover.step(marker: nil, now: now, diskBuild: "7", runningIsOnDisk: true),
            .proceed)
    }

    func testOldAgentWaitsUntilTheSwap() {
        // Restarted by KeepAlive before the installer swapped the bundle.
        XCTAssertEqual(
            UpdateHandover.step(
                marker: marker(ageSeconds: 2), now: now, diskBuild: "7", runningIsOnDisk: true),
            .wait)
    }

    func testOldAgentStartsTheNewVersionOnceSwapped() {
        // Same old process, a moment later: the file at the path is another one.
        XCTAssertEqual(
            UpdateHandover.step(
                marker: marker(ageSeconds: 3), now: now, diskBuild: "8", runningIsOnDisk: false),
            .startNewVersion)
    }

    func testSwapBetweenTheTwoReadsIsCaughtByTheInode() {
        // Build read before the swap, inode after it.
        XCTAssertEqual(
            UpdateHandover.step(
                marker: marker(ageSeconds: 3), now: now, diskBuild: "7", runningIsOnDisk: false),
            .startNewVersion)
    }

    func testNewAgentProceeds() {
        XCTAssertEqual(
            UpdateHandover.step(
                marker: marker(ageSeconds: 4), now: now, diskBuild: "8", runningIsOnDisk: true),
            .proceed)
    }

    func testUnreadableInfoPlistWaitsRatherThanGuessing() {
        XCTAssertEqual(
            UpdateHandover.step(
                marker: marker(ageSeconds: 1), now: now, diskBuild: nil, runningIsOnDisk: true),
            .wait)
    }

    func testStaleMarkerIsIgnored() {
        let stale = marker(ageSeconds: UpdateHandover.lifetime + 1)
        XCTAssertEqual(
            UpdateHandover.step(marker: stale, now: now, diskBuild: "7", runningIsOnDisk: true),
            .proceed)
        XCTAssertFalse(UpdateHandover.isRelaunchAfterUpdate(marker: stale, now: now))
    }

    func testMarkerFromTheFutureIsIgnored() {
        XCTAssertFalse(UpdateHandover.isFresh(marker(ageSeconds: -3600), now: now))
    }

    // MARK: Sparkle's relaunch

    func testRelaunchDuringHandoverLeavesLaunchdAlone() {
        XCTAssertTrue(UpdateHandover.isRelaunchAfterUpdate(marker: marker(ageSeconds: 5), now: now))
        XCTAssertFalse(UpdateHandover.isRelaunchAfterUpdate(marker: nil, now: now))
    }

    // MARK: Telling an update from a first install

    func testFirstInstallIsNotAnUpdate() {
        XCTAssertFalse(UpdateHandover.wasUpdated(previousBuild: nil, currentBuild: "8"))
        XCTAssertFalse(UpdateHandover.wasUpdated(previousBuild: "8", currentBuild: "8"))
        XCTAssertTrue(UpdateHandover.wasUpdated(previousBuild: "7", currentBuild: "8"))
        // A downgrade is not news, and "10" comes after "9", not before.
        XCTAssertFalse(UpdateHandover.wasUpdated(previousBuild: "103", currentBuild: "6"))
        XCTAssertTrue(UpdateHandover.wasUpdated(previousBuild: "9", currentBuild: "10"))
    }

    func testMarkerSurvivesTheUserDefaultsRoundTrip() {
        let original = marker(ageSeconds: 0)
        XCTAssertEqual(UpdateHandover.Marker(dictionary: original.dictionary), original)
        XCTAssertNil(UpdateHandover.Marker(dictionary: ["fromBuild": "7"]))
        XCTAssertNil(UpdateHandover.Marker(dictionary: nil))
    }

    // MARK: Configuration

    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BrailliantKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
    }

    private func appInfo() throws -> [String: Any] {
        let url = repository.appendingPathComponent("App/BrailliantConnect/Info.plist")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// From 1.2.2 the app reads docs/appcast.xml through GitHub Pages; 1.2.0
    /// and 1.2.1 still read appcast.xml at the root, through
    /// raw.githubusercontent.com. Both files must exist, or one generation of
    /// installed copies never hears of an update again.
    func testFeedIsTheCommittedAppcastOverHTTPS() throws {
        let feed = try XCTUnwrap(appInfo()["SUFeedURL"] as? String)
        XCTAssertEqual(feed, "https://math65.github.io/brailliantconnect/appcast.xml")
        for path in ["docs/appcast.xml", "appcast.xml"] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: repository.appendingPathComponent(path).path),
                "\(path) must be committed: a generation of installed copies reads it")
        }
    }

    /// Every item goes into both feeds: an old copy reaches the new feed only
    /// by installing a version that names it.
    func testBothFeedsOfferTheSameBuilds() throws {
        func builds(_ path: String) throws -> [String] {
            let document = try XMLDocument(
                contentsOf: repository.appendingPathComponent(path), options: [])
            return try document.nodes(forXPath: "//item/*[local-name()='version']")
                .compactMap { $0.stringValue }
        }
        XCTAssertEqual(try builds("docs/appcast.xml"), try builds("appcast.xml"))
    }

    /// The key is either the marked placeholder — which `make-dist.sh` refuses
    /// to ship — or a real Ed25519 public key: 32 bytes, in base64.
    func testPublicKeyIsThePlaceholderOrAValidKey() throws {
        let key = try XCTUnwrap(appInfo()["SUPublicEDKey"] as? String)
        if key.hasPrefix("PLACEHOLDER") { return }
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32, "SUPublicEDKey is not an Ed25519 key")
    }

    func testScheduledUpdatesInstallOnTheirOwn() throws {
        let info = try appInfo()
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, true)
        XCTAssertEqual(info["SUScheduledCheckInterval"] as? Int, 86_400)
    }

    func testAppcastIsWellFormed() throws {
        for path in ["docs/appcast.xml", "appcast.xml"] {
            let url = repository.appendingPathComponent(path)
            XCTAssertNoThrow(try XMLDocument(contentsOf: url, options: []), path)
        }
    }

    func testUpdateMessagesAreTranslated() {
        for key in [
            "Check for Updates…",
            "Updated to %@ on %@",
            "BrailliantConnect %@ installed",
            "The update is in place and BrailliantConnect is running again.",
            "BrailliantConnect %@ is available",
            "Choose Check for Updates… in the BrailliantConnect menu to install it.",
        ] {
            XCTAssertNotNil(L.table[key], "no French translation for \"\(key)\"")
        }
    }
}
