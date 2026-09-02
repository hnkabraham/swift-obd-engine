import Foundation
import XCTest

#if SWIFT_PACKAGE
@testable import OBDModels
@testable import OBDEngine
#else
#endif

final class OBDLifecycleHardeningTests: XCTestCase {
    private let vehicle = Vehicle(
        id: UUID(
            uuidString: "10000000-0000-0000-0000-000000000001"
        )!,
        vin: "1HGCM82633A004352",
        make: "Honda",
        model: "Accord",
        year: 2020
    )
    private var capabilitySuiteName = ""
    private var capabilityDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        capabilitySuiteName = "OBDLifecycleHardening.\(UUID().uuidString)"
        capabilityDefaults = UserDefaults(suiteName: capabilitySuiteName)!
    }

    override func tearDown() {
        capabilityDefaults.removePersistentDomain(
            forName: capabilitySuiteName
        )
        capabilityDefaults = nil
        super.tearDown()
    }

    /// `OBDService` otherwise defaults to `OBDVehicleCapabilityCache(defaults:
    /// .standard)`, which would persist a protocol for this suite's fixed
    /// vehicle UUID into the test process's shared defaults and let one run's
    /// residue send the next run down the cached fast path instead.
    private var isolatedCapabilityCache: OBDVehicleCapabilityCache {
        OBDVehicleCapabilityCache(
            defaults: capabilityDefaults,
            namespace: "test.capabilities"
        )
    }

    func testColdSearchUsesThirtySecondsAndPersistsAllPIDPages()
        async throws {
        let store = LifecycleMemoryCapabilityStore()
        let clock = LifecycleStepClock()
        let transport = LifecycleTransport { command in
            switch command.raw {
            case "ATZ":
                return "ELM327 v2.3>"
            case "01 00":
                return "7E8 06 41 00 80 10 00 01>"
            case "01 20":
                return "7E8 06 41 20 80 00 00 01>"
            case "01 40":
                return "7E8 06 41 40 40 00 00 00>"
            case "ATDPN":
                return "A6>"
            default:
                return command.raw.hasPrefix("AT") ? "OK>" : "NO DATA>"
            }
        }
        let service = OBDService(
            commandTransport: transport,
            capabilityCache: store,
            now: { clock.next() }
        )

        try await service.initialize(for: vehicle)

        let probes = transport.recordedCommands.filter {
            $0.raw == "01 00"
        }
        XCTAssertEqual(probes.map(\.timeout), [30])
        XCTAssertEqual(
            transport.recordedCommands.map(\.raw),
            [
                "ATZ", "ATE0", "ATL0", "ATS0", "ATH1", "ATCAF1",
                "ATAL", "ATAT1", "ATSP0", "01 00", "01 20",
                "01 40", "ATDPN",
            ]
        )
        let capabilities = try XCTUnwrap(
            store.capabilities(for: vehicle.id)
        )
        XCTAssertEqual(capabilities.protocolIdentifier, "A6")
        XCTAssertEqual(
            capabilities.supportedMode01PIDs,
            [0x01, 0x0C, 0x20, 0x21, 0x40, 0x42]
        )
        XCTAssertEqual(capabilities.probeLatency, 1)
        XCTAssertEqual(
            service.vehicleLinkState,
            .vehicleReady(protocolIdentifier: "A6")
        )
        XCTAssertEqual(transport.vehicleCommunicationConfirmationCount, 1)
    }

    func testStaleSavedProtocolFallsBackImmediatelyToAutomaticSearch()
        async throws {
        let store = LifecycleMemoryCapabilityStore(
            records: [
                vehicle.id: OBDVehicleCapabilities(
                    vehicleID: vehicle.id,
                    protocolIdentifier: "A6",
                    probeLatency: 0.1
                ),
            ]
        )
        let probeCount = LifecycleCounter()
        let transport = LifecycleTransport { command in
            switch command.raw {
            case "ATZ":
                return "OBDLink MX+ 5.9.1>"
            case "01 00":
                return await probeCount.next() == 1
                    ? "SEARCHING...>"
                    : "7E8 06 41 00 00 00 00 00>"
            case "ATDPN":
                return "A6>"
            default:
                return command.raw.hasPrefix("AT") ? "OK>" : "NO DATA>"
            }
        }
        let service = OBDService(
            commandTransport: transport,
            capabilityCache: store
        )

        try await service.initialize(for: vehicle)

        let commands = transport.recordedCommands
        let relevant = commands.filter {
            ["ATSP6", "ATSP0", "01 00"].contains($0.raw)
        }
        XCTAssertEqual(
            relevant.map(\.raw),
            ["ATSP6", "01 00", "ATSP0", "01 00"]
        )
        XCTAssertEqual(
            relevant.filter { $0.raw == "01 00" }.map(\.timeout),
            [30, 30]
        )
    }

    func testForceAutomaticRetryNeverUsesCachedProtocol() async throws {
        let store = LifecycleMemoryCapabilityStore(
            records: [
                vehicle.id: OBDVehicleCapabilities(
                    vehicleID: vehicle.id,
                    protocolIdentifier: "A6",
                    probeLatency: 0.1
                ),
            ]
        )
        let transport = LifecycleTransport(
            handler: { command in
                lifecycleInitializationResponse(command)
            }
        )
        let service = OBDService(
            commandTransport: transport,
            capabilityCache: store
        )

        try await service.initialize(
            for: vehicle,
            forceAutomaticProtocol: true
        )

        let commands = transport.recordedCommands.map(\.raw)
        XCTAssertFalse(commands.contains("ATSP6"))
        XCTAssertEqual(commands.filter { $0 == "ATSP0" }.count, 1)
        XCTAssertEqual(
            transport.recordedCommands.first {
                $0.raw == "01 00"
            }?.timeout,
            30
        )
    }

    func testKnownUnsupportedPIDFailsWithoutWritingToAdapter()
        async throws {
        let transport = LifecycleTransport(
            handler: { command in
                lifecycleInitializationResponse(command)
            }
        )
        let service = OBDService(
            commandTransport: transport,
            capabilityCache: LifecycleMemoryCapabilityStore()
        )
        try await service.initialize(for: vehicle)
        let writesBeforeRead = transport.recordedCommands.count

        do {
            _ = try await service.readPID(
                StandardPIDLibrary.engineRPM
            )
            XCTFail("An unsupported PID must fail locally")
        } catch let OBDError.unsupportedByVehicle(.commandFailed(message)) {
            XCTAssertTrue(message.contains("not supported"))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertEqual(
            transport.recordedCommands.count,
            writesBeforeRead
        )
        XCTAssertFalse(
            transport.recordedCommands.map(\.raw).contains("01 0C")
        )
    }

    func testResetBannerIsAcceptedButMissingCriticalOKRetiresTransport()
        async {
        let transport = LifecycleTransport { command in
            switch command.raw {
            case "ATZ":
                return "ELM327 v1.5>"
            case "ATE0":
                return "ATE0\rREADY>"
            default:
                return "OK>"
            }
        }
        let service = OBDService(
            commandTransport: transport,
            capabilityCache: isolatedCapabilityCache
        )

        do {
            try await service.initialize()
            XCTFail("A critical setup command without OK must fail")
        } catch let OBDError.commandFailed(message) {
            XCTAssertTrue(message.contains("ATE0"))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertEqual(transport.retirementCount, 1)
        XCTAssertEqual(
            transport.recordedCommands.map(\.raw),
            ["ATZ", "ATE0"]
        )
    }

    func testConcurrentInitializationIsSingleFlightAndExclusive()
        async throws {
        let gate = LifecycleAsyncGate()
        let transport = LifecycleTransport { command in
            if command.raw == "ATZ" {
                await gate.enterAndWait()
                return "ELM327 v2.3>"
            }
            return lifecycleInitializationResponse(command)
        }
        let service = OBDService(
            commandTransport: transport,
            capabilityCache: isolatedCapabilityCache
        )

        let first = Task { try await service.initialize() }
        await gate.waitUntilEntered()
        let second = Task { try await service.initialize() }
        for _ in 0..<20 { await Task.yield() }
        await gate.release()

        try await first.value
        try await second.value
        XCTAssertEqual(
            transport.recordedCommands.filter {
                $0.raw == "ATZ"
            }.count,
            1
        )
    }

    func testDifferentVehicleCancelsPriorFlightAndRunsItsOwnDiscovery()
        async throws {
        let secondVehicle = Vehicle(
            id: UUID(
                uuidString:
                    "20000000-0000-0000-0000-000000000002"
            )!,
            make: "Toyota",
            model: "Camry",
            year: 2021
        )
        let gate = LifecycleAsyncGate()
        let resetCount = LifecycleCounter()
        let store = LifecycleMemoryCapabilityStore()
        let transport = LifecycleTransport { command in
            if command.raw == "ATZ",
               await resetCount.next() == 1 {
                // Vehicle A's flight is released by the supersede cancellation
                // itself, never by the test: releasing on a yield budget lets
                // A finish its remaining setup commands and commit before B
                // registers its differing flight key.
                await gate.enterAndWaitForCancellation()
                return "ELM327 v2.3>"
            }
            return lifecycleInitializationResponse(command)
        }
        let service = OBDService(
            commandTransport: transport,
            capabilityCache: store
        )

        let first = Task {
            try await service.initialize(for: vehicle)
        }
        await gate.waitUntilEntered()
        let second = Task {
            try await service.initialize(for: secondVehicle)
        }

        do {
            try await first.value
            XCTFail("Vehicle A's superseded flight must be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        try await second.value
        XCTAssertNil(store.capabilities(for: vehicle.id))
        XCTAssertNotNil(store.capabilities(for: secondVehicle.id))
        XCTAssertEqual(
            transport.recordedCommands.filter {
                $0.raw == "ATZ"
            }.count,
            2
        )
    }

    func testCancelledQueuedReadDoesNotTransmitAfterWireReservation()
        async throws {
        let gate = LifecycleAsyncGate()
        let transport = LifecycleTransport { command in
            if command.raw == "03" {
                await gate.enterAndWait()
                return "43 00 00>"
            }
            if command.raw == "07" {
                return "47 00 00>"
            }
            return lifecycleInitializationResponse(command)
        }
        let service = OBDService(
            commandTransport: transport,
            capabilityCache: isolatedCapabilityCache
        )
        let first = Task {
            try await service.readStoredDTCs()
        }
        await gate.waitUntilEntered()
        let cancelled = Task {
            try await service.readPendingDTCs()
        }
        for _ in 0..<20 { await Task.yield() }
        cancelled.cancel()
        await gate.release()

        _ = try await first.value
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled queued read must not reach the adapter")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(
            transport.recordedCommands.map(\.raw).contains("07")
        )
    }

    func testGenerationChangeCancelsStaleInitializationWithoutRetiringNewTransport()
        async {
        let transport = LifecycleTransport(
            generationChangeCommand: "ATZ",
            handler: { command in
                lifecycleInitializationResponse(command)
            }
        )
        let service = OBDService(
            commandTransport: transport,
            capabilityCache: isolatedCapabilityCache
        )

        do {
            try await service.initialize()
            XCTFail("A stale transport generation must not initialize")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(transport.retirementCount, 0)
        XCTAssertEqual(
            transport.recordedCommands.map(\.raw),
            ["ATZ"]
        )
    }

    func testAdapterHealthReadsIdentityVoltageProtocolAndLatency()
        async throws {
        let clock = LifecycleStepClock()
        let transport = LifecycleTransport { command in
            switch command.raw {
            case "ATI": return "OBDLink MX+ 5.9.1>"
            case "ATRV": return "12.6V>"
            case "ATDPN": return "A6>"
            default: return "?"
            }
        }
        let service = OBDService(
            commandTransport: transport,
            capabilityCache: isolatedCapabilityCache,
            now: { clock.next() }
        )

        let report = try await service.readAdapterHealth()

        XCTAssertEqual(report.status, .healthy)
        XCTAssertEqual(report.adapterIdentity, "OBDLink MX+ 5.9.1")
        XCTAssertEqual(report.supplyVoltage, 12.6)
        XCTAssertEqual(report.protocolIdentifier, "A6")
        XCTAssertEqual(report.roundTripLatency, 1)
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testSoftRepairWarmStartsThenForcesAutomaticProtocol()
        async throws {
        let store = LifecycleMemoryCapabilityStore(
            records: [
                vehicle.id: OBDVehicleCapabilities(
                    vehicleID: vehicle.id,
                    protocolIdentifier: "A6",
                    probeLatency: 0.1
                ),
            ]
        )
        let transport = LifecycleTransport { command in
            if command.raw == "ATWS" {
                return "STN2230 v5.9.1>"
            }
            return lifecycleInitializationResponse(command)
        }
        let service = OBDService(
            commandTransport: transport,
            capabilityCache: store
        )

        try await service.softRepair(for: vehicle)

        let commands = transport.recordedCommands.map(\.raw)
        XCTAssertEqual(commands.first, "ATWS")
        XCTAssertFalse(commands.contains("ATZ"))
        XCTAssertFalse(commands.contains("ATSP6"))
        XCTAssertTrue(commands.contains("ATSP0"))
        XCTAssertEqual(
            service.vehicleLinkState,
            .vehicleReady(protocolIdentifier: "A6")
        )
    }

    func testLegacyProtocolMigratesOnceWithoutCrossVehicleLeak() {
        let suite = "OBDLifecycleMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            "A6",
            forKey: OBDVehicleCapabilityCache.legacyProtocolKey
        )
        let cache = OBDVehicleCapabilityCache(
            defaults: defaults,
            namespace: "test.capabilities"
        )
        let firstVehicle = UUID()
        let secondVehicle = UUID()

        XCTAssertEqual(
            cache.capabilities(for: firstVehicle)?.protocolIdentifier,
            "A6"
        )
        XCTAssertNil(cache.capabilities(for: secondVehicle))
        XCTAssertNil(
            defaults.string(
                forKey: OBDVehicleCapabilityCache.legacyProtocolKey
            )
        )
    }

    func testCapabilityCacheKeepsOnlySixtyFourNewestVehicles() {
        let suite = "OBDLifecycleBounds.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = OBDVehicleCapabilityCache(
            defaults: defaults,
            namespace: "test.capabilities"
        )
        var identifiers: [UUID] = []
        for index in 0..<65 {
            let identifier = UUID()
            identifiers.append(identifier)
            cache.save(
                OBDVehicleCapabilities(
                    vehicleID: identifier,
                    protocolIdentifier: "A6",
                    probeLatency: 0.1,
                    updatedAt: Date(
                        timeIntervalSince1970: TimeInterval(index)
                    )
                )
            )
        }

        XCTAssertNil(cache.capabilities(for: identifiers[0]))
        XCTAssertNotNil(cache.capabilities(for: identifiers[64]))
    }

    func testAnonymousInitializationRerunsFullPIDDiscoveryForSelectedVehicle()
        async throws {
        let store = LifecycleMemoryCapabilityStore()
        let transport = LifecycleTransport { command in
            switch command.raw {
            case "ATZ":
                return "ELM327 v2.3>"
            case "01 00":
                return "7E8 06 41 00 80 10 00 01>"
            case "01 20":
                return "7E8 06 41 20 80 00 00 01>"
            case "01 40":
                return "7E8 06 41 40 40 00 00 00>"
            case "ATDPN":
                return "A6>"
            default:
                return command.raw.hasPrefix("AT") ? "OK>" : "NO DATA>"
            }
        }
        let service = OBDService(
            commandTransport: transport,
            capabilityCache: store
        )

        try await service.initialize()

        XCTAssertNil(store.capabilities(for: vehicle.id))
        XCTAssertFalse(
            transport.recordedCommands.map(\.raw).contains("01 20")
        )

        try await service.initialize(for: vehicle)

        XCTAssertEqual(
            transport.recordedCommands.filter { $0.raw == "ATZ" }.count,
            2
        )
        XCTAssertEqual(
            transport.recordedCommands.filter { $0.raw == "01 00" }.count,
            2
        )
        XCTAssertTrue(
            transport.recordedCommands.map(\.raw).contains("01 20")
        )
        XCTAssertTrue(
            transport.recordedCommands.map(\.raw).contains("01 40")
        )
        XCTAssertEqual(
            store.capabilities(for: vehicle.id)?.supportedMode01PIDs,
            [0x01, 0x0C, 0x20, 0x21, 0x40, 0x42]
        )
    }

    func testDeselectVehicleInvalidatesReadySessionWithoutDisconnectingAdapter()
        async throws {
        let transport = LifecycleTransport { command in
            lifecycleInitializationResponse(command)
        }
        let service = OBDService(
            commandTransport: transport,
            capabilityCache: isolatedCapabilityCache
        )
        try await service.initialize(for: vehicle)
        XCTAssertTrue(service.isVehicleReady(for: vehicle))

        service.deselectVehicle()

        XCTAssertNil(service.selectedVehicle)
        XCTAssertFalse(service.isVehicleReady(for: vehicle))
        XCTAssertEqual(service.vehicleLinkState, .adapterConnected)
    }

    func testForegroundReconciliationPreservesTransportButRequiresFreshProbe()
        async throws {
        let transport = LifecycleTransport { command in
            lifecycleInitializationResponse(command)
        }
        let service = OBDService(
            commandTransport: transport,
            capabilityCache: LifecycleMemoryCapabilityStore()
        )
        try await service.initialize(for: vehicle)
        let generation = transport.transportGeneration
        let commandCount = transport.recordedCommands.count

        service.reconcileConnectionOnForeground()

        XCTAssertFalse(service.isVehicleReady(for: vehicle))
        XCTAssertEqual(service.vehicleLinkState, .adapterConnected)
        XCTAssertEqual(transport.transportGeneration, generation)
        XCTAssertEqual(transport.retirementCount, 0)
        XCTAssertEqual(transport.recordedCommands.count, commandCount)

        try await service.initialize(for: vehicle)

        XCTAssertTrue(service.isVehicleReady(for: vehicle))
        XCTAssertEqual(
            service.vehicleLinkState,
            .vehicleReady(protocolIdentifier: "A6")
        )
        XCTAssertEqual(
            transport.recordedCommands.filter {
                $0.raw == "01 00"
            }.count,
            2
        )
        XCTAssertEqual(
            transport.vehicleCommunicationConfirmationCount,
            2
        )
    }

    func testForegroundReconciliationSupersedesInFlightInitialization()
        async throws {
        let gate = LifecycleAsyncGate()
        let resetCount = LifecycleCounter()
        let transport = LifecycleTransport { command in
            if command.raw == "ATZ",
               await resetCount.next() == 1 {
                await gate.enterAndWait()
            }
            return lifecycleInitializationResponse(command)
        }
        let service = OBDService(
            commandTransport: transport,
            capabilityCache: LifecycleMemoryCapabilityStore()
        )
        let suspendedFlight = Task {
            try await service.initialize(for: vehicle)
        }
        await gate.waitUntilEntered()

        service.reconcileConnectionOnForeground()
        let foregroundFlight = Task {
            try await service.initialize(for: vehicle)
        }
        await gate.release()

        do {
            try await suspendedFlight.value
            XCTFail("The pre-foreground validation must not become ready")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        try await foregroundFlight.value

        XCTAssertTrue(service.isVehicleReady(for: vehicle))
        XCTAssertEqual(
            transport.recordedCommands.filter {
                $0.raw == "ATZ"
            }.count,
            2
        )
        XCTAssertEqual(
            transport.vehicleCommunicationConfirmationCount,
            1
        )
    }

    func testMode04RequiresFreshMatchingVINImmediatelyBeforeClear()
        async throws {
        let ecuVINResponse = asciiHex(vehicle.vin!)
        let transport = LifecycleTransport { command in
            switch command.raw {
            case "09 02":
                return ecuVINResponse
            case "04":
                return "44>"
            default:
                return lifecycleInitializationResponse(command)
            }
        }
        let service = OBDService(
            commandTransport: transport,
            capabilityCache: isolatedCapabilityCache
        )

        try await service.clearDTCs(for: vehicle)

        XCTAssertEqual(
            Array(transport.recordedCommands.map(\.raw).suffix(2)),
            ["09 02", "04"]
        )
    }

    func testMode04RejectsMismatchedVINWithoutSendingClear()
        async {
        let ecuVINResponse = asciiHex("1M8GDM9AXKP042788")
        let transport = LifecycleTransport { command in
            if command.raw == "09 02" {
                return ecuVINResponse
            }
            if command.raw == "04" {
                return "44>"
            }
            return lifecycleInitializationResponse(command)
        }
        let service = OBDService(
            commandTransport: transport,
            capabilityCache: isolatedCapabilityCache
        )

        do {
            try await service.clearDTCs(for: vehicle)
            XCTFail("A VIN mismatch must block destructive Mode 04")
        } catch let OBDError.commandFailed(message) {
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains("does not match")
            )
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertFalse(
            transport.recordedCommands.map(\.raw).contains("04")
        )
    }

    func testMode04FailsClosedWhenECUVINIsUnsupported()
        async {
        let transport = LifecycleTransport { command in
            if command.raw == "09 02" {
                return "NO DATA>"
            }
            if command.raw == "04" {
                return "44>"
            }
            return lifecycleInitializationResponse(command)
        }
        let service = OBDService(
            commandTransport: transport,
            capabilityCache: isolatedCapabilityCache
        )

        do {
            try await service.clearDTCs(for: vehicle)
            XCTFail("Unsupported VIN verification must block Mode 04")
        } catch let OBDError.commandFailed(message) {
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains(
                    "does not support Mode 09 VIN"
                )
            )
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertFalse(
            transport.recordedCommands.map(\.raw).contains("04")
        )
    }

    func testAdvancedDiagnosticsRejectsMismatchedVINBeforeMode06()
        async {
        let ecuVINResponse = asciiHex("1M8GDM9AXKP042788")
        let transport = LifecycleTransport { command in
            if command.raw == "09 02" {
                return ecuVINResponse
            }
            return lifecycleInitializationResponse(command)
        }
        let service = OBDService(
            commandTransport: transport,
            capabilityCache: isolatedCapabilityCache
        )

        do {
            _ = try await service.readAdvancedDiagnostics(
                for: vehicle,
                maximumMode06Monitors: 1,
                maximumDuration: 5
            )
            XCTFail("Mismatched ECU evidence must not be attributed")
        } catch let OBDError.commandFailed(message) {
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains("does not match")
            )
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertFalse(
            transport.recordedCommands.contains {
                $0.raw.hasPrefix("06")
            }
        )
    }

    func testAdvancedDiagnosticsRechecksVINBeforeReturningEvidence()
        async {
        let vinReadCount = LifecycleCounter()
        let matchingVIN = asciiHex(vehicle.vin!)
        let differentVIN = asciiHex("1M8GDM9AXKP042788")
        let transport = LifecycleTransport { command in
            switch command.raw {
            case "09 02":
                return await vinReadCount.next() == 1
                    ? matchingVIN
                    : differentVIN
            case "06 00":
                return "7E8 06 46 00 00 00 00 00>"
            default:
                return lifecycleInitializationResponse(command)
            }
        }
        let service = OBDService(
            commandTransport: transport,
            capabilityCache: isolatedCapabilityCache
        )

        do {
            _ = try await service.readAdvancedDiagnostics(
                for: vehicle,
                maximumMode06Monitors: 1,
                maximumDuration: 5
            )
            XCTFail("Evidence must not return after the live VIN changes")
        } catch let OBDError.commandFailed(message) {
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains("does not match")
            )
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertEqual(
            transport.recordedCommands.filter {
                $0.raw == "09 02"
            }.count,
            2
        )
        XCTAssertTrue(
            transport.recordedCommands.map(\.raw).contains("06 00")
        )
    }

    func testFullScanAcceptsMatchingStructurallyValidVIN() async throws {
        let (service, _) = makeVINScanService(
            ecuResponse: asciiHex("1HGCM82633A004352")
        )

        let scan = try await service.performFullScan(vehicle: vehicle)

        XCTAssertEqual(scan.vehicle.vin, vehicle.vin)
    }

    func testFullScanRejectsDifferentStructurallyValidVINBeforeDiagnostics()
        async {
        let (service, transport) = makeVINScanService(
            ecuResponse: asciiHex("1M8GDM9AXKP042788")
        )

        do {
            _ = try await service.performFullScan(vehicle: vehicle)
            XCTFail("A different valid ECU VIN must stop attribution")
        } catch let OBDError.commandFailed(message) {
            XCTAssertTrue(message.localizedCaseInsensitiveContains("VIN"))
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains("does not match")
            )
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertFalse(
            transport.recordedCommands.map(\.raw).contains("03")
        )
    }

    func testFullScanIgnoresMalformedECUVINForIdentityGate()
        async throws {
        let (service, _) = makeVINScanService(
            ecuResponse:
                "31 48 47 49 4F 51 32 36 33 33 41 30 30 34 33 35 32"
        )

        let scan = try await service.performFullScan(vehicle: vehicle)

        XCTAssertEqual(scan.vehicle.vin, vehicle.vin)
    }

    func testFullScanAllowsExplicitlyUnsupportedMode09VIN()
        async throws {
        let (service, _) = makeVINScanService(
            ecuResponse: "NO DATA>"
        )

        let scan = try await service.performFullScan(vehicle: vehicle)

        XCTAssertEqual(scan.vehicle.vin, vehicle.vin)
    }

    private func makeVINScanService(
        ecuResponse: String
    ) -> (OBDService, LifecycleTransport) {
        let transport = LifecycleTransport { command in
            switch command.raw {
            case "ATZ":
                return "ELM327 v2.3>"
            case "01 00":
                return "7E8 06 41 00 00 00 00 00>"
            case "ATDPN":
                return "A6>"
            case "09 02":
                return ecuResponse
            case "03":
                return "43 00 00>"
            case "07":
                return "47 00 00>"
            case "0A":
                return "4A 00 00>"
            case "01 01":
                return "41 01 00 07 00 00>"
            default:
                return command.raw.hasPrefix("AT") ? "OK>" : "NO DATA>"
            }
        }
        return (
            OBDService(
                commandTransport: transport,
                capabilityCache: LifecycleMemoryCapabilityStore()
            ),
            transport
        )
    }

    private func asciiHex(_ value: String) -> String {
        value.utf8.map {
            String(format: "%02X", $0)
        }.joined(separator: " ")
    }

}

private func lifecycleInitializationResponse(
    _ command: ELM327Command
) -> String {
    switch command.raw {
    case "ATZ":
        return "ELM327 v2.3>"
    case "01 00":
        return "7E8 06 41 00 00 00 00 00>"
    case "ATDPN":
        return "A6>"
    default:
        return command.raw.hasPrefix("AT") ? "OK>" : "NO DATA>"
    }
}

private final class LifecycleTransport:
    OBDCommandTransport,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var commands: [ELM327Command] = []
    private var generation: UInt64 = 1
    private var retirements = 0
    private var vehicleCommunicationConfirmations = 0
    private let generationChangeCommand: String?
    private let handler:
        @Sendable (ELM327Command) async throws -> String

    init(
        generationChangeCommand: String? = nil,
        handler: @escaping
            @Sendable (ELM327Command) async throws -> String
    ) {
        self.generationChangeCommand = generationChangeCommand
        self.handler = handler
    }

    var isConnected: Bool { true }

    var transportGeneration: UInt64 {
        locked { generation }
    }

    var recordedCommands: [ELM327Command] {
        locked { commands }
    }

    var retirementCount: Int {
        locked { retirements }
    }

    var vehicleCommunicationConfirmationCount: Int {
        locked { vehicleCommunicationConfirmations }
    }

    func sendCommand(_ command: ELM327Command) async throws -> String {
        record(command)
        return try await handler(command)
    }

    func retireAfterFatalInitializationFailure(
        expectedTransportGeneration: UInt64
    ) {
        locked {
            guard generation == expectedTransportGeneration else { return }
            retirements += 1
        }
    }

    func confirmVehicleCommunication(
        expectedTransportGeneration: UInt64
    ) {
        locked {
            guard generation == expectedTransportGeneration else { return }
            vehicleCommunicationConfirmations += 1
        }
    }

    private func record(_ command: ELM327Command) {
        locked {
            commands.append(command)
            if command.raw == generationChangeCommand {
                generation &+= 1
            }
        }
    }

    private func locked<Result>(
        _ body: () throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private final class LifecycleMemoryCapabilityStore:
    OBDVehicleCapabilityStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var records: [UUID: OBDVehicleCapabilities]

    init(records: [UUID: OBDVehicleCapabilities] = [:]) {
        self.records = records
    }

    func capabilities(
        for vehicleID: UUID
    ) -> OBDVehicleCapabilities? {
        locked { records[vehicleID] }
    }

    func save(_ capabilities: OBDVehicleCapabilities) {
        locked {
            records[capabilities.vehicleID] = capabilities
        }
    }

    private func locked<Result>(
        _ body: () throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private final class LifecycleStepClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func next() -> Date {
        lock.lock()
        defer {
            value += 1
            lock.unlock()
        }
        return Date(timeIntervalSince1970: value)
    }
}

private actor LifecycleCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}

private actor LifecycleAsyncGate {
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

    /// Parks the caller until its own task is cancelled. A supersede test can
    /// then release the first flight on the superseding cancellation instead of
    /// on a yield budget, which the first flight can outrun. The iteration cap
    /// only turns a missing cancellation into a failure rather than a hang.
    func enterAndWaitForCancellation() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        var remainingYields = 10_000
        while !Task.isCancelled, remainingYields > 0 {
            remainingYields -= 1
            await Task.yield()
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
