import Foundation

// MARK: - Vehicle

public struct Vehicle: Identifiable, Codable, Hashable {
    public let id: UUID
    public var vin: String?
    public var make: String
    public var model: String
    public var year: Int
    public var engineType: EngineType
    public var fuelType: FuelType
    public var nickname: String
    public var odometer: Int
    public var engineDisplacement: Double

    public var displayName: String { nickname.isEmpty ? "\(year) \(make) \(model)" : nickname }

    public init(id: UUID = UUID(), vin: String? = nil, make: String, model: String, year: Int,
                engineType: EngineType = .gasoline, fuelType: FuelType = .gasoline,
                nickname: String = "", odometer: Int = 0, engineDisplacement: Double = 2.0) {
        self.id = id; self.vin = vin; self.make = make; self.model = model; self.year = year
        self.engineType = engineType; self.fuelType = fuelType; self.nickname = nickname
        self.odometer = odometer; self.engineDisplacement = engineDisplacement
    }

    public enum EngineType: String, Codable, CaseIterable { case gasoline, diesel, hybrid, electric }
    public enum FuelType: String, Codable, CaseIterable { case gasoline, diesel, e85, lpg, cng, electric }
}

// MARK: - DTC (Diagnostic Trouble Code)

public struct DiagnosticTroubleCode: Identifiable, Codable, Hashable {
    public let id: UUID
    public let code: String
    public let description: String
    public let system: VehicleSystem
    public let severity: CodeSeverity
    /// The most actionable status when more than one OBD service reports the code.
    public let status: CodeStatus
    /// Every status observed for this code during the scan.
    ///
    /// Older saved scans only contain `status`; the custom decoder migrates
    /// those records to a one-element collection.
    public let observedStatuses: [CodeStatus]
    public let freezeFrame: FreezeFrameData?
    public let possibleFixes: [Fix]
    public let relatedTSBs: [TSB]
    /// Whether `severity` came from a classification table rather than a
    /// fallback.
    ///
    /// An unrecognized code previously inherited `.medium` silently, so the UI
    /// rendered confident "schedule diagnosis soon" guidance over a code the
    /// app had never seen. Callers must present unclassified codes as
    /// unassessed rather than as moderate.
    public let isSeverityClassified: Bool

    public init(id: UUID = UUID(), code: String, description: String, system: VehicleSystem,
                severity: CodeSeverity, status: CodeStatus, freezeFrame: FreezeFrameData? = nil,
                possibleFixes: [Fix] = [], relatedTSBs: [TSB] = [],
                observedStatuses: [CodeStatus]? = nil,
                isSeverityClassified: Bool = true) {
        self.id = id; self.code = code; self.description = description; self.system = system
        self.severity = severity; self.status = status
        self.observedStatuses = Self.normalizedStatuses(
            primary: status,
            observed: observedStatuses ?? [status]
        )
        self.freezeFrame = freezeFrame
        self.possibleFixes = possibleFixes; self.relatedTSBs = relatedTSBs
        self.isSeverityClassified = isSeverityClassified
    }

    private enum CodingKeys: String, CodingKey {
        case id, code, description, system, severity, status, observedStatuses
        case freezeFrame, possibleFixes, relatedTSBs, isSeverityClassified
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        code = try container.decode(String.self, forKey: .code)
        description = try container.decode(String.self, forKey: .description)
        system = try container.decode(VehicleSystem.self, forKey: .system)
        severity = try container.decode(CodeSeverity.self, forKey: .severity)
        status = try container.decode(CodeStatus.self, forKey: .status)
        observedStatuses = Self.normalizedStatuses(
            primary: status,
            observed: try container.decodeIfPresent(
                [CodeStatus].self,
                forKey: .observedStatuses
            ) ?? [status]
        )
        freezeFrame = try container.decodeIfPresent(
            FreezeFrameData.self,
            forKey: .freezeFrame
        )
        possibleFixes = try container.decodeIfPresent(
            [Fix].self,
            forKey: .possibleFixes
        ) ?? []
        relatedTSBs = try container.decodeIfPresent(
            [TSB].self,
            forKey: .relatedTSBs
        ) ?? []
        // Records written before this flag existed keep their stored severity
        // presentation rather than being retroactively marked unassessed.
        isSeverityClassified = try container.decodeIfPresent(
            Bool.self,
            forKey: .isSeverityClassified
        ) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(code, forKey: .code)
        try container.encode(description, forKey: .description)
        try container.encode(system, forKey: .system)
        try container.encode(severity, forKey: .severity)
        try container.encode(status, forKey: .status)
        try container.encode(observedStatuses, forKey: .observedStatuses)
        try container.encodeIfPresent(freezeFrame, forKey: .freezeFrame)
        try container.encode(possibleFixes, forKey: .possibleFixes)
        try container.encode(relatedTSBs, forKey: .relatedTSBs)
        try container.encode(isSeverityClassified, forKey: .isSeverityClassified)
    }

    private static func normalizedStatuses(
        primary: CodeStatus,
        observed: [CodeStatus]
    ) -> [CodeStatus] {
        var result = [primary]
        var seen: Set<CodeStatus> = [primary]
        for status in observed where seen.insert(status).inserted {
            result.append(status)
        }
        return result
    }

    public enum VehicleSystem: String, Codable, CaseIterable {
        case powertrain = "P", chassis = "C", body = "B", network = "U"
    }

    public enum CodeSeverity: String, Codable, CaseIterable {
        case low, medium, high, critical
    }

    public enum CodeStatus: String, Codable, CaseIterable {
        case confirmed, pending, permanent, historical
    }
}

// MARK: - Fix

public struct Fix: Identifiable, Codable, Hashable {
    public let id: UUID
    public let description: String
    public let estimatedCost: Double
    public let confidence: Double
    public let parts: [Part]
    public let diyDifficulty: Int
    public let estimatedHours: Double

    public init(id: UUID = UUID(), description: String, estimatedCost: Double = 0,
                confidence: Double = 0.5, parts: [Part] = [], diyDifficulty: Int = 1,
                estimatedHours: Double = 1.0) {
        self.id = id; self.description = description; self.estimatedCost = estimatedCost
        self.confidence = confidence; self.parts = parts; self.diyDifficulty = diyDifficulty
        self.estimatedHours = estimatedHours
    }
}

public struct Part: Identifiable, Codable, Hashable {
    public let id: UUID
    public let name: String
    public let partNumber: String?
    public let price: Double
    public let url: URL?

    public init(id: UUID = UUID(), name: String, partNumber: String? = nil, price: Double = 0, url: URL? = nil) {
        self.id = id; self.name = name; self.partNumber = partNumber; self.price = price; self.url = url
    }
}

// MARK: - TSB (Technical Service Bulletin)

public struct TSB: Identifiable, Codable, Hashable {
    public let id: UUID
    public let bulletinNumber: String
    public let title: String
    public let description: String
    public let date: Date
    public let make: String
    public let model: String
    public let yearRange: ClosedRange<Int>

    public init(id: UUID = UUID(), bulletinNumber: String, title: String, description: String,
                date: Date, make: String, model: String, yearRange: ClosedRange<Int>) {
        self.id = id; self.bulletinNumber = bulletinNumber; self.title = title
        self.description = description; self.date = date; self.make = make
        self.model = model; self.yearRange = yearRange
    }
}

// MARK: - Freeze Frame

public struct FreezeFrameData: Codable, Hashable {
    public static let unattributedDTCCode = "Unattributed freeze frame"

    public let timestamp: Date
    public let pids: [PIDValue]
    public let dtcCode: String
    /// The Mode 02 record number this data was read from. Frame 0 is the
    /// SAE-required record; higher frames are manufacturer-specific extras.
    public let frameNumber: UInt8

    public init(
        timestamp: Date = Date(),
        pids: [PIDValue] = [],
        dtcCode: String = "",
        frameNumber: UInt8 = 0
    ) {
        self.timestamp = timestamp; self.pids = pids; self.dtcCode = dtcCode
        self.frameNumber = frameNumber
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, pids, dtcCode, frameNumber
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        pids = try container.decode([PIDValue].self, forKey: .pids)
        dtcCode = try container.decode(String.self, forKey: .dtcCode)
        // Scans saved before multi-frame support only ever held frame 0.
        frameNumber = try container.decodeIfPresent(
            UInt8.self, forKey: .frameNumber
        ) ?? 0
    }
}

// MARK: - PID (Parameter ID)

public struct PIDDefinition: Identifiable, Codable, Hashable {
    public let id: UUID
    public let hexCode: String
    public let name: String
    public let description: String
    public let unit: String
    public let minValue: Double
    public let maxValue: Double
    public let category: PIDCategory
    public let equation: PIDEquation

    public init(id: UUID = UUID(), hexCode: String, name: String, description: String,
                unit: String, minValue: Double, maxValue: Double, category: PIDCategory,
                equation: PIDEquation = .linear(multiplier: 1, offset: 0)) {
        self.id = id; self.hexCode = hexCode; self.name = name; self.description = description
        self.unit = unit; self.minValue = minValue; self.maxValue = maxValue
        self.category = category; self.equation = equation
    }

    public enum PIDCategory: String, Codable, CaseIterable {
        case engine, fuel, emissions, transmission, speed, temperature, pressure, electrical, hybrid, custom
    }

    public enum PIDEquation: Codable, Hashable {
        case linear(multiplier: Double, offset: Double)
        case custom(formula: String)
        case bitEncoded(mask: UInt8, shift: Int)
    }
}

public struct PIDValue: Identifiable, Codable, Hashable {
    public let id: UUID
    public let pid: PIDDefinition
    public let value: Double
    public let timestamp: Date

    public var formattedValue: String {
        String(format: "%.1f %@", value, pid.unit)
    }

    public init(id: UUID = UUID(), pid: PIDDefinition, value: Double, timestamp: Date = Date()) {
        self.id = id; self.pid = pid; self.value = value; self.timestamp = timestamp
    }
}

// MARK: - Scan Result

public struct OBDScanResult: Identifiable, Codable {
    public let id: UUID
    public let vehicle: Vehicle
    public let timestamp: Date
    public let dtcs: [DiagnosticTroubleCode]
    public let readinessMonitors: [ReadinessMonitor]
    public let freezeFrames: [FreezeFrameData]
    public let liveData: [PIDValue]
    /// Whether this record was fabricated by demo mode rather than read from
    /// a vehicle.
    ///
    /// This travels with the record instead of being inferred from live app
    /// state, because a saved demo scan outlives the demo session and would
    /// otherwise be indistinguishable from ECU evidence after a relaunch.
    public let isSimulated: Bool

    public init(id: UUID = UUID(), vehicle: Vehicle, timestamp: Date = Date(),
                dtcs: [DiagnosticTroubleCode] = [], readinessMonitors: [ReadinessMonitor] = [],
                freezeFrames: [FreezeFrameData] = [], liveData: [PIDValue] = [],
                isSimulated: Bool = false) {
        self.id = id; self.vehicle = vehicle; self.timestamp = timestamp; self.dtcs = dtcs
        self.readinessMonitors = readinessMonitors; self.freezeFrames = freezeFrames
        self.liveData = liveData
        self.isSimulated = isSimulated
    }
}

// MARK: - Readiness Monitor

public struct ReadinessMonitor: Identifiable, Codable, Hashable {
    public let id: UUID
    public let name: String
    public let isReady: Bool
    public let isSupported: Bool

    public init(id: UUID = UUID(), name: String, isReady: Bool, isSupported: Bool) {
        self.id = id; self.name = name; self.isReady = isReady; self.isSupported = isSupported
    }

    public static let allMonitors: [String] = [
        "Misfire", "Fuel System", "Comprehensive Component",
        "Catalyst", "Heated Catalyst", "EVAP System",
        "Secondary Air", "A/C Refrigerant", "Oxygen Sensor",
        "Oxygen Sensor Heater", "EGR System", "NMHC Catalyst",
        "NOx Catalyst", "Boost Pressure", "PM Filter", "EGR/VVT"
    ]
}

// MARK: - Connection State

public struct ConnectionState: Equatable {
    public enum Status: Equatable {
        case disconnected, scanning, connecting, connected, disconnecting, error(String)
    }

    public let status: Status
    public let adapterName: String?
    public let adapterFirmware: String?
    public let signalStrength: Int?

    public init(status: Status = .disconnected, adapterName: String? = nil,
                adapterFirmware: String? = nil, signalStrength: Int? = nil) {
        self.status = status; self.adapterName = adapterName
        self.adapterFirmware = adapterFirmware; self.signalStrength = signalStrength
    }

    public static let disconnected = ConnectionState()
}

// MARK: - Vehicle Link and Adapter Health

/// Distinguishes a live phone-to-adapter transport from a vehicle ECU link.
///
/// `ConnectionState.Status.connected` means the adapter's Bluetooth or MFi
/// transport is ready. A diagnostic request is safe only after this state
/// reaches `vehicleReady`.
public enum OBDVehicleLinkState: Equatable, Sendable {
    case disconnected
    case adapterConnected
    case initializingAdapter
    case searchingVehicleProtocol
    case vehicleReady(protocolIdentifier: String)
    case repairing
    case error(message: String, adapterConnected: Bool)
}

/// Vehicle-scoped information learned during SAE Mode 01 discovery.
///
/// The stable `Vehicle.id` is deliberately the cache key. VINs can be absent
/// or corrected later, while make/model strings are not unique enough to keep
/// one car's bus protocol from leaking into another car's connection attempt.
public struct OBDVehicleCapabilities: Codable, Equatable, Sendable {
    public let vehicleID: UUID
    public let protocolIdentifier: String
    public let supportedMode01PIDs: Set<UInt8>
    public let probeLatency: TimeInterval
    public let updatedAt: Date

    public init(
        vehicleID: UUID,
        protocolIdentifier: String,
        supportedMode01PIDs: Set<UInt8> = [],
        probeLatency: TimeInterval,
        updatedAt: Date = Date()
    ) {
        self.vehicleID = vehicleID
        self.protocolIdentifier = protocolIdentifier
        self.supportedMode01PIDs = supportedMode01PIDs
        self.probeLatency = max(0, probeLatency)
        self.updatedAt = updatedAt
    }
}

/// Read-only adapter observations suitable for an Adapter Health screen.
public struct OBDAdapterHealthReport: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case healthy
        case degraded
        case unavailable
    }

    public let status: Status
    public let adapterIdentity: String?
    public let supplyVoltage: Double?
    public let protocolIdentifier: String?
    public let roundTripLatency: TimeInterval?
    public let issues: [String]
    public let measuredAt: Date

    public init(
        status: Status,
        adapterIdentity: String? = nil,
        supplyVoltage: Double? = nil,
        protocolIdentifier: String? = nil,
        roundTripLatency: TimeInterval? = nil,
        issues: [String] = [],
        measuredAt: Date = Date()
    ) {
        self.status = status
        self.adapterIdentity = adapterIdentity
        self.supplyVoltage = supplyVoltage
        self.protocolIdentifier = protocolIdentifier
        self.roundTripLatency = roundTripLatency.map { max(0, $0) }
        self.issues = issues
        self.measuredAt = measuredAt
    }
}
