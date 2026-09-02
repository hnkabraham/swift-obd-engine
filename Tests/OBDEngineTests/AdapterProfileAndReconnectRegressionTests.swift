import XCTest

#if SWIFT_PACKAGE
@testable import OBDEngine
#else
#endif

/// Split-role layouts are common on shipping serial adapters: the documented
/// service is present, but its read and write roles live on two characteristics
/// instead of the single bidirectional one the profile table expects. Those
/// adapters must still resolve through generic same-service pairing, and the
/// recognized serial service has to win that pass over an unrelated service
/// whose UUID merely sorts earlier.
///
/// Despite the name, nothing here covers reconnect. The remembered-adapter
/// fallback lives on `OBDConnectionManager`, whose CoreBluetooth transport is
/// substitutable through the `OBDBluetoothCentral` seam, so its recovery rules
/// belong in a fixture-driven test against that seam rather than here.
final class AdapterProfileAndReconnectRegressionTests: XCTestCase {
    func testMicrochipTransparentUARTSplitRolesResolve() throws {
        let service = "49535343-FE7D-4AE5-8FA9-9FAFD205E455"
        let notifyOnly = "49535343-1E4D-4BD9-BA61-23C647249616"
        let writeOnly = "49535343-8841-43F4-A8D4-ECBE34729BB3"
        let candidates = [
            candidate(service, notifyOnly, notify: true),
            candidate(service, writeOnly, writeWithoutResponse: true),
        ]

        for ordering in [candidates, candidates.reversed().map { $0 }] {
            let profile = try XCTUnwrap(
                BLEAdapterProfileResolver.resolve(ordering)
            )
            XCTAssertEqual(profile.kind, .genericUART)
            XCTAssertEqual(profile.serviceUUID, service)
            XCTAssertEqual(profile.writeUUID, writeOnly)
            XCTAssertEqual(profile.notifyUUID, notifyOnly)
            XCTAssertEqual(profile.writeStrategy, .withoutResponse)
        }
    }

    func testFFE0SplitRoleCloneResolves() throws {
        let profile = try XCTUnwrap(BLEAdapterProfileResolver.resolve([
            candidate("FFE0", "FFE1", notify: true),
            candidate("FFE0", "FFE2", write: true),
        ]))

        XCTAssertEqual(profile.kind, .genericUART)
        XCTAssertEqual(profile.serviceUUID, "FFE0")
        XCTAssertEqual(profile.writeUUID, "FFE2")
        XCTAssertEqual(profile.notifyUUID, "FFE1")
        XCTAssertEqual(profile.writeStrategy, .withResponse)
    }

    /// A Nordic legacy DFU control point sorts before every recognized serial
    /// service and advertises write plus notify, so lexicographic ordering
    /// alone would send the whole `ATZ`/`ATE0` setup sequence to a
    /// firmware-update endpoint instead of the split-role FFE0 pair beside it.
    func testSplitRoleSerialServiceBeatsAnEarlierSortingUnrelatedService()
        throws {
        let dfuService = "00001530-1212-EFDE-1523-785FEABCD123"
        let dfuControlPoint = "00001531-1212-EFDE-1523-785FEABCD123"
        let candidates = [
            candidate(dfuService, dfuControlPoint, write: true, notify: true),
            candidate("FFE0", "FFE1", notify: true),
            candidate("FFE0", "FFE2", write: true),
        ]

        for ordering in [candidates, candidates.reversed().map { $0 }] {
            let profile = try XCTUnwrap(
                BLEAdapterProfileResolver.resolve(ordering)
            )
            XCTAssertEqual(profile.kind, .genericUART)
            XCTAssertEqual(profile.serviceUUID, "FFE0")
            XCTAssertEqual(profile.writeUUID, "FFE2")
            XCTAssertEqual(profile.notifyUUID, "FFE1")
        }
    }

    /// The same precedence has to hold for the long-form serial services, so a
    /// recognized layout is never decided by where its UUID happens to sort.
    func testMicrochipSplitRolesOutrankAnEarlierSortingService() throws {
        let service = "49535343-FE7D-4AE5-8FA9-9FAFD205E455"
        let notifyOnly = "49535343-1E4D-4BD9-BA61-23C647249616"
        let writeOnly = "49535343-8841-43F4-A8D4-ECBE34729BB3"

        let profile = try XCTUnwrap(BLEAdapterProfileResolver.resolve([
            candidate("0001", "0002", write: true, notify: true),
            candidate(service, notifyOnly, notify: true),
            candidate(service, writeOnly, writeWithoutResponse: true),
        ]))

        XCTAssertEqual(profile.kind, .genericUART)
        XCTAssertEqual(profile.serviceUUID, service)
        XCTAssertEqual(profile.writeUUID, writeOnly)
        XCTAssertEqual(profile.notifyUUID, notifyOnly)
    }

    func testProprietaryUARTSurvivesAnUnrelatedRecognizedService() throws {
        let profile = try XCTUnwrap(BLEAdapterProfileResolver.resolve([
            candidate("FFE0", "FFE1", notify: true),
            candidate("ABCD", "0001", writeWithoutResponse: true, notify: true),
        ]))

        XCTAssertEqual(profile.kind, .genericUART)
        XCTAssertEqual(profile.serviceUUID, "ABCD")
        XCTAssertEqual(profile.writeUUID, "0001")
        XCTAssertEqual(profile.notifyUUID, "0001")
    }

    func testSplitRolesNeverPairAcrossTwoServices() {
        XCTAssertNil(BLEAdapterProfileResolver.resolve([
            candidate(
                "49535343-FE7D-4AE5-8FA9-9FAFD205E455",
                "49535343-8841-43F4-A8D4-ECBE34729BB3",
                writeWithoutResponse: true
            ),
            candidate(
                "ABCD",
                "49535343-1E4D-4BD9-BA61-23C647249616",
                notify: true
            ),
        ]))

        XCTAssertNil(BLEAdapterProfileResolver.resolve([
            candidate("FFE0", "FFE2", write: true),
            candidate("ABCD", "0002", notify: true),
        ]))
    }

    func testFFF0KeepsItsStrictRoles() throws {
        let profile = try XCTUnwrap(BLEAdapterProfileResolver.resolve([
            candidate("FFF0", "FFF1", notify: true),
            candidate("FFF0", "FFF2", write: true),
        ]))
        XCTAssertEqual(profile.kind, .obdLinkCX)
        XCTAssertEqual(profile.writeUUID, "FFF2")
        XCTAssertEqual(profile.notifyUUID, "FFF1")

        // An FFF0 characteristic outside the documented roles is a control
        // endpoint, so it never becomes a generic UART even when it advertises
        // both properties.
        XCTAssertNil(BLEAdapterProfileResolver.resolve([
            candidate("FFF0", "FFF3", writeWithoutResponse: true, notify: true),
        ]))
        XCTAssertNil(BLEAdapterProfileResolver.resolve([
            candidate("FFF0", "FFF1", notify: true),
            candidate("FFF0", "FFF3", write: true),
        ]))
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
