import Foundation

/// A property-only view of a peripheral seen while scanning.
///
/// Keeping auto-connect selection independent from `CBPeripheral` makes adapter
/// choice deterministic and unit-testable without Bluetooth hardware.
public struct DiscoveredAdapterCandidate: Equatable, Sendable {
    public let identifier: UUID
    public let name: String
    public let signalStrength: Int
    /// Sequence number of this peripheral's first advertisement in the current
    /// scan. Used only as the final tiebreak, so ranking stays a total order
    /// even when two adapters report the same signal strength.
    public let discoveryOrder: Int

    public init(
        identifier: UUID,
        name: String,
        signalStrength: Int,
        discoveryOrder: Int
    ) {
        self.identifier = identifier
        self.name = name
        self.signalStrength = signalStrength
        self.discoveryOrder = discoveryOrder
    }

    /// CoreBluetooth reports `127` — and other non-negative values — when a
    /// reading is unavailable. Treating that as a measurement would make the
    /// least-known advertisement look like the closest adapter in the room.
    public var hasUsableSignalStrength: Bool {
        signalStrength < 0 && signalStrength >= -127
    }

    var rankedSignalStrength: Int {
        hasUsableSignalStrength ? signalStrength : Int.min
    }
}

/// Deterministic auto-connect selection among discovered OBD adapters.
///
/// Several adapters are routinely in range at once (a repair shop, a parking
/// garage), so connecting to whichever advertisement arrives first can attach
/// to a neighboring vehicle's adapter. Selection therefore prefers the adapter
/// this device last completed setup with, then the strongest signal.
public enum AdapterCandidateRanking {
    /// Name fragments shared by ELM327-compatible adapters.
    static let knownNameFragments = [
        "obd", "elm", "vgate", "veepeak", "carista",
        "plx", "scantool", "obdlink", "v-link",
    ]

    public static func matchesKnownAdapterName(_ name: String) -> Bool {
        let normalizedName = name.lowercased()
        return knownNameFragments.contains(where: normalizedName.contains)
    }

    public static func isHigherPriority(
        _ lhs: DiscoveredAdapterCandidate,
        than rhs: DiscoveredAdapterCandidate,
        preferredIdentifier: UUID? = nil
    ) -> Bool {
        if let preferredIdentifier, lhs.identifier != rhs.identifier {
            if lhs.identifier == preferredIdentifier { return true }
            if rhs.identifier == preferredIdentifier { return false }
        }
        if lhs.rankedSignalStrength != rhs.rankedSignalStrength {
            return lhs.rankedSignalStrength > rhs.rankedSignalStrength
        }
        return lhs.discoveryOrder < rhs.discoveryOrder
    }

    public static func ranked(
        _ candidates: [DiscoveredAdapterCandidate],
        preferredIdentifier: UUID? = nil
    ) -> [DiscoveredAdapterCandidate] {
        candidates.sorted {
            isHigherPriority($0, than: $1, preferredIdentifier: preferredIdentifier)
        }
    }

    /// The adapter to connect to, independent of the order candidates were
    /// collected in.
    public static func best(
        of candidates: [DiscoveredAdapterCandidate],
        preferredIdentifier: UUID? = nil
    ) -> DiscoveredAdapterCandidate? {
        candidates.reduce(nil) { best, candidate in
            guard let best else { return candidate }
            return isHigherPriority(
                candidate,
                than: best,
                preferredIdentifier: preferredIdentifier
            ) ? candidate : best
        }
    }
}
