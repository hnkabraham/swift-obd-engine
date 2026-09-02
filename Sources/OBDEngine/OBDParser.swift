import Foundation
#if SWIFT_PACKAGE
import OBDModels
#endif

public protocol OBDParserProtocol {
    func parsePIDValue(hexCode: String, rawBytes: [UInt8], definition: PIDDefinition) -> PIDValue?
    func parseDTCs(from rawData: String) -> [String]
    func parseFreezeFrameDTC(from rawData: String, frameNumber: UInt8) -> String?
    func parseVIN(from rawData: String) -> String?
    func parseReadinessMonitors(pidData: [UInt8]) -> [ReadinessMonitor]?
}

/// One diagnostic payload plus the ECU/header identity that produced it.
///
/// Existing callers can continue using `responsePayloads(from:)`; this richer
/// form is available when multi-ECU attribution matters.
public struct AddressedOBDResponsePayload: Equatable, Sendable {
    public let sourceAddress: String?
    public let bytes: [UInt8]
    /// True when the frame arrived on a legacy transport (J1850, ISO 9141-2,
    /// ISO 14230) whose checksummed header was stripped during parsing. Such
    /// payloads are service-leading without a CAN count byte, so consumers
    /// must not apply CAN-shaped decoding rules.
    public let isLegacyTransport: Bool
    /// True when the payload was reassembled from ATCAF1-numbered print
    /// lines. Automatic formatting exists only on ISO 15765 (CAN), so these
    /// payloads follow CAN shapes — a Mode 03 list is `43 <count> <pairs>` —
    /// even when the adapter printed no header tokens for them.
    public let isCAF1Formatted: Bool

    public init(
        sourceAddress: String?,
        bytes: [UInt8],
        isLegacyTransport: Bool = false,
        isCAF1Formatted: Bool = false
    ) {
        self.sourceAddress = sourceAddress
        self.bytes = bytes
        self.isLegacyTransport = isLegacyTransport
        self.isCAF1Formatted = isCAF1Formatted
    }
}

/// Turns ELM327 text responses into typed OBD-II values.
///
/// Adapters vary considerably: some echo commands, some include CAN headers and
/// ISO-TP PCI bytes, and some return compact hexadecimal strings. The parser
/// accepts all of those forms and deliberately ignores adapter status text.
public final class OBDParser: OBDParserProtocol {
    private static let positiveResponseServices: Set<UInt8> = [
        0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x49, 0x4A,
    ]

    private static let twoBytePIDs: Set<String> = [
        "0C", "10", "1F", "21", "23",
        "3C", "3E", "42", "43", "44",
    ]

    private static let fourBytePIDs: Set<String> = ["24", "25"]

    public init() {}

    // MARK: - PID values

    public func parsePIDValue(
        hexCode: String,
        rawBytes: [UInt8],
        definition: PIDDefinition
    ) -> PIDValue? {
        let normalizedCode = Self.normalizedPID(hexCode)
        guard normalizedCode == Self.normalizedPID(definition.hexCode) else { return nil }

        let requiredCount = expectedDataByteCount(for: normalizedCode, equation: definition.equation)
        guard rawBytes.count >= requiredCount else { return nil }
        let bytes = Array(rawBytes.prefix(requiredCount))

        let value: Double
        switch definition.equation {
        case .linear(let multiplier, let offset):
            let combined = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            value = Double(combined) * multiplier + offset

        case .bitEncoded(let mask, let shift):
            guard shift >= 0, shift < 8 else { return nil }
            value = Double((bytes[0] & mask) >> UInt8(shift))

        case .custom(let formula):
            guard let evaluated = evaluateCustomFormula(formula, bytes: bytes) else { return nil }
            value = evaluated
        }

        guard value.isFinite else { return nil }
        return PIDValue(pid: definition, value: value)
    }

    /// Parses a complete Mode 01 ELM327 response for one PID.
    public func parsePIDResponse(
        _ rawData: String,
        definition: PIDDefinition,
        responseService: UInt8 = 0x41,
        frameNumber: UInt8 = 0
    ) -> PIDValue? {
        guard let pid = UInt8(Self.normalizedPID(definition.hexCode), radix: 16) else { return nil }

        // More than one ECU can answer the same Mode 01 request, and a gateway
        // or secondary module often replies `00 00`. Taking whichever arrived
        // first made the reading order-dependent — a running engine could show
        // 0 rpm. Collect every responder and resolve deterministically by the
        // lowest response address, which is the primary powertrain module.
        // (`readCustomPID` already applies this rule for imported PIDs.)
        var candidates: [(address: String, value: PIDValue)] = []

        for payload in decodedAddressedFrames(from: rawData) {
            let frame = payload.bytes
            guard let serviceIndex = frame.firstIndex(of: responseService),
                  frame.indices.contains(serviceIndex + 1),
                  frame[serviceIndex + 1] == pid else {
                continue
            }

            var dataStart = serviceIndex + 2
            if responseService == 0x42 {
                guard frame.indices.contains(dataStart),
                      frame[dataStart] == frameNumber else {
                    continue
                }
                dataStart += 1
            }
            guard dataStart < frame.endIndex else { continue }
            let bytes = Array(frame[dataStart...])
            if let value = parsePIDValue(
                hexCode: definition.hexCode,
                rawBytes: bytes,
                definition: definition
            ) {
                // Unaddressed (legacy) frames sort first and keep the previous
                // single-responder behaviour unchanged.
                candidates.append((payload.sourceAddress ?? "", value))
            }
        }

        return candidates
            .sorted { $0.address < $1.address }
            .first?
            .value
    }

    public func expectedDataByteCount(for hexCode: String) -> Int {
        expectedDataByteCount(for: Self.normalizedPID(hexCode), equation: nil)
    }

    private func expectedDataByteCount(
        for normalizedCode: String,
        equation: PIDDefinition.PIDEquation?
    ) -> Int {
        if case .bitEncoded? = equation {
            return 1
        }
        if Self.fourBytePIDs.contains(normalizedCode) {
            return 4
        }
        return Self.twoBytePIDs.contains(normalizedCode) ? 2 : 1
    }

    private func evaluateCustomFormula(_ formula: String, bytes: [UInt8]) -> Double? {
        let normalized = formula
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
        let a = Double(bytes[safe: 0] ?? 0)
        let b = Double(bytes[safe: 1] ?? 0)
        let combined = (a * 256) + b

        switch normalized {
        case "A":
            return a
        case "A-40":
            return a - 40
        case "A/2-64", "(A/2)-64":
            return (a / 2) - 64
        case "(A*256+B)/4", "((A*256)+B)/4":
            return combined / 4
        case "(A*256+B)/100", "((A*256)+B)/100":
            return combined / 100
        case "(A*256+B)/32768", "((A*256)+B)/32768":
            return combined / 32_768
        case "2*((A*256)+B)/32768", "(2*((A*256)+B))/32768", "(2*(A*256+B))/32768":
            return (combined * 2) / 32_768
        case "2*((A*256)+B)/65536", "(2*((A*256)+B))/65536", "(2*(A*256+B))/65536":
            return (combined * 2) / 65_536
        case "(A*256+B)", "A*256+B":
            return combined
        default:
            return nil
        }
    }

    // MARK: - Trouble codes

    /// Decodes stored, pending, or permanent trouble codes.
    ///
    /// The wire format differs by transport, and the two shapes must not be
    /// conflated. ISO 15765-4 (CAN) prefixes the list with a one-byte DTC
    /// count — `43 <count> <count × 2 bytes>` — while J1850, ISO 9141-2, and
    /// ISO 14230 emit `43 <pairs…>` padded to the frame width with `00 00`.
    /// Applying the legacy rule to a CAN reply consumes the count byte as a
    /// DTC high byte and yields a real but wrong code (`43 01 01 33` reads as
    /// P0101 instead of P0133), so the transport is resolved per payload from
    /// three signals: a CAN source address, an ATCAF1 reassembly origin (the
    /// adapter prints numbered lines only on CAN, even without header
    /// tokens), and the absence of a stripped legacy checksummed header.
    /// Source presence alone cannot distinguish CAN from legacy because
    /// `ATH1` legacy headers are also synthesized into addresses when their
    /// additive checksum validates.
    public func parseDTCs(from rawData: String) -> [String] {
        var codes: [String] = []
        var seen = Set<String>()

        for payload in decodedAddressedFrames(from: rawData) {
            let frame = payload.bytes
            let decoded: [String]

            if !payload.isLegacyTransport,
               payload.sourceAddress != nil || payload.isCAF1Formatted {
                // CAN payloads are already stripped to the service byte by the
                // single-frame and ISO-TP paths, so the service must lead.
                guard let service = frame.first,
                      service == 0x43 || service == 0x47 || service == 0x4A else {
                    continue
                }
                decoded = countPrefixedDTCs(in: frame)
            } else {
                guard let serviceIndex = frame.firstIndex(where: {
                    $0 == 0x43 || $0 == 0x47 || $0 == 0x4A
                }) else {
                    continue
                }
                decoded = paddedDTCs(in: frame, serviceIndex: serviceIndex)
            }

            for code in decoded where seen.insert(code).inserted {
                codes.append(code)
            }
        }

        return codes
    }

    /// ISO 15765-4 shape: `43 <count> <count × 2 bytes>`.
    ///
    /// A reply that declares more codes than it carries is decoded only as far
    /// as it is intact. Padding bytes are never invented, because a fabricated
    /// code is worse than a missing one.
    private func countPrefixedDTCs(in frame: [UInt8]) -> [String] {
        guard frame.count >= 2 else { return [] }
        let declaredCount = Int(frame[1])
        let availablePairs = (frame.count - 2) / 2
        let usablePairs = min(declaredCount, availablePairs)
        guard usablePairs > 0 else { return [] }

        var codes: [String] = []
        for pair in 0..<usablePairs {
            let index = 2 + pair * 2
            let raw = (UInt16(frame[index]) << 8) | UInt16(frame[index + 1])
            guard raw != 0 else { continue }
            codes.append(decodeDTC(raw))
        }
        return codes
    }

    /// Legacy shape: `43 <pairs…>` padded to the frame width with `00 00`.
    private func paddedDTCs(in frame: [UInt8], serviceIndex: Int) -> [String] {
        var codes: [String] = []
        var index = serviceIndex + 1
        while index + 1 < frame.count {
            let raw = (UInt16(frame[index]) << 8) | UInt16(frame[index + 1])
            index += 2
            guard raw != 0 else { continue }
            codes.append(decodeDTC(raw))
        }
        return codes
    }

    /// Extracts the DTC that caused one Mode 02 freeze-frame record.
    ///
    /// SAE J1979 identifies the triggering DTC through PID 02. The response is
    /// `42 02 <frame number> <DTC high byte> <DTC low byte>`.
    public func parseFreezeFrameDTC(
        from rawData: String,
        frameNumber: UInt8 = 0
    ) -> String? {
        for frame in decodedFrames(from: rawData) {
            guard let serviceIndex = frame.indices.first(where: {
                frame[$0] == 0x42 &&
                    frame.indices.contains($0 + 4) &&
                    frame[$0 + 1] == 0x02 &&
                    frame[$0 + 2] == frameNumber
            }) else {
                continue
            }

            let raw = (UInt16(frame[serviceIndex + 3]) << 8) |
                UInt16(frame[serviceIndex + 4])
            return raw == 0 ? nil : decodeDTC(raw)
        }
        return nil
    }

    // MARK: - Vehicle identification number

    public func parseVIN(from rawData: String) -> String? {
        let frames = decodedFrames(from: rawData)
        guard !frames.isEmpty else { return nil }

        var mode09Bytes: [UInt8] = []
        var collectingMode09VIN = false

        for frame in frames {
            if let serviceIndex = frame.indices.first(where: {
                frame[$0] == 0x49 &&
                    frame.indices.contains($0 + 1) &&
                    frame[$0 + 1] == 0x02
            }) {
                collectingMode09VIN = true
                var start = serviceIndex + 2
                // PID 09 02 responses include a record counter before VIN data.
                if frame.indices.contains(start), frame[start] <= 0x09 {
                    start += 1
                }
                if start < frame.count {
                    mode09Bytes.append(contentsOf: frame[start...])
                }
            } else if collectingMode09VIN {
                mode09Bytes.append(contentsOf: frame)
            }
        }

        if let vin = firstValidVIN(in: mode09Bytes) {
            return vin
        }

        // A few adapters return only the 17 ASCII bytes without the 49 02 header.
        return firstValidVIN(in: frames.flatMap { $0 })
    }

    private func firstValidVIN(in bytes: [UInt8]) -> String? {
        var run: [UInt8] = []

        func candidate(from bytes: [UInt8]) -> String? {
            guard bytes.count >= 17 else { return nil }
            for start in 0...(bytes.count - 17) {
                let candidate = String(bytes: bytes[start..<(start + 17)], encoding: .ascii) ?? ""
                if Self.isValidVIN(candidate) {
                    return candidate
                }
            }
            return nil
        }

        for byte in bytes {
            if Self.isVINCharacter(byte) {
                run.append(byte)
            } else {
                if let vin = candidate(from: run) { return vin }
                run.removeAll(keepingCapacity: true)
            }
        }

        return candidate(from: run)
    }

    private static func isVINCharacter(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) ||
            (byte >= 0x41 && byte <= 0x5A && byte != 0x49 && byte != 0x4F && byte != 0x51)
    }

    private static func isValidVIN(_ value: String) -> Bool {
        value.count == 17 &&
            value.utf8.allSatisfy(isVINCharacter)
    }

    // MARK: - Readiness

    /// Parses the four data bytes (A–D) from Mode 01 PID 01.
    ///
    /// The method also accepts a complete `41 01 A B C D` payload or a CAN
    /// length byte followed by that payload.
    public func parseReadinessMonitors(pidData: [UInt8]) -> [ReadinessMonitor]? {
        let data: [UInt8]
        let responseIndex = pidData.indices.first(where: {
            pidData[$0] == 0x41 &&
                pidData.indices.contains($0 + 1) &&
                pidData[$0 + 1] == 0x01
        })

        if let responseIndex, pidData.count >= responseIndex + 6 {
            data = Array(pidData[(responseIndex + 2)..<(responseIndex + 6)])
        } else if responseIndex != nil {
            // A truncated `41 01` reply must not fall through to the bare
            // four-byte reading below: that decodes the ISO-TP length byte and
            // the service/PID bytes themselves as monitor status and yields a
            // complete, plausible, entirely fabricated readiness table.
            return nil
        } else {
            guard pidData.count >= 4 else { return nil }
            data = Array(pidData.prefix(4))
        }

        let b = data[1]
        let c = data[2]
        let d = data[3]
        let compressionIgnition = (b & 0x08) != 0

        var monitors: [ReadinessMonitor] = [
            monitor(name: "Misfire", supported: b & 0x01 != 0, incomplete: b & 0x10 != 0),
            monitor(name: "Fuel System", supported: b & 0x02 != 0, incomplete: b & 0x20 != 0),
            monitor(name: "Comprehensive Component", supported: b & 0x04 != 0, incomplete: b & 0x40 != 0),
        ]

        if compressionIgnition {
            monitors += [
                monitor(name: "NMHC Catalyst", supported: c & 0x01 != 0, incomplete: d & 0x01 != 0),
                monitor(name: "NOx Catalyst", supported: c & 0x02 != 0, incomplete: d & 0x02 != 0),
                monitor(name: "Boost Pressure", supported: c & 0x08 != 0, incomplete: d & 0x08 != 0),
                monitor(name: "Oxygen Sensor", supported: c & 0x20 != 0, incomplete: d & 0x20 != 0),
                monitor(name: "PM Filter", supported: c & 0x40 != 0, incomplete: d & 0x40 != 0),
                monitor(name: "EGR/VVT", supported: c & 0x80 != 0, incomplete: d & 0x80 != 0),
            ]
        } else {
            monitors += [
                monitor(name: "Catalyst", supported: c & 0x01 != 0, incomplete: d & 0x01 != 0),
                monitor(name: "Heated Catalyst", supported: c & 0x02 != 0, incomplete: d & 0x02 != 0),
                monitor(name: "EVAP System", supported: c & 0x04 != 0, incomplete: d & 0x04 != 0),
                monitor(name: "Secondary Air", supported: c & 0x08 != 0, incomplete: d & 0x08 != 0),
                monitor(name: "A/C Refrigerant", supported: c & 0x10 != 0, incomplete: d & 0x10 != 0),
                monitor(name: "Oxygen Sensor", supported: c & 0x20 != 0, incomplete: d & 0x20 != 0),
                monitor(name: "Oxygen Sensor Heater", supported: c & 0x40 != 0, incomplete: d & 0x40 != 0),
                monitor(name: "EGR System", supported: c & 0x80 != 0, incomplete: d & 0x80 != 0),
            ]
        }

        return monitors
    }

    /// Merges Mode 01 PID 01 across every responding ECU.
    ///
    /// J1979 requires a monitor to be treated as incomplete if *any* module
    /// that supports it reports it incomplete. Taking whichever ECU answered
    /// first made readiness order-dependent and could tell a driver the car
    /// was inspection-ready while a second module still had work outstanding.
    /// Supported is OR across responders; ready is AND across those that
    /// support the monitor.
    public func parseReadinessMonitors(from rawData: String) -> [ReadinessMonitor]? {
        var merged: [String: ReadinessMonitor] = [:]
        var order: [String] = []

        for frame in decodedFrames(from: rawData) {
            guard frame.contains(0x41),
                  frame.contains(0x01),
                  let monitors = parseReadinessMonitors(pidData: frame) else {
                continue
            }

            for monitor in monitors {
                guard let existing = merged[monitor.name] else {
                    merged[monitor.name] = monitor
                    order.append(monitor.name)
                    continue
                }

                let supported = existing.isSupported || monitor.isSupported
                // Only modules that support the monitor get a vote on ready.
                let ready: Bool
                switch (existing.isSupported, monitor.isSupported) {
                case (true, true): ready = existing.isReady && monitor.isReady
                case (true, false): ready = existing.isReady
                case (false, true): ready = monitor.isReady
                case (false, false): ready = false
                }

                merged[monitor.name] = ReadinessMonitor(
                    name: monitor.name,
                    isReady: supported && ready,
                    isSupported: supported
                )
            }
        }

        guard !order.isEmpty else { return nil }
        return order.compactMap { merged[$0] }
    }

    private func monitor(name: String, supported: Bool, incomplete: Bool) -> ReadinessMonitor {
        ReadinessMonitor(
            name: name,
            isReady: supported && !incomplete,
            isSupported: supported
        )
    }

    // MARK: - ELM327 framing

    /// Returns complete diagnostic payloads with common CAN headers removed and
    /// ISO-TP multi-frame messages reassembled.
    public func responsePayloads(from rawData: String) -> [[UInt8]] {
        addressedResponsePayloads(from: rawData).map(\.bytes)
    }

    public func addressedResponsePayloads(
        from rawData: String
    ) -> [AddressedOBDResponsePayload] {
        decodedAddressedFrames(from: rawData)
    }

    private func decodedFrames(from rawData: String) -> [[UInt8]] {
        decodedAddressedFrames(from: rawData).map(\.bytes)
    }

    private func decodedAddressedFrames(
        from rawData: String
    ) -> [AddressedOBDResponsePayload] {
        let normalized = rawData
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: ">", with: "\n")

        let physicalFrames = Self.mergeCAF1Fragments(
            normalized
                .components(separatedBy: .newlines)
                .compactMap(parsePhysicalLine)
        )

        var completed: [AddressedOBDResponsePayload] = []
        var assemblies: [String: ISOAssembly] = [:]

        for frame in physicalFrames {
            guard let first = frame.bytes.first else { continue }
            let frameType = first & 0xF0
            let key = frame.source ?? "__unaddressed__"

            if frameType == 0x00,
               (frame.hasCANHeader ||
                frame.bytes.dropFirst().contains(where: Self.isDiagnosticResponseByte)),
               Int(first) <= frame.bytes.count - 1 {
                let length = Int(first)
                if length > 0 {
                    completed.append(AddressedOBDResponsePayload(
                        sourceAddress: frame.source,
                        bytes: Array(frame.bytes.dropFirst().prefix(length)),
                        isLegacyTransport: frame.isLegacyChecksummedHeader,
                        isCAF1Formatted: frame.isCAF1Formatted
                    ))
                }
                continue
            }

            if frameType == 0x10,
               frame.bytes.count >= 3 {
                let expectedLength =
                    (Int(first & 0x0F) << 8) | Int(frame.bytes[1])
                let initialPayload = Array(frame.bytes.dropFirst(2))
                guard expectedLength > 0,
                      expectedLength <= 4_095,
                      frame.hasCANHeader ||
                      initialPayload.contains(where: Self.isDiagnosticResponseByte) else {
                    continue
                }

                if initialPayload.count >= expectedLength {
                    completed.append(AddressedOBDResponsePayload(
                        sourceAddress: frame.source,
                        bytes: Array(initialPayload.prefix(expectedLength)),
                        isLegacyTransport: frame.isLegacyChecksummedHeader,
                        isCAF1Formatted: frame.isCAF1Formatted
                    ))
                } else {
                    assemblies[key] = ISOAssembly(
                        expectedLength: expectedLength,
                        nextSequence: 1,
                        payload: initialPayload,
                        sourceAddress: frame.source,
                        isLegacyTransport: frame.isLegacyChecksummedHeader
                    )
                }
                continue
            }

            if frameType == 0x20,
               frame.hasCANHeader || assemblies[key] != nil {
                guard var assembly = assemblies[key] else { continue }
                let sequence = first & 0x0F
                guard sequence == assembly.nextSequence else {
                    // A missing, duplicated, or out-of-order continuation makes
                    // the diagnostic payload unsafe to decode.
                    assemblies.removeValue(forKey: key)
                    continue
                }

                assembly.payload.append(contentsOf: frame.bytes.dropFirst())
                if assembly.payload.count >= assembly.expectedLength {
                    completed.append(AddressedOBDResponsePayload(
                        sourceAddress: assembly.sourceAddress,
                        bytes: Array(assembly.payload.prefix(assembly.expectedLength)),
                        isLegacyTransport: assembly.isLegacyTransport
                    ))
                    assemblies.removeValue(forKey: key)
                } else {
                    assembly.nextSequence = (assembly.nextSequence + 1) & 0x0F
                    assemblies[key] = assembly
                }
                continue
            }

            // Flow-control frames belong to the transport conversation, not to
            // an OBD response payload.
            if frameType == 0x30, frame.hasCANHeader {
                continue
            }

            completed.append(AddressedOBDResponsePayload(
                sourceAddress: frame.source,
                bytes: frame.bytes,
                isLegacyTransport: frame.isLegacyChecksummedHeader,
                isCAF1Formatted: frame.isCAF1Formatted
            ))
        }

        return completed
    }

    /// Rejoins ATCAF1-formatted multi-line output into whole messages.
    ///
    /// With automatic formatting enabled (`ATCAF1`) the adapter removes the
    /// ISO-TP PCI bytes and prints each message longer than one frame across
    /// numbered lines — `0:` … `F:` — optionally after the CAN header token.
    /// Decoding those lines independently truncates every payload past the
    /// first printed line, and lets a fragment whose first byte happens to
    /// look like a service byte masquerade as its own response, so
    /// consecutive fragments from one ECU are concatenated back together in
    /// print order. A numbered line whose predecessor was never seen is an
    /// orphan continuation: its leading bytes are arbitrary mid-message
    /// content, so it is discarded rather than decoded.
    private static func mergeCAF1Fragments(
        _ frames: [PhysicalFrame]
    ) -> [PhysicalFrame] {
        var merged: [PhysicalFrame] = []
        var runSource: String?
        var runBytes: [UInt8] = []
        // Non-nil marks an open run; the value is the next label expected.
        var expectedNext: Int?

        func flushOpenRun() {
            if let expectedNext {
                merged.append(PhysicalFrame(
                    source: runSource,
                    bytes: runBytes,
                    isCAF1Formatted: true
                ))
            }
            expectedNext = nil
            runBytes = []
        }

        for frame in frames {
            if let label = frame.lineLabel {
                if let next = expectedNext,
                   label == next,
                   frame.source == runSource {
                    // Line counters are single hex digits wrapping F → 0.
                    runBytes += frame.bytes
                    expectedNext = (label + 1) % 16
                } else {
                    flushOpenRun()
                    guard label == 0 else { continue }
                    runSource = frame.source
                    runBytes = frame.bytes
                    expectedNext = 1 % 16
                }
            } else {
                flushOpenRun()
                merged.append(frame)
            }
        }
        flushOpenRun()
        return merged
    }

    private struct PhysicalFrame {
        let source: String?
        let bytes: [UInt8]
        var isLegacyChecksummedHeader: Bool
        /// Frame index from ATCAF1 multi-line printing (`0:` … `F:`), when the
        /// line carried one. Non-nil marks the line as a fragment of a larger
        /// ISO-TP message whose PCI bytes the adapter removed.
        var lineLabel: Int?
        /// True for frames that arrived as ATCAF1-numbered print lines —
        /// either directly, or reassembled from such fragments. Automatic
        /// formatting exists only on CAN, so these follow CAN shapes even
        /// when no header token was printed.
        var isCAF1Formatted: Bool

        init(
            source: String?,
            bytes: [UInt8],
            isLegacyChecksummedHeader: Bool = false,
            lineLabel: Int? = nil,
            isCAF1Formatted: Bool? = nil
        ) {
            self.source = source
            self.bytes = bytes
            self.isLegacyChecksummedHeader = isLegacyChecksummedHeader
            self.lineLabel = lineLabel
            self.isCAF1Formatted = isCAF1Formatted ?? (lineLabel != nil)
        }

        /// Only genuine CAN addressing counts as a CAN header. Legacy frames
        /// whose checksummed header was stripped carry a synthesized address
        /// and must never be treated as CAN-shaped.
        var hasCANHeader: Bool {
            source != nil && !isLegacyChecksummedHeader
        }
    }

    private struct ISOAssembly {
        let expectedLength: Int
        var nextSequence: UInt8
        var payload: [UInt8]
        let sourceAddress: String?
        let isLegacyTransport: Bool

        init(
            expectedLength: Int,
            nextSequence: UInt8,
            payload: [UInt8],
            sourceAddress: String?,
            isLegacyTransport: Bool = false
        ) {
            self.expectedLength = expectedLength
            self.nextSequence = nextSequence
            self.payload = payload
            self.sourceAddress = sourceAddress
            self.isLegacyTransport = isLegacyTransport
        }
    }

    private static func isDiagnosticResponseByte(_ byte: UInt8) -> Bool {
        positiveResponseServices.contains(byte) || byte == 0x7F
    }

    private func parsePhysicalLine(_ rawLine: String) -> PhysicalFrame? {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !line.isEmpty else { return nil }

        let ignoredPhrases = [
            "NO DATA", "STOPPED", "UNABLE TO CONNECT", "BUS INIT",
            "CAN ERROR", "BUFFER FULL", "ERROR", "ELM327", "SEARCHING",
        ]
        if ignoredPhrases.contains(where: { line.contains($0) }) {
            return nil
        }
        if line == "OK" || line == "?" || line.hasPrefix("AT") {
            return nil
        }

        var tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }

        var source: String?
        var lineLabel: Int?

        if let first = tokens.first,
           (first.count == 3 || first.count == 8),
           first.allSatisfy(\.isHexDigit),
           (first.count == 3 || first.hasPrefix("18")) {
            tokens.removeFirst()
            source = first
        } else if let first = tokens.first,
                  tokens.count > 1,
                  first.hasSuffix(":"),
                  let fusedSource = Self.canSourceToken(String(first.dropLast())) {
            // A header token fused to its colon (`7E8:43 …`) used to be
            // consumed wholesale by the old label stripper, losing the
            // address. Split it here so the identity survives.
            source = fusedSource
            let remainder = String(first.dropFirst(fusedSource.count + 1))
            tokens[0] = remainder
            if remainder.isEmpty { tokens.removeFirst() }
        }

        // With ATCAF1 the adapter numbers each printed line of a multi-frame
        // message (`0:` … `F:`), optionally after the header token. Capture
        // the index instead of discarding it: consecutive numbered fragments
        // belong to one message and are merged before decoding.
        if let first = tokens.first,
           first.hasSuffix(":"), first.count == 2,
           let digit = first.first,
           let value = digit.hexDigitValue {
            lineLabel = value
            tokens.removeFirst()
        }

        var compact = tokens.joined()
            .replacingOccurrences(of: "0X", with: "")
        compact.removeAll { !$0.isHexDigit }
        guard !compact.isEmpty else { return nil }

        // With spaces disabled an 11-bit CAN ID produces an odd-length line,
        // for example `7E804410C1AF8`.
        if compact.count.isMultiple(of: 2) == false,
           compact.count > 3,
           compact.first == "6" || compact.first == "7" {
            source = String(compact.prefix(3))
            compact.removeFirst(3)
        } else if compact.count >= 12,
                  compact.hasPrefix("18DA"),
                  compact.count.isMultiple(of: 2) {
            source = String(compact.prefix(8))
            compact.removeFirst(8)
        }

        guard compact.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = compact.startIndex
        while index < compact.endIndex {
            let end = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<end], radix: 16) else { return nil }
            bytes.append(byte)
            index = end
        }
        guard !bytes.isEmpty else { return nil }

        // With ATH1, ELM327 exposes three header bytes and a trailing checksum
        // for J1850, ISO 9141, and ISO 14230. Detect that shape by locating the
        // diagnostic response service immediately after the three-byte header.
        // CAN IDs were already removed above and never include a checksum here.
        let legacyChecksumIsValid = bytes.last.map { checksum in
            bytes.dropLast().reduce(UInt8(0), &+) == checksum
        } ?? false
        let hasLegacyHeaderShape = bytes.count >= 3 && (
            // J1850 VPW / ISO 9141-2
            (bytes[0] == 0x48 && bytes[1] == 0x6B) ||
            // ISO 14230 (KWP2000) three-byte header
            ((bytes[0] & 0xC0) == 0x80 && bytes[1] == 0xF1) ||
            // J1850 PWM. Without this the header was never stripped and
            // `parsePIDResponse` matched the 0x41 *header* byte instead of the
            // service byte, so every PWM vehicle failed to connect.
            (bytes[0] == 0x41 && bytes[1] == 0x6B)
        )
        var strippedLegacyHeader = false
        if source == nil,
           bytes.count >= 5,
           hasLegacyHeaderShape,
           legacyChecksumIsValid,
           Self.isDiagnosticResponseByte(bytes[3]) {
            source = bytes.prefix(3)
                .map { String(format: "%02X", $0) }
                .joined()
            bytes = Array(bytes.dropFirst(3).dropLast())
            strippedLegacyHeader = true
        }

        return PhysicalFrame(
            source: source,
            bytes: bytes,
            isLegacyChecksummedHeader: strippedLegacyHeader,
            lineLabel: lineLabel
        )
    }

    /// Recognizes a CAN header token: 3 hex digits, or 8 hex digits starting
    /// with `18` (extended 29-bit addressing).
    private static func canSourceToken(_ value: String) -> String? {
        let isHex = value.allSatisfy(\.isHexDigit)
        guard isHex, value.count == 3 || (value.count == 8 && value.hasPrefix("18")) else {
            return nil
        }
        return value
    }

    private func decodeDTC(_ raw: UInt16) -> String {
        let systemChar: Character
        switch (raw >> 14) & 0x3 {
        case 0: systemChar = "P"
        case 1: systemChar = "C"
        case 2: systemChar = "B"
        case 3: systemChar = "U"
        default: systemChar = "P"
        }

        let firstDigit = (raw >> 12) & 0x3
        let secondDigit = (raw >> 8) & 0xF
        let thirdDigit = (raw >> 4) & 0xF
        let fourthDigit = raw & 0xF
        return String(
            format: "%@%1X%1X%1X%1X",
            String(systemChar),
            firstDigit,
            secondDigit,
            thirdDigit,
            fourthDigit
        )
    }

    private static func normalizedPID(_ value: String) -> String {
        let stripped = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "0X", with: "")
        guard let byte = UInt8(stripped, radix: 16) else { return stripped }
        return String(format: "%02X", byte)
    }
}

private extension Character {
    var isHexDigit: Bool {
        isNumber || ("A"..."F").contains(String(self))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
