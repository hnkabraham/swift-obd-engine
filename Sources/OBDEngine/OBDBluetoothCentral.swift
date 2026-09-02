import CoreBluetooth
import Foundation

/// A property-only view of a peripheral the central owns.
///
/// `DiscoveredAdapterCandidate` stays separate on purpose: it is the ranking
/// input for auto-connect selection and carries scan-scoped measurements
/// (signal strength, discovery order). This type is the transport-scoped
/// handle — everything `OBDConnectionManager` still needs to name and address
/// a peripheral once `CBPeripheral` no longer crosses the seam.
struct BLEPeripheralIdentity: Equatable, Sendable {
    let identifier: UUID
    /// The peripheral's GAP name, which is `nil` until iOS has read it. Scan
    /// results fall back to the advertised local name, which is delivered
    /// alongside the identity rather than folded into it.
    let name: String?

    init(identifier: UUID, name: String?) {
        self.identifier = identifier
        self.name = name
    }

    init(peripheral: CBPeripheral) {
        self.init(identifier: peripheral.identifier, name: peripheral.name)
    }
}

/// A service/characteristic pair addressed by canonical UUID.
///
/// Endpoints are the only characteristic reference that crosses the seam, so
/// the manager can name a GATT endpoint without holding a `CBCharacteristic`.
struct BLEEndpoint: Hashable, Sendable {
    let serviceUUID: String
    let characteristicUUID: String

    init(serviceUUID: String, characteristicUUID: String) {
        self.serviceUUID = BLECharacteristicCandidate.canonicalUUID(serviceUUID)
        self.characteristicUUID =
            BLECharacteristicCandidate.canonicalUUID(characteristicUUID)
    }

    init(service: CBService, characteristic: CBCharacteristic) {
        self.init(
            serviceUUID: service.uuid.uuidString,
            characteristicUUID: characteristic.uuid.uuidString
        )
    }

    init(candidate: BLECharacteristicCandidate) {
        self.init(
            serviceUUID: candidate.serviceUUID,
            characteristicUUID: candidate.characteristicUUID
        )
    }
}

/// Everything the BLE transport reports upward. Delivered on the main queue so
/// the manager's command queue and Apple-object confinement rules hold.
enum OBDBluetoothCentralEvent {
    case stateChanged(CBManagerState)
    /// `advertisedLocalName` stays separate from the identity because a
    /// peripheral iOS has not named yet is still matched by the name it
    /// advertises.
    case discovered(
        peripheral: BLEPeripheralIdentity,
        advertisedLocalName: String?,
        rssi: Int,
        advertisedServiceUUIDs: [CBUUID]
    )
    case connected(id: UUID)
    case failedToConnect(id: UUID, error: Error?)
    case disconnected(id: UUID, error: Error?)
    /// Emitted once per peripheral after every discovered service has reported
    /// its characteristics. `discoveryError` is the last per-service failure of
    /// an otherwise complete pass: it is not fatal on its own, because the
    /// remaining services may still contain a usable profile, and only becomes
    /// the reported error when profile resolution then fails.
    case characteristicsResolved(
        id: UUID,
        candidates: [BLECharacteristicCandidate],
        discoveryError: Error?
    )
    /// Discovery produced nothing to resolve. A `nil` error means the
    /// peripheral exposed no services at all.
    case characteristicDiscoveryFailed(id: UUID, error: Error?)
    case notificationState(
        id: UUID,
        endpoint: BLEEndpoint,
        isNotifying: Bool,
        error: Error?
    )
    /// Payload from the endpoint notifications were enabled on. The central
    /// filters by that endpoint, so byte framing can never mix two
    /// characteristics.
    case receivedData(Data)
    /// Acknowledgement of a `withResponse` write. The write strategy paces the
    /// chunked transfer with it, so it is a transport event rather than an
    /// optional extra.
    case writeAcknowledged(id: UUID, endpoint: BLEEndpoint, error: Error?)
    case readyForWriteWithoutResponse
}

/// The BLE surface `OBDConnectionManager` drives.
///
/// Only value types and endpoint keys cross this boundary: `CBPeripheral` and
/// `CBCharacteristic` objects, and the GATT bookkeeping needed to keep them,
/// belong to the implementation.
protocol OBDBluetoothCentral: AnyObject {
    var state: CBManagerState { get }
    var isScanning: Bool { get }
    var onEvent: ((OBDBluetoothCentralEvent) -> Void)? { get set }

    func scan(services: [CBUUID]?)
    func stopScan()
    func connect(id: UUID)
    func cancelConnection(id: UUID)
    func retrievePeripherals(
        withIdentifiers identifiers: [UUID]
    ) -> [BLEPeripheralIdentity]
    func retrieveConnectedPeripherals(
        services: [CBUUID]
    ) -> [BLEPeripheralIdentity]
    /// Runs a full service + characteristic discovery pass and reports it with
    /// `characteristicsResolved` or `characteristicDiscoveryFailed`.
    func discoverEndpoints(id: UUID)
    func enableNotifications(id: UUID, endpoint: BLEEndpoint)
    func write(id: UUID, data: Data, endpoint: BLEEndpoint, withResponse: Bool)
    func canSendWriteWithoutResponse(id: UUID) -> Bool
    func maximumWriteValueLength(id: UUID, withResponse: Bool) -> Int
    func isConnected(id: UUID) -> Bool
    func isNotifying(id: UUID, endpoint: BLEEndpoint) -> Bool
}

/// The live CoreBluetooth implementation.
///
/// Constructing this type constructs a `CBCentralManager`, which is a radio
/// touch: TCC kills a test process that reaches it, and the app would prompt
/// for Bluetooth permission at launch. `OBDConnectionManager` therefore builds
/// it lazily on first radio use, never in its initializer.
final class CoreBluetoothCentral: NSObject, OBDBluetoothCentral {
    /// GATT objects for one peripheral. Keeping them here — rather than in the
    /// manager — is what lets the manager work in resolved candidates and
    /// endpoint keys alone.
    private struct GATTDiscovery {
        var pendingServices: Set<ObjectIdentifier> = []
        var candidates: [BLECharacteristicCandidate] = []
        var characteristics: [BLEEndpoint: CBCharacteristic] = [:]
        var discoveryError: Error?
    }

    private let central: CBCentralManager
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var gatt: [UUID: GATTDiscovery] = [:]
    private var notifyEndpoints: [UUID: BLEEndpoint] = [:]

    var onEvent: ((OBDBluetoothCentralEvent) -> Void)?

    override init() {
        // Delegate assignment follows construction so `self` is fully
        // initialized before CoreBluetooth can call back.
        central = CBCentralManager(delegate: nil, queue: .main)
        super.init()
        central.delegate = self
    }

    var state: CBManagerState { central.state }

    var isScanning: Bool { central.isScanning }

    func scan(services: [CBUUID]?) {
        // A new scan releases the previous scan's advertisers, mirroring the
        // discovery state the manager clears at the same point — a scan that
        // ends without a connect must not retain every peripheral that ever
        // advertised nearby for the manager's lifetime. Anything not
        // disconnected stays so a live or tearing-down session survives a
        // concurrent rescan.
        peripherals = peripherals.filter { $0.value.state != .disconnected }
        central.scanForPeripherals(
            withServices: services,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScan() {
        central.stopScan()
    }

    func connect(id: UUID) {
        guard let peripheral = peripherals[id] else { return }
        // Every advertiser seen during a scan is retained until a target is
        // chosen, mirroring the discovery state the manager clears at the same
        // point. Peripherals that are still connected or disconnecting stay so
        // their final callbacks can be delivered.
        peripherals = peripherals.filter {
            $0.key == id || $0.value.state != .disconnected
        }
        central.connect(peripheral, options: nil)
    }

    func cancelConnection(id: UUID) {
        guard let peripheral = peripherals[id] else { return }
        // The delegate is cleared with the same call that retires the
        // peripheral, so no late GATT callback can be read as the next
        // session's.
        peripheral.delegate = nil
        gatt[id] = nil
        notifyEndpoints[id] = nil
        central.cancelPeripheralConnection(peripheral)
    }

    func retrievePeripherals(
        withIdentifiers identifiers: [UUID]
    ) -> [BLEPeripheralIdentity] {
        track(central.retrievePeripherals(withIdentifiers: identifiers))
    }

    func retrieveConnectedPeripherals(
        services: [CBUUID]
    ) -> [BLEPeripheralIdentity] {
        track(central.retrieveConnectedPeripherals(withServices: services))
    }

    func discoverEndpoints(id: UUID) {
        guard let peripheral = peripherals[id] else { return }
        gatt[id] = GATTDiscovery()
        notifyEndpoints[id] = nil
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func enableNotifications(id: UUID, endpoint: BLEEndpoint) {
        guard let peripheral = peripherals[id],
              let characteristic = gatt[id]?.characteristics[endpoint] else {
            return
        }
        notifyEndpoints[id] = endpoint
        guard !characteristic.isNotifying else {
            // An endpoint that already notifies produces no
            // `didUpdateNotificationStateFor` callback, so report the state the
            // caller is waiting on directly.
            emit(.notificationState(
                id: id,
                endpoint: endpoint,
                isNotifying: true,
                error: nil
            ))
            return
        }
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func write(
        id: UUID,
        data: Data,
        endpoint: BLEEndpoint,
        withResponse: Bool
    ) {
        guard let peripheral = peripherals[id],
              let characteristic = gatt[id]?.characteristics[endpoint] else {
            return
        }
        peripheral.writeValue(
            data,
            for: characteristic,
            type: withResponse ? .withResponse : .withoutResponse
        )
    }

    func canSendWriteWithoutResponse(id: UUID) -> Bool {
        peripherals[id]?.canSendWriteWithoutResponse ?? false
    }

    func maximumWriteValueLength(id: UUID, withResponse: Bool) -> Int {
        peripherals[id]?.maximumWriteValueLength(
            for: withResponse ? .withResponse : .withoutResponse
        ) ?? 0
    }

    func isConnected(id: UUID) -> Bool {
        peripherals[id]?.state == .connected
    }

    func isNotifying(id: UUID, endpoint: BLEEndpoint) -> Bool {
        gatt[id]?.characteristics[endpoint]?.isNotifying == true
    }

    private func track(
        _ peripherals: [CBPeripheral]
    ) -> [BLEPeripheralIdentity] {
        // CoreBluetooth only delivers callbacks for peripherals the caller
        // retains, so every peripheral handed out is kept here.
        for peripheral in peripherals {
            self.peripherals[peripheral.identifier] = peripheral
        }
        return peripherals.map(BLEPeripheralIdentity.init(peripheral:))
    }

    /// CoreBluetooth callbacks already arrive on the main queue; the hop only
    /// covers events synthesized from a caller-initiated shortcut.
    private func emit(_ event: OBDBluetoothCentralEvent) {
        if Thread.isMainThread {
            onEvent?(event)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onEvent?(event)
            }
        }
    }

    private func endpoint(
        for characteristic: CBCharacteristic,
        on id: UUID
    ) -> BLEEndpoint? {
        gatt[id]?.characteristics.first { $0.value === characteristic }?.key
    }
}

// MARK: - CBCentralManagerDelegate

extension CoreBluetoothCentral: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        emit(.stateChanged(central.state))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        peripherals[peripheral.identifier] = peripheral
        emit(.discovered(
            peripheral: BLEPeripheralIdentity(peripheral: peripheral),
            advertisedLocalName:
                advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            rssi: RSSI.intValue,
            advertisedServiceUUIDs:
                advertisementData[CBAdvertisementDataServiceUUIDsKey]
                as? [CBUUID] ?? []
        ))
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        peripherals[peripheral.identifier] = peripheral
        emit(.connected(id: peripheral.identifier))
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        emit(.failedToConnect(id: peripheral.identifier, error: error))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        // A disconnect invalidates the peripheral's GATT objects; the endpoint
        // map has to go with them.
        gatt[peripheral.identifier] = nil
        notifyEndpoints[peripheral.identifier] = nil
        emit(.disconnected(id: peripheral.identifier, error: error))
    }
}

// MARK: - CBPeripheralDelegate

extension CoreBluetoothCentral: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let id = peripheral.identifier
        if let error {
            emit(.characteristicDiscoveryFailed(id: id, error: error))
            return
        }
        guard let services = peripheral.services, !services.isEmpty else {
            emit(.characteristicDiscoveryFailed(id: id, error: nil))
            return
        }

        gatt[id, default: GATTDiscovery()].pendingServices =
            Set(services.map(ObjectIdentifier.init))
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let id = peripheral.identifier
        guard var discovery = gatt[id] else { return }

        discovery.pendingServices.remove(ObjectIdentifier(service))
        if let error {
            discovery.discoveryError = error
        } else if let characteristics = service.characteristics {
            for characteristic in characteristics {
                discovery.candidates.append(BLECharacteristicCandidate(
                    service: service,
                    characteristic: characteristic
                ))
                discovery.characteristics[
                    BLEEndpoint(service: service, characteristic: characteristic)
                ] = characteristic
            }
        }
        gatt[id] = discovery

        if discovery.pendingServices.isEmpty {
            emit(.characteristicsResolved(
                id: id,
                candidates: discovery.candidates,
                discoveryError: discovery.discoveryError
            ))
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let id = peripheral.identifier
        guard let endpoint = endpoint(for: characteristic, on: id) else { return }
        emit(.notificationState(
            id: id,
            endpoint: endpoint,
            isNotifying: characteristic.isNotifying,
            error: error
        ))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let id = peripheral.identifier
        guard let endpoint = endpoint(for: characteristic, on: id) else { return }
        if let error {
            // A failed update on the notify endpoint is a notification-stream
            // failure, and the manager retires the transport on either error,
            // so it travels the same event rather than a second channel.
            // Errors on any other characteristic are unrelated to the stream
            // and must not tear down a healthy session, matching the success
            // path's endpoint filter below.
            guard endpoint == notifyEndpoints[id] else { return }
            emit(.notificationState(
                id: id,
                endpoint: endpoint,
                isNotifying: characteristic.isNotifying,
                error: error
            ))
            return
        }
        guard endpoint == notifyEndpoints[id],
              let data = characteristic.value else {
            return
        }
        emit(.receivedData(data))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let id = peripheral.identifier
        guard let endpoint = endpoint(for: characteristic, on: id) else { return }
        emit(.writeAcknowledged(id: id, endpoint: endpoint, error: error))
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        // Only the peripheral this central was asked to discover ever has it as
        // a delegate, so the readiness signal needs no addressing.
        emit(.readyForWriteWithoutResponse)
    }
}
