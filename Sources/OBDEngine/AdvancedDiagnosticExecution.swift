import Foundation
#if SWIFT_PACKAGE
import OBDModels
#endif

public struct EnhancedDiagnosticExecutionReport: Sendable {
    public let profileID: String
    public let profileName: String
    public let values: [EnhancedDataIdentifierValue]
    public let dtcs: [EnhancedDTCRecord]
    public let evidence: [AdvancedDiagnosticEvidence]

    public init(
        profileID: String,
        profileName: String,
        values: [EnhancedDataIdentifierValue],
        dtcs: [EnhancedDTCRecord],
        evidence: [AdvancedDiagnosticEvidence]
    ) {
        self.profileID = profileID
        self.profileName = profileName
        self.values = values
        self.dtcs = dtcs
        self.evidence = evidence
    }
}

extension AdvancedDiagnosticEvidence {
    var persistableNote: AdvancedDiagnosticEvidenceNote {
        AdvancedDiagnosticEvidenceNote(
            kind: AdvancedDiagnosticEvidenceNote.Kind(
                rawValue: kind.rawValue
            ) ?? .malformedResponse,
            requestService: requestService,
            sourceAddress: sourceAddress,
            negativeResponseCode: negativeResponseCode,
            detail: detail
        )
    }
}
