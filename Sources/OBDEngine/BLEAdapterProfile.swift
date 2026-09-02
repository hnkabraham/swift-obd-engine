import CoreBluetooth
import Foundation

/// A property-only view of a BLE characteristic. Keeping profile resolution
/// independent from `CBPeripheral` makes adapter matching deterministic and
/// unit-testable without Bluetooth hardware.
public struct BLECharacteristicCandidate: Equatable, Sendable {
    public let serviceUUID: String
    public let characteristicUUID: String
    public let canWriteWithResponse: Bool
    public let canWriteWithoutResponse: Bool
    public let canNotify: Bool
    public let canIndicate: Bool

    public init(
        serviceUUID: String,
        characteristicUUID: String,
        canWriteWithResponse: Bool = false,
        canWriteWithoutResponse: Bool = false,
        canNotify: Bool = false,
        canIndicate: Bool = false
    ) {
        self.serviceUUID = Self.canonicalUUID(serviceUUID)
        self.characteristicUUID = Self.canonicalUUID(characteristicUUID)
        self.canWriteWithResponse = canWriteWithResponse
        self.canWriteWithoutResponse = canWriteWithoutResponse
        self.canNotify = canNotify
        self.canIndicate = canIndicate
    }

    init(service: CBService, characteristic: CBCharacteristic) {
        self.init(
            serviceUUID: service.uuid.uuidString,
            characteristicUUID: characteristic.uuid.uuidString,
            canWriteWithResponse: characteristic.properties.contains(.write),
            canWriteWithoutResponse: characteristic.properties.contains(.writeWithoutResponse),
            canNotify: characteristic.properties.contains(.notify),
            canIndicate: characteristic.properties.contains(.indicate)
        )
    }

    public var canWrite: Bool {
        canWriteWithResponse || canWriteWithoutResponse
    }

    public var canReceiveUpdates: Bool {
        canNotify || canIndicate
    }

    public static func canonicalUUID(_ rawValue: String) -> String {
        let value = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let bluetoothBaseSuffix = "-0000-1000-8000-00805F9B34FB"
        if value.hasSuffix(bluetoothBaseSuffix) {
            let prefix = String(value.dropLast(bluetoothBaseSuffix.count))
            if prefix.count == 8, prefix.hasPrefix("0000") {
                return String(prefix.suffix(4))
            }
            return prefix
        }
        return value
    }
}

public struct ResolvedBLEAdapterProfile: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case obdLinkCX
        case fffUART
        case nordicUART
        case elmUART
        case ffeUART
        case isscUART
        case genericUART
    }

    public enum WriteStrategy: Equatable, Sendable {
        case withResponse
        case withoutResponse
    }

    public let kind: Kind
    public let serviceUUID: String
    public let writeUUID: String
    public let notifyUUID: String
    public let writeStrategy: WriteStrategy

    public init(
        kind: Kind,
        serviceUUID: String,
        writeUUID: String,
        notifyUUID: String,
        writeStrategy: WriteStrategy
    ) {
        self.kind = kind
        self.serviceUUID = BLECharacteristicCandidate.canonicalUUID(serviceUUID)
        self.writeUUID = BLECharacteristicCandidate.canonicalUUID(writeUUID)
        self.notifyUUID = BLECharacteristicCandidate.canonicalUUID(notifyUUID)
        self.writeStrategy = writeStrategy
    }
}

/// Resolves an adapter's serial-style BLE endpoints within one service.
///
/// Known profiles always win over generic fallback. A recognized but
/// incomplete OBDLink CX service is rejected rather than misinterpreting its
/// notification-only FFF1 characteristic as writable.
public enum BLEAdapterProfileResolver {
    private struct Definition {
        let kind: ResolvedBLEAdapterProfile.Kind
        let serviceUUID: String
        let writeUUID: String
        let notifyUUID: String
    }

    private static let definitions: [Definition] = [
        Definition(
            kind: .nordicUART,
            serviceUUID: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E",
            writeUUID: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E",
            notifyUUID: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
        ),
        Definition(
            kind: .elmUART,
            serviceUUID: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2",
            writeUUID: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F",
            notifyUUID: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F"
        ),
        Definition(
            kind: .ffeUART,
            serviceUUID: "FFE0",
            writeUUID: "FFE1",
            notifyUUID: "FFE1"
        ),
        Definition(
            kind: .isscUART,
            serviceUUID: "49535343-FE7D-4AE5-8FA9-9FAFD205E455",
            writeUUID: "49535343-8841-43F4-A8D4-ECBE34729BB3",
            notifyUUID: "49535343-8841-43F4-A8D4-ECBE34729BB3"
        ),
    ]

    /// Service UUIDs with a documented serial-style layout. This is useful for
    /// advertisement filtering, but a service match alone never makes an
    /// adapter usable; `resolve(_:)` still validates every characteristic role.
    public static var knownServiceUUIDs: Set<String> {
        Set(definitions.map(\.serviceUUID)).union(["FFF0"])
    }

    public static func resolve(
        _ candidates: [BLECharacteristicCandidate]
    ) -> ResolvedBLEAdapterProfile? {
        let normalized = candidates.map {
            BLECharacteristicCandidate(
                serviceUUID: $0.serviceUUID,
                characteristicUUID: $0.characteristicUUID,
                canWriteWithResponse: $0.canWriteWithResponse,
                canWriteWithoutResponse: $0.canWriteWithoutResponse,
                canNotify: $0.canNotify,
                canIndicate: $0.canIndicate
            )
        }

        // FFF0 is shared by the official OBDLink CX layout and a handful of
        // ELM327 clone layouts. Resolve only the known, same-service role
        // combinations below. Never let an arbitrary FFF0 characteristic
        // fall through to generic pairing.
        let fffCandidates = normalized.filter { $0.serviceUUID == "FFF0" }
        if !fffCandidates.isEmpty {
            if let profile = resolveFFF0(fffCandidates) {
                return profile
            }
        }

        for definition in definitions {
            let serviceCandidates = normalized.filter {
                $0.serviceUUID == definition.serviceUUID
            }
            guard !serviceCandidates.isEmpty else { continue }

            guard let writer = serviceCandidates.first(where: {
                $0.characteristicUUID == definition.writeUUID && $0.canWrite
            }),
            let notifier = serviceCandidates.first(where: {
                $0.characteristicUUID == definition.notifyUUID &&
                    $0.canReceiveUpdates
            }) else {
                continue
            }

            return resolved(
                kind: definition.kind,
                writer: writer,
                notifier: notifier
            )
        }

        // Generic pairing is the last resort for undocumented adapters and for
        // documented services whose roles are simply split across two
        // characteristics. Both endpoints always come from the same service, so
        // an unrelated notify endpoint can never be paired with another
        // service's writer, and the services with a documented serial layout
        // are tried before anything else so a split-role known adapter is never
        // paired to an unrelated control endpoint. FFF0 is the one exception:
        // `resolveFFF0` already enumerates every safe role combination there,
        // and its remaining characteristics are control endpoints rather than
        // serial ones.
        let grouped = Dictionary(
            grouping: normalized.filter { $0.serviceUUID != "FFF0" },
            by: \.serviceUUID
        )
        for serviceUUID in genericPairingOrder(of: Array(grouped.keys)) {
            guard let serviceCandidates = grouped[serviceUUID] else { continue }
            let sorted = serviceCandidates.sorted {
                $0.characteristicUUID < $1.characteristicUUID
            }
            if let bidirectional = sorted.first(where: {
                $0.canWrite && $0.canReceiveUpdates
            }) {
                return resolved(
                    kind: .genericUART,
                    writer: bidirectional,
                    notifier: bidirectional
                )
            }
            guard let writer = sorted.first(where: \.canWrite),
                  let notifier = sorted.first(where: \.canReceiveUpdates) else {
                continue
            }
            return resolved(
                kind: .genericUART,
                writer: writer,
                notifier: notifier
            )
        }
        return nil
    }

    /// Orders the services the generic pass will try.
    ///
    /// Services with a documented serial layout come first, in the profile
    /// table's own order, because a split-role known adapter — an FFE0 clone
    /// that notifies on FFE1 and writes on FFE2, say — must not lose to an
    /// unrelated service whose UUID merely sorts earlier (a Nordic legacy DFU
    /// control point at 00001530-…, a vendor configuration service). Writing
    /// `ATZ` to a firmware-update endpoint is the exact hazard this pass has to
    /// avoid. Everything else follows in sorted order so the result stays
    /// deterministic regardless of characteristic discovery order.
    private static func genericPairingOrder(
        of serviceUUIDs: [String]
    ) -> [String] {
        let available = Set(serviceUUIDs)
        let recognized = definitions
            .map { BLECharacteristicCandidate.canonicalUUID($0.serviceUUID) }
            .filter { available.contains($0) }
        let recognizedSet = Set(recognized)
        return recognized + serviceUUIDs
            .filter { !recognizedSet.contains($0) }
            .sorted()
    }

    private static func resolveFFF0(
        _ candidates: [BLECharacteristicCandidate]
    ) -> ResolvedBLEAdapterProfile? {
        func candidate(
            _ uuid: String,
            where predicate: (BLECharacteristicCandidate) -> Bool
        ) -> BLECharacteristicCandidate? {
            candidates.first {
                $0.characteristicUUID == uuid && predicate($0)
            }
        }

        // Official OBDLink CX: FFF2 writes, FFF1 notifies.
        if let writer = candidate("FFF2", where: \.canWrite),
           let notifier = candidate("FFF1", where: \.canReceiveUpdates) {
            return resolved(
                kind: .obdLinkCX,
                writer: writer,
                notifier: notifier
            )
        }

        // Common clones expose one bidirectional characteristic.
        for uuid in ["FFF1", "FFF2"] {
            if let endpoint = candidate(uuid, where: {
                $0.canWrite && $0.canReceiveUpdates
            }) {
                return resolved(
                    kind: .fffUART,
                    writer: endpoint,
                    notifier: endpoint
                )
            }
        }

        // A smaller clone family reverses the two official roles. This is
        // still safe because both endpoints are explicitly validated inside
        // the same FFF0 service.
        if let writer = candidate("FFF1", where: \.canWrite),
           let notifier = candidate("FFF2", where: \.canReceiveUpdates) {
            return resolved(
                kind: .fffUART,
                writer: writer,
                notifier: notifier
            )
        }
        return nil
    }

    private static func resolved(
        kind: ResolvedBLEAdapterProfile.Kind,
        writer: BLECharacteristicCandidate,
        notifier: BLECharacteristicCandidate
    ) -> ResolvedBLEAdapterProfile {
        ResolvedBLEAdapterProfile(
            kind: kind,
            serviceUUID: writer.serviceUUID,
            writeUUID: writer.characteristicUUID,
            notifyUUID: notifier.characteristicUUID,
            writeStrategy: writer.canWriteWithResponse
                ? .withResponse
                : .withoutResponse
        )
    }
}
