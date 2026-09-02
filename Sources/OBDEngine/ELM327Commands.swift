import Foundation

public struct ELM327Command: Sendable, Equatable {
    public let raw: String
    public let description: String
    public let timeout: TimeInterval

    public init(raw: String, description: String = "", timeout: TimeInterval = 1.0) {
        // ELM commands are one printable ASCII line. Removing control
        // characters prevents an imported/custom value from injecting a second
        // command through CR, LF, or NUL delimiters.
        self.raw = String(raw.unicodeScalars.filter {
            $0.value >= 0x20 && $0.value <= 0x7E
        })
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        self.description = description
        self.timeout = max(0.1, timeout)
    }

    public static let reset = ELM327Command(raw: "ATZ", description: "Reset adapter", timeout: 2.5)
    public static let echoOff = ELM327Command(raw: "ATE0", description: "Echo off")
    public static let headersOn = ELM327Command(raw: "ATH1", description: "Headers on")
    public static let headersOff = ELM327Command(raw: "ATH0", description: "Headers off")
    public static let lineFeedOff = ELM327Command(raw: "ATL0", description: "Linefeed off")
    public static let spacesOff = ELM327Command(raw: "ATS0", description: "Spaces off")
    public static let setProtocolAuto = ELM327Command(raw: "ATSP0", description: "Auto protocol", timeout: 5)
    public static let adaptiveTimingAuto = ELM327Command(raw: "ATAT1", description: "Adaptive timing")
    public static let memoryOff = ELM327Command(raw: "ATM0", description: "Disable saved protocol memory")
    public static let allowLongMessages = ELM327Command(raw: "ATAL", description: "Allow long messages")
    public static let canAutoFormattingOn = ELM327Command(
        raw: "ATCAF1",
        description: "Enable automatic CAN formatting"
    )
    public static let readVoltage = ELM327Command(raw: "ATRV", description: "Read voltage")
    public static let version = ELM327Command(raw: "ATI", description: "Adapter version")
    public static let protocolName = ELM327Command(raw: "ATDPN", description: "Protocol name")
    public static let warmStart = ELM327Command(raw: "ATWS", description: "Warm start")
    public static let protocolProbe = ELM327Command(
        raw: "01 00",
        description: "Discover vehicle protocol and supported PIDs",
        timeout: 30
    )
    /// Confirms a cached protocol lock before the service falls back to
    /// `ATSP0`.
    ///
    /// The deadline has to match `protocolProbe`. ISO 9141-2 and KWP2000
    /// 5-baud bus initialization needs several seconds before the ECU's first
    /// byte, and an expired command deadline fails this probe outright — the
    /// transport survives it now, but the automatic fallback would still be
    /// entered on evidence the adapter never actually produced, and the drain
    /// that follows costs the next command its own settle. A correct saved
    /// protocol answers long before this.
    public static let savedProtocolProbe = ELM327Command(
        raw: "01 00",
        description: "Verify saved vehicle protocol",
        timeout: 30
    )

    /// Adapter setup that is independent of vehicle protocol selection.
    ///
    /// Keeping `ATSP0` out of this sequence lets the service verify a
    /// vehicle-scoped saved protocol first without starting a second automatic
    /// search or accidentally reusing another vehicle's protocol.
    public static let adapterSetupSequence: [ELM327Command] = [
        .reset, .echoOff, .lineFeedOff, .spacesOff,
        .headersOn, .canAutoFormattingOn, .allowLongMessages,
        .adaptiveTimingAuto,
    ]

    /// Compatibility sequence for callers that always want a cold automatic
    /// protocol search.
    public static let initSequence: [ELM327Command] = [
        .reset, .echoOff, .lineFeedOff, .spacesOff,
        .headersOn, .canAutoFormattingOn, .allowLongMessages,
        .adaptiveTimingAuto, .setProtocolAuto,
    ]

    public static let closeSequence: [ELM327Command] = [
        ELM327Command(raw: "ATPC", description: "Protocol close"),
    ]

    public static func readPID(_ hexCode: String) -> ELM327Command {
        let pid = normalizedByte(hexCode)
        return ELM327Command(raw: "01 \(pid)", description: "Read PID \(pid) (Mode 01)", timeout: 1)
    }

    public static func readStoredDTCs() -> ELM327Command {
        ELM327Command(raw: "03", description: "Read stored DTCs (Mode 03)", timeout: 2.0)
    }

    public static func readPendingDTCs() -> ELM327Command {
        ELM327Command(raw: "07", description: "Read pending DTCs (Mode 07)", timeout: 2.0)
    }

    public static func readPermanentDTCs() -> ELM327Command {
        ELM327Command(raw: "0A", description: "Read permanent DTCs (Mode 0A)", timeout: 2.0)
    }

    public static func clearDTCs() -> ELM327Command {
        ELM327Command(raw: "04", description: "Clear DTCs (Mode 04)", timeout: 3.0)
    }

    public static func readVIN() -> ELM327Command {
        ELM327Command(raw: "09 02", description: "Read VIN (Mode 09 PID 02)", timeout: 3.0)
    }

    public static func readECUName() -> ELM327Command {
        ELM327Command(raw: "09 0A", description: "Read ECU name (Mode 09 PID 0A)", timeout: 2.0)
    }

    public static func readCalibrationID() -> ELM327Command {
        ELM327Command(raw: "09 04", description: "Read calibration ID (Mode 09 PID 04)", timeout: 2.0)
    }

    public static func readFreezeFrame(_ dtcCode: String) -> ELM327Command {
        // Kept for source compatibility. Mode 02 is addressed by PID and frame
        // number, not by a five-character DTC.
        let pid = dtcCode.count <= 2 ? normalizedByte(dtcCode) : "00"
        return readFreezeFramePID(pid)
    }

    public static func readFreezeFramePID(_ hexCode: String, frameNumber: UInt8 = 0) -> ELM327Command {
        let pid = normalizedByte(hexCode)
        return ELM327Command(
            raw: String(format: "02 %@ %02X", pid, frameNumber),
            description: "Read freeze-frame PID \(pid), frame \(frameNumber) (Mode 02)",
            timeout: 2
        )
    }

    public static func readO2SensorResults() -> ELM327Command {
        ELM327Command(raw: "05", description: "Read O2 sensor test results (Mode 05)", timeout: 2.0)
    }

    public static func readMode6TestResults(_ testID: String) -> ELM327Command {
        let id = normalizedByte(testID)
        return ELM327Command(raw: "06 \(id)", description: "Read Mode 06 test \(id)", timeout: 2.0)
    }

    /// Reads one page of the Mode 01 support bitmap.
    ///
    /// The deadline matches `protocolProbe` for the same reason: an expired
    /// page deadline takes the "keep the confirmed pages and stop discovery"
    /// path (the quarantine leaves the transport generation intact, so the
    /// catch's transport check passes), and that truncated support set is
    /// persisted in the capability cache. A page that is merely slow on a
    /// marginal bus must get the time to answer rather than being recorded
    /// as absent for every later scan. A vehicle without the page still
    /// answers quickly — the adapter's own `ST` timer returns `NO DATA` — so
    /// the long deadline only bites when the adapter has genuinely stopped
    /// responding.
    public static func readSupportedPIDs(range: Int) -> ELM327Command {
        let boundedRange = min(max(range, 0), 0xE0)
        return ELM327Command(
            raw: String(format: "01 %02X", boundedRange),
            description: String(format: "Read supported PIDs for range %02X", boundedRange),
            timeout: 30
        )
    }

    /// Locks the adapter to a protocol previously confirmed for this vehicle.
    ///
    /// `ATDPN` prefixes automatically selected protocols with `A` (for example
    /// `A6`). `ATSP` expects only the underlying protocol code.
    public static func setProtocol(
        _ protocolIdentifier: String
    ) -> ELM327Command? {
        let normalized = protocolIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let code: Character?
        if normalized.count == 1 {
            code = normalized.first
        } else if normalized.count == 2, normalized.first == "A" {
            code = normalized.last
        } else {
            code = nil
        }
        guard let code, "123456789ABC".contains(code) else {
            return nil
        }
        return ELM327Command(
            raw: "ATSP\(code)",
            description: "Use saved vehicle protocol \(code)",
            timeout: 3
        )
    }

    private static func normalizedByte(_ value: String) -> String {
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "0X", with: "")
        guard let byte = UInt8(cleaned, radix: 16) else { return "00" }
        return String(format: "%02X", byte)
    }
}
