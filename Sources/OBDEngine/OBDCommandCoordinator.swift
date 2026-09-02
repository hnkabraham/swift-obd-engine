import Foundation

enum OBDCommandCoordinatorError: LocalizedError {
    case restorationFailed(String)

    var errorDescription: String? {
        switch self {
        case .restorationFailed(let detail):
            return "The adapter header could not be restored after the enhanced request. \(detail)"
        }
    }
}

/// Whether an ELM `STOPPED` response may be retried once.
///
/// `STOPPED` is what an ELM327 answers when a command arrives while it is still
/// searching for a protocol: the search is abandoned, this command is never
/// run, and the adapter returns to a fresh prompt. That makes the failure
/// transient by construction — unlike `NO DATA` or a negative response, it says
/// nothing about the command or the vehicle — so repeating the command once
/// from the fresh prompt is what restores command synchronization.
///
/// The permission is deliberately narrow. A retry is only safe for a command
/// whose second execution is indistinguishable from its first, so it covers
/// adapter configuration (`AT…`) and the read-only OBD modes. Mode 04 (clear
/// DTCs) and anything else that writes to the vehicle are excluded: `STOPPED`
/// proves the search was interrupted, not that the request never reached the
/// bus, and a repeated clear is not recoverable.
enum OBDStoppedRetryPolicy {
    /// Modes whose responses are reads: current data, freeze frames, stored /
    /// pending / permanent DTCs, on-board test results, and vehicle info.
    static let idempotentModes: Set<String> = [
        "01", "02", "03", "06", "07", "09", "0A",
    ]

    /// Error tokens that describe a different failure than an interrupted
    /// protocol search. A response carrying any of them is not retried, even
    /// when `STOPPED` also appears: only one of the two can be the reason.
    private static let competingErrorTokens = [
        "ERROR", "UNABLETOCONNECT", "CANERROR", "BUSERROR", "BUFFERFULL",
    ]

    static func normalized(_ text: String) -> String {
        text
            .uppercased()
            .filter { !$0.isWhitespace && $0 != ">" }
    }

    static func isIdempotentReadOnly(_ command: ELM327Command) -> Bool {
        let raw = normalized(command.raw)
        guard !raw.isEmpty else { return false }
        if raw.hasPrefix("AT") { return true }
        return idempotentModes.contains(String(raw.prefix(2)))
    }

    /// `retryCount` is the number of retries already spent, so exactly one is
    /// ever permitted: a second `STOPPED` is the adapter's answer, not noise.
    static func shouldRetry(
        command: ELM327Command,
        response: String,
        retryCount: Int
    ) -> Bool {
        guard retryCount == 0 else { return false }
        let cleaned = normalized(response)
        guard cleaned.contains("STOPPED"),
              !competingErrorTokens.contains(where: cleaned.contains) else {
            return false
        }
        return isIdempotentReadOnly(command)
    }
}

/// Applies ``OBDStoppedRetryPolicy`` to every command sent through it.
///
/// This sits directly under the command serializers, so the retry always runs
/// inside the caller's reservation: no other command can slip between the
/// `STOPPED` and the repeat, which is the whole point of retrying from a known
/// prompt. It owns no state — the retry budget is the single boolean above.
struct OBDStoppedRetryingTransport: OBDCommandTransport {
    /// The adapter reports `STOPPED` as it abandons the search; the settle lets
    /// it finish returning to the prompt before the repeat arrives, instead of
    /// interrupting it a second time.
    static let settleInterval: TimeInterval = 0.1

    private let base: any OBDCommandTransport
    private let settle: @Sendable () async -> Void

    init(
        base: any OBDCommandTransport,
        settle: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(
                nanoseconds: UInt64(
                    OBDStoppedRetryingTransport.settleInterval * 1_000_000_000
                )
            )
        }
    ) {
        self.base = base
        self.settle = settle
    }

    var isConnected: Bool { base.isConnected }

    var transportGeneration: UInt64 { base.transportGeneration }

    func retireAfterFatalInitializationFailure(
        expectedTransportGeneration: UInt64
    ) {
        base.retireAfterFatalInitializationFailure(
            expectedTransportGeneration: expectedTransportGeneration
        )
    }

    func confirmVehicleCommunication(expectedTransportGeneration: UInt64) {
        base.confirmVehicleCommunication(
            expectedTransportGeneration: expectedTransportGeneration
        )
    }

    func sendCommand(_ command: ELM327Command) async throws -> String {
        let response = try await base.sendCommand(command)
        guard OBDStoppedRetryPolicy.shouldRetry(
            command: command,
            response: response,
            retryCount: 0
        ) else {
            return response
        }
        await settle()
        // A cancelled operation must not spend the retry it no longer wants.
        try Task.checkCancellation()
        return try await base.sendCommand(command)
    }
}

/// Serializes every high-level OBD command and supports indivisible batches.
///
/// `OBDConnectionManager` already serializes bytes on the wire, but separately
/// enqueued commands from concurrent tasks can still interleave. Enhanced
/// physical-address transactions must set a module header, perform a request,
/// and restore the functional header without a live-data poll entering between
/// those steps.
actor OBDCommandCoordinator {
    private let transport: any OBDCommandTransport
    private var isReserved = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(transport: any OBDCommandTransport) {
        self.transport = transport
    }

    func send(_ command: ELM327Command) async throws -> String {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await transport.sendCommand(command)
    }

    /// Executes a header/request/restoration sequence as one queue reservation.
    ///
    /// The caller supplies restoration commands separately so they are still
    /// attempted if a preparation command or request fails.
    func sendExclusive(
        preparation: [ELM327Command],
        request: ELM327Command,
        restoration: [ELM327Command]
    ) async throws -> String {
        await acquire()
        defer { release() }

        var primaryError: Error?
        var response: String?
        do {
            try Task.checkCancellation()
            for command in preparation {
                let response = try await transport.sendCommand(command)
                try validateControlResponse(response, command: command)
            }
            response = try await transport.sendCommand(request)
        } catch {
            primaryError = error
        }

        var restorationError: Error?
        for command in restoration {
            do {
                let response = try await transport.sendCommand(command)
                try validateControlResponse(response, command: command)
            } catch {
                restorationError = restorationError ?? error
            }
        }

        if let restorationError {
            throw OBDCommandCoordinatorError.restorationFailed(
                restorationError.localizedDescription
            )
        }
        if let primaryError {
            throw primaryError
        }
        guard let response else {
            throw OBDError.invalidResponse
        }
        return response
    }

    private func acquire() async {
        if !isReserved {
            isReserved = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isReserved = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func validateControlResponse(
        _ response: String,
        command: ELM327Command
    ) throws {
        let normalized = response
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: ">", with: "")
        guard normalized.contains("OK"),
              !normalized.contains("ERROR"),
              !normalized.contains("STOPPED"),
              !normalized.contains("UNABLETOCONNECT"),
              !normalized.contains("CANERROR"),
              normalized != "?" else {
            throw OBDError.commandFailed(
                "Adapter rejected \(command.raw)"
            )
        }
    }
}
