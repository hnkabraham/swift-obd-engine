import Foundation
import XCTest

#if SWIFT_PACKAGE
@testable import OBDModels
@testable import OBDEngine
#else
#endif

/// A reading outside its configured envelope is the diagnosis, not a decode
/// failure. These tests pin the difference between an excursion (kept, flagged)
/// and an adapter that returned nothing usable (the only unsupported case).
final class CustomPIDRangeHandlingTests: XCTestCase {
    private struct RangeCase {
        let label: String
        let responseBytes: [UInt8]
        let expectedValue: Double
        let expectedStatus: CustomPIDRangeStatus
    }

    /// `A * 2` over a 10…100 envelope, so one response byte can land on either
    /// side of both bounds as well as exactly on them.
    private static let rangeCases: [RangeCase] = [
        RangeCase(
            label: "below minimum",
            responseBytes: [0x00],
            expectedValue: 0,
            expectedStatus: .belowMinimum
        ),
        RangeCase(
            label: "at minimum",
            responseBytes: [0x05],
            expectedValue: 10,
            expectedStatus: .withinRange
        ),
        RangeCase(
            label: "in range",
            responseBytes: [0x1E],
            expectedValue: 60,
            expectedStatus: .withinRange
        ),
        RangeCase(
            label: "at maximum",
            responseBytes: [0x32],
            expectedValue: 100,
            expectedStatus: .withinRange
        ),
        RangeCase(
            label: "above maximum",
            responseBytes: [0x50],
            expectedValue: 160,
            expectedStatus: .aboveMaximum
        ),
    ]

    func testReadingKeepsOutOfRangeValuesAndFlagsTheExcursion() throws {
        let definition = try makeRangeDefinition()

        for testCase in Self.rangeCases {
            let reading = try definition.reading(
                from: testCase.responseBytes
            )

            XCTAssertEqual(
                reading.value,
                testCase.expectedValue,
                accuracy: 0.000_001,
                testCase.label
            )
            XCTAssertEqual(
                reading.rangeStatus,
                testCase.expectedStatus,
                testCase.label
            )
            XCTAssertEqual(
                reading.isOutOfRange,
                testCase.expectedStatus != .withinRange,
                testCase.label
            )
            XCTAssertEqual(
                definition.valueRange.status(for: reading.value),
                testCase.expectedStatus,
                testCase.label
            )
        }
    }

    func testOutOfRangeValuesAreNeverReportedAsUnsupported() throws {
        let definition = try makeRangeDefinition()

        for testCase in Self.rangeCases {
            XCTAssertEqual(
                try definition.scaledValue(from: testCase.responseBytes),
                testCase.expectedValue,
                accuracy: 0.000_001,
                testCase.label
            )
        }
    }

    func testDecodingFailsOnlyWhenThereIsNoUsableResponse() throws {
        let definition = try makeRangeDefinition()

        XCTAssertThrowsError(try definition.reading(from: [])) { error in
            XCTAssertEqual(
                error as? CustomPIDValidationError,
                .missingResponseByte(0)
            )
        }

        let twoByte = try makeRangeDefinition(
            responseByteCount: 2,
            formula: "A / (B - B)"
        )
        XCTAssertThrowsError(try twoByte.reading(from: [0x0A, 0x00])) { error in
            XCTAssertEqual(
                error as? CustomPIDValidationError,
                .divisionByZero
            )
        }
    }

    func testStrictDecodeStillEnforcesRangeForPackAuthoring() throws {
        let definition = try makeRangeDefinition()

        for testCase in Self.rangeCases {
            if testCase.expectedStatus == .withinRange {
                XCTAssertEqual(
                    try definition.validatedScaledValue(
                        from: testCase.responseBytes
                    ),
                    testCase.expectedValue,
                    accuracy: 0.000_001,
                    testCase.label
                )
            } else {
                XCTAssertThrowsError(
                    try definition.validatedScaledValue(
                        from: testCase.responseBytes
                    ),
                    testCase.label
                ) { error in
                    XCTAssertEqual(
                        error as? CustomPIDValidationError,
                        .resultOutOfRange
                    )
                }
            }
        }
    }

    func testReadingDecodesLegacyPayloadWithoutRangeStatus() throws {
        let legacy = Data(#"{"value":160}"#.utf8)

        let decoded = try JSONDecoder().decode(
            CustomPIDReading.self,
            from: legacy
        )

        XCTAssertEqual(decoded.value, 160, accuracy: 0)
        XCTAssertEqual(decoded.rangeStatus, .withinRange)
        XCTAssertFalse(decoded.isOutOfRange)

        let flagged = CustomPIDReading(
            value: -5,
            rangeStatus: .belowMinimum
        )
        let roundTrip = try JSONDecoder().decode(
            CustomPIDReading.self,
            from: try JSONEncoder().encode(flagged)
        )
        XCTAssertEqual(roundTrip, flagged)
    }

    func testReadCustomPIDReportsExcursionsAndFailsOnlyOnNoUsableData() async throws {
        let definition = try makeRangeDefinition()

        let overRange = OBDService(
            commandTransport: CustomPIDRangeScriptedTransport(
                response: "7E8 03 41 0C 50>"
            )
        )
        let reading = try await overRange.readCustomPID(definition)
        XCTAssertEqual(reading.value, 160, accuracy: 0.000_001)
        XCTAssertEqual(
            reading.rangeStatus,
            .aboveMaximum,
            "The excursion flag travels with the value to the display"
        )

        let noData = OBDService(
            commandTransport: CustomPIDRangeScriptedTransport(
                response: "NO DATA>"
            )
        )
        do {
            _ = try await noData.readCustomPID(definition)
            XCTFail("An adapter with no data must not report a reading")
        } catch let OBDError.unsupportedByVehicle(.commandFailed(message)) {
            XCTAssertTrue(message.contains("NO DATA"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let negative = OBDService(
            commandTransport: CustomPIDRangeScriptedTransport(
                response: "7E8 03 7F 01 11>"
            )
        )
        do {
            _ = try await negative.readCustomPID(definition)
            XCTFail("An ECU negative response must not report a reading")
        } catch let OBDError.unsupportedByVehicle(.commandFailed(message)) {
            XCTAssertTrue(message.contains("Service 01 not supported"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeRangeDefinition(
        responseByteCount: Int = 1,
        formula: String = "A * 2",
        minimum: Double = 10,
        maximum: Double = 100
    ) throws -> CustomPIDDefinition {
        try CustomPIDDefinition(
            id: UUID(uuidString: "F11E0000-0000-0000-0000-0000000000A1")!,
            request: CustomPIDRequest(service: "01", parameter: "0C"),
            name: "Synthetic range fixture",
            description: "A test-only value with no OEM meaning.",
            responseByteCount: responseByteCount,
            formula: BoundedPIDFormula(formula),
            unit: .unitless,
            valueRange: CustomPIDValueRange(
                minimum: minimum,
                maximum: maximum
            ),
            displayPrecision: 1,
            category: .custom
        )
    }
}

private final class CustomPIDRangeScriptedTransport:
    OBDCommandTransport,
    @unchecked Sendable
{
    let isConnected = true

    private let response: String

    init(response: String) {
        self.response = response
    }

    func sendCommand(_ command: ELM327Command) async throws -> String {
        response
    }
}
