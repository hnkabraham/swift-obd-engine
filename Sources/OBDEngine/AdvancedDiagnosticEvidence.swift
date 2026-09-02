import Foundation
#if SWIFT_PACKAGE
import OBDModels
#endif

public struct AdvancedDiagnosticEvidence: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
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

public enum AdvancedDiagnosticRequestError: LocalizedError, Equatable {
    case invalidMode06Page
    case invalidProfile([EnhancedProfileValidationIssue])
    case moduleNotFound
    case dataIdentifierNotFound
    case subfunctionNotAllowed
    case unsupportedAddressing
    case timeBudgetExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidMode06Page:
            return "Mode 06 capability pages must start on a 0x20 boundary"
        case .invalidProfile:
            return "The enhanced diagnostic profile is invalid"
        case .moduleNotFound:
            return "The enhanced diagnostic module is not defined"
        case .dataIdentifierNotFound:
            return "The requested data identifier is not defined"
        case .subfunctionNotAllowed:
            return "The profile does not allow this DTC read subfunction"
        case .unsupportedAddressing:
            return "This enhanced addressing mode is not supported by the current transport"
        case .timeBudgetExceeded:
            return "The advanced scan reached its time limit. Partial, unverified results were not saved."
        }
    }
}
