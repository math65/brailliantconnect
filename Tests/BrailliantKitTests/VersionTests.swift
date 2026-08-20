import XCTest

@testable import BrailliantKit

/// Keeps the version the program reports and the version it is built as from
/// drifting apart.
///
/// They live in two files that nothing else connects: a Swift constant, read by
/// `brailliant --version` and by `doctor`, and `MARKETING_VERSION` in the Xcode
/// project, which is what ends up in the bundle a user downloads. Bumping one
/// and forgetting the other produces the worst kind of wrong answer — a
/// confident one, in the report someone sends when asking for help.
final class VersionTests: XCTestCase {

    /// The Xcode project, found from this file rather than the working
    /// directory: `swift test` may be run from anywhere.
    private var projectFile: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BrailliantKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("App/BrailliantConnect.xcodeproj/project.pbxproj")
    }

    func testVersionMatchesTheXcodeProject() throws {
        let project = try XCTUnwrap(
            try? String(contentsOf: projectFile, encoding: .utf8),
            "The Xcode project is committed and expected at \(projectFile.path)")

        let marketing =
            project
            .components(separatedBy: "MARKETING_VERSION = ")
            .dropFirst()
            .map { $0.prefix { $0 != ";" } }
            .map(String.init)

        XCTAssertFalse(marketing.isEmpty, "No MARKETING_VERSION in the Xcode project")
        for version in marketing {
            XCTAssertEqual(
                version, Version.current,
                "Version.current is \(Version.current) and the project builds \(version)")
        }
    }

    func testVersionLooksLikeAVersion() {
        XCTAssertTrue(
            Version.current.split(separator: ".").count >= 2,
            "\(Version.current) is not a version number")
    }
}
