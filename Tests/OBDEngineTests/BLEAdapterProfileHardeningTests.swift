import XCTest

#if SWIFT_PACKAGE
@testable import OBDEngine
#else
#endif

final class BLEAdapterProfileHardeningTests: XCTestCase {
    func testKnownServiceSetIncludesFFF0AndNordicUART() {
        XCTAssertTrue(BLEAdapterProfileResolver.knownServiceUUIDs.contains(
            "FFF0"
        ))
        XCTAssertTrue(BLEAdapterProfileResolver.knownServiceUUIDs.contains(
            "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
        ))
    }

    func testNordicUARTUsesExactSameServiceRoles() throws {
        let service = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
        let write = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
        let notify = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
        let candidates = [
            candidate(service, notify, notify: true),
            candidate(service, write, writeWithoutResponse: true),
        ]

        for ordering in [candidates, candidates.reversed().map { $0 }] {
            let profile = try XCTUnwrap(
                BLEAdapterProfileResolver.resolve(ordering)
            )
            XCTAssertEqual(profile.kind, .nordicUART)
            XCTAssertEqual(profile.serviceUUID, service)
            XCTAssertEqual(profile.writeUUID, write)
            XCTAssertEqual(profile.notifyUUID, notify)
        }
    }

    func testNordicUARTNeverPairsAcrossServices() {
        XCTAssertNil(BLEAdapterProfileResolver.resolve([
            candidate(
                "6E400001-B5A3-F393-E0A9-E50E24DCCA9E",
                "6E400002-B5A3-F393-E0A9-E50E24DCCA9E",
                writeWithoutResponse: true
            ),
            candidate(
                "ABCD",
                "6E400003-B5A3-F393-E0A9-E50E24DCCA9E",
                notify: true
            ),
        ]))
    }

    func testCompleteKnownProfileWinsOverIncompleteKnownService() throws {
        let profile = try XCTUnwrap(BLEAdapterProfileResolver.resolve([
            candidate("FFF0", "FFF1", notify: true),
            candidate(
                "6E400001-B5A3-F393-E0A9-E50E24DCCA9E",
                "6E400002-B5A3-F393-E0A9-E50E24DCCA9E",
                writeWithoutResponse: true
            ),
            candidate(
                "6E400001-B5A3-F393-E0A9-E50E24DCCA9E",
                "6E400003-B5A3-F393-E0A9-E50E24DCCA9E",
                notify: true
            ),
        ]))

        XCTAssertEqual(profile.kind, .nordicUART)
    }

    func testSafeFFF0BidirectionalCloneVariants() throws {
        for uuid in ["FFF1", "FFF2"] {
            let profile = try XCTUnwrap(
                BLEAdapterProfileResolver.resolve([
                    candidate(
                        "FFF0",
                        uuid,
                        writeWithoutResponse: true,
                        notify: true
                    ),
                ])
            )
            XCTAssertEqual(profile.kind, .fffUART)
            XCTAssertEqual(profile.writeUUID, uuid)
            XCTAssertEqual(profile.notifyUUID, uuid)
        }
    }

    func testSafeFFF0ReversedSplitCloneVariant() throws {
        let profile = try XCTUnwrap(BLEAdapterProfileResolver.resolve([
            candidate("FFF0", "FFF1", writeWithoutResponse: true),
            candidate("FFF0", "FFF2", notify: true),
        ]))

        XCTAssertEqual(profile.kind, .fffUART)
        XCTAssertEqual(profile.writeUUID, "FFF1")
        XCTAssertEqual(profile.notifyUUID, "FFF2")
    }

    func testUnknownFFF0PairDoesNotFallThroughToGeneric() {
        XCTAssertNil(BLEAdapterProfileResolver.resolve([
            candidate("FFF0", "FFF4", writeWithoutResponse: true),
            candidate("FFF0", "FFF5", notify: true),
        ]))
    }

    private func candidate(
        _ service: String,
        _ characteristic: String,
        write: Bool = false,
        writeWithoutResponse: Bool = false,
        notify: Bool = false
    ) -> BLECharacteristicCandidate {
        BLECharacteristicCandidate(
            serviceUUID: service,
            characteristicUUID: characteristic,
            canWriteWithResponse: write,
            canWriteWithoutResponse: writeWithoutResponse,
            canNotify: notify
        )
    }
}
