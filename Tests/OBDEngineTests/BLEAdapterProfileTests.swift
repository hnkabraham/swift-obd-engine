import XCTest

#if SWIFT_PACKAGE
@testable import OBDEngine
#else
#endif

final class BLEAdapterProfileTests: XCTestCase {
    func testOBDLinkCXUsesFFF2ForWritesAndFFF1ForNotifications() throws {
        let candidates = [
            candidate("FFF0", "FFF1", notify: true),
            candidate("FFF0", "FFF2", write: true, writeWithoutResponse: true),
        ]

        for ordering in [candidates, Array(candidates.reversed())] {
            let profile = try XCTUnwrap(
                BLEAdapterProfileResolver.resolve(ordering)
            )
            XCTAssertEqual(profile.kind, .obdLinkCX)
            XCTAssertEqual(profile.serviceUUID, "FFF0")
            XCTAssertEqual(profile.writeUUID, "FFF2")
            XCTAssertEqual(profile.notifyUUID, "FFF1")
            XCTAssertEqual(profile.writeStrategy, .withResponse)
        }
    }

    func testNotificationOnlyFFF1CanNeverBecomeAWriter() {
        let profile = BLEAdapterProfileResolver.resolve([
            candidate("FFF0", "FFF1", notify: true),
        ])

        XCTAssertNil(profile)
    }

    func testRecognizedOBDLinkServiceDoesNotFallBackWhenFFF2IsInvalid() {
        let profile = BLEAdapterProfileResolver.resolve([
            candidate("FFF0", "FFF1", notify: true),
            candidate("FFF0", "FFF2"),
            candidate("FFF0", "FFF3", write: true),
        ])

        XCTAssertNil(profile)
    }

    func testCommonBidirectionalUARTProfilesResolveByCapabilities() throws {
        let layouts: [(String, String, ResolvedBLEAdapterProfile.Kind)] = [
            (
                "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2",
                "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F",
                .elmUART
            ),
            ("FFE0", "FFE1", .ffeUART),
            (
                "49535343-FE7D-4AE5-8FA9-9FAFD205E455",
                "49535343-8841-43F4-A8D4-ECBE34729BB3",
                .isscUART
            ),
        ]

        for (service, characteristic, expectedKind) in layouts {
            let profile = try XCTUnwrap(BLEAdapterProfileResolver.resolve([
                candidate(
                    service,
                    characteristic,
                    writeWithoutResponse: true,
                    notify: true
                ),
            ]))
            XCTAssertEqual(profile.kind, expectedKind)
            XCTAssertEqual(profile.writeUUID, characteristic)
            XCTAssertEqual(profile.notifyUUID, characteristic)
            XCTAssertEqual(profile.writeStrategy, .withoutResponse)
        }
    }

    func testGenericFallbackKeepsBothEndpointsInOneService() throws {
        let profile = try XCTUnwrap(BLEAdapterProfileResolver.resolve([
            candidate("ABCD", "0001", write: true),
            candidate("ABCD", "0002", indicate: true),
        ]))

        XCTAssertEqual(profile.kind, .genericUART)
        XCTAssertEqual(profile.serviceUUID, "ABCD")
        XCTAssertEqual(profile.writeUUID, "0001")
        XCTAssertEqual(profile.notifyUUID, "0002")
    }

    func testGenericFallbackNeverCombinesDifferentServices() {
        let profile = BLEAdapterProfileResolver.resolve([
            candidate("AAAA", "0001", write: true),
            candidate("BBBB", "0002", notify: true),
        ])

        XCTAssertNil(profile)
    }

    func testKnownProfileWinsOverLexicallyEarlierGenericService() throws {
        let profile = try XCTUnwrap(BLEAdapterProfileResolver.resolve([
            candidate("0001", "0002", write: true, notify: true),
            candidate("FFE0", "FFE1", write: true, notify: true),
        ]))

        XCTAssertEqual(profile.kind, .ffeUART)
    }

    func testBluetoothBaseUUIDAndShortUUIDCanonicalizeIdentically() throws {
        let profile = try XCTUnwrap(BLEAdapterProfileResolver.resolve([
            candidate(
                "0000FFF0-0000-1000-8000-00805F9B34FB",
                "0000FFF1-0000-1000-8000-00805F9B34FB",
                notify: true
            ),
            candidate(
                "FFF0",
                "0000FFF2-0000-1000-8000-00805F9B34FB",
                write: true
            ),
        ]))

        XCTAssertEqual(profile.kind, .obdLinkCX)
        XCTAssertEqual(profile.serviceUUID, "FFF0")
        XCTAssertEqual(profile.writeUUID, "FFF2")
        XCTAssertEqual(profile.notifyUUID, "FFF1")
    }

    func testIdleBluetoothStateChangesDoNotCreateUnsolicitedConnectionErrors() {
        XCTAssertFalse(OBDConnectionManager.shouldSurfaceCentralFailure(
            status: .disconnected,
            pendingScanRequest: false
        ))
        XCTAssertFalse(OBDConnectionManager.shouldSurfaceCentralFailure(
            status: .disconnecting,
            pendingScanRequest: false
        ))
        XCTAssertFalse(OBDConnectionManager.shouldSurfaceCentralFailure(
            status: .error("Previous failure"),
            pendingScanRequest: false
        ))
    }

    func testBluetoothFailuresSurfaceDuringConnectionWorkOrAnActiveSession() {
        XCTAssertTrue(OBDConnectionManager.shouldSurfaceCentralFailure(
            status: .disconnected,
            pendingScanRequest: true
        ))

        XCTAssertTrue(OBDConnectionManager.shouldSurfaceCentralFailure(
            status: .scanning,
            pendingScanRequest: false
        ))
        XCTAssertTrue(OBDConnectionManager.shouldSurfaceCentralFailure(
            status: .connecting,
            pendingScanRequest: false
        ))
        XCTAssertTrue(OBDConnectionManager.shouldSurfaceCentralFailure(
            status: .connected,
            pendingScanRequest: false
        ))
    }

    func testCoreBluetoothFailureNeverRetiresAnActiveMFiRoute() {
        XCTAssertFalse(OBDConnectionManager.shouldSurfaceCentralFailure(
            status: .connected,
            pendingScanRequest: false,
            activeConnectionType: .mfi
        ))
        XCTAssertFalse(OBDConnectionManager.shouldSurfaceCentralFailure(
            status: .connecting,
            pendingScanRequest: true,
            activeConnectionType: .mfi
        ))
        XCTAssertTrue(OBDConnectionManager.shouldSurfaceCentralFailure(
            status: .connected,
            pendingScanRequest: false,
            activeConnectionType: .ble
        ))
    }

    private func candidate(
        _ service: String,
        _ characteristic: String,
        write: Bool = false,
        writeWithoutResponse: Bool = false,
        notify: Bool = false,
        indicate: Bool = false
    ) -> BLECharacteristicCandidate {
        BLECharacteristicCandidate(
            serviceUUID: service,
            characteristicUUID: characteristic,
            canWriteWithResponse: write,
            canWriteWithoutResponse: writeWithoutResponse,
            canNotify: notify,
            canIndicate: indicate
        )
    }
}
