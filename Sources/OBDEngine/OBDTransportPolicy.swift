import Foundation

/// Minimal command-deadline state machine. A response timeout is ineligible
/// until the selected transport has accepted the command's final byte.
struct OBDCommandDeadlineState: Equatable {
    enum Phase: Equatable {
        case idle
        case writing
        case awaitingResponse
        case readyToComplete
    }

    private(set) var phase: Phase = .idle
    private var responseArrivedWhileWriting = false

    var isWriting: Bool {
        phase == .writing
    }

    var responseDeadlineCanRun: Bool {
        phase == .awaitingResponse
    }

    var transactionCanComplete: Bool {
        phase == .readyToComplete
    }

    mutating func beginWrite() {
        responseArrivedWhileWriting = false
        phase = .writing
    }

    @discardableResult
    mutating func markAllBytesAccepted() -> Bool {
        guard phase == .writing else { return false }
        phase = responseArrivedWhileWriting
            ? .readyToComplete
            : .awaitingResponse
        return true
    }

    mutating func markResponseReceived() {
        switch phase {
        case .writing:
            responseArrivedWhileWriting = true
        case .awaitingResponse:
            phase = .readyToComplete
        case .idle, .readyToComplete:
            break
        }
    }

    mutating func reset() {
        responseArrivedWhileWriting = false
        phase = .idle
    }
}

/// Owns the prompt boundary after a command's response deadline expires.
///
/// A timed-out command is not finished from the adapter's perspective: its
/// bytes can still arrive, and on a half-duplex ELM link those bytes would
/// otherwise complete whichever command owns the stream next. Retiring the
/// transport used to be the only thing preventing that. This state machine
/// replaces the retirement with a quarantine: every byte is discarded until the
/// `>` prompt closes the stale response, and a quiet window after that prompt
/// decides whether the adapter is genuinely finished talking.
///
/// Nothing is buffered. The drain only has to answer two questions — has a
/// prompt arrived, and has anything non-blank followed it — so a noisy adapter
/// cannot grow this state, and its own deadline bounds how long it may talk.
struct OBDResponseDrainState: Equatable {
    enum Phase: Equatable {
        /// No quarantine: the command queue owns the stream.
        case inactive
        /// Bytes are being discarded and no prompt has closed them yet.
        case awaitingPrompt
        /// A prompt arrived with nothing after it. The quiet window now decides
        /// whether the stream is really idle.
        case settling
    }

    private(set) var phase: Phase = .inactive
    /// Tags the deadlines a drain owns so a superseded drain's timer is inert.
    private(set) var generation: UInt64 = 0
    private var promptObserved = false
    private var trailingBytesAreBlank = true

    var isDraining: Bool {
        phase != .inactive
    }

    /// Opens a quarantine and returns the generation its deadlines carry.
    mutating func begin() -> UInt64 {
        generation &+= 1
        promptObserved = false
        trailingBytesAreBlank = true
        phase = .awaitingPrompt
        return generation
    }

    /// Discards quarantined bytes. Returns `true` when the stream sits at a
    /// prompt with nothing after it, which is when the quiet window may run.
    ///
    /// Bytes that follow a prompt reopen the drain: a late response and the
    /// adapter's own prompt both end in `>`, so only silence proves the stale
    /// traffic is over.
    @discardableResult
    mutating func ingest(_ text: String) -> Bool {
        guard isDraining else { return false }

        let trailing: Substring
        if let prompt = text.lastIndex(of: ">") {
            promptObserved = true
            trailingBytesAreBlank = true
            trailing = text[text.index(after: prompt)...]
        } else {
            trailing = Substring(text)
        }
        if !trailing.allSatisfy(\.isWhitespace) {
            trailingBytesAreBlank = false
        }

        phase = promptObserved && trailingBytesAreBlank ? .settling : .awaitingPrompt
        return phase == .settling
    }

    /// Closes the quarantine once the quiet window elapsed on the drain that
    /// armed it. A superseded generation or renewed adapter chatter declines.
    mutating func finishSettling(generation expected: UInt64) -> Bool {
        guard phase == .settling,
              generation == expected else {
            return false
        }
        reset()
        return true
    }

    mutating func reset() {
        phase = .inactive
        promptObserved = false
        trailingBytesAreBlank = true
    }
}

/// Counts consecutive recovery attempts until higher layers confirm that the
/// adapter can communicate with an ECU. Opening a physical byte stream alone
/// is deliberately not success: otherwise a deterministic initialization
/// failure can reconnect forever while resetting its own budget each time.
struct OBDReconnectTracker: Equatable {
    let maximumAttempts: Int
    private(set) var attempts = 0

    init(maximumAttempts: Int) {
        self.maximumAttempts = max(0, maximumAttempts)
    }

    mutating func reset() {
        attempts = 0
    }

    mutating func consumeAttemptIfEligible(
        automaticReconnectEnabled: Bool,
        wasIntentionalDisconnect: Bool
    ) -> Int? {
        guard OBDTransportPolicy.shouldReconnect(
            automaticReconnectEnabled: automaticReconnectEnabled,
            wasIntentionalDisconnect: wasIntentionalDisconnect,
            attempt: attempts,
            maximumAttempts: maximumAttempts
        ) else {
            return nil
        }
        let consumed = attempts
        attempts += 1
        return consumed
    }

    @discardableResult
    mutating func confirmVehicleCommunication(
        expectedGeneration: UInt64,
        activeGeneration: UInt64
    ) -> Bool {
        guard OBDTransportPolicy.generationIsCurrent(
            expected: expectedGeneration,
            active: activeGeneration
        ) else {
            return false
        }
        reset()
        return true
    }
}

/// Pure transport rules shared by the live CoreBluetooth /
/// ExternalAccessory manager and hardware-independent tests.
///
/// Keeping these decisions free of Apple transport objects makes reconnect,
/// generation, stream-lifecycle, and partial-write behavior deterministic.
enum OBDTransportPolicy {
    static let supportedAccessoryProtocols = ["com.obdlink"]

    static func matchingAccessoryProtocol(
        from protocolStrings: [String]
    ) -> String? {
        protocolStrings.first { candidate in
            supportedAccessoryProtocols.contains {
                $0.caseInsensitiveCompare(candidate) == .orderedSame
            }
        }
    }

    static func mfiAccessorySelectionIsAmbiguous(
        compatibleAccessoryCount: Int
    ) -> Bool {
        compatibleAccessoryCount > 1
    }

    static func accessoryStreamsAreUsable(
        input: Stream.Status,
        output: Stream.Status
    ) -> Bool {
        streamCanCarryBytes(input) && streamCanCarryBytes(output)
    }

    static func streamCanCarryBytes(_ status: Stream.Status) -> Bool {
        switch status {
        case .opening, .open, .reading, .writing:
            return true
        case .notOpen, .atEnd, .closed, .error:
            return false
        @unknown default:
            return false
        }
    }

    static func accessoryWriteProgress(
        totalBytes: Int,
        currentOffset: Int,
        acceptedBytes: Int
    ) -> Int? {
        guard totalBytes >= 0,
              currentOffset >= 0,
              currentOffset <= totalBytes,
              acceptedBytes >= 0,
              acceptedBytes <= totalBytes - currentOffset else {
            return nil
        }
        return currentOffset + acceptedBytes
    }

    static func accessoryWriteCompleted(
        totalBytes: Int,
        offset: Int
    ) -> Bool {
        totalBytes >= 0 && offset == totalBytes
    }

    static func generationIsCurrent(
        expected: UInt64,
        active: UInt64
    ) -> Bool {
        expected == active
    }

    static func publishedConnectionNeedsRediscovery(
        publishedConnected: Bool,
        transportIsUsable: Bool
    ) -> Bool {
        publishedConnected && !transportIsUsable
    }

    static func healthyConnectionShouldBeRepublished(
        publishedConnected: Bool,
        transportIsUsable: Bool
    ) -> Bool {
        publishedConnected && transportIsUsable
    }

    static func fatalRetirementIsEligible(
        expectedGeneration: UInt64,
        activeGeneration: UInt64,
        hasLiveTransport: Bool
    ) -> Bool {
        hasLiveTransport &&
            generationIsCurrent(
                expected: expectedGeneration,
                active: activeGeneration
            )
    }

    static func shouldReconnect(
        automaticReconnectEnabled: Bool,
        wasIntentionalDisconnect: Bool,
        attempt: Int,
        maximumAttempts: Int
    ) -> Bool {
        automaticReconnectEnabled &&
            !wasIntentionalDisconnect &&
            attempt >= 0 &&
            attempt < maximumAttempts
    }

    static func reconnectDelay(
        attempt: Int,
        baseDelay: TimeInterval,
        maximumDelay: TimeInterval = 4
    ) -> TimeInterval {
        guard baseDelay > 0, maximumDelay > 0 else { return 0 }
        let exponent = max(0, min(attempt, 8))
        return min(baseDelay * pow(2, Double(exponent)), maximumDelay)
    }
}
