import Foundation
import XCTest

#if SWIFT_PACKAGE
@testable import OBDModels
@testable import OBDEngine
#else
#endif

final class OBDParserTransportBoundaryTests: XCTestCase {
    private let parser = OBDParser()

    func testInterleaved29BitISOTPRepliesRemainAttributed() {
        let response = """
        18DAF110 10 0A 49 02 01 41 42 43
        18DAF111 10 0A 49 02 01 51 52 53
        18DAF110 21 44 45 46 47 00 00 00
        18DAF111 21 54 55 56 57 00 00 00
        >
        """

        let payloads = parser.addressedResponsePayloads(from: response)

        XCTAssertEqual(payloads.count, 2)
        XCTAssertEqual(payloads[0].sourceAddress, "18DAF110")
        XCTAssertEqual(
            payloads[0].bytes,
            [0x49, 0x02, 0x01, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47]
        )
        XCTAssertEqual(payloads[1].sourceAddress, "18DAF111")
        XCTAssertEqual(
            payloads[1].bytes,
            [0x49, 0x02, 0x01, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57]
        )
    }

    func testISOTPSequenceWrapsFromTwoFToTwoZero() throws {
        let expectedLength = 114
        var lines = [
            "18DAF110 10 72 49 02 01 41 42 43",
        ]
        for sequence in 1...15 {
            let marker = String(format: "%02X", 0x20 | sequence)
            lines.append(
                "18DAF110 \(marker) 44 45 46 47 48 49 4A"
            )
        }
        lines.append("18DAF110 20 4B 4C 4D 4E 4F 50 51")

        let payload = try XCTUnwrap(
            parser.addressedResponsePayloads(
                from: lines.joined(separator: "\r") + "\r>"
            ).first
        )

        XCTAssertEqual(payload.sourceAddress, "18DAF110")
        XCTAssertEqual(payload.bytes.count, expectedLength)
        XCTAssertEqual(payload.bytes.prefix(6), [0x49, 0x02, 0x01, 0x41, 0x42, 0x43])
        XCTAssertEqual(payload.bytes.suffix(3), [0x4B, 0x4C, 0x4D])
    }

    func testMalformedResponderDoesNotPoisonAnotherECUAssembly() {
        let response = """
        18DAF110 10 0A 49 02 01 41 42 43
        18DAF111 10 0A 49 02 01 51 52 53
        18DAF111 22 54 55 56 57 00 00 00
        18DAF110 21 44 45 46 47 00 00 00
        >
        """

        let payloads = parser.addressedResponsePayloads(from: response)

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads.first?.sourceAddress, "18DAF110")
        XCTAssertEqual(
            payloads.first?.bytes,
            [0x49, 0x02, 0x01, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47]
        )
    }

    // The transport-side accumulator, `OBDConnectionManager.ingestIncomingData`,
    // is private and only reachable by driving the `OBDBluetoothCentral` seam.
    // This covers the parser half of the contract only: no fragment is
    // independently parseable, and the buffer the transport hands over parses
    // once the prompt arrives.
    func testCANLineSplitAcrossNotificationsParsesOnlyOnceConcatenated() throws {
        let notifications = [
            "7E8 06 41",
            " 01 00 07",
            " 00 00\r",
            ">",
        ]

        for notification in notifications {
            XCTAssertNil(
                parser.parseReadinessMonitors(from: notification),
                "Fragment \(notification) must not decode on its own"
            )
        }

        let monitors = try XCTUnwrap(
            parser.parseReadinessMonitors(
                from: notifications.joined()
            )
        )

        XCTAssertFalse(monitors.isEmpty)
        XCTAssertEqual(
            monitors.first(where: { $0.name == "Misfire" })?.isSupported,
            true
        )
    }
}
