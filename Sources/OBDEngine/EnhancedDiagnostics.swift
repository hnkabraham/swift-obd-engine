import Foundation
#if SWIFT_PACKAGE
import OBDModels
#endif

public enum EnhancedTransportSupport: Equatable, Sendable {
    case compatible
    case requiresProtocolConfirmation
    case incompatible(reason: String)

    public var isExecutable: Bool {
        if case .compatible = self { return true }
        return false
    }
}

/// A read-only ELM command transaction for one physically addressed ECU.
///
/// The header change, diagnostic request, and functional-header restoration
/// must be executed exclusively; interleaving generic PID polling would send a
/// request to the wrong ECU.
public struct EnhancedDiagnosticCommandPlan: Equatable, Sendable {
    public let moduleID: String
    public let requestService: UInt8
    public let preparationCommands: [ELM327Command]
    public let requestCommand: ELM327Command
    public let restorationCommands: [ELM327Command]
    public let expectedResponseIdentifiers: [UInt32]
    public let transportSupport: EnhancedTransportSupport
    public let requiresExclusiveTransaction: Bool

    public init(
        moduleID: String,
        requestService: UInt8,
        preparationCommands: [ELM327Command],
        requestCommand: ELM327Command,
        restorationCommands: [ELM327Command],
        expectedResponseIdentifiers: [UInt32],
        transportSupport: EnhancedTransportSupport,
        requiresExclusiveTransaction: Bool = true
    ) {
        self.moduleID = moduleID
        self.requestService = requestService
        self.preparationCommands = preparationCommands
        self.requestCommand = requestCommand
        self.restorationCommands = restorationCommands
        self.expectedResponseIdentifiers = expectedResponseIdentifiers
        self.transportSupport = transportSupport
        self.requiresExclusiveTransaction = requiresExclusiveTransaction
    }

    public var allCommands: [ELM327Command] {
        preparationCommands + [requestCommand] + restorationCommands
    }

    public var capabilityEvidence: AdvancedDiagnosticEvidence {
        switch transportSupport {
        case .compatible:
            return .init(
                kind: .capability,
                requestService: requestService,
                detail: "Detected CAN protocol matches the profile addressing"
            )
        case .requiresProtocolConfirmation:
            return .init(
                kind: .unsupportedTransport,
                requestService: requestService,
                detail: "Confirm the active CAN protocol before executing this transaction"
            )
        case .incompatible(let reason):
            return .init(
                kind: .unsupportedTransport,
                requestService: requestService,
                detail: reason
            )
        }
    }
}

public enum EnhancedDiagnosticCommandFactory {
    public static func readDataIdentifier(
        profile: EnhancedDiagnosticProfile,
        moduleID: String,
        dataIdentifier: UInt16,
        detectedProtocolIdentifier: String? = nil
    ) throws -> EnhancedDiagnosticCommandPlan {
        let module = try validatedModule(profile: profile, moduleID: moduleID)
        guard module.dataIdentifiers.contains(where: {
            $0.dataIdentifier == dataIdentifier
        }) else {
            throw AdvancedDiagnosticRequestError.dataIdentifierNotFound
        }

        let high = UInt8((dataIdentifier >> 8) & 0xFF)
        let low = UInt8(dataIdentifier & 0xFF)
        return plan(
            module: module,
            service: 0x22,
            request: ELM327Command(
                raw: String(format: "22 %02X %02X", high, low),
                description: String(
                    format: "Read licensed/user-defined DID %04X from %@",
                    dataIdentifier,
                    module.name
                ),
                timeout: 4
            ),
            detectedProtocolIdentifier: detectedProtocolIdentifier
        )
    }

    public static func readDTCs(
        profile: EnhancedDiagnosticProfile,
        moduleID: String,
        subfunction: EnhancedDTCReadSubfunction,
        statusMask: UInt8 = 0xFF,
        detectedProtocolIdentifier: String? = nil
    ) throws -> EnhancedDiagnosticCommandPlan {
        let module = try validatedModule(profile: profile, moduleID: moduleID)
        guard module.allowedDTCReadSubfunctions.contains(subfunction) else {
            throw AdvancedDiagnosticRequestError.subfunctionNotAllowed
        }

        let raw: String
        switch subfunction {
        case .reportByStatusMask:
            raw = String(format: "19 %02X %02X", subfunction.rawValue, statusMask)
        case .reportSupportedDTC:
            raw = String(format: "19 %02X", subfunction.rawValue)
        }
        return plan(
            module: module,
            service: 0x19,
            request: ELM327Command(
                raw: raw,
                description: "Read raw UDS DTC records from \(module.name)",
                timeout: 5
            ),
            detectedProtocolIdentifier: detectedProtocolIdentifier
        )
    }

    private static func validatedModule(
        profile: EnhancedDiagnosticProfile,
        moduleID: String
    ) throws -> EnhancedECUModuleDefinition {
        let issues = profile.validationIssues()
        guard issues.isEmpty else {
            throw AdvancedDiagnosticRequestError.invalidProfile(issues)
        }
        guard let module = profile.modules.first(where: { $0.id == moduleID }) else {
            throw AdvancedDiagnosticRequestError.moduleNotFound
        }
        return module
    }

    private static func plan(
        module: EnhancedECUModuleDefinition,
        service: UInt8,
        request: ELM327Command,
        detectedProtocolIdentifier: String?
    ) -> EnhancedDiagnosticCommandPlan {
        let addressing = module.addressing
        let support = transportSupport(
            for: addressing,
            detectedProtocolIdentifier: detectedProtocolIdentifier
        )
        return EnhancedDiagnosticCommandPlan(
            moduleID: module.id,
            requestService: service,
            preparationCommands: [
                .headersOn,
                .canAutoFormattingOn,
                ELM327Command(
                    raw: "ATSH \(addressing.transmitHeader)",
                    description: "Select \(module.name) physical request address"
                ),
            ],
            requestCommand: request,
            restorationCommands: [
                ELM327Command(
                    raw: "ATSH \(addressing.functionalHeader)",
                    description: "Restore functional OBD request address"
                ),
            ],
            expectedResponseIdentifiers: addressing.responseIdentifiers,
            transportSupport: support
        )
    }

    private static func transportSupport(
        for addressing: EnhancedCANAddressing,
        detectedProtocolIdentifier: String?
    ) -> EnhancedTransportSupport {
        guard var identifier = detectedProtocolIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(),
            !identifier.isEmpty else {
            return .requiresProtocolConfirmation
        }
        if identifier.count == 2, identifier.first == "A" {
            identifier.removeFirst()
        }

        let is11Bit = identifier == "6" || identifier == "8"
        let is29Bit = identifier == "7" || identifier == "9"
        switch addressing.format {
        case .standard11Bit where is11Bit:
            return .compatible
        case .extended29Bit where is29Bit:
            return .compatible
        case .standard11Bit where is29Bit:
            return .incompatible(reason: "The active vehicle protocol uses 29-bit CAN IDs")
        case .extended29Bit where is11Bit:
            return .incompatible(reason: "The active vehicle protocol uses 11-bit CAN IDs")
        default:
            return .incompatible(reason: "Enhanced UDS reads require a matching ISO 15765 CAN protocol")
        }
    }
}

public struct EnhancedDataIdentifierReport: Equatable, Sendable {
    public let values: [EnhancedDataIdentifierValue]
    public let evidence: [AdvancedDiagnosticEvidence]

    public init(
        values: [EnhancedDataIdentifierValue],
        evidence: [AdvancedDiagnosticEvidence]
    ) {
        self.values = values
        self.evidence = evidence
    }
}

public struct EnhancedDTCReport: Equatable, Sendable {
    public let records: [EnhancedDTCRecord]
    public let evidence: [AdvancedDiagnosticEvidence]

    public init(
        records: [EnhancedDTCRecord],
        evidence: [AdvancedDiagnosticEvidence]
    ) {
        self.records = records
        self.evidence = evidence
    }
}

public final class EnhancedDiagnosticParser: @unchecked Sendable {
    public static let maximumResponses = 32
    public static let maximumDTCRecords = 512

    private let obdParser: OBDParser

    public init(obdParser: OBDParser = OBDParser()) {
        self.obdParser = obdParser
    }

    public func parseDataIdentifier(
        from response: String,
        module: EnhancedECUModuleDefinition,
        definition: EnhancedDataIdentifierDefinition
    ) -> EnhancedDataIdentifierReport {
        guard module.dataIdentifiers.contains(definition) else {
            return EnhancedDataIdentifierReport(
                values: [],
                evidence: [
                    .init(
                        kind: .profileValidation,
                        requestService: 0x22,
                        detail: "The DID definition is not part of the selected module profile"
                    ),
                ]
            )
        }
        var values: [EnhancedDataIdentifierValue] = []
        var evidence: [AdvancedDiagnosticEvidence] = []
        let payloads = obdParser.addressedResponsePayloads(from: response)
        appendEmptyResponseEvidence(
            response,
            payloadsAreEmpty: payloads.isEmpty,
            service: 0x22,
            evidence: &evidence
        )

        for addressed in payloads.prefix(Self.maximumResponses) {
            guard let source = acceptedSource(
                addressed.sourceAddress,
                module: module,
                service: 0x22,
                evidence: &evidence
            ) else {
                continue
            }
            let payload = addressed.bytes
            if appendNegativeEvidence(
                payload,
                requestService: 0x22,
                source: source,
                evidence: &evidence
            ) {
                continue
            }
            let high = UInt8((definition.dataIdentifier >> 8) & 0xFF)
            let low = UInt8(definition.dataIdentifier & 0xFF)
            guard payload.count >= 3,
                  payload[0] == 0x62,
                  payload[1] == high,
                  payload[2] == low else {
                evidence.append(.init(
                    kind: .malformedResponse,
                    requestService: 0x22,
                    sourceAddress: source,
                    detail: "Response service or data identifier did not match the request"
                ))
                continue
            }
            let data = Array(payload.dropFirst(3))
            guard let decoded = decode(data, using: definition.decoder) else {
                evidence.append(.init(
                    kind: .malformedResponse,
                    requestService: 0x22,
                    sourceAddress: source,
                    detail: "DID payload did not satisfy its bounded decoder"
                ))
                continue
            }
            values.append(EnhancedDataIdentifierValue(
                sourceAddress: source,
                moduleID: module.id,
                dataIdentifier: definition.dataIdentifier,
                definitionName: definition.name,
                rawHex: hex(data),
                decodedValue: decoded,
                unit: definition.unit
            ))
        }
        if payloads.count > Self.maximumResponses {
            evidence.append(.init(
                kind: .boundsExceeded,
                requestService: 0x22,
                detail: "Enhanced response count exceeded the safety bound"
            ))
        }
        return EnhancedDataIdentifierReport(values: values, evidence: evidence)
    }

    public func parseDTCs(
        from response: String,
        module: EnhancedECUModuleDefinition,
        subfunction: EnhancedDTCReadSubfunction
    ) -> EnhancedDTCReport {
        guard module.allowedDTCReadSubfunctions.contains(subfunction) else {
            return EnhancedDTCReport(
                records: [],
                evidence: [
                    .init(
                        kind: .profileValidation,
                        requestService: 0x19,
                        detail: "The module profile does not allow this DTC subfunction"
                    ),
                ]
            )
        }

        var records: [EnhancedDTCRecord] = []
        var evidence: [AdvancedDiagnosticEvidence] = []
        let payloads = obdParser.addressedResponsePayloads(from: response)
        appendEmptyResponseEvidence(
            response,
            payloadsAreEmpty: payloads.isEmpty,
            service: 0x19,
            evidence: &evidence
        )

        for addressed in payloads.prefix(Self.maximumResponses) {
            guard let source = acceptedSource(
                addressed.sourceAddress,
                module: module,
                service: 0x19,
                evidence: &evidence
            ) else {
                continue
            }
            let payload = addressed.bytes
            if appendNegativeEvidence(
                payload,
                requestService: 0x19,
                source: source,
                evidence: &evidence
            ) {
                continue
            }
            guard payload.count >= 3,
                  payload[0] == 0x59,
                  payload[1] == subfunction.rawValue,
                  (payload.count - 3).isMultiple(of: 4) else {
                evidence.append(.init(
                    kind: .malformedResponse,
                    requestService: 0x19,
                    sourceAddress: source,
                    detail: "UDS DTC response has an invalid service, subfunction, or record length"
                ))
                continue
            }

            let availabilityMask = payload[2]
            var index = 3
            while index < payload.count {
                if records.count >= Self.maximumDTCRecords {
                    evidence.append(.init(
                        kind: .boundsExceeded,
                        requestService: 0x19,
                        sourceAddress: source,
                        detail: "UDS DTC record limit exceeded"
                    ))
                    break
                }
                let rawCode = Array(payload[index..<(index + 3)])
                if rawCode.allSatisfy({ $0 == 0 }) {
                    evidence.append(.init(
                        kind: .malformedResponse,
                        requestService: 0x19,
                        sourceAddress: source,
                        detail: "ECU returned a reserved zero DTC record"
                    ))
                    index += 4
                    continue
                }
                records.append(EnhancedDTCRecord(
                    sourceAddress: source,
                    moduleID: module.id,
                    code: hex(rawCode),
                    status: UDSDTCStatus(rawValue: payload[index + 3]),
                    statusAvailabilityMask: availabilityMask
                ))
                index += 4
            }
        }
        if payloads.count > Self.maximumResponses {
            evidence.append(.init(
                kind: .boundsExceeded,
                requestService: 0x19,
                detail: "Enhanced response count exceeded the safety bound"
            ))
        }
        return EnhancedDTCReport(records: records, evidence: evidence)
    }

    private func acceptedSource(
        _ rawSource: String?,
        module: EnhancedECUModuleDefinition,
        service: UInt8,
        evidence: inout [AdvancedDiagnosticEvidence]
    ) -> DiagnosticSourceAddress? {
        guard let rawSource,
              let source = DiagnosticSourceAddress(rawValue: rawSource),
              let identifier = source.canIdentifier else {
            evidence.append(.init(
                kind: .unsupportedTransport,
                requestService: service,
                detail: "Enhanced reads require preserved 11-bit or 29-bit CAN source headers"
            ))
            return nil
        }
        let expectedKind: DiagnosticSourceAddress.Kind =
            module.addressing.format == .standard11Bit
                ? .can11Bit
                : .can29Bit
        guard source.kind == expectedKind,
              module.addressing.responseIdentifiers.contains(identifier) else {
            evidence.append(.init(
                kind: .unexpectedSource,
                requestService: service,
                sourceAddress: source,
                detail: "Response came from an ECU not authorized by the profile"
            ))
            return nil
        }
        return source
    }

    private func decode(
        _ data: [UInt8],
        using decoder: EnhancedValueDecoder
    ) -> EnhancedDecodedValue? {
        switch decoder {
        case .unsignedInteger(
            let byteCount,
            let byteOrder,
            let multiplier,
            let offset
        ):
            guard data.count == byteCount,
                  (1...8).contains(byteCount),
                  multiplier.isFinite,
                  offset.isFinite else {
                return nil
            }
            let raw = unsignedInteger(data, byteOrder: byteOrder)
            let value = Double(raw) * multiplier + offset
            return value.isFinite ? .number(value) : nil

        case .signedInteger(
            let byteCount,
            let byteOrder,
            let multiplier,
            let offset
        ):
            guard data.count == byteCount,
                  (1...8).contains(byteCount),
                  multiplier.isFinite,
                  offset.isFinite else {
                return nil
            }
            let raw = unsignedInteger(data, byteOrder: byteOrder)
            let bits = byteCount * 8
            let signed: Int64
            if bits == 64 {
                signed = Int64(bitPattern: raw)
            } else {
                let signBit = UInt64(1) << (bits - 1)
                signed = raw & signBit == 0
                    ? Int64(raw)
                    : Int64(raw) - Int64(UInt64(1) << bits)
            }
            let value = Double(signed) * multiplier + offset
            return value.isFinite ? .number(value) : nil

        case .ascii(let minimum, let maximum, let trimNullPadding):
            guard minimum >= 0,
                  maximum >= minimum,
                  maximum <= 64,
                  (minimum...maximum).contains(data.count) else {
                return nil
            }
            var textBytes = data
            if trimNullPadding {
                while textBytes.last == 0 {
                    textBytes.removeLast()
                }
            }
            guard textBytes.allSatisfy({ (0x20...0x7E).contains($0) }),
                  let text = String(bytes: textBytes, encoding: .ascii) else {
                return nil
            }
            return .text(text)

        case .rawHex(let minimum, let maximum):
            guard minimum >= 0,
                  maximum >= minimum,
                  maximum <= 64,
                  (minimum...maximum).contains(data.count) else {
                return nil
            }
            return .rawHex(hex(data))
        }
    }

    private func unsignedInteger(
        _ data: [UInt8],
        byteOrder: EnhancedByteOrder
    ) -> UInt64 {
        let bytes: [UInt8]
        switch byteOrder {
        case .bigEndian:
            bytes = data
        case .littleEndian:
            bytes = Array(data.reversed())
        }
        return bytes.reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
    }

    private func appendNegativeEvidence(
        _ payload: [UInt8],
        requestService: UInt8,
        source: DiagnosticSourceAddress,
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
        service: UInt8,
        evidence: inout [AdvancedDiagnosticEvidence]
    ) {
        guard payloadsAreEmpty else { return }
        let normalized = response
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
        let kind: AdvancedDiagnosticEvidence.Kind =
            normalized.contains("NODATA") ? .noData : .malformedResponse
        evidence.append(.init(
            kind: kind,
            requestService: service,
            detail: normalized.contains("NODATA")
                ? "Adapter reported no data for this read-only request"
                : "No decodable diagnostic payload was returned"
        ))
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}
