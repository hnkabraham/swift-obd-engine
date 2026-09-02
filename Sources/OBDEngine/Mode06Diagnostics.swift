import Foundation
#if SWIFT_PACKAGE
import OBDModels
#endif

public struct Mode06CapabilityReport: Equatable, Sendable {
    public let pages: [Mode06CapabilityPage]
    public let evidence: [AdvancedDiagnosticEvidence]

    public init(
        pages: [Mode06CapabilityPage],
        evidence: [AdvancedDiagnosticEvidence]
    ) {
        self.pages = pages
        self.evidence = evidence
    }
}

public struct Mode06ResultReport: Equatable, Sendable {
    public let results: [Mode06MonitorResult]
    public let evidence: [AdvancedDiagnosticEvidence]

    public init(
        results: [Mode06MonitorResult],
        evidence: [AdvancedDiagnosticEvidence]
    ) {
        self.results = results
        self.evidence = evidence
    }
}

public enum Mode06CommandFactory {
    public static func capabilityPage(
        baseMonitorID: UInt8
    ) throws -> ELM327Command {
        guard baseMonitorID % 0x20 == 0 else {
            throw AdvancedDiagnosticRequestError.invalidMode06Page
        }
        return ELM327Command(
            raw: String(format: "06 %02X", baseMonitorID),
            description: String(
                format: "Read supported Mode 06 monitor IDs after %02X",
                baseMonitorID
            ),
            timeout: 3
        )
    }

    public static func monitorResults(
        monitorID: UInt8
    ) -> ELM327Command {
        ELM327Command(
            raw: String(format: "06 %02X", monitorID),
            description: String(
                format: "Read raw Mode 06 monitor %02X results",
                monitorID
            ),
            timeout: 3
        )
    }

    /// Older non-CAN J1979 implementations return all Mode 06 records for a
    /// service-only request.
    public static let legacyAllResults = ELM327Command(
        raw: "06",
        description: "Read raw legacy Mode 06 monitor results",
        timeout: 5
    )
}

public final class Mode06Parser: @unchecked Sendable {
    public static let maximumResponses = 32
    public static let maximumRecords = 512

    private let obdParser: OBDParser

    public init(obdParser: OBDParser = OBDParser()) {
        self.obdParser = obdParser
    }

    public func parseCapabilityPage(
        from response: String,
        requestedBaseMonitorID: UInt8
    ) -> Mode06CapabilityReport {
        guard requestedBaseMonitorID % 0x20 == 0 else {
            return Mode06CapabilityReport(
                pages: [],
                evidence: [
                    .init(
                        kind: .malformedResponse,
                        requestService: 0x06,
                        detail: "Invalid requested Mode 06 capability page"
                    ),
                ]
            )
        }

        var pages: [Mode06CapabilityPage] = []
        var evidence: [AdvancedDiagnosticEvidence] = []
        let payloads = obdParser.addressedResponsePayloads(from: response)
        appendEmptyResponseEvidence(
            response,
            payloadsAreEmpty: payloads.isEmpty,
            evidence: &evidence
        )
        for addressed in payloads.prefix(Self.maximumResponses) {
            let source = sourceAddress(
                addressed.sourceAddress,
                service: 0x06,
                evidence: &evidence
            )
            let payload = addressed.bytes

            if appendNegativeEvidence(
                payload,
                requestService: 0x06,
                source: source,
                evidence: &evidence
            ) {
                continue
            }
            guard payload.count == 6,
                  payload[0] == 0x46,
                  payload[1] == requestedBaseMonitorID else {
                evidence.append(.init(
                    kind: .malformedResponse,
                    requestService: 0x06,
                    sourceAddress: source,
                    detail: "Expected 46, requested page, and four support bytes"
                ))
                continue
            }

            let bitmap = Array(payload[2...5])
            var supported: [UInt8] = []
            for offset in 1...32 {
                let identifierValue = Int(requestedBaseMonitorID) + offset
                guard let identifier = UInt8(exactly: identifierValue) else {
                    continue
                }
                let byteIndex = (offset - 1) / 8
                let bitIndex = 7 - ((offset - 1) % 8)
                if bitmap[byteIndex] & (UInt8(1) << bitIndex) != 0 {
                    supported.append(identifier)
                }
            }
            pages.append(Mode06CapabilityPage(
                sourceAddress: source,
                baseMonitorID: requestedBaseMonitorID,
                supportedMonitorIDs: supported
            ))
            evidence.append(.init(
                kind: .capability,
                requestService: 0x06,
                sourceAddress: source,
                detail: "\(supported.count) Mode 06 monitor IDs reported"
            ))
        }
        if payloads.count > Self.maximumResponses {
            evidence.append(.init(
                kind: .boundsExceeded,
                requestService: 0x06,
                detail: "Mode 06 response count exceeded the safety bound"
            ))
        }
        return Mode06CapabilityReport(pages: pages, evidence: evidence)
    }

    public func parseResults(
        from response: String,
        format: Mode06RecordFormat,
        expectedMonitorID: UInt8? = nil
    ) -> Mode06ResultReport {
        var results: [Mode06MonitorResult] = []
        var evidence: [AdvancedDiagnosticEvidence] = []
        let recordLength = format == .can ? 9 : 6
        let payloads = obdParser.addressedResponsePayloads(from: response)
        appendEmptyResponseEvidence(
            response,
            payloadsAreEmpty: payloads.isEmpty,
            evidence: &evidence
        )

        for addressed in payloads.prefix(Self.maximumResponses) {
            let source = sourceAddress(
                addressed.sourceAddress,
                service: 0x06,
                evidence: &evidence
            )
            let payload = addressed.bytes
            if appendNegativeEvidence(
                payload,
                requestService: 0x06,
                source: source,
                evidence: &evidence
            ) {
                continue
            }
            guard payload.first == 0x46,
                  payload.count > 1,
                  (payload.count - 1).isMultiple(of: recordLength) else {
                evidence.append(.init(
                    kind: .malformedResponse,
                    requestService: 0x06,
                    sourceAddress: source,
                    detail: "Mode 06 payload does not contain complete records"
                ))
                continue
            }

            var index = 1
            while index < payload.count {
                if results.count >= Self.maximumRecords {
                    evidence.append(.init(
                        kind: .boundsExceeded,
                        requestService: 0x06,
                        sourceAddress: source,
                        detail: "Mode 06 record limit exceeded"
                    ))
                    break
                }

                let result: Mode06MonitorResult
                switch format {
                case .can:
                    let monitorID = payload[index]
                    guard expectedMonitorID == nil ||
                            monitorID == expectedMonitorID else {
                        evidence.append(.init(
                            kind: .malformedResponse,
                            requestService: 0x06,
                            sourceAddress: source,
                            detail: "Response monitor ID did not match the request"
                        ))
                        index += recordLength
                        continue
                    }
                    result = Mode06MonitorResult(
                        sourceAddress: source,
                        format: .can,
                        monitorID: monitorID,
                        testID: payload[index + 1],
                        componentID: nil,
                        unitAndScalingID: payload[index + 2],
                        rawTestValue: uint16(payload[index + 3], payload[index + 4]),
                        rawMinimum: uint16(payload[index + 5], payload[index + 6]),
                        rawMaximum: uint16(payload[index + 7], payload[index + 8])
                    )
                case .legacy:
                    // SAE J1979 (non-CAN) Table 69: TID, limit type |
                    // component ID, test value, and one limit — a minimum
                    // when bit 7 of the limit-type byte is set, otherwise a
                    // maximum. The other bound is left open.
                    let limitTypeAndComponentID = payload[index + 1]
                    let isMinimum = limitTypeAndComponentID & 0x80 != 0
                    let limit = uint16(payload[index + 4], payload[index + 5])
                    result = Mode06MonitorResult(
                        sourceAddress: source,
                        format: .legacy,
                        monitorID: nil,
                        testID: payload[index],
                        componentID: limitTypeAndComponentID & 0x7F,
                        unitAndScalingID: nil,
                        rawTestValue: uint16(payload[index + 2], payload[index + 3]),
                        rawMinimum: isMinimum ? limit : 0,
                        rawMaximum: isMinimum ? 0xFFFF : limit,
                        reportedLimit: isMinimum ? .minimum : .maximum
                    )
                }
                results.append(result)
                index += recordLength
            }
        }
        if payloads.count > Self.maximumResponses {
            evidence.append(.init(
                kind: .boundsExceeded,
                requestService: 0x06,
                detail: "Mode 06 response count exceeded the safety bound"
            ))
        }
        return Mode06ResultReport(results: results, evidence: evidence)
    }

    public func evaluate(
        _ result: Mode06MonitorResult,
        using scaling: Mode06ScalingDefinition
    ) -> Mode06EvaluatedResult? {
        guard scaling.isValid else { return nil }
        if let expectedID = scaling.unitAndScalingID,
           result.unitAndScalingID != expectedID {
            return nil
        }

        func decode(_ value: UInt16) -> Double {
            let base: Double
            switch scaling.representation {
            case .unsigned16:
                base = Double(value)
            case .signed16TwosComplement:
                base = Double(Int16(bitPattern: value))
            }
            return base * scaling.multiplier + scaling.offset
        }

        let value = decode(result.rawTestValue)
        let minimum = decode(result.rawMinimum)
        let maximum = decode(result.rawMaximum)
        guard value.isFinite, minimum.isFinite, maximum.isFinite else {
            return nil
        }
        let status: Mode06EvaluatedResult.LimitStatus
        switch result.reportedLimit {
        case .minimum?:
            // One-sided legacy record: the unreported bound is a sentinel and
            // must not take part in the comparison.
            status = value >= minimum ? .withinLimits : .outsideLimits
        case .maximum?:
            status = value <= maximum ? .withinLimits : .outsideLimits
        case nil:
            if minimum > maximum {
                status = .invalidLimits
            } else if (minimum...maximum).contains(value) {
                status = .withinLimits
            } else {
                status = .outsideLimits
            }
        }
        return Mode06EvaluatedResult(
            rawResult: result,
            testValue: value,
            minimum: minimum,
            maximum: maximum,
            unit: scaling.unit,
            limitStatus: status
        )
    }

    private func appendNegativeEvidence(
        _ payload: [UInt8],
        requestService: UInt8,
        source: DiagnosticSourceAddress?,
        evidence: inout [AdvancedDiagnosticEvidence]
    ) -> Bool {
        guard payload.count >= 3,
              payload[0] == 0x7F,
              payload[1] == requestService else {
            return false
        }
        evidence.append(.init(
            kind: .negativeResponse,
            requestService: requestService,
            sourceAddress: source,
            negativeResponseCode: payload[2],
            detail: String(
                format: "ECU returned negative response code 0x%02X",
                payload[2]
            )
        ))
        return true
    }

    private func appendEmptyResponseEvidence(
        _ response: String,
        payloadsAreEmpty: Bool,
        evidence: inout [AdvancedDiagnosticEvidence]
    ) {
        guard payloadsAreEmpty else { return }
        let normalized = response
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
        let isNoData = normalized.contains("NODATA")
        evidence.append(.init(
            kind: isNoData ? .noData : .malformedResponse,
            requestService: 0x06,
            detail: isNoData
                ? "Adapter reported no Mode 06 data"
                : "No decodable Mode 06 payload was returned"
        ))
    }

    private func sourceAddress(
        _ rawValue: String?,
        service: UInt8,
        evidence: inout [AdvancedDiagnosticEvidence]
    ) -> DiagnosticSourceAddress? {
        guard let rawValue else { return nil }
        guard let source = DiagnosticSourceAddress(rawValue: rawValue) else {
            evidence.append(.init(
                kind: .malformedResponse,
                requestService: service,
                detail: "Invalid ECU source address"
            ))
            return nil
        }
        return source
    }

    private func uint16(_ high: UInt8, _ low: UInt8) -> UInt16 {
        (UInt16(high) << 8) | UInt16(low)
    }
}
