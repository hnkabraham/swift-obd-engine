import Foundation
#if SWIFT_PACKAGE
import OBDModels
#endif

protocol OBDVehicleCapabilityStoring: Sendable {
    func capabilities(for vehicleID: UUID) -> OBDVehicleCapabilities?
    func save(_ capabilities: OBDVehicleCapabilities)
}

/// File-protected-by-the-app-sandbox, vehicle-scoped protocol capability cache.
///
/// Older builds could store one global protocol. The first stable vehicle UUID
/// that asks for a cache entry may consume that value exactly once; the marker
/// is written even when the legacy value is malformed so a later vehicle can
/// never inherit it.
final class OBDVehicleCapabilityCache:
    OBDVehicleCapabilityStoring,
    @unchecked Sendable
{
    static let legacyProtocolKey = "obd.detectedProtocolIdentifier"

    private struct Payload: Codable {
        var records: [OBDVehicleCapabilities]
    }

    private let defaults: UserDefaults
    private let recordsKey: String
    private let migrationMarkerKey: String
    private let legacyProtocolKey: String
    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        namespace: String = "obd.vehicleCapabilities.v1",
        legacyProtocolKey: String =
            OBDVehicleCapabilityCache.legacyProtocolKey
    ) {
        self.defaults = defaults
        recordsKey = "\(namespace).records"
        migrationMarkerKey = "\(namespace).legacyProtocolMigrated"
        self.legacyProtocolKey = legacyProtocolKey
    }

    func capabilities(for vehicleID: UUID) -> OBDVehicleCapabilities? {
        lock.lock()
        defer { lock.unlock() }

        var records = loadRecords()
        let existing = records[vehicleID]

        guard !defaults.bool(forKey: migrationMarkerKey) else {
            return existing
        }

        // Consume the legacy slot once even if this vehicle already has a
        // modern record. Otherwise a second vehicle could inherit old global
        // state after the first vehicle was restored from the new cache.
        defaults.set(true, forKey: migrationMarkerKey)
        defer {
            defaults.removeObject(forKey: legacyProtocolKey)
        }
        guard existing == nil,
              let legacy = defaults.string(forKey: legacyProtocolKey),
              Self.isValidProtocolIdentifier(legacy) else {
            return existing
        }

        let migrated = OBDVehicleCapabilities(
            vehicleID: vehicleID,
            protocolIdentifier: legacy.uppercased(),
            probeLatency: 0
        )
        records[vehicleID] = migrated
        persist(records)
        return migrated
    }

    func save(_ capabilities: OBDVehicleCapabilities) {
        lock.lock()
        defer { lock.unlock() }

        var records = loadRecords()
        records[capabilities.vehicleID] = capabilities
        persist(records)

        // A modern vehicle-specific save also seals migration. This matters
        // when initialization succeeds before any cache read occurs.
        defaults.set(true, forKey: migrationMarkerKey)
        defaults.removeObject(forKey: legacyProtocolKey)
    }

    private func loadRecords() -> [UUID: OBDVehicleCapabilities] {
        guard let data = defaults.data(forKey: recordsKey),
              let payload = try? JSONDecoder().decode(
                  Payload.self,
                  from: data
              ) else {
            return [:]
        }
        return Dictionary(
            payload.records.map { ($0.vehicleID, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
    }

    private func persist(
        _ records: [UUID: OBDVehicleCapabilities]
    ) {
        let values = records.values.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.vehicleID.uuidString < $1.vehicleID.uuidString
        }.prefix(64)
        guard let data = try? JSONEncoder().encode(
            Payload(records: Array(values))
        ) else {
            return
        }
        defaults.set(data, forKey: recordsKey)
    }

    private static func isValidProtocolIdentifier(
        _ rawValue: String
    ) -> Bool {
        let value = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let validCodes = Set("123456789ABC")
        if value.count == 1, let code = value.first {
            return validCodes.contains(code)
        }
        if value.count == 2,
           value.first == "A",
           let code = value.last {
            return validCodes.contains(code)
        }
        return false
    }
}
