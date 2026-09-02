import Foundation

/// Persistable evidence captured by the optional advanced-diagnostics pass.
///
/// Mode 06 values remain raw unless a sourced scaling definition is available.
/// Manufacturer-specific values are only present when the user has installed
/// and selected a validated user-provided or licensed profile.
public struct AdvancedDiagnosticSnapshot: Codable, Hashable, Sendable {
    public let capturedAt: Date
    public let mode06Results: [Mode06MonitorResult]
    public let enhancedProfileID: String?
    public let enhancedProfileName: String?
    public let enhancedValues: [EnhancedDataIdentifierValue]
    public let enhancedDTCs: [EnhancedDTCRecord]
    public let evidence: [AdvancedDiagnosticEvidenceNote]

    public init(
        capturedAt: Date = Date(),
        mode06Results: [Mode06MonitorResult] = [],
        enhancedProfileID: String? = nil,
        enhancedProfileName: String? = nil,
        enhancedValues: [EnhancedDataIdentifierValue] = [],
        enhancedDTCs: [EnhancedDTCRecord] = [],
        evidence: [AdvancedDiagnosticEvidenceNote] = []
    ) {
        self.capturedAt = capturedAt
        self.mode06Results = Array(mode06Results.prefix(512))
        self.enhancedProfileID = enhancedProfileID
        self.enhancedProfileName = enhancedProfileName
        self.enhancedValues = Array(enhancedValues.prefix(512))
        self.enhancedDTCs = Array(enhancedDTCs.prefix(512))
        self.evidence = Array(evidence.prefix(512))
    }

    public var hasResults: Bool {
        !mode06Results.isEmpty ||
            !enhancedValues.isEmpty ||
            !enhancedDTCs.isEmpty
    }
}

/// A bounded, user-presentable copy of transport/parser evidence.
///
/// Keeping this representation in Models lets scan history preserve why an
/// advanced request was unsupported or rejected without persisting arbitrary
/// adapter transcripts.
public struct AdvancedDiagnosticEvidenceNote: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case capability
        case noData
        case negativeResponse
        case malformedResponse
        case unexpectedSource
        case unsupportedTransport
        case profileValidation
        case boundsExceeded
    }

    public let kind: Kind
    public let requestService: UInt8
    public let sourceAddress: DiagnosticSourceAddress?
    public let negativeResponseCode: UInt8?
    public let detail: String

    public init(
        kind: Kind,
        requestService: UInt8,
        sourceAddress: DiagnosticSourceAddress? = nil,
        negativeResponseCode: UInt8? = nil,
        detail: String
    ) {
        self.kind = kind
        self.requestService = requestService
        self.sourceAddress = sourceAddress
        self.negativeResponseCode = negativeResponseCode
        self.detail = String(detail.prefix(256))
    }
}
