import XCTest

@testable import BrailliantKit

final class DisplayClockTests: XCTestCase {

    private let paris = TimeZone(identifier: "Europe/Paris")!

    /// What libmtp's `mktime` produces from a wall-clock reading, on a Mac in
    /// Paris: the reading taken as Paris time.
    private func libmtpStamp(reading: String) -> Int {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = paris
        parser.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return Int(parser.date(from: reading)!.timeIntervalSince1970)
    }

    private func utc(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    /// The measured case: written at 23:37:39 UTC (01:37 in Paris), the display
    /// read "23:37:39", and libmtp turned that into 21:37:39 UTC.
    func testSummerReadingFromAUTCDisplayIsTheRealInstant() {
        let stamp = libmtpStamp(reading: "2026-10-14 23:37:39")
        XCTAssertEqual(stamp, 1_792_013_859)
        XCTAssertEqual(
            DisplayClock.instant(fromLibMTPStamp: stamp, clockOffset: 0, macZone: paris),
            utc("2026-10-14T23:37:39Z"))
    }

    /// In winter libmtp is off by one hour, not two: a constant would be wrong.
    func testWinterReadingIsCorrectedByOneHourOnly() {
        let stamp = libmtpStamp(reading: "2026-01-15 10:00:00")
        XCTAssertEqual(
            DisplayClock.instant(fromLibMTPStamp: stamp, clockOffset: 0, macZone: paris),
            utc("2026-01-15T10:00:00Z"))
    }

    /// A display set to Paris time: once its offset is known, dates are exact.
    func testDisplayOnLocalTimeWithKnownOffset() {
        let stamp = libmtpStamp(reading: "2026-10-15 01:37:39")
        XCTAssertEqual(
            DisplayClock.instant(fromLibMTPStamp: stamp, clockOffset: 7200, macZone: paris),
            utc("2026-10-14T23:37:39Z"))
    }

    func testCalibrationOnAUTCDisplayFindsZero() {
        let sent = utc("2026-10-14T23:37:30Z")
        let stamped = utc("2026-10-14T23:37:39Z")
        XCTAssertEqual(
            DisplayClock.offset(
                reading: stamped, readWith: 0, sentBetween: sent,
                and: sent.addingTimeInterval(20)),
            0)
    }

    /// Read as UTC first, a display on Paris time looks two hours ahead.
    func testCalibrationFindsALocalTimeDisplay() {
        let sent = utc("2026-10-14T23:37:30Z")
        let stamped = utc("2026-10-15T01:37:41Z")
        XCTAssertEqual(
            DisplayClock.offset(
                reading: stamped, readWith: 0, sentBetween: sent,
                and: sent.addingTimeInterval(20)),
            7200)
    }

    func testCalibrationRefusesAClockThatIsSimplyWrong() {
        let sent = utc("2026-10-14T23:37:30Z")
        XCTAssertNil(
            DisplayClock.offset(
                reading: sent.addingTimeInterval(600), readWith: 0, sentBetween: sent,
                and: sent.addingTimeInterval(5)))
    }

    func testCalibrationRefusesALongTransfer() {
        let sent = utc("2026-10-14T23:37:30Z")
        XCTAssertNil(
            DisplayClock.offset(
                reading: sent, readWith: 0, sentBetween: sent,
                and: sent.addingTimeInterval(600)))
    }

    func testOffsetIsRememberedPerSerial() {
        let defaults = UserDefaults(suiteName: "DisplayClockTests")!
        defaults.removePersistentDomain(forName: "DisplayClockTests")
        XCTAssertEqual(DisplayClock.storedOffset(forSerial: "A", in: defaults), 0)
        DisplayClock.store(3600, forSerial: "A", in: defaults)
        XCTAssertEqual(DisplayClock.storedOffset(forSerial: "A", in: defaults), 3600)
        XCTAssertEqual(DisplayClock.storedOffset(forSerial: "B", in: defaults), 0)
        DisplayClock.store(3600, forSerial: "", in: defaults)
        XCTAssertEqual(DisplayClock.storedOffset(forSerial: "", in: defaults), 0)
        defaults.removePersistentDomain(forName: "DisplayClockTests")
    }
}
