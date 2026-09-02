import Foundation
import XCTest

#if SWIFT_PACKAGE
@testable import OBDModels
@testable import OBDEngine
#else
#endif

final class OBDTransportReassemblyTests: XCTestCase {
    private let parser = OBDParser()

    func testDTCParserReassemblesISOTPAndHonorsDeclaredLength() {
        // ISO 15765-4: `43 <count> <count × 2 bytes>`, declared length 0x08.
        // The trailing P0171 pair falls outside the declared length and must
        // not be decoded.
        let response = """
        7E8 10 08 43 03 01 33 03
        7E8 21 00 C1 00 01 71 FF FF
        >
        """

        XCTAssertEqual(
            parser.parseDTCs(from: response),
            ["P0133", "P0300", "U0100"]
        )
        XCTAssertFalse(parser.parseDTCs(from: response).contains("P0171"))
    }

    func testDTCParserRejectsOutOfSequenceISOTPContinuation() {
        let response = """
        7E8 10 08 43 03 01 33 03
        7E8 22 00 C1 00 00 00 00 00
        >
        """

        XCTAssertTrue(parser.parseDTCs(from: response).isEmpty)
    }

    func testInterleavedISOTPResponsesRemainBoundToTheirSourceECU() {
        let response = """
        7E8 10 14 49 02 01 31 48 47
        7E9 10 14 49 02 01 31 4D 38
        7E8 21 43 4D 38 32 36 33 33
        7E9 21 47 44 4D 39 41 58 4B
        7E8 22 41 30 30 34 33 35 32
        7E9 22 50 30 34 32 37 38 38
        >
        """

        let payloads = parser.addressedResponsePayloads(from: response)

        XCTAssertEqual(payloads.map(\.sourceAddress), ["7E8", "7E9"])
        XCTAssertEqual(
            String(bytes: payloads[0].bytes.dropFirst(3), encoding: .ascii),
            "1HGCM82633A004352"
        )
        XCTAssertEqual(
            String(bytes: payloads[1].bytes.dropFirst(3), encoding: .ascii),
            "1M8GDM9AXKP042788"
        )
    }

    func testBadSequenceInvalidatesOnlyTheAffectedECU() {
        let response = """
        7E8 10 14 49 02 01 31 48 47
        7E9 10 14 49 02 01 31 4D 38
        7E8 22 43 4D 38 32 36 33 33
        7E9 21 47 44 4D 39 41 58 4B
        7E9 22 50 30 34 32 37 38 38
        >
        """

        let payloads = parser.addressedResponsePayloads(from: response)

        XCTAssertEqual(payloads.map(\.sourceAddress), ["7E9"])
        XCTAssertEqual(parser.parseVIN(from: response), "1M8GDM9AXKP042788")
    }

    func testISO9141HeaderAndChecksumAreRemovedBeforePIDParsing() throws {
        let response = "48 6B 10 41 0C 2E E0 1E>"

        let addressed = try XCTUnwrap(
            parser.addressedResponsePayloads(from: response).first
        )
        let rpm = parser.parsePIDResponse(
            response,
            definition: StandardPIDLibrary.engineRPM
        )

        XCTAssertEqual(addressed.sourceAddress, "486B10")
        XCTAssertEqual(addressed.bytes, [0x41, 0x0C, 0x2E, 0xE0])
        XCTAssertEqual(rpm?.value ?? -1, 3_000, accuracy: 0.001)
    }

    func testKWPHeaderAndChecksumAreRemovedBeforePIDParsing() throws {
        let response = "86 F1 10 41 0C 2E E0 E2>"

        let addressed = try XCTUnwrap(
            parser.addressedResponsePayloads(from: response).first
        )

        XCTAssertEqual(addressed.sourceAddress, "86F110")
        XCTAssertEqual(addressed.bytes, [0x41, 0x0C, 0x2E, 0xE0])
        XCTAssertEqual(
            parser.parsePIDResponse(
                response,
                definition: StandardPIDLibrary.engineRPM
            )?.value ?? -1,
            3_000,
            accuracy: 0.001
        )
    }

    func testLegacyHeaderDTCResponseIsNotDecodedAsCANCountPrefixed() {
        // ISO 9141-2 with ATH1: `48 6B <addr> 43 <pairs…> <checksum>`. The
        // additive checksum validates and the header is stripped into a
        // source address, but a legacy Mode 03 reply has NO count byte —
        // decoding it as CAN would consume P0133's high byte as a count and
        // report a wrong code instead.
        let response = "48 6B 10 43 01 33 00 00 3A>"

        XCTAssertEqual(
            parser.parseDTCs(from: response),
            ["P0133"],
            "A stripped legacy header must not route DTCs through CAN count-prefixed decoding"
        )
    }

    func testLegacyHeaderMultipleDTCsDecodeInWireOrder() {
        // Two codes (P0133, P0300) padded to frame width. Under CAN-style
        // decoding this reads count=0x01 from P0133's high byte and reports
        // only a shifted P0300.
        let response = "48 6B 10 43 01 33 03 00 3D>"

        XCTAssertEqual(
            parser.parseDTCs(from: response),
            ["P0133", "P0300"]
        )
    }

    func testCANCountPrefixedDTCResponseStillUsesTheCountByte() {
        // The same payload shape WITH a CAN header (18DA…) is genuinely
        // count-prefixed and must keep using it.
        let response = "18DAF110 04 43 01 01 33"

        XCTAssertEqual(
            parser.parseDTCs(from: response),
            ["P0133"]
        )
    }

    func testLegacyHeaderVINRecordsDoNotIncludePerMessageChecksums() {
        let response = """
        48 6B 10 49 02 01 31 48 47 43 12
        48 6B 10 49 02 02 4D 38 32 36 FD
        48 6B 10 49 02 03 33 33 41 30 E8
        48 6B 10 49 02 04 30 34 33 35 DE
        48 6B 10 49 02 05 32 45
        >
        """

        XCTAssertEqual(parser.parseVIN(from: response), "1HGCM82633A004352")
    }

    func testRawASCIIVINIsNotMistakenForLegacyHeader() {
        XCTAssertEqual(
            parser.parseVIN(
                from: "31 48 47 43 4D 38 32 36 33 33 41 30 30 34 33 35 32"
            ),
            "1HGCM82633A004352"
        )
    }

    func testMode02PID02IdentifiesTriggeringDTC() {
        XCTAssertEqual(
            parser.parseFreezeFrameDTC(
                from: "7E8 05 42 02 00 01 33",
                frameNumber: 0
            ),
            "P0133"
        )
    }

    func testMode02PIDValueSkipsFrameNumberByte() {
        let value = parser.parsePIDResponse(
            "7E8 04 42 04 00 80",
            definition: StandardPIDLibrary.calculatedLoad,
            responseService: 0x42,
            frameNumber: 0
        )

        XCTAssertEqual(value?.value ?? -1, 50.176, accuracy: 0.001)
    }
}

final class OBDPIDReferenceVectorTests: XCTestCase {
    private let parser = OBDParser()

    func testWidebandOxygenLambdaReferenceVectors() {
        // SAE J1979: λ = 2 × ((A×256)+B) / 65536, so 0x8000 is stoichiometric
        // (1.0) and 0xFFFF is the top of range (65535 × 2 / 65536 ≈ 1.99997).
        // The earlier 2/32768 multiplier doubled every reading.
        let stoichiometric = parser.parsePIDValue(
            hexCode: "24",
            rawBytes: [0x80, 0x00, 0x20, 0x00],
            definition: StandardPIDLibrary.o2Bank1Sensor1Wide
        )
        let topOfRange = parser.parsePIDValue(
            hexCode: "25",
            rawBytes: [0xFF, 0xFF, 0x10, 0x00],
            definition: StandardPIDLibrary.o2Bank2Sensor1Wide
        )
        let lean = parser.parsePIDValue(
            hexCode: "25",
            rawBytes: [0xC0, 0x00, 0x10, 0x00],
            definition: StandardPIDLibrary.o2Bank2Sensor1Wide
        )

        XCTAssertEqual(stoichiometric?.value ?? -1, 1.0, accuracy: 0.000_001)
        XCTAssertEqual(
            topOfRange?.value ?? -1,
            65_535.0 * 2 / 65_536,
            accuracy: 0.000_001
        )
        XCTAssertEqual(lean?.value ?? -1, 1.5, accuracy: 0.000_001)
        XCTAssertNil(parser.parsePIDValue(
            hexCode: "24",
            rawBytes: [0x80, 0x00],
            definition: StandardPIDLibrary.o2Bank1Sensor1Wide
        ))
    }

    func testCommandedEquivalenceRatioReferenceVectors() {
        // SAE J1979 PID 44 uses the same λ scaling as the wideband PIDs.
        let stoichiometric = parser.parsePIDValue(
            hexCode: "44",
            rawBytes: [0x80, 0x00],
            definition: StandardPIDLibrary.commandedEquivRatio
        )
        let lean = parser.parsePIDValue(
            hexCode: "44",
            rawBytes: [0xC0, 0x00],
            definition: StandardPIDLibrary.commandedEquivRatio
        )
        let topOfRange = parser.parsePIDValue(
            hexCode: "44",
            rawBytes: [0xFF, 0xFF],
            definition: StandardPIDLibrary.commandedEquivRatio
        )

        XCTAssertEqual(stoichiometric?.value ?? -1, 1.0, accuracy: 0.000_001)
        XCTAssertEqual(lean?.value ?? -1, 1.5, accuracy: 0.000_001)
        XCTAssertEqual(
            topOfRange?.value ?? -1,
            65_535.0 * 2 / 65_536,
            accuracy: 0.000_001
        )
    }

    func testUnverifiedGenericPIDsAreNotAdvertised() {
        XCTAssertNil(StandardPIDLibrary.definition(for: "70"))
        XCTAssertNil(StandardPIDLibrary.definition(for: "82"))
    }
}

final class DiagnosticTroubleCodeStatusTests: XCTestCase {
    func testLegacyPayloadMigratesPrimaryStatusIntoObservedStatuses() throws {
        let original = makeDTC(status: .pending)
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "observedStatuses")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(
            DiagnosticTroubleCode.self,
            from: legacyData
        )

        XCTAssertEqual(decoded.status, .pending)
        XCTAssertEqual(decoded.observedStatuses, [.pending])
    }

    func testObservedStatusesRoundTripWithPrimaryFirstAndNoDuplicates() throws {
        let original = DiagnosticTroubleCode(
            code: "P0133",
            description: "O2 sensor slow response",
            system: .powertrain,
            severity: .medium,
            status: .confirmed,
            observedStatuses: [.pending, .confirmed, .permanent, .pending]
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            DiagnosticTroubleCode.self,
            from: encoded
        )

        XCTAssertEqual(decoded.status, .confirmed)
        XCTAssertEqual(
            decoded.observedStatuses,
            [.confirmed, .pending, .permanent]
        )
    }

    private func makeDTC(
        status: DiagnosticTroubleCode.CodeStatus
    ) -> DiagnosticTroubleCode {
        DiagnosticTroubleCode(
            code: "P0133",
            description: "O2 sensor slow response",
            system: .powertrain,
            severity: .medium,
            status: status
        )
    }
}

final class OBDScanCompletenessTests: XCTestCase {
    private let vehicle = Vehicle(
        make: "Honda",
        model: "Accord",
        year: 2020
    )

    // MARK: - ISO 15765-4 wire format at the service layer
    //
    // These drive the real CAN shape — `43 <count> <pairs>` behind a `7E8`
    // header — all the way through OBDService, rather than the headerless
    // legacy shape `ATH1` makes impossible on a CAN vehicle.

    private func canDTCTransport(
        storedResponse: String
    ) -> ScriptedOBDTransport {
        ScriptedOBDTransport { command in
            if command.raw == "ATDPN" { return "A6" }
            if command.raw.hasPrefix("AT") { return "OK" }
            switch command.raw {
            case "01 00": return "7E8 06 41 00 BE 3F A8 13"
            case "03": return storedResponse
            case "07": return "7E8 02 47 00"
            case "0A": return "7E8 02 4A 00"
            case "01 01": return "7E8 06 41 01 00 07 00 00"
            default: return "NO DATA"
            }
        }
    }

    func testStoredDTCsDecodeSingleCANCodeWithoutConsumingTheCountByte() async throws {
        let service = OBDService(
            commandTransport: canDTCTransport(storedResponse: "7E8 04 43 01 01 33")
        )
        _ = try await service.initialize()

        let dtcs = try await service.readStoredDTCs()

        // Decoding the count byte as a DTC high byte would yield P0101 —
        // a real code, so the error is silent rather than obvious.
        XCTAssertEqual(dtcs.map(\.code), ["P0133"])
    }

    func testStoredDTCsDecodeMultipleCANCodes() async throws {
        let service = OBDService(
            commandTransport: canDTCTransport(
                storedResponse: "7E8 06 43 02 01 33 04 20"
            )
        )
        _ = try await service.initialize()

        let dtcs = try await service.readStoredDTCs()

        XCTAssertEqual(dtcs.map(\.code), ["P0133", "P0420"])
    }

    func testStoredDTCsAcceptCANZeroCodeReply() async throws {
        let service = OBDService(
            commandTransport: canDTCTransport(storedResponse: "7E8 02 43 00")
        )
        _ = try await service.initialize()

        // `43 00` is what a healthy CAN vehicle returns. It must read as an
        // empty list, not as `.invalidResponse`.
        let dtcs = try await service.readStoredDTCs()

        XCTAssertTrue(dtcs.isEmpty)
    }

    func testStoredDTCsDecodeMultiFrameCANReply() async throws {
        let service = OBDService(
            commandTransport: canDTCTransport(
                storedResponse: """
                7E8 10 08 43 03 01 33 03
                7E8 21 00 C1 00 00 00 00 00
                """
            )
        )
        _ = try await service.initialize()

        let dtcs = try await service.readStoredDTCs()

        XCTAssertEqual(dtcs.map(\.code), ["P0133", "P0300", "U0100"])
    }

    func testStoredDTCsDoNotFabricateCodesFromATruncatedCANReply() async throws {
        // Declares three codes but carries one and a half.
        let service = OBDService(
            commandTransport: canDTCTransport(
                storedResponse: "7E8 05 43 03 01 33 03"
            )
        )
        _ = try await service.initialize()

        let dtcs = try await service.readStoredDTCs()

        XCTAssertEqual(dtcs.map(\.code), ["P0133"])
    }

    func testFullScanCompletesOnAConformantCANVehicle() async throws {
        let service = OBDService(
            commandTransport: canDTCTransport(
                storedResponse: "7E8 04 43 01 04 20"
            )
        )

        let scan = try await service.performFullScan(vehicle: vehicle)

        XCTAssertEqual(scan.dtcs.map(\.code), ["P0420"])
    }

    func testFullScanPropagatesEssentialStoredDTCTransportFailure() async {
        let transport = ScriptedOBDTransport { command in
            if command.raw == "ATDPN" { return "A6" }
            if command.raw.hasPrefix("AT") { return "OK" }
            if command.raw == "01 00" { return "7E8 06 41 00 BE 3F A8 13" }
            if command.raw == "03" { throw OBDError.notConnected }
            return "NO DATA"
        }
        let service = OBDService(commandTransport: transport)

        do {
            _ = try await service.performFullScan(vehicle: vehicle)
            XCTFail("A lost essential DTC query must fail the scan")
        } catch {
            XCTAssertEqual(error as? OBDError, .notConnected)
        }
    }

    func testFullScanToleratesExplicitlyUnsupportedOptionalServices() async throws {
        let transport = ScriptedOBDTransport { command in
            if command.raw == "ATDPN" { return "A6" }
            if command.raw.hasPrefix("AT") { return "OK" }
            switch command.raw {
            case "01 00":
                return "7E8 06 41 00 BE 3F A8 13"
            case "03":
                return "43 00 00"
            case "07":
                return "7F 07 11"
            case "0A":
                return "7F 0A 11"
            case "01 01":
                return "41 01 00 07 00 00"
            case "09 02":
                return "?"
            default:
                return "NO DATA"
            }
        }
        let service = OBDService(commandTransport: transport)

        let scan = try await service.performFullScan(vehicle: vehicle)

        XCTAssertTrue(scan.dtcs.isEmpty)
        XCTAssertFalse(scan.readinessMonitors.isEmpty)
        XCTAssertTrue(scan.freezeFrames.isEmpty)
        XCTAssertTrue(scan.liveData.isEmpty)
    }

    func testUnsupportedVehicleClassificationIsStructuralAndLocaleIndependent() {
        // Classification must key off the error CASE, never off localized
        // display text: on a non-English device the old substring match lost
        // phrases like "no data" and aborted whole scans.
        let localizedMessages = [
            "SIN DATOS para 0107",              // es
            "PAS DE DONNÉES pour 0107",         // fr
            "KEINE DATEN für 0107",             // de
            "NO DATA for 0107",                 // en
        ]
        for message in localizedMessages {
            let wrapped = OBDError.unsupportedByVehicle(.commandFailed(message))
            if case .unsupportedByVehicle = wrapped as? OBDError {} else {
                XCTFail("\(message) must classify structurally")
            }
            // Wrapping is display-transparent: the user-facing text is the
            // wrapped error's own description, unchanged from before.
            XCTAssertEqual(
                wrapped.errorDescription,
                OBDError.commandFailed(message).errorDescription
            )
        }
    }

    func testFullScanPreservesStatusesAndCapturesOneAttributedFreezeFrame() async throws {
        let transport = ScriptedOBDTransport { command in
            if command.raw == "ATDPN" { return "A6" }
            if command.raw.hasPrefix("AT") { return "OK" }
            switch command.raw {
            case "01 00":
                return "7E8 06 41 00 BE 3F A8 13"
            case "03":
                return "43 01 33 00 00"
            case "07":
                return "47 01 33 00 00"
            case "0A":
                return "4A 01 33 00 00"
            case "01 01":
                return "41 01 00 07 00 00"
            case "09 02":
                return "NO DATA"
            case "02 02 00":
                return "42 02 00 01 33"
            case "02 04 00":
                return "42 04 00 80"
            default:
                return "NO DATA"
            }
        }
        let service = OBDService(commandTransport: transport)

        let scan = try await service.performFullScan(vehicle: vehicle)

        let dtc = try XCTUnwrap(scan.dtcs.first)
        XCTAssertEqual(scan.dtcs.count, 1)
        XCTAssertEqual(dtc.status, .confirmed)
        XCTAssertEqual(
            dtc.observedStatuses,
            [.confirmed, .pending, .permanent]
        )
        let frame = try XCTUnwrap(scan.freezeFrames.first)
        XCTAssertEqual(scan.freezeFrames.count, 1)
        XCTAssertEqual(frame.dtcCode, "P0133")
        XCTAssertEqual(frame.pids.map(\.pid.hexCode), ["04"])
    }

    func testFreezeFrameUsesExplicitLabelWhenPID02IsUnavailable() async throws {
        let transport = ScriptedOBDTransport { command in
            switch command.raw {
            case "02 02 00":
                return "NO DATA"
            case "02 04 00":
                return "42 04 00 80"
            default:
                return "NO DATA"
            }
        }
        let service = OBDService(commandTransport: transport)

        let result = try await service.readFreezeFrame(frameNumber: 0)
        let frame = try XCTUnwrap(result)

        XCTAssertEqual(
            frame.dtcCode,
            FreezeFrameData.unattributedDTCCode
        )
    }
}

final class ELMTransportInitializationTests: XCTestCase {
    func testInitializationKeepsHeadersAndCANFormattingEnabled() {
        XCTAssertEqual(
            ELM327Command.initSequence.map(\.raw),
            [
                "ATZ", "ATE0", "ATL0", "ATS0", "ATH1",
                "ATCAF1", "ATAL", "ATAT1", "ATSP0",
            ]
        )
        XCTAssertEqual(ELM327Command.protocolProbe.raw, "01 00")
        XCTAssertGreaterThanOrEqual(ELM327Command.protocolProbe.timeout, 15)
    }

    func testInitializationRequiresPositivePID00Response() async {
        let transport = ScriptedOBDTransport { command in
            if command.raw == "01 00" { return "SEARCHING..." }
            if command.raw == "ATDPN" { return "A6" }
            return "OK"
        }
        let service = OBDService(commandTransport: transport)

        do {
            try await service.initialize()
            XCTFail("SEARCHING without a vehicle payload must not initialize")
        } catch {
            XCTAssertEqual(error as? OBDError, .invalidResponse)
        }
        XCTAssertNil(service.detectedProtocolIdentifier)
    }

    func testInitializationRecordsDetectedProtocolAfterProbe() async throws {
        let transport = ScriptedOBDTransport { command in
            switch command.raw {
            case "01 00":
                return "7E8 06 41 00 BE 3F A8 13"
            case "ATDPN":
                return "ATDPN\rA6\r>"
            default:
                return "OK"
            }
        }
        let service = OBDService(commandTransport: transport)

        try await service.initialize()

        XCTAssertEqual(service.detectedProtocolIdentifier, "A6")
    }

    func testCommandNormalizationRemovesTransportDelimiters() {
        XCTAssertEqual(
            ELM327Command(raw: "04\r\nATZ\u{0}").raw,
            "04ATZ"
        )
    }
}

private final class ScriptedOBDTransport:
    OBDCommandTransport,
    @unchecked Sendable
{
    let isConnected = true
    private let handler: @Sendable (ELM327Command) throws -> String

    init(handler: @escaping @Sendable (ELM327Command) throws -> String) {
        self.handler = handler
    }

    func sendCommand(_ command: ELM327Command) async throws -> String {
        try handler(command)
    }
}

// MARK: - Severity classification invariants

final class DTCSeverityClassificationTests: XCTestCase {
    private let vehicle = Vehicle(make: "Ford", model: "Mustang", year: 2018)

    func testCriticalTierIsReachableFromTheClassificationTable() {
        // `requiresStop` is derived from `.critical`. If no entry ever carries
        // it, the entire stop-driving branch is unreachable code.
        let critical = KnownDTCs.database.filter { $0.value.severity == .critical }
        XCTAssertFalse(
            critical.isEmpty,
            "No DTC is classified .critical, so 'stop driving' can never fire"
        )
    }

    func testEveryMisfireCodeInTheP0300BlockIsClassified() {
        // A cylinder-8 misfire must not be de-rated below cylinder 6.
        for cylinder in 1...12 {
            let code = String(format: "P03%02d", cylinder)
            let info = KnownDTCs.lookup(code)
            XCTAssertNotNil(info, "\(code) is an SAE misfire code but is unclassified")
            XCTAssertEqual(
                info?.severity,
                .high,
                "\(code) must match the severity of every other cylinder misfire"
            )
        }
    }

    func testUnrecognizedCodeIsReportedAsUnassessedRatherThanModerate() async throws {
        let transport = ScriptedOBDTransport { command in
            if command.raw == "ATDPN" { return "A6" }
            if command.raw.hasPrefix("AT") { return "OK" }
            switch command.raw {
            case "01 00": return "7E8 06 41 00 BE 3F A8 13"
            // P1234 is manufacturer-specific and absent from the table.
            case "03": return "7E8 04 43 01 12 34"
            case "07": return "7E8 02 47 00"
            case "0A": return "7E8 02 4A 00"
            case "01 01": return "7E8 06 41 01 00 07 00 00"
            default: return "NO DATA"
            }
        }
        let service = OBDService(commandTransport: transport)
        let scan = try await service.performFullScan(vehicle: vehicle)

        let dtc = try XCTUnwrap(scan.dtcs.first)
        XCTAssertEqual(dtc.code, "P1234")
        XCTAssertFalse(
            dtc.isSeverityClassified,
            "An unrecognized code must not claim an assessed severity"
        )
    }

    func testClassifiedCodeKeepsItsAssessment() throws {
        let info = try XCTUnwrap(KnownDTCs.lookup("P0301"))
        XCTAssertEqual(info.severity, .high)
    }
}

// MARK: - Truncated-frame safety

final class TruncatedFrameSafetyTests: XCTestCase {
    private let parser = OBDParser()

    func testTruncatedReadinessReplyProducesNoMonitorsRatherThanFabricatedOnes() {
        // The exact byte sequence a mid-notification BLE boundary produces
        // from `7E8 06 41 01 81 07 ...`: framing bytes only, no monitor data.
        let truncated: [UInt8] = [0x06, 0x41, 0x01, 0x81, 0x07]

        XCTAssertNil(
            parser.parseReadinessMonitors(pidData: truncated),
            "A truncated 41 01 reply must not decode framing bytes as monitors"
        )
    }

    func testCompleteReadinessReplyStillDecodes() throws {
        let complete: [UInt8] = [0x41, 0x01, 0x00, 0x07, 0x00, 0x00]

        let monitors = try XCTUnwrap(
            parser.parseReadinessMonitors(pidData: complete)
        )
        XCTAssertFalse(monitors.isEmpty)
    }

    func testBareFourByteReadingIsStillAcceptedWithoutAMarker() throws {
        // Callers that already stripped `41 01` pass A–D directly.
        let bare: [UInt8] = [0x00, 0x07, 0x00, 0x00]

        XCTAssertNotNil(parser.parseReadinessMonitors(pidData: bare))
    }
}

// MARK: - Multi-ECU resolution and legacy transports

final class MultiECUAndLegacyTransportTests: XCTestCase {
    private let parser = OBDParser()

    func testReadinessMergesAcrossRespondersRegardlessOfOrder() throws {
        // 7E8 reports EVAP complete, 7E9 reports it incomplete. J1979 says the
        // monitor is incomplete; the answer must not depend on arrival order.
        let forward = """
        7E8 06 41 01 00 07 04 00
        7E9 06 41 01 00 07 04 04
        >
        """
        let reversed = """
        7E9 06 41 01 00 07 04 04
        7E8 06 41 01 00 07 04 00
        >
        """

        let a = try XCTUnwrap(parser.parseReadinessMonitors(from: forward))
        let b = try XCTUnwrap(parser.parseReadinessMonitors(from: reversed))

        XCTAssertEqual(
            a.map(\.isReady), b.map(\.isReady),
            "Readiness must not depend on which ECU answered first"
        )
        XCTAssertEqual(
            a.map(\.isSupported), b.map(\.isSupported)
        )
    }

    func testStandardPIDPrefersThePrimaryPowertrainResponder() throws {
        // A secondary module answers 0 rpm; the engine is actually at 3000.
        let response = """
        7E9 04 41 0C 00 00
        7E8 04 41 0C 2E E0
        >
        """

        let rpm = try XCTUnwrap(
            parser.parsePIDResponse(
                response,
                definition: StandardPIDLibrary.engineRPM
            )
        )

        XCTAssertEqual(rpm.value, 3_000, accuracy: 0.001)
    }

    func testJ1850PWMHeaderIsStrippedBeforePIDParsing() throws {
        // Ford PWM, ~1996-2004. The 0x41 header byte must not be mistaken for
        // the Mode 01 service byte.
        let response = "41 6B 10 41 0C 2E E0 17>"

        let addressed = try XCTUnwrap(
            parser.addressedResponsePayloads(from: response).first
        )
        XCTAssertEqual(addressed.sourceAddress, "416B10")
        XCTAssertEqual(addressed.bytes, [0x41, 0x0C, 0x2E, 0xE0])

        let rpm = try XCTUnwrap(
            parser.parsePIDResponse(
                response,
                definition: StandardPIDLibrary.engineRPM
            )
        )
        XCTAssertEqual(rpm.value, 3_000, accuracy: 0.001)
    }
}

// MARK: - ATCAF1 multi-line reassembly

/// With `ATCAF1` the adapter strips ISO-TP PCI bytes and prints messages
/// longer than one frame across numbered lines (`0:` … `F:`), optionally after
/// a repeating CAN header token. Those fragments must be rejoined before
/// decoding; treating each printed line as its own response truncates every
/// DTC list past the first line and lets padding bytes masquerade as codes.
final class CAF1FragmentReassemblyTests: XCTestCase {
    private let parser = OBDParser()

    func testHeaderlessCAF1DTCListDecodesPairsStraddlingThePrintBoundary() {
        // The P0300 pair begins on line 0 and ends on line 1. Decoding the
        // lines independently loses it.
        let response = """
        0: 43 03 01 33 04 20
        1: 03 00
        >
        """

        XCTAssertEqual(
            parser.parseDTCs(from: response),
            ["P0133", "P0420", "P0300"]
        )
    }

    func testHeadersRepeatedPerLineDecodeInsteadOfBeingDropped() {
        // With ATH1 the header token repeats on every printed line. A
        // tokenizer that fuses the line number into the hex stream produces
        // odd-length garbage and discards the whole message — previously this
        // response yielded no codes at all.
        let response = """
        7E8 0: 43 02 01 33 04 20
        7E8 1: 03 00
        >
        """

        XCTAssertEqual(parser.parseDTCs(from: response), ["P0133", "P0420"])
        XCTAssertEqual(
            parser.addressedResponsePayloads(from: response).first?.sourceAddress,
            "7E8"
        )
    }

    func testFiveCodeListSurvivesThreeLinePrinting() {
        // `43 05 <5 × 2 bytes>` = 12 data bytes, which CAF1 splits as 6 + 4 +
        // 2. Every code must come back exactly once, in wire order.
        let response = """
        7E8 0: 43 05 01 33 04 20
        7E8 1: 03 00 04 30
        7E8 2: 05 60
        >
        """

        XCTAssertEqual(
            parser.parseDTCs(from: response),
            ["P0133", "P0420", "P0300", "P0430", "P0560"]
        )
    }

    func testOrphanContinuationIsDiscardedRatherThanDecoded() {
        // A fragment whose predecessor never arrived starts mid-message;
        // decoding its arbitrary leading bytes could fabricate values.
        let response = """
        1: 03 00 55 55
        >
        """

        XCTAssertTrue(parser.parseDTCs(from: response).isEmpty)
        XCTAssertTrue(
            parser.addressedResponsePayloads(from: response).isEmpty,
            "An orphan continuation must not be presented as a payload"
        )
    }

    func testSequenceGapDecodesOnlyTheIntactPrefix() {
        // Label 2 without label 1 breaks the run: line 0 is still decoded —
        // bounded by the declared count so nothing is invented — and the
        // orphan is dropped.
        let response = """
        0: 43 03 01 33 04 20
        2: 03 00
        >
        """

        XCTAssertEqual(parser.parseDTCs(from: response), ["P0133", "P0420"])
        XCTAssertEqual(parser.addressedResponsePayloads(from: response).count, 1)
    }

    func testVINReassemblesAcrossNumberedLinesWithRepeatedHeaders() {
        // Mode 09 PID 02: `49 02 01` then the 17 VIN ASCII bytes, split
        // 4 / 8 / 5 across three printed lines.
        let response = """
        7E8 0: 49 02 01 31 47 31 5A
        7E8 1: 43 35 37 44 36 38 31 31
        7E8 2: 30 30 30 31 32
        >
        """

        XCTAssertEqual(parser.parseVIN(from: response), "1G1ZC57D681100012")
    }

    func testMode06RecordSplitAcrossCAF1LinesParses() {
        // One CAN record (9 bytes) after the 46 service byte = 10 bytes of
        // payload, which can never fit a single frame and therefore always
        // arrives fragmented under CAF1. MID=01 TID=05 UASID=04,
        // value/min/max = FFE4 / 0019 / FFFF.
        let response = """
        7E8 0: 46 01 05 04 FF E4
        7E8 1: 00 19 FF FF
        >
        """

        let report = Mode06Parser(obdParser: parser).parseResults(
            from: response,
            format: .can
        )

        XCTAssertEqual(report.results.count, 1)
        XCTAssertFalse(
            report.evidence.contains { $0.kind == .malformedResponse },
            "A complete record split by printing must not read as malformed"
        )
        let result = try? XCTUnwrap(report.results.first)
        XCTAssertEqual(result?.monitorID, 1)
        XCTAssertEqual(result?.testID, 5)
        XCTAssertEqual(result?.unitAndScalingID, 4)
        XCTAssertEqual(result?.rawTestValue, 0xFFE4)
        XCTAssertEqual(result?.rawMinimum, 0x0019)
        XCTAssertEqual(result?.rawMaximum, 0xFFFF)
    }

    func testSingleFrameCAF1ResponsesAreUnaffectedByMerging() {
        // Frames without line numbers pass through untouched.
        let response = """
        7E8 06 41 0C 2E E0
        >
        """

        let rpm = try? XCTUnwrap(
            parser.parsePIDResponse(
                response,
                definition: StandardPIDLibrary.engineRPM
            )
        )
        XCTAssertEqual(rpm?.value ?? -1, 3_000, accuracy: 0.001)
    }
}
