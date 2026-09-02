import Foundation
import XCTest

#if SWIFT_PACKAGE
@testable import OBDModels
@testable import OBDEngine
#else
#endif

// MARK: - Fixtures

/// A transport that answers from a script and records what it was asked.
///
/// The retry under test is a second `sendCommand` for the same command, so the
/// recorded order is the assertion: nothing else can distinguish "retried once"
/// from "answered once" at this layer.
private final class ScriptedRetryTransport: OBDCommandTransport, @unchecked Sendable {
    let isConnected = true
    private(set) var sent: [String] = []
    private var responses: [String: [String]]
    private let fallback: String

    /// `responses` maps a raw command to the answers it gets, in order. The
    /// last answer repeats once the script runs out.
    init(responses: [String: [String]], fallback: String = "OK") {
        self.responses = responses
        self.fallback = fallback
    }

    func sendCommand(_ command: ELM327Command) async throws -> String {
        sent.append(command.raw)
        guard var scripted = responses[command.raw], !scripted.isEmpty else {
            return fallback
        }
        let next = scripted.removeFirst()
        if !scripted.isEmpty {
            responses[command.raw] = scripted
        }
        return next
    }
}

// MARK: - Tests

/// Fixture coverage for the single `STOPPED` retry.
///
/// `STOPPED` is the ELM327's answer when a command lands during a protocol
/// search: the search is abandoned and the command never runs, so the failure
/// is transient by construction. These tests pin both halves of the policy —
/// the one retry that recovers it, and the commands that must never be repeated
/// no matter what the adapter says.
final class OBDStoppedRetryPolicyTests: XCTestCase {
    // MARK: 1. The pure predicate

    func testIdempotentReadOnlyCommandsAreRetriedOnce() {
        for raw in [
            "ATZ", "ATSP0", "ATDPN", "0100", "01 0C", "02 05 00", "03",
            "06 01", "07", "09 02", "0A",
        ] {
            XCTAssertTrue(
                OBDStoppedRetryPolicy.shouldRetry(
                    command: ELM327Command(raw: raw),
                    response: "STOPPED",
                    retryCount: 0
                ),
                "\(raw) is read-only, so repeating it is indistinguishable "
                    + "from running it once."
            )
        }
    }

    func testCommandsThatChangeVehicleStateAreNeverRetried() {
        // `STOPPED` proves the search was interrupted, not that the request
        // never reached the bus. Mode 04 is the one that cannot be taken back.
        for raw in ["04", "0401", "05", "08 01", "2F", "31 01 02"] {
            XCTAssertFalse(
                OBDStoppedRetryPolicy.shouldRetry(
                    command: ELM327Command(raw: raw),
                    response: "STOPPED",
                    retryCount: 0
                ),
                "\(raw) is not a read whose repeat is guaranteed harmless."
            )
        }
        XCTAssertFalse(
            OBDStoppedRetryPolicy.isIdempotentReadOnly(
                ELM327Command.clearDTCs()
            )
        )
        XCTAssertTrue(
            OBDStoppedRetryPolicy.isIdempotentReadOnly(
                ELM327Command.readStoredDTCs()
            )
        )
    }

    func testOnlyAStoppedResponseAndOnlyTheFirstRetryQualify() {
        let command = ELM327Command.readStoredDTCs()

        // Formatting varies by adapter: spaces, echoed prompt, lower case.
        for response in ["STOPPED", "stopped\r>", "  STOPPED  \r\n>"] {
            XCTAssertTrue(
                OBDStoppedRetryPolicy.shouldRetry(
                    command: command,
                    response: response,
                    retryCount: 0
                ),
                "\(response) is a STOPPED response."
            )
        }

        for response in ["NO DATA", "43 00", "?", "", "UNABLE TO CONNECT"] {
            XCTAssertFalse(
                OBDStoppedRetryPolicy.shouldRetry(
                    command: command,
                    response: response,
                    retryCount: 0
                ),
                "\(response) is not an interrupted protocol search."
            )
        }

        // A response carrying a second failure is not explained by the search.
        XCTAssertFalse(
            OBDStoppedRetryPolicy.shouldRetry(
                command: command,
                response: "STOPPED\rBUS ERROR",
                retryCount: 0
            )
        )

        XCTAssertFalse(
            OBDStoppedRetryPolicy.shouldRetry(
                command: command,
                response: "STOPPED",
                retryCount: 1
            ),
            "A second STOPPED is the adapter's answer, not a transient."
        )
    }

    // MARK: 2. The retry in the serialized send path

    func testIdempotentCommandIsRetriedOnceAndSucceedsOnTheRetry() async throws {
        let transport = ScriptedRetryTransport(
            responses: ["03": ["STOPPED", "43 01 01 33"]]
        )
        var settles = 0
        let retrying = OBDStoppedRetryingTransport(
            base: transport,
            settle: { settles += 1 }
        )

        let response = try await retrying.sendCommand(
            ELM327Command.readStoredDTCs()
        )

        XCTAssertEqual(response, "43 01 01 33")
        XCTAssertEqual(
            transport.sent,
            ["03", "03"],
            "The retry is one repeat of the same command."
        )
        XCTAssertEqual(
            settles,
            1,
            "The adapter is still returning to its prompt when STOPPED "
                + "arrives, so the repeat waits for it."
        )
    }

    func testClearDTCsIsNotRetriedAndSurfacesTheStoppedResponse() async throws {
        let transport = ScriptedRetryTransport(
            responses: ["04": ["STOPPED", "44"]]
        )
        var settles = 0
        let retrying = OBDStoppedRetryingTransport(
            base: transport,
            settle: { settles += 1 }
        )

        let response = try await retrying.sendCommand(ELM327Command.clearDTCs())

        XCTAssertEqual(response, "STOPPED")
        XCTAssertEqual(
            transport.sent,
            ["04"],
            "A clear that may already have reached the bus is never repeated."
        )
        XCTAssertEqual(settles, 0)
    }

    func testSecondStoppedSurfacesTheFailure() async throws {
        let transport = ScriptedRetryTransport(
            responses: ["0100": ["STOPPED", "STOPPED", "41 00 BE 3F A8 13"]]
        )
        var settles = 0
        let retrying = OBDStoppedRetryingTransport(
            base: transport,
            settle: { settles += 1 }
        )

        let response = try await retrying.sendCommand(
            ELM327Command(raw: "0100", timeout: 5)
        )

        XCTAssertEqual(
            response,
            "STOPPED",
            "The retry is single: a second STOPPED is reported, not retried "
                + "into an unbounded loop."
        )
        XCTAssertEqual(transport.sent, ["0100", "0100"])
        XCTAssertEqual(settles, 1)
    }

    /// A `STOPPED` that survives the retry still has to fail the command it was
    /// running, and the coordinator's control-response validation is what does
    /// that for header/configuration steps.
    func testPersistentStoppedFailsTheExclusiveTransaction() async {
        let transport = ScriptedRetryTransport(
            responses: ["ATSH7E0": ["STOPPED", "STOPPED"]]
        )
        let coordinator = OBDCommandCoordinator(
            transport: OBDStoppedRetryingTransport(
                base: transport,
                settle: {}
            )
        )

        do {
            let response = try await coordinator.sendExclusive(
                preparation: [ELM327Command(raw: "ATSH7E0")],
                request: ELM327Command(raw: "22 F1 90", timeout: 2),
                restoration: [ELM327Command(raw: "ATSH7DF")]
            )
            XCTFail("A rejected header must not run the request, got \(response).")
        } catch {
            XCTAssertTrue(
                error is OBDError || error is OBDCommandCoordinatorError,
                "Unexpected error: \(error)"
            )
        }
        XCTAssertEqual(
            transport.sent,
            ["ATSH7E0", "ATSH7E0", "ATSH7DF"],
            "The header is retried once, then the transaction fails and the "
                + "functional header is still restored."
        )
    }

    // MARK: 3. The wiring

    /// The retry has to be installed where every send already passes through,
    /// including the adapter-setup sequence that `performExclusive` runs — the
    /// place an interrupted protocol search actually happens.
    func testServiceInitializationRecoversFromAStoppedProtocolProbe() async throws {
        let transport = ScriptedRetryTransport(
            responses: [
                "01 00": ["STOPPED", "41 00 BE 3F A8 13"],
                "ATDPN": ["A6"],
            ]
        )
        let service = OBDService(commandTransport: transport)

        try await service.initialize()

        XCTAssertEqual(service.detectedProtocolIdentifier, "A6")
        XCTAssertEqual(
            transport.sent.filter { $0 == "01 00" }.count,
            2,
            "The probe that interrupted the protocol search is retried once "
                + "instead of failing initialization."
        )
    }
}
