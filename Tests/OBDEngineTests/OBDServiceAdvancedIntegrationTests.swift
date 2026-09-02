import Foundation
import XCTest

#if SWIFT_PACKAGE
@testable import OBDModels
@testable import OBDEngine
#else
#endif

final class OBDServiceCustomPIDIntegrationTests: XCTestCase {
    func testReadCustomPIDValidatesPrefixAndEvaluatesBoundedFormula() async throws {
        let transport = AdvancedScriptedTransport { command in
            XCTAssertEqual(command.raw, "01 0C")
            return "7E8 04 41 0C 01 02>"
        }
        let service = OBDService(commandTransport: transport)

        let reading = try await service.readCustomPID(
            try makeCustomPID(formula: "(A * 256 + B) / 4")
        )

        XCTAssertEqual(reading.value, 64.5, accuracy: 0.000_001)
        XCTAssertEqual(transport.recordedCommands, ["01 0C"])
    }

    func testReadCustomPIDRejectsWrongPositiveServiceOrParameter() async throws {
        let definition = try makeCustomPID()
        let responses = [
            "7E8 04 42 0C 01 02>",
            "7E8 04 41 0D 01 02>",
        ]

        for response in responses {
            let service = OBDService(
                commandTransport: AdvancedScriptedTransport { _ in response }
            )
            do {
                _ = try await service.readCustomPID(definition)
                XCTFail("A mismatched response prefix must be rejected")
            } catch {
                XCTAssertEqual(error as? OBDError, .invalidResponse)
            }
        }
    }

    func testReadCustomPIDRejectsMalformedPayloadLength() async throws {
        let definition = try makeCustomPID()
        let service = OBDService(
            commandTransport: AdvancedScriptedTransport { _ in
                "7E8 05 41 0C 01 02 FF>"
            }
        )

        do {
            _ = try await service.readCustomPID(definition)
            XCTFail("Trailing bytes must not be accepted as a custom PID value")
        } catch {
            XCTAssertEqual(error as? OBDError, .invalidResponse)
        }
    }

    func testReadCustomPIDPropagatesFormulaFailure() async throws {
        let definition = try makeCustomPID(
            formula: "A / B",
            range: try CustomPIDValueRange(minimum: -1_000, maximum: 1_000)
        )
        let service = OBDService(
            commandTransport: AdvancedScriptedTransport { _ in
                "7E8 04 41 0C 0A 00>"
            }
        )

        do {
            _ = try await service.readCustomPID(definition)
            XCTFail("Division by zero must remain a formula error")
        } catch {
            XCTAssertEqual(
                error as? CustomPIDValidationError,
                .divisionByZero
            )
        }
    }

    func testReadCustomPIDSurfacesNegativeResponse() async throws {
        let service = OBDService(
            commandTransport: AdvancedScriptedTransport { _ in
                "7E8 03 7F 01 11>"
            }
        )

        do {
            _ = try await service.readCustomPID(try makeCustomPID())
            XCTFail("An ECU negative response must not be parsed as data")
        } catch let OBDError.unsupportedByVehicle(.commandFailed(message)) {
            XCTAssertTrue(message.contains("Service 01 not supported"))
            XCTAssertTrue(message.contains("0x11"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReadCustomPIDRejectsConflictingMultiECUReplies() async throws {
        let service = OBDService(
            commandTransport: AdvancedScriptedTransport { _ in
                """
                7E8 04 41 0C 01 02
                7E9 04 41 0C 03 04
                >
                """
            }
        )

        do {
            _ = try await service.readCustomPID(try makeCustomPID())
            XCTFail("A custom PID must not choose an arbitrary ECU reply")
        } catch {
            XCTAssertEqual(error as? OBDError, .invalidResponse)
        }
    }

    func testReadCustomPIDAcceptsIdenticalMultiECUReplies() async throws {
        let service = OBDService(
            commandTransport: AdvancedScriptedTransport { _ in
                """
                7E8 04 41 0C 01 02
                7E9 04 41 0C 01 02
                >
                """
            }
        )

        let reading = try await service.readCustomPID(try makeCustomPID())

        XCTAssertEqual(reading.value, 64.5, accuracy: 0.000_001)
    }

    func testReadCustomPIDDemoIsDeterministicBoundedAndOffline() async throws {
        let transport = AdvancedScriptedTransport { _ in
            XCTFail("Demo custom PIDs must not access the adapter")
            return "NO DATA"
        }
        let service = OBDService(commandTransport: transport)
        let vehicle = Vehicle(
            make: "Fixture",
            model: "Demo",
            year: 2026
        )
        let definition = try makeCustomPID()
        service.connectDemo(vehicle: vehicle)

        let first = try await service.readCustomPID(definition)
        let second = try await service.readCustomPID(definition)

        XCTAssertEqual(first.value, second.value, accuracy: 0)
        XCTAssertEqual(first.rangeStatus, .withinRange)
        XCTAssertTrue(
            definition.valueRange.minimum...definition.valueRange.maximum
                ~= first.value
        )
        XCTAssertTrue(transport.recordedCommands.isEmpty)
    }
}

final class OBDServiceMode06IntegrationTests: XCTestCase {
    func testCANMode06PaginatesCapabilitiesAndPreservesMultiECUResults() async throws {
        let transport = AdvancedScriptedTransport { command in
            if let response = initializationResponse(
                for: command,
                protocolIdentifier: "A6"
            ) {
                return response
            }
            switch command.raw {
            case "06 00":
                return """
                7E8 06 46 00 80 00 00 01
                7E9 06 46 00 40 00 00 00
                >
                """
            case "06 20":
                return "7E8 06 46 20 80 00 00 00>"
            case "06 01":
                return """
                7E8 10 0A 46 01 81 0B 00 64
                7E9 10 0A 46 01 82 0B 00 C9
                7E8 21 00 00 00 C8 00 00 00
                7E9 21 00 00 00 C8 00 00 00
                >
                """
            case "06 02":
                return "NO DATA>"
            case "06 21":
                return """
                7E8 10 0A 46 21 83 0B 00 18
                7E8 21 00 00 00 64 00 00 00
                >
                """
            default:
                XCTFail("Unexpected command \(command.raw)")
                return "?"
            }
        }
        let service = OBDService(commandTransport: transport)

        let report = try await service.readMode06Results(
            maximumMonitorCount: 8
        )

        XCTAssertEqual(report.results.count, 3)
        XCTAssertEqual(
            report.results.map(\.sourceAddress?.rawValue),
            ["7E8", "7E9", "7E8"]
        )
        XCTAssertEqual(report.results.map(\.monitorID), [0x01, 0x01, 0x21])
        XCTAssertEqual(report.results.map(\.testID), [0x81, 0x82, 0x83])
        XCTAssertTrue(report.evidence.contains { $0.kind == .noData })
        XCTAssertEqual(
            advancedCommands(in: transport.recordedCommands),
            ["06 00", "06 20", "06 01", "06 02", "06 21"]
        )
    }

    func testCANMode06BoundsDiscoveredMonitorRequests() async throws {
        let transport = AdvancedScriptedTransport { command in
            if let response = initializationResponse(
                for: command,
                protocolIdentifier: "6"
            ) {
                return response
            }
            switch command.raw {
            case "06 00":
                return "7E8 06 46 00 E0 00 00 00>"
            case "06 01":
                return """
                7E8 10 0A 46 01 81 0B 00 64
                7E8 21 00 00 00 C8 00 00 00
                >
                """
            default:
                XCTFail("The monitor bound allowed an extra request: \(command.raw)")
                return "?"
            }
        }
        let service = OBDService(commandTransport: transport)

        let report = try await service.readMode06Results(
            maximumMonitorCount: 1
        )

        XCTAssertEqual(report.results.map(\.monitorID), [0x01])
        XCTAssertTrue(report.evidence.contains { evidence in
            evidence.kind == .boundsExceeded &&
                evidence.detail.contains("limited to 1")
        })
        XCTAssertEqual(
            advancedCommands(in: transport.recordedCommands),
            ["06 00", "06 01"]
        )
    }

    func testLegacyMode06UsesServiceOnlyRequestAndLegacyLayout() async throws {
        let transport = AdvancedScriptedTransport { command in
            if let response = initializationResponse(
                for: command,
                protocolIdentifier: "A3"
            ) {
                return response
            }
            if command.raw == "06" {
                return "46 21 02 00 64 00 00 00 C8>"
            }
            XCTFail("Unexpected command \(command.raw)")
            return "?"
        }
        let service = OBDService(commandTransport: transport)

        let report = try await service.readMode06Results()
        let result = try XCTUnwrap(report.results.first)

        XCTAssertEqual(result.format, .legacy)
        XCTAssertNil(result.monitorID)
        XCTAssertEqual(result.testID, 0x21)
        XCTAssertEqual(result.componentID, 0x02)
        XCTAssertEqual(result.rawTestValue, 100)
        XCTAssertEqual(
            advancedCommands(in: transport.recordedCommands),
            ["06"]
        )
    }

    func testMode06DemoReturnsBoundedOfflineEvidence() async throws {
        let transport = AdvancedScriptedTransport { _ in
            XCTFail("Demo Mode 06 must not access the adapter")
            return "NO DATA"
        }
        let service = OBDService(commandTransport: transport)
        service.connectDemo(
            vehicle: Vehicle(make: "Fixture", model: "Demo", year: 2026)
        )

        let report = try await service.readMode06Results(
            maximumMonitorCount: 1
        )

        XCTAssertEqual(report.results.count, 2)
        XCTAssertEqual(report.results.map(\.format), [.can, .can])
        XCTAssertEqual(report.evidence.map(\.kind), [.capability])
        XCTAssertTrue(transport.recordedCommands.isEmpty)
    }
}

final class OBDServiceEnhancedIntegrationTests: XCTestCase {
    func testEnhancedReadsUseExclusivePhysicalTransactionsAndRestoreHeader() async throws {
        let transport = AdvancedScriptedTransport { command in
            if let response = initializationResponse(
                for: command,
                protocolIdentifier: "A6"
            ) {
                return response
            }
            switch command.raw {
            case "22 F1 90":
                return "7E8 05 62 F1 90 12 34>"
            case "19 02 FF":
                return "7E8 07 59 02 FF 12 34 56 0D>"
            default:
                XCTFail("Unexpected command \(command.raw)")
                return "?"
            }
        }
        let service = OBDService(commandTransport: transport)

        let report = try await service.readEnhancedDiagnostics(
            profile: advancedProfile(includeDTCRead: true)
        )

        XCTAssertEqual(report.values.count, 1)
        XCTAssertEqual(report.dtcs.map(\.code), ["123456"])
        XCTAssertEqual(
            advancedCommands(in: transport.recordedCommands),
            [
                "ATH1", "ATCAF1", "ATSH 7E0", "22 F1 90", "ATSH 7DF",
                "ATH1", "ATCAF1", "ATSH 7E0", "19 02 FF", "ATSH 7DF",
            ]
        )
    }

    func testEnhancedRequestFailureStillRestoresFunctionalHeader() async throws {
        let transport = AdvancedScriptedTransport { command in
            if let response = initializationResponse(
                for: command,
                protocolIdentifier: "A6"
            ) {
                return response
            }
            if command.raw == "22 F1 90" {
                throw OBDError.commandTimedOut(command.raw)
            }
            XCTFail("Unexpected command \(command.raw)")
            return "?"
        }
        let service = OBDService(commandTransport: transport)

        let report = try await service.readEnhancedDiagnostics(
            profile: advancedProfile(includeDTCRead: false)
        )

        XCTAssertTrue(report.values.isEmpty)
        XCTAssertTrue(report.evidence.contains {
            $0.kind == .malformedResponse &&
                $0.requestService == 0x22
        })
        XCTAssertEqual(service.detectedProtocolIdentifier, "A6")
        XCTAssertEqual(
            Array(transport.recordedCommands.suffix(5)),
            ["ATH1", "ATCAF1", "ATSH 7E0", "22 F1 90", "ATSH 7DF"]
        )
    }

    func testRestorationFailureDiscardsResponseDisconnectsAndStopsProfile() async throws {
        let transport = AdvancedScriptedTransport { command in
            if command.raw == "ATSH 7DF" {
                throw OBDError.commandFailed("fixture restoration failure")
            }
            if let response = initializationResponse(
                for: command,
                protocolIdentifier: "A6"
            ) {
                return response
            }
            switch command.raw {
            case "22 F1 90":
                return "7E8 05 62 F1 90 12 34>"
            default:
                XCTFail("Unexpected command \(command.raw)")
                return "?"
            }
        }
        let service = OBDService(commandTransport: transport)

        let report = try await service.readEnhancedDiagnostics(
            profile: advancedProfile(includeDTCRead: true)
        )

        XCTAssertTrue(report.values.isEmpty)
        XCTAssertTrue(report.dtcs.isEmpty)
        XCTAssertTrue(report.evidence.contains {
            $0.kind == .unsupportedTransport &&
                $0.requestService == 0x22
        })
        XCTAssertNil(service.detectedProtocolIdentifier)
        XCTAssertFalse(
            transport.recordedCommands.contains("19 02 FF"),
            "The service must stop after it cannot prove header restoration"
        )
        XCTAssertEqual(transport.recordedCommands.last, "ATSH 7DF")
    }

    func testConcurrentPIDReadCannotInterleaveWithEnhancedHeaderTransaction() async throws {
        let requestGate = AdvancedAsyncGate()
        let pidStarted = AdvancedAsyncSignal()
        let transport = AdvancedScriptedTransport { command in
            if let response = initializationResponse(
                for: command,
                protocolIdentifier: "A6"
            ) {
                return response
            }
            switch command.raw {
            case "22 F1 90":
                await requestGate.enterAndWait()
                return "7E8 05 62 F1 90 12 34>"
            case "01 0C":
                return "7E8 04 41 0C 2E E0>"
            default:
                XCTFail("Unexpected command \(command.raw)")
                return "?"
            }
        }
        let service = OBDService(commandTransport: transport)
        try await service.initialize()

        let enhancedTask = Task {
            try await service.readEnhancedDiagnostics(
                profile: advancedProfile(includeDTCRead: false)
            )
        }
        await requestGate.waitUntilEntered()
        let pidTask = Task {
            await pidStarted.signal()
            return try await service.readPID(StandardPIDLibrary.engineRPM)
        }
        await pidStarted.wait()
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertFalse(
            transport.recordedCommands.contains("01 0C"),
            "A normal PID request entered while the physical header was active"
        )

        await requestGate.release()
        let enhanced = try await enhancedTask.value
        let rpm = try await pidTask.value
        let advanced = advancedCommands(in: transport.recordedCommands)

        XCTAssertEqual(enhanced.values.count, 1)
        XCTAssertEqual(rpm.value, 3_000, accuracy: 0.001)
        XCTAssertLessThan(
            try XCTUnwrap(advanced.firstIndex(of: "ATSH 7DF")),
            try XCTUnwrap(advanced.firstIndex(of: "01 0C"))
        )
    }

    func testReadAdvancedDiagnosticsAggregatesMode06AndEnhancedEvidence() async throws {
        let transport = AdvancedScriptedTransport { command in
            if let response = initializationResponse(
                for: command,
                protocolIdentifier: "A6"
            ) {
                return response
            }
            switch command.raw {
            case "06 00":
                return "7E8 06 46 00 80 00 00 00>"
            case "06 01":
                return """
                7E8 10 0A 46 01 81 0B 00 64
                7E8 21 00 00 00 C8 00 00 00
                >
                """
            case "22 F1 90":
                return "7E8 05 62 F1 90 12 34>"
            case "19 02 FF":
                return "7E8 07 59 02 FF 12 34 56 0D>"
            default:
                XCTFail("Unexpected command \(command.raw)")
                return "?"
            }
        }
        let service = OBDService(commandTransport: transport)
        let profile = advancedProfile(includeDTCRead: true)

        let snapshot = try await service.readAdvancedDiagnostics(
            profile: profile,
            maximumMode06Monitors: 1,
            maximumEnhancedDataIdentifiers: 1
        )

        XCTAssertTrue(snapshot.hasResults)
        XCTAssertEqual(snapshot.mode06Results.count, 1)
        XCTAssertEqual(snapshot.enhancedProfileID, profile.id)
        XCTAssertEqual(snapshot.enhancedProfileName, profile.displayName)
        XCTAssertEqual(snapshot.enhancedValues.count, 1)
        XCTAssertEqual(snapshot.enhancedDTCs.map(\.code), ["123456"])
        XCTAssertTrue(snapshot.evidence.contains {
            $0.kind == .capability && $0.requestService == 0x06
        })
        XCTAssertTrue(snapshot.evidence.contains {
            $0.kind == .capability && $0.requestService == 0x22
        })
        XCTAssertTrue(snapshot.evidence.contains {
            $0.kind == .capability && $0.requestService == 0x19
        })
    }
}

private final class AdvancedScriptedTransport:
    OBDCommandTransport,
    @unchecked Sendable
{
    let isConnected: Bool

    private let lock = NSLock()
    private var commandLog: [String] = []
    private let handler:
        @Sendable (ELM327Command) async throws -> String

    init(
        isConnected: Bool = true,
        handler: @escaping
            @Sendable (ELM327Command) async throws -> String
    ) {
        self.isConnected = isConnected
        self.handler = handler
    }

    var recordedCommands: [String] {
        lock.withLock { commandLog }
    }

    func sendCommand(_ command: ELM327Command) async throws -> String {
        lock.withLock {
            commandLog.append(command.raw)
        }
        return try await handler(command)
    }
}

private actor AdvancedAsyncGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }

        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor AdvancedAsyncSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signaled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        guard !signaled else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private func makeCustomPID(
    formula: String = "(A * 256 + B) / 4",
    range: CustomPIDValueRange? = nil
) throws -> CustomPIDDefinition {
    try CustomPIDDefinition(
        id: UUID(uuidString: "F11E0000-0000-0000-0000-000000000001")!,
        request: try CustomPIDRequest(service: "01", parameter: "0C"),
        name: "Synthetic Fixture PID",
        description: "A test-only value with no OEM meaning",
        responseByteCount: 2,
        formula: try BoundedPIDFormula(formula),
        unit: .unitless,
        valueRange: try range ?? CustomPIDValueRange(
            minimum: 0,
            maximum: 65_536
        ),
        displayPrecision: 2,
        category: .custom
    )
}

private func advancedProfile(
    includeDTCRead: Bool
) -> EnhancedDiagnosticProfile {
    let definition = EnhancedDataIdentifierDefinition(
        dataIdentifier: 0xF190,
        name: "Synthetic Fixture Value",
        description: "A test-only value with no OEM meaning",
        unit: "fixture",
        decoder: .unsignedInteger(
            byteCount: 2,
            byteOrder: .bigEndian,
            multiplier: 0.1,
            offset: -40
        )
    )
    let module = EnhancedECUModuleDefinition(
        id: "engine",
        name: "Synthetic Engine",
        addressing: EnhancedCANAddressing(
            format: .standard11Bit,
            requestIdentifier: 0x7E0,
            responseIdentifiers: [0x7E8]
        ),
        dataIdentifiers: [definition],
        allowedDTCReadSubfunctions: includeDTCRead
            ? [.reportByStatusMask]
            : []
    )
    return EnhancedDiagnosticProfile(
        id: "test.service.integration",
        displayName: "Synthetic Service Integration",
        provenance: EnhancedProfileProvenance(
            origin: .userDefined,
            revision: "fixture-1"
        ),
        applicability: EnhancedVehicleApplicability(
            makes: ["Fixture"],
            models: ["Test"],
            minimumYear: 2000,
            maximumYear: 2200
        ),
        modules: [module]
    )
}

private func initializationResponse(
    for command: ELM327Command,
    protocolIdentifier: String
) -> String? {
    switch command.raw {
    case "01 00":
        return "7E8 06 41 00 BE 3F A8 13>"
    case "ATDPN":
        return protocolIdentifier
    default:
        return command.raw.hasPrefix("AT") ? "OK>" : nil
    }
}

private func advancedCommands(in commands: [String]) -> [String] {
    guard let protocolIndex = commands.firstIndex(of: "ATDPN") else {
        return commands
    }
    return Array(commands.dropFirst(protocolIndex + 1))
}
