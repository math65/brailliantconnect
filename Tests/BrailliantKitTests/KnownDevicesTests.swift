import XCTest

@testable import BrailliantKit

/// Which devices are served, from the values a tester measured on his own
/// (27 Oct 2026): a Monarch, a StellarTrek, a BrailleNote Touch Plus.
final class KnownDevicesTests: XCTestCase {

    // MARK: From the USB descriptor (the agent)

    func testHumanWareVendorIDIsEnough() {
        // The Monarch: 1c71:d100, manufacturer "Humanware".
        XCTAssertTrue(
            KnownDevices.recognizes(
                vendorID: 0x1C71, manufacturer: nil, serialNumber: nil))
    }

    func testStellarTrekByItsManufacturer() {
        XCTAssertTrue(
            KnownDevices.recognizes(
                vendorID: 0x18D1, manufacturer: "Humanware", serialNumber: "332a20103312100254"))
        XCTAssertTrue(
            KnownDevices.recognizes(
                vendorID: 0x18D1, manufacturer: " HumanWare ", serialNumber: nil))
    }

    func testGooglePhoneIsNotTaken() {
        XCTAssertFalse(
            KnownDevices.recognizes(
                vendorID: 0x18D1, manufacturer: "Google", serialNumber: "650500000132"))
        XCTAssertFalse(
            KnownDevices.recognizes(
                vendorID: 0x18D1, manufacturer: nil, serialNumber: nil))
    }

    func testBrailleNoteBySerialNumber() {
        XCTAssertTrue(
            KnownDevices.recognizes(
                vendorID: 0x05C6, manufacturer: "Android", serialNumber: "650500000132"))
        XCTAssertTrue(
            KnownDevices.recognizes(
                vendorID: 0x05C6, manufacturer: "Android", serialNumber: "650400009999"))
    }

    func testQualcommPhoneIsNotTaken() {
        for serial in [
            "a1b2c3d4", "650480000707", "65050000013", "6505000001320", "750300001234", "",
        ] {
            XCTAssertFalse(
                KnownDevices.recognizes(
                    vendorID: 0x05C6, manufacturer: "Android", serialNumber: serial), serial)
        }
        XCTAssertFalse(
            KnownDevices.recognizes(
                vendorID: 0x05C6, manufacturer: "Humanware", serialNumber: nil))
    }

    func testOtherVendorsAreNotTaken() {
        // A BrailleNote's serial or the right manufacturer is not enough on
        // its own: only the vendors measured are looked at.
        XCTAssertFalse(
            KnownDevices.recognizes(
                vendorID: 0x04E8, manufacturer: "Humanware", serialNumber: "650500000132"))
    }

    // MARK: Over MTP, once opened (the extension, the tool)

    func testOnlyTheMeasuredVendorsAreOpened() {
        XCTAssertTrue(KnownDevices.mayBeKnown(vendorID: 0x1C71))
        XCTAssertTrue(KnownDevices.mayBeKnown(vendorID: 0x18D1))
        XCTAssertTrue(KnownDevices.mayBeKnown(vendorID: 0x05C6))
        XCTAssertFalse(KnownDevices.mayBeKnown(vendorID: 0x04E8))
        XCTAssertTrue(KnownDevices.needsNoConfirmation(vendorID: 0x1C71))
        XCTAssertFalse(KnownDevices.needsNoConfirmation(vendorID: 0x18D1))
        XCTAssertFalse(KnownDevices.needsNoConfirmation(vendorID: 0x05C6))
    }

    func testStellarTrekByItsModel() {
        XCTAssertTrue(
            KnownDevices.confirms(
                vendorID: 0x18D1, model: "StellarTrek", serialNumber: "332a20103312100254"))
        XCTAssertTrue(
            KnownDevices.confirms(
                vendorID: 0x18D1, model: "Stellar Trek", serialNumber: ""))
        XCTAssertFalse(
            KnownDevices.confirms(
                vendorID: 0x18D1, model: "Pixel 9", serialNumber: "650500000132"))
    }

    func testBrailleNoteBySerialOrModel() {
        XCTAssertTrue(
            KnownDevices.confirms(
                vendorID: 0x05C6, model: "BrailleNote Touch +", serialNumber: "650500000132"))
        XCTAssertTrue(
            KnownDevices.confirms(
                vendorID: 0x05C6, model: "", serialNumber: "650500000132"))
        XCTAssertTrue(
            KnownDevices.confirms(
                vendorID: 0x05C6, model: "BrailleNote Touch +", serialNumber: ""))
        XCTAssertFalse(
            KnownDevices.confirms(
                vendorID: 0x05C6, model: "OnePlus 2", serialNumber: "a1b2c3d4"))
    }
}
