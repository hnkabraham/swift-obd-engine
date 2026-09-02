import Foundation

// MARK: - Shared source identity

/// A source address retained from an ELM response header.
///
/// Three and eight hexadecimal characters represent 11-bit and 29-bit CAN
/// identifiers. Six characters represent a legacy three-byte OBD header.
public struct DiagnosticSourceAddress: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case can11Bit
        case can29Bit
        case legacyThreeByteHeader
    }

    public let rawValue: String
    public let kind: Kind

    public init?(rawValue: String) {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard normalized.allSatisfy(\.isHexDigit) else { return nil }
        switch normalized.count {
        case 3:
            guard let value = UInt32(normalized, radix: 16), value <= 0x7FF else {
                return nil
            }
            kind = .can11Bit
        case 6:
            guard UInt32(normalized, radix: 16) != nil else { return nil }
            kind = .legacyThreeByteHeader
        case 8:
            guard let value = UInt32(normalized, radix: 16),
                  value <= 0x1FFF_FFFF else {
                return nil
            }
            kind = .can29Bit
        default:
            return nil
        }
        self.rawValue = normalized
    }

    public var canIdentifier: UInt32? {
        guard kind != .legacyThreeByteHeader else { return nil }
        return UInt32(rawValue, radix: 16)
    }
}

// MARK: - SAE Mode 06

public enum Mode06RecordFormat: String, Codable, Hashable, Sendable {
    /// ISO 15765/J1979 layout: monitor ID, test ID, unit/scaling ID,
    /// test value, minimum, and maximum.
    case can
    /// Legacy J1979 layout: test ID, component ID, test value, minimum,
    /// and maximum.
    case legacy
}

/// A raw Mode 06 result exactly as supplied by the ECU.
///
/// Values deliberately remain unscaled until a sourced scaling definition is
/// supplied. SAE unit/scaling mappings are not guessed or embedded.
public struct Mode06MonitorResult: Codable, Hashable, Sendable {
    public let sourceAddress: DiagnosticSourceAddress?
    public let format: Mode06RecordFormat
    public let monitorID: UInt8?
    public let testID: UInt8
    public let componentID: UInt8?
    public let unitAndScalingID: UInt8?
    public let rawTestValue: UInt16
    public let rawMinimum: UInt16
    public let rawMaximum: UInt16

    public init(
        sourceAddress: DiagnosticSourceAddress?,
        format: Mode06RecordFormat,
        monitorID: UInt8?,
        testID: UInt8,
        componentID: UInt8?,
        unitAndScalingID: UInt8?,
        rawTestValue: UInt16,
        rawMinimum: UInt16,
        rawMaximum: UInt16
    ) {
        self.sourceAddress = sourceAddress
        self.format = format
        self.monitorID = monitorID
        self.testID = testID
        self.componentID = componentID
        self.unitAndScalingID = unitAndScalingID
        self.rawTestValue = rawTestValue
        self.rawMinimum = rawMinimum
        self.rawMaximum = rawMaximum
    }
}

public struct Mode06CapabilityPage: Codable, Hashable, Sendable {
    public let sourceAddress: DiagnosticSourceAddress?
    public let baseMonitorID: UInt8
    public let supportedMonitorIDs: [UInt8]

    public init(
        sourceAddress: DiagnosticSourceAddress?,
        baseMonitorID: UInt8,
        supportedMonitorIDs: [UInt8]
    ) {
        self.sourceAddress = sourceAddress
        self.baseMonitorID = baseMonitorID
        self.supportedMonitorIDs = supportedMonitorIDs
    }

    public var hasContinuationPage: Bool {
        guard let continuation = UInt8(
            exactly: Int(baseMonitorID) + 0x20
        ) else {
            return false
        }
        return supportedMonitorIDs.contains(continuation)
    }
}

public struct Mode06ScalingDefinition: Codable, Hashable, Sendable {
    public enum Representation: String, Codable, Hashable, Sendable {
        case unsigned16
        case signed16TwosComplement
    }

    public let unitAndScalingID: UInt8?
    public let representation: Representation
    public let multiplier: Double
    public let offset: Double
    public let unit: String
    public let provenanceNote: String

    public init(
        unitAndScalingID: UInt8? = nil,
        representation: Representation,
        multiplier: Double,
        offset: Double,
        unit: String,
        provenanceNote: String
    ) {
        self.unitAndScalingID = unitAndScalingID
        self.representation = representation
        self.multiplier = multiplier
        self.offset = offset
        self.unit = unit
        self.provenanceNote = provenanceNote
    }

    public var isValid: Bool {
        multiplier.isFinite &&
            offset.isFinite &&
            !unit.contains(where: \.isNewline) &&
            unit.count <= 24 &&
            !provenanceNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            provenanceNote.count <= 256
    }
}

public struct Mode06EvaluatedResult: Codable, Hashable, Sendable {
    public enum LimitStatus: String, Codable, Hashable, Sendable {
        case withinLimits
        case outsideLimits
        case invalidLimits
    }

    public let rawResult: Mode06MonitorResult
    public let testValue: Double
    public let minimum: Double
    public let maximum: Double
    public let unit: String
    public let limitStatus: LimitStatus

    public init(
        rawResult: Mode06MonitorResult,
        testValue: Double,
        minimum: Double,
        maximum: Double,
        unit: String,
        limitStatus: LimitStatus
    ) {
        self.rawResult = rawResult
        self.testValue = testValue
        self.minimum = minimum
        self.maximum = maximum
        self.unit = unit
        self.limitStatus = limitStatus
    }
}

// MARK: - Enhanced diagnostic profiles

public enum EnhancedProfileOrigin: String, Codable, Hashable, Sendable {
    case userDefined
    case licensed
}

public struct EnhancedProfileProvenance: Codable, Hashable, Sendable {
    public let origin: EnhancedProfileOrigin
    public let providerName: String?
    public let licenseIdentifier: String?
    public let revision: String

    public init(
        origin: EnhancedProfileOrigin,
        providerName: String? = nil,
        licenseIdentifier: String? = nil,
        revision: String
    ) {
        self.origin = origin
        self.providerName = providerName
        self.licenseIdentifier = licenseIdentifier
        self.revision = revision
    }
}

public struct EnhancedVehicleApplicability: Codable, Hashable, Sendable {
    public let makes: [String]
    public let models: [String]
    public let minimumYear: Int?
    public let maximumYear: Int?

    public init(
        makes: [String] = [],
        models: [String] = [],
        minimumYear: Int? = nil,
        maximumYear: Int? = nil
    ) {
        self.makes = makes
        self.models = models
        self.minimumYear = minimumYear
        self.maximumYear = maximumYear
    }
}

public struct EnhancedCANAddressing: Codable, Hashable, Sendable {
    public enum Format: String, Codable, Hashable, Sendable {
        case standard11Bit
        case extended29Bit
    }

    public let format: Format
    public let requestIdentifier: UInt32
    public let responseIdentifiers: [UInt32]

    public init(
        format: Format,
        requestIdentifier: UInt32,
        responseIdentifiers: [UInt32]
    ) {
        self.format = format
        self.requestIdentifier = requestIdentifier
        self.responseIdentifiers = responseIdentifiers
    }

    public var transmitHeader: String {
        switch format {
        case .standard11Bit:
            return String(format: "%03X", requestIdentifier)
        case .extended29Bit:
            return String(format: "%08X", requestIdentifier)
        }
    }

    public var functionalHeader: String {
        switch format {
        case .standard11Bit:
            return "7DF"
        case .extended29Bit:
            return "18DB33F1"
        }
    }
}

public enum EnhancedByteOrder: String, Codable, Hashable, Sendable {
    case bigEndian
    case littleEndian
}

/// Bounded decoders allowed in imported profiles. Arbitrary executable formula
/// strings are intentionally unsupported.
public enum EnhancedValueDecoder: Codable, Hashable, Sendable {
    case unsignedInteger(
        byteCount: Int,
        byteOrder: EnhancedByteOrder,
        multiplier: Double,
        offset: Double
    )
    case signedInteger(
        byteCount: Int,
        byteOrder: EnhancedByteOrder,
        multiplier: Double,
        offset: Double
    )
    case ascii(
        minimumLength: Int,
        maximumLength: Int,
        trimNullPadding: Bool
    )
    case rawHex(minimumLength: Int, maximumLength: Int)
}

public struct EnhancedDataIdentifierDefinition: Codable, Hashable, Sendable {
    public let dataIdentifier: UInt16
    public let name: String
    public let description: String
    public let unit: String
    public let decoder: EnhancedValueDecoder

    public init(
        dataIdentifier: UInt16,
        name: String,
        description: String = "",
        unit: String = "",
        decoder: EnhancedValueDecoder
    ) {
        self.dataIdentifier = dataIdentifier
        self.name = name
        self.description = description
        self.unit = unit
        self.decoder = decoder
    }
}

public enum EnhancedDTCReadSubfunction: UInt8, Codable, Hashable, Sendable {
    /// ISO 14229 ReportDTCByStatusMask.
    case reportByStatusMask = 0x02
    /// ISO 14229 ReportSupportedDTC.
    case reportSupportedDTC = 0x0A
}

public struct EnhancedECUModuleDefinition: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let addressing: EnhancedCANAddressing
    public let dataIdentifiers: [EnhancedDataIdentifierDefinition]
    public let allowedDTCReadSubfunctions: [EnhancedDTCReadSubfunction]

    public init(
        id: String,
        name: String,
        addressing: EnhancedCANAddressing,
        dataIdentifiers: [EnhancedDataIdentifierDefinition] = [],
        allowedDTCReadSubfunctions: [EnhancedDTCReadSubfunction] = []
    ) {
        self.id = id
        self.name = name
        self.addressing = addressing
        self.dataIdentifiers = dataIdentifiers
        self.allowedDTCReadSubfunctions = allowedDTCReadSubfunctions
    }
}

public struct EnhancedDiagnosticProfile: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let id: String
    public let displayName: String
    public let schemaVersion: Int
    public let provenance: EnhancedProfileProvenance
    public let applicability: EnhancedVehicleApplicability
    public let modules: [EnhancedECUModuleDefinition]

    public init(
        id: String,
        displayName: String,
        schemaVersion: Int = currentSchemaVersion,
        provenance: EnhancedProfileProvenance,
        applicability: EnhancedVehicleApplicability = EnhancedVehicleApplicability(),
        modules: [EnhancedECUModuleDefinition]
    ) {
        self.id = id
        self.displayName = displayName
        self.schemaVersion = schemaVersion
        self.provenance = provenance
        self.applicability = applicability
        self.modules = modules
    }

    public func validationIssues() -> [EnhancedProfileValidationIssue] {
        EnhancedDiagnosticProfileValidator.validate(self)
    }
}

public struct EnhancedProfileValidationIssue: Codable, Hashable, Sendable {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

public enum EnhancedDiagnosticProfileValidator {
    public static let maximumModuleCount = 32
    public static let maximumDataIdentifiersPerModule = 256
    public static let maximumResponseIdentifiersPerModule = 16
    public static let maximumTextLength = 256

    public static func validate(
        _ profile: EnhancedDiagnosticProfile
    ) -> [EnhancedProfileValidationIssue] {
        var issues: [EnhancedProfileValidationIssue] = []

        validateIdentifier(profile.id, path: "id", issues: &issues)
        validateText(profile.displayName, path: "displayName", maximum: 96, issues: &issues)
        if profile.schemaVersion != EnhancedDiagnosticProfile.currentSchemaVersion {
            issues.append(.init(
                path: "schemaVersion",
                message: "Unsupported profile schema version"
            ))
        }

        validateText(
            profile.provenance.revision,
            path: "provenance.revision",
            maximum: 64,
            issues: &issues
        )
        if profile.provenance.origin == .licensed {
            validateRequiredText(
                profile.provenance.providerName,
                path: "provenance.providerName",
                issues: &issues
            )
            validateRequiredText(
                profile.provenance.licenseIdentifier,
                path: "provenance.licenseIdentifier",
                issues: &issues
            )
        }

        if profile.modules.isEmpty {
            issues.append(.init(path: "modules", message: "At least one module is required"))
        }
        if profile.modules.count > maximumModuleCount {
            issues.append(.init(path: "modules", message: "Too many modules"))
        }

        var moduleIDs = Set<String>()
        for (moduleIndex, module) in profile.modules.enumerated() {
            let path = "modules[\(moduleIndex)]"
            validateIdentifier(module.id, path: "\(path).id", issues: &issues)
            if !moduleIDs.insert(module.id).inserted {
                issues.append(.init(path: "\(path).id", message: "Duplicate module identifier"))
            }
            validateText(module.name, path: "\(path).name", maximum: 96, issues: &issues)
            validateAddressing(module.addressing, path: "\(path).addressing", issues: &issues)

            if module.dataIdentifiers.count > maximumDataIdentifiersPerModule {
                issues.append(.init(
                    path: "\(path).dataIdentifiers",
                    message: "Too many data identifiers"
                ))
            }
            var identifiers = Set<UInt16>()
            for (didIndex, definition) in module.dataIdentifiers.enumerated() {
                let didPath = "\(path).dataIdentifiers[\(didIndex)]"
                if !identifiers.insert(definition.dataIdentifier).inserted {
                    issues.append(.init(
                        path: "\(didPath).dataIdentifier",
                        message: "Duplicate data identifier"
                    ))
                }
                validateText(
                    definition.name,
                    path: "\(didPath).name",
                    maximum: 96,
                    issues: &issues
                )
                validateText(
                    definition.description,
                    path: "\(didPath).description",
                    maximum: maximumTextLength,
                    allowEmpty: true,
                    issues: &issues
                )
                validateText(
                    definition.unit,
                    path: "\(didPath).unit",
                    maximum: 24,
                    allowEmpty: true,
                    issues: &issues
                )
                validateDecoder(
                    definition.decoder,
                    path: "\(didPath).decoder",
                    issues: &issues
                )
            }

            if Set(module.allowedDTCReadSubfunctions).count !=
                module.allowedDTCReadSubfunctions.count {
                issues.append(.init(
                    path: "\(path).allowedDTCReadSubfunctions",
                    message: "Duplicate DTC subfunction"
                ))
            }
        }

        validateApplicability(profile.applicability, issues: &issues)
        return issues
    }

    private static func validateAddressing(
        _ addressing: EnhancedCANAddressing,
        path: String,
        issues: inout [EnhancedProfileValidationIssue]
    ) {
        let maximum: UInt32 = addressing.format == .standard11Bit
            ? 0x7FF
            : 0x1FFF_FFFF
        if addressing.requestIdentifier > maximum {
            issues.append(.init(path: "\(path).requestIdentifier", message: "CAN ID out of range"))
        }
        if addressing.responseIdentifiers.isEmpty {
            issues.append(.init(
                path: "\(path).responseIdentifiers",
                message: "At least one response CAN ID is required"
            ))
        }
        if addressing.responseIdentifiers.count > maximumResponseIdentifiersPerModule {
            issues.append(.init(
                path: "\(path).responseIdentifiers",
                message: "Too many response CAN IDs"
            ))
        }
        if Set(addressing.responseIdentifiers).count != addressing.responseIdentifiers.count {
            issues.append(.init(
                path: "\(path).responseIdentifiers",
                message: "Duplicate response CAN ID"
            ))
        }
        for identifier in addressing.responseIdentifiers where identifier > maximum {
            issues.append(.init(
                path: "\(path).responseIdentifiers",
                message: "Response CAN ID out of range"
            ))
        }
    }

    private static func validateDecoder(
        _ decoder: EnhancedValueDecoder,
        path: String,
        issues: inout [EnhancedProfileValidationIssue]
    ) {
        switch decoder {
        case .unsignedInteger(let count, _, let multiplier, let offset),
             .signedInteger(let count, _, let multiplier, let offset):
            if !(1...8).contains(count) {
                issues.append(.init(path: path, message: "Integer width must be 1 through 8 bytes"))
            }
            if !multiplier.isFinite || !offset.isFinite {
                issues.append(.init(path: path, message: "Numeric scaling must be finite"))
            }
        case .ascii(let minimum, let maximum, _),
             .rawHex(let minimum, let maximum):
            if minimum < 0 || maximum < minimum || maximum > 64 {
                issues.append(.init(path: path, message: "Payload bounds must fit 0 through 64 bytes"))
            }
        }
    }

    private static func validateApplicability(
        _ applicability: EnhancedVehicleApplicability,
        issues: inout [EnhancedProfileValidationIssue]
    ) {
        if applicability.makes.count > 32 || applicability.models.count > 64 {
            issues.append(.init(path: "applicability", message: "Too many applicability values"))
        }
        for (index, make) in applicability.makes.enumerated() {
            validateText(
                make,
                path: "applicability.makes[\(index)]",
                maximum: 64,
                issues: &issues
            )
        }
        for (index, model) in applicability.models.enumerated() {
            validateText(
                model,
                path: "applicability.models[\(index)]",
                maximum: 64,
                issues: &issues
            )
        }
        if let minimum = applicability.minimumYear,
           !(1980...2200).contains(minimum) {
            issues.append(.init(path: "applicability.minimumYear", message: "Year out of range"))
        }
        if let maximum = applicability.maximumYear,
           !(1980...2200).contains(maximum) {
            issues.append(.init(path: "applicability.maximumYear", message: "Year out of range"))
        }
        if let minimum = applicability.minimumYear,
           let maximum = applicability.maximumYear,
           minimum > maximum {
            issues.append(.init(path: "applicability", message: "Minimum year exceeds maximum year"))
        }
    }

    private static func validateIdentifier(
        _ value: String,
        path: String,
        issues: inout [EnhancedProfileValidationIssue]
    ) {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._-")
        )
        if value.isEmpty ||
            value.count > 64 ||
            value.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            issues.append(.init(
                path: path,
                message: "Identifier must use 1–64 letters, numbers, dots, underscores, or hyphens"
            ))
        }
    }

    private static func validateRequiredText(
        _ value: String?,
        path: String,
        issues: inout [EnhancedProfileValidationIssue]
    ) {
        guard let value else {
            issues.append(.init(path: path, message: "Licensed profiles require this value"))
            return
        }
        validateText(value, path: path, maximum: 128, issues: &issues)
    }

    private static func validateText(
        _ value: String,
        path: String,
        maximum: Int,
        allowEmpty: Bool = false,
        issues: inout [EnhancedProfileValidationIssue]
    ) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if (!allowEmpty && trimmed.isEmpty) ||
            value.count > maximum ||
            value.unicodeScalars.contains(where: {
                $0.value < 0x20 && $0.value != 0x09
            }) {
            issues.append(.init(path: path, message: "Invalid or oversized text"))
        }
    }
}

public enum EnhancedDecodedValue: Codable, Hashable, Sendable {
    case number(Double)
    case text(String)
    case rawHex(String)
}

public struct EnhancedDataIdentifierValue: Codable, Hashable, Sendable {
    public let sourceAddress: DiagnosticSourceAddress
    public let moduleID: String
    public let dataIdentifier: UInt16
    public let definitionName: String
    public let rawHex: String
    public let decodedValue: EnhancedDecodedValue
    public let unit: String

    public init(
        sourceAddress: DiagnosticSourceAddress,
        moduleID: String,
        dataIdentifier: UInt16,
        definitionName: String,
        rawHex: String,
        decodedValue: EnhancedDecodedValue,
        unit: String
    ) {
        self.sourceAddress = sourceAddress
        self.moduleID = moduleID
        self.dataIdentifier = dataIdentifier
        self.definitionName = definitionName
        self.rawHex = rawHex
        self.decodedValue = decodedValue
        self.unit = unit
    }
}

public struct UDSDTCStatus: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let testFailed = Self(rawValue: 1 << 0)
    public static let testFailedThisOperationCycle = Self(rawValue: 1 << 1)
    public static let pendingDTC = Self(rawValue: 1 << 2)
    public static let confirmedDTC = Self(rawValue: 1 << 3)
    public static let testNotCompletedSinceLastClear = Self(rawValue: 1 << 4)
    public static let testFailedSinceLastClear = Self(rawValue: 1 << 5)
    public static let testNotCompletedThisOperationCycle = Self(rawValue: 1 << 6)
    public static let warningIndicatorRequested = Self(rawValue: 1 << 7)
}

public struct EnhancedDTCRecord: Codable, Hashable, Sendable {
    public let sourceAddress: DiagnosticSourceAddress
    public let moduleID: String
    /// Six hexadecimal digits representing the ECU-supplied 24-bit UDS DTC.
    public let code: String
    public let status: UDSDTCStatus
    public let statusAvailabilityMask: UInt8

    public init(
        sourceAddress: DiagnosticSourceAddress,
        moduleID: String,
        code: String,
        status: UDSDTCStatus,
        statusAvailabilityMask: UInt8
    ) {
        self.sourceAddress = sourceAddress
        self.moduleID = moduleID
        self.code = code
        self.status = status
        self.statusAvailabilityMask = statusAvailabilityMask
    }
}
