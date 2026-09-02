import CoreBluetooth
import Foundation
#if canImport(ExternalAccessory)
@preconcurrency import ExternalAccessory
#endif
#if SWIFT_PACKAGE
import OBDModels
#endif

public protocol OBDConnectionManagerDelegate: AnyObject {
    func connectionManager(_ manager: OBDConnectionManager, didUpdateState state: ConnectionState)
    func connectionManager(_ manager: OBDConnectionManager, didReceiveResponse response: String, for command: ELM327Command)
    func connectionManager(_ manager: OBDConnectionManager, didReceiveError error: Error)
}

public extension OBDConnectionManagerDelegate {
    func connectionManager(_ manager: OBDConnectionManager, didReceiveResponse response: String, for command: ELM327Command) {}
    func connectionManager(_ manager: OBDConnectionManager, didReceiveError error: Error) {}
}

/// CoreBluetooth and MFi ExternalAccessory transport for
/// ELM327/STN-compatible adapters.
///
/// Apple transport callbacks and command-queue mutation are confined to the
/// main queue. A connection is considered ready only after a property-validated
/// BLE profile is notification-ready or both MFi streams are open.
public final class OBDConnectionManager: NSObject, @unchecked Sendable {
    public enum ConnectionType: Equatable, Sendable {
        case ble
        case wifi
        case mfi
    }

    /// Delegate and callback sinks. Assignments come from app/UI threads while
    /// invocations happen on the main queue, so reads and writes are guarded
    /// by `callbackLock`; handlers are invoked only after it is released.
    public weak var delegate: OBDConnectionManagerDelegate? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return _delegate
        }
        set {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            _delegate = newValue
        }
    }
    public var onConnectionStateChange: ((ConnectionState) -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return _onConnectionStateChange
        }
        set {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            _onConnectionStateChange = newValue
        }
    }
    public var onResponse: ((String, ELM327Command) -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return _onResponse
        }
        set {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            _onResponse = newValue
        }
    }
    private let callbackLock = NSLock()
    private weak var _delegate: OBDConnectionManagerDelegate?
    private var _onConnectionStateChange: ((ConnectionState) -> Void)?
    private var _onResponse: ((String, ELM327Command) -> Void)?

    private struct PublicTransportSnapshot {
        var connectionState: ConnectionState = .disconnected
        var activeConnectionType: ConnectionType?
        var transportGeneration: UInt64 = 0
        var transportIsUsable = false
    }

    /// CoreBluetooth and stream objects remain main-queue confined, while
    /// OBDService legitimately asks for connection/generation state from Swift
    /// concurrency executors. Publish only value-type state through this lock
    /// so those readers never touch Apple transport objects off their queue.
    private let publicSnapshotLock = NSLock()
    private var publicSnapshot = PublicTransportSnapshot()

    public private(set) var connectionState: ConnectionState {
        get {
            withPublicSnapshot { $0.connectionState }
        }
        set {
            mutatePublicSnapshot { $0.connectionState = newValue }
        }
    }

    /// Physical route currently owned by the manager. A non-nil value does
    /// not imply that an ECU has answered; higher layers establish vehicle
    /// readiness after the adapter transport reaches `.connected`.
    public private(set) var activeConnectionType: ConnectionType? {
        get {
            withPublicSnapshot { $0.activeConnectionType }
        }
        set {
            mutatePublicSnapshot { $0.activeConnectionType = newValue }
        }
    }

    /// Monotonic token for the active physical byte stream. Long-running
    /// operations can retain this value and decline to continue after a
    /// disconnect, transport switch, or reconnect.
    public private(set) var transportGeneration: UInt64 {
        get {
            withPublicSnapshot { $0.transportGeneration }
        }
        set {
            mutatePublicSnapshot { $0.transportGeneration = newValue }
        }
    }

    public var isConnected: Bool {
        withPublicSnapshot {
            $0.connectionState.status == .connected &&
                $0.transportIsUsable
        }
    }

    private func withPublicSnapshot<T>(
        _ body: (PublicTransportSnapshot) -> T
    ) -> T {
        publicSnapshotLock.lock()
        defer { publicSnapshotLock.unlock() }
        return body(publicSnapshot)
    }

    private func mutatePublicSnapshot(
        _ body: (inout PublicTransportSnapshot) -> Void
    ) {
        publicSnapshotLock.lock()
        body(&publicSnapshot)
        publicSnapshotLock.unlock()
    }

    private func publishTransportUsability(_ isUsable: Bool) {
        mutatePublicSnapshot { $0.transportIsUsable = isUsable }
    }

    private struct QueuedCommand {
        let command: ELM327Command
        let expectedTransportGeneration: UInt64
        let continuation: CheckedContinuation<String, Error>
    }

    // Created on first radio use, never in init: constructing the production
    // central constructs a CBCentralManager, which counts as Bluetooth access,
    // which TCC kills in a transport-injected test process and which prompts
    // the user for permission at app launch instead of on their first explicit
    // connect.
    private var _bluetoothCentral: OBDBluetoothCentral?
    private var bluetoothCentral: OBDBluetoothCentral {
        if let existing = _bluetoothCentral { return existing }
        let created = makeBluetoothCentral()
        // Stored before the sink is wired so an implementation that reports
        // synchronously cannot re-enter this accessor and build a second one.
        _bluetoothCentral = created
        created.onEvent = { [weak self] event in
            self?.handle(event)
        }
        return created
    }
    private var connectedPeripheral: BLEPeripheralIdentity?
    private var writeEndpoint: BLEEndpoint?
    private var notifyEndpoint: BLEEndpoint?
    private var resolvedProfile: ResolvedBLEAdapterProfile?
    private var discoveredCandidates: [BLECharacteristicCandidate] = []
    private var characteristicDiscoveryError: Error?

    private var pendingScanRequest = false
    private var scanTimeout: DispatchWorkItem?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var connectionAttemptID = UUID()
    private var activeAdapterName: String?
    private var activeSignalStrength: Int?

    private var discoveredAdapters: [UUID: DiscoveredAdapterCandidate] = [:]
    private var discoveredPeripherals: [UUID: BLEPeripheralIdentity] = [:]
    private var discoveryCounter = 0
    private var adapterSelectionWorkItem: DispatchWorkItem?
    private var preferredAdapterIdentifier: UUID?
    private var connectingToRememberedAdapter = false
    /// Set when the remembered adapter timed out on the retrieve fast path.
    /// It stays set across automatic reconnect attempts so none of them pays
    /// another full `connectionTimeout` on the same unreachable peripheral;
    /// only an explicit user connect or a session that actually reaches
    /// transport-ready clears it.
    private var rememberedAdapterFastPathSuppressed = false

    private let discoveryTimeout: TimeInterval
    private let connectionTimeout: TimeInterval
    private let selectionWindow: TimeInterval
    private let commandWriteTimeout: TimeInterval
    private let responseDrainTimeout: TimeInterval
    private let responseDrainSettleWindow: TimeInterval
    private let reconnectBaseDelay: TimeInterval
    private let defaults: UserDefaults
    private let makeBluetoothCentral: () -> OBDBluetoothCentral
    /// Every deferred BLE/reconnect deadline runs through this. The work item
    /// stays the cancellation token, so a cancelled item is still a no-op when
    /// its delay elapses.
    private let scheduleAfter: (TimeInterval, DispatchWorkItem) -> Void
    private let maximumResponseBytes = 64 * 1_024

    /// Defaults key holding the identifier of the adapter that last completed
    /// Bluetooth setup on this device.
    static let lastAdapterIdentifierKey = "obd.lastConnectedAdapterIdentifier"

    private var commandQueue: [QueuedCommand] = []
    private var isProcessingCommand = false
    private var currentCommandGeneration: UInt64 = 0
    private var currentCommandTransportGeneration: UInt64?
    private var responseBuffer = ""
    private var completedResponse: String?
    private var currentWriteTimeout: DispatchWorkItem?
    private var currentResponseTimeout: DispatchWorkItem?
    private var pendingWriteChunks: [Data] = []
    private var awaitingWriteAcknowledgement = false
    private var commandDeadlineState = OBDCommandDeadlineState()
    private var writeFlushRetry: DispatchWorkItem?
    private let writeFlushRetryInterval: TimeInterval = 0.05
    private var drainState = OBDResponseDrainState()
    private var drainDeadline: DispatchWorkItem?
    private var drainSettleWork: DispatchWorkItem?

    private var automaticReconnectEnabled = false
    private var intentionalDisconnect = false
    private var reconnectTracker: OBDReconnectTracker
    private var reconnectWorkItem: DispatchWorkItem?

#if canImport(ExternalAccessory)
    private var accessorySession: EASession?
    private var accessory: EAAccessory?
    private var accessorySessionGeneration: UInt64 = 0
    private var openAccessoryStreams: Set<ObjectIdentifier> = []
    private var pendingAccessoryWrite: Data?
    private var pendingAccessoryWriteOffset = 0
    private var pendingAccessoryWriteSessionGeneration: UInt64?
#endif

    /// Production transport. Calling this is the radio touch the lazy
    /// `bluetoothCentral` accessor defers until the first connect.
    private static func makeProductionBluetoothCentral() -> OBDBluetoothCentral {
        CoreBluetoothCentral()
    }

    private static func scheduleOnMainQueue(
        after delay: TimeInterval,
        execute work: DispatchWorkItem
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    public convenience init(
        discoveryTimeout: TimeInterval = 15,
        connectionTimeout: TimeInterval = 15,
        selectionWindow: TimeInterval = 2,
        commandWriteTimeout: TimeInterval = 2,
        responseDrainTimeout: TimeInterval = 2,
        responseDrainSettleWindow: TimeInterval = 0.3,
        maximumReconnectAttempts: Int = 3,
        reconnectBaseDelay: TimeInterval = 0.75,
        preferredAdapterIdentifier: UUID? = nil,
        defaults: UserDefaults = .standard
    ) {
        // Both seam arguments are named here so this call can never resolve
        // back to itself.
        self.init(
            discoveryTimeout: discoveryTimeout,
            connectionTimeout: connectionTimeout,
            selectionWindow: selectionWindow,
            commandWriteTimeout: commandWriteTimeout,
            responseDrainTimeout: responseDrainTimeout,
            responseDrainSettleWindow: responseDrainSettleWindow,
            maximumReconnectAttempts: maximumReconnectAttempts,
            reconnectBaseDelay: reconnectBaseDelay,
            preferredAdapterIdentifier: preferredAdapterIdentifier,
            defaults: defaults,
            makeBluetoothCentral: Self.makeProductionBluetoothCentral,
            scheduleAfter: Self.scheduleOnMainQueue
        )
    }

    /// Testable initializer. The transport and the deferred-work clock are the
    /// only injectable seams; every policy above them is the production one.
    init(
        discoveryTimeout: TimeInterval = 15,
        connectionTimeout: TimeInterval = 15,
        selectionWindow: TimeInterval = 2,
        commandWriteTimeout: TimeInterval = 2,
        responseDrainTimeout: TimeInterval = 2,
        responseDrainSettleWindow: TimeInterval = 0.3,
        maximumReconnectAttempts: Int = 3,
        reconnectBaseDelay: TimeInterval = 0.75,
        preferredAdapterIdentifier: UUID? = nil,
        defaults: UserDefaults = .standard,
        makeBluetoothCentral: @escaping () -> OBDBluetoothCentral =
            OBDConnectionManager.makeProductionBluetoothCentral,
        scheduleAfter: @escaping (TimeInterval, DispatchWorkItem) -> Void =
            OBDConnectionManager.scheduleOnMainQueue
    ) {
        self.makeBluetoothCentral = makeBluetoothCentral
        self.scheduleAfter = scheduleAfter
        let resolvedDiscoveryTimeout = max(3, discoveryTimeout)
        self.discoveryTimeout = resolvedDiscoveryTimeout
        self.connectionTimeout = max(3, connectionTimeout)
        // The window has to stay well inside the discovery timeout so ranking
        // never eats the whole scan budget.
        self.selectionWindow = min(
            max(0.5, selectionWindow),
            resolvedDiscoveryTimeout / 2
        )
        self.commandWriteTimeout = max(0.5, commandWriteTimeout)
        // A drain that outlives its own budget is indistinguishable from a dead
        // adapter, so the budget stays short; the quiet window only has to
        // outlast the gap between an adapter's own prompt and any trailing
        // bytes, and must stay well inside the budget it runs under.
        let resolvedDrainTimeout = max(0.25, responseDrainTimeout)
        self.responseDrainTimeout = resolvedDrainTimeout
        self.responseDrainSettleWindow = min(
            max(0.05, responseDrainSettleWindow),
            resolvedDrainTimeout / 2
        )
        self.reconnectTracker = OBDReconnectTracker(
            maximumAttempts: maximumReconnectAttempts
        )
        self.reconnectBaseDelay = max(0.1, reconnectBaseDelay)
        self.defaults = defaults
        self.preferredAdapterIdentifier = preferredAdapterIdentifier ??
            defaults.string(forKey: OBDConnectionManager.lastAdapterIdentifierKey)
            .flatMap(UUID.init(uuidString:))
        super.init()
#if canImport(ExternalAccessory)
        EAAccessoryManager.shared().registerForLocalNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessoryDidConnect(_:)),
            name: .EAAccessoryDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessoryDidDisconnect(_:)),
            name: .EAAccessoryDidDisconnect,
            object: nil
        )
#endif
    }

    deinit {
        reconnectWorkItem?.cancel()
        // Nothing can resume a continuation once its owner is gone, so an
        // awaiting `sendCommand` would hang forever.
        let pending = commandQueue
        commandQueue.removeAll()
        pending.forEach {
            $0.continuation.resume(throwing: OBDError.notConnected)
        }
#if canImport(ExternalAccessory)
        // Only this instance's registrations may be dropped here.
        // `unregisterForLocalNotifications()` is a process-wide switch, so
        // calling it would also silence every other live manager's accessory
        // connect/disconnect callbacks.
        NotificationCenter.default.removeObserver(self)
        let streams = [
            accessorySession?.inputStream as Stream?,
            accessorySession?.outputStream as Stream?,
        ].compactMap { $0 }
        // The delegate is this instance and has to be cleared before it is
        // gone; closing and unscheduling instead mutate the main run loop.
        for stream in streams {
            stream.delegate = nil
        }
        Self.closeAccessoryStreamsOnMainRunLoop(streams)
#endif
    }

#if canImport(ExternalAccessory)
    /// Streams are scheduled on the main run loop, and a run loop may only be
    /// mutated from its own thread. `deinit` runs wherever the last reference
    /// was released, so teardown hops to the main queue when it has to.
    private static func closeAccessoryStreamsOnMainRunLoop(_ streams: [Stream]) {
        guard !streams.isEmpty else { return }
        let teardown = {
            for stream in streams {
                stream.close()
                stream.remove(from: .main, forMode: .common)
            }
        }
        if Thread.isMainThread {
            teardown()
        } else {
            DispatchQueue.main.async(execute: teardown)
        }
    }
#endif

    // MARK: - Connection

    public func connect() {
        runOnMain { [weak self] in
            guard let self else { return }
            self.intentionalDisconnect = false
            self.automaticReconnectEnabled = true
            self.rememberedAdapterFastPathSuppressed = false
            self.reconnectTracker.reset()
            self.cancelReconnect()
            self.startConnectionDiscovery()
        }
    }

    public func startScanning() {
        runOnMain { [weak self] in
            guard let self else { return }
            self.intentionalDisconnect = false
            self.automaticReconnectEnabled = true
            self.rememberedAdapterFastPathSuppressed = false
            self.reconnectTracker.reset()
            self.cancelReconnect()
            self.startConnectionDiscovery()
        }
    }

    /// Revalidates Apple-owned transport objects after suspension. Connection
    /// and accessory notifications are best-effort across process suspension,
    /// so foregrounding must compare the published state with the live route.
    public func reconcileConnectionOnForeground() {
        runOnMain { [weak self] in
            guard let self,
                  self.automaticReconnectEnabled,
                  !self.intentionalDisconnect else {
                return
            }
            // Returning to the foreground is a fresh attempt on a session the
            // user still wants. Attempts spent while the app was suspended —
            // where scanning and timers barely run — must not leave the budget
            // permanently empty for the rest of the session.
            self.reconnectTracker.reset()
            self.cancelReconnect()
            self.startConnectionDiscovery()
        }
    }

    private func startConnectionDiscovery() {
        let publishedConnected = connectionState.status == .connected
        let transportIsUsable = mainQueueTransportIsUsable
        if OBDTransportPolicy.healthyConnectionShouldBeRepublished(
            publishedConnected: publishedConnected,
            transportIsUsable: transportIsUsable
        ) {
            publishTransportUsability(true)
            // Re-emitting this state restarts higher-level vehicle preparation
            // after OBDService deliberately reset it for a connect/reconcile.
            updateState(connectionState)
            return
        }
        if OBDTransportPolicy.publishedConnectionNeedsRediscovery(
            publishedConnected: publishedConnected,
            transportIsUsable: transportIsUsable
        ) {
            discardSilentlyDeadTransport()
        }

        guard connectionState.status != .connecting,
              connectionState.status != .disconnecting else {
            return
        }
#if canImport(ExternalAccessory)
        if connectToAttachedAccessoryIfAvailable() {
            return
        }
#endif
        switch bluetoothCentral.state {
        case .poweredOn:
            beginScan()
        case .unknown, .resetting:
            pendingScanRequest = true
            updateState(.init(status: .scanning))
        case .poweredOff:
            // Keep the explicit connection intent. The central reports a state
            // change when the radio becomes usable.
            pendingScanRequest = true
            updateState(.init(
                status: .error(String(localized: "Bluetooth is powered off"))
            ))
        case .unauthorized:
            updateState(.init(
                status: .error(String(localized: "Bluetooth permission denied"))
            ))
        case .unsupported:
            updateState(.init(
                status: .error(
                    String(
                        localized:
                            "Bluetooth is not supported on this device"
                    )
                )
            ))
        @unknown default:
            updateState(.init(
                status: .error(String(localized: "Bluetooth is unavailable"))
            ))
        }
    }

    /// Reads CoreBluetooth / ExternalAccessory objects only from the manager's
    /// main queue. Public readers consume the cached value-type snapshot.
    private var mainQueueTransportIsUsable: Bool {
        switch activeConnectionType {
        case .ble:
            // Read through the stored central: a live BLE route implies one
            // already exists, so this check never becomes the first radio
            // touch.
            guard let central = _bluetoothCentral,
                  let peripheral = connectedPeripheral,
                  let notifyEndpoint else {
                return false
            }
            return central.isConnected(id: peripheral.identifier) &&
                central.isNotifying(
                    id: peripheral.identifier,
                    endpoint: notifyEndpoint
                )
        case .mfi:
#if canImport(ExternalAccessory)
            return accessoryTransportIsReady
#else
            return false
#endif
        case .wifi, .none:
            return false
        }
    }

    /// A route can die while the app is suspended without delivering its final
    /// callback. Retire its generation and clear every Apple object before
    /// immediate re-enumeration, but avoid surfacing a stale intermediate error.
    private func discardSilentlyDeadTransport() {
        stopScanInternal()
        cancelConnectionTimeout()
        retireCommandTransport(with: OBDError.notConnected)
        connectionAttemptID = UUID()
        abandonConnectedPeripheral()
#if canImport(ExternalAccessory)
        teardownAccessorySession()
#endif
        publishTransportUsability(false)
        activeConnectionType = nil
        clearEndpointState()
        clearDiscoveryState()
        updateState(.disconnected)
    }

    public func stopScanning() {
        runOnMain { [weak self] in
            guard let self else { return }
            self.pendingScanRequest = false
            self.automaticReconnectEnabled = false
            self.cancelReconnect()
            self.stopScanInternal()
        }
    }

    public func disconnect() {
        runOnMain { [weak self] in
            guard let self else { return }
            self.intentionalDisconnect = true
            self.automaticReconnectEnabled = false
            self.reconnectTracker.reset()
            self.cancelReconnect()
            self.pendingScanRequest = false
            self.stopScanInternal()
            self.cancelConnectionTimeout()
            self.connectionAttemptID = UUID()
            self.retireCommandTransport(with: OBDError.notConnected)

            let peripheral = self.connectedPeripheral
            if let peripheral {
                self.updateState(.init(
                    status: .disconnecting,
                    adapterName: self.activeAdapterName ?? peripheral.name,
                    signalStrength: self.activeSignalStrength
                ))
                self.bluetoothCentral.cancelConnection(id: peripheral.identifier)
            }

            self.connectedPeripheral = nil
#if canImport(ExternalAccessory)
            self.teardownAccessorySession()
#endif
            self.publishTransportUsability(false)
            self.activeConnectionType = nil
            self.clearEndpointState()
            self.clearDiscoveryState()
            self.activeAdapterName = nil
            self.activeSignalStrength = nil
            self.updateState(.disconnected)
        }
    }

    /// Initialization failures can leave an ELM/STN adapter in a partial
    /// command state. Retire the physical stream rather than allowing a later
    /// retry to reuse unread bytes or an iOS-owned stale MFi session.
    public func retireAfterFatalInitializationFailure(
        expectedTransportGeneration: UInt64
    ) {
        runOnMain { [weak self] in
            guard let self else { return }
            var hasLiveTransport = self.activeConnectionType != nil ||
                self.connectedPeripheral != nil
#if canImport(ExternalAccessory)
            hasLiveTransport = hasLiveTransport ||
                self.accessorySession != nil
#endif
            guard OBDTransportPolicy.fatalRetirementIsEligible(
                expectedGeneration: expectedTransportGeneration,
                activeGeneration: self.transportGeneration,
                hasLiveTransport: hasLiveTransport
            ) else {
                return
            }
            self.failConnection(with: OBDError.commandFailed(
                String(localized: "Adapter initialization failed")
            ))
        }
    }

    /// Compatibility wrapper for callers that do not already retain a
    /// generation. The snapshot and the main-queue retirement are still joined
    /// by the same generation guard.
    public func retireAfterFatalInitializationFailure() {
        retireAfterFatalInitializationFailure(
            expectedTransportGeneration: transportGeneration
        )
    }

    /// Resets the reconnect budget only after the ECU, not merely the adapter,
    /// has completed a command on the same physical transport generation.
    public func confirmVehicleCommunication(
        expectedTransportGeneration: UInt64
    ) {
        runOnMain { [weak self] in
            guard let self,
                  self.mainQueueTransportIsUsable,
                  self.connectionState.status == .connected else {
                return
            }
            _ = self.reconnectTracker.confirmVehicleCommunication(
                expectedGeneration: expectedTransportGeneration,
                activeGeneration: self.transportGeneration
            )
        }
    }

    private func beginScan(allowRememberedAdapter: Bool = true) {
        guard connectionState.status != .connected,
              connectionState.status != .connecting,
              connectionState.status != .disconnecting else {
            return
        }

        pendingScanRequest = false
        stopScanInternal()
        cancelConnectionTimeout()
        abandonConnectedPeripheral()
#if canImport(ExternalAccessory)
        teardownAccessorySession()
#endif
        publishTransportUsability(false)
        activeConnectionType = nil
        clearEndpointState()
        clearDiscoveryState()
        connectionAttemptID = UUID()
        updateState(.init(status: .scanning))

        // Prefer the exact adapter previously used, then adapters that iOS
        // already has connected to a known serial service. This recovers from
        // missed advertisements and app relaunches without weakening profile
        // validation after connection. Once the remembered adapter has timed
        // out on that fast path, recovery skips it entirely until it proves
        // itself again by advertising — the stored preference still wins the
        // ranking in `didDiscover`, which costs nothing when it is out of range.
        if connectToRecoveredPeripheralIfAvailable(
            allowRememberedIdentifier: allowRememberedAdapter &&
                !rememberedAdapterFastPathSuppressed
        ) {
            return
        }

        // Name filtering happens on discovery. Scanning without a service
        // restriction accommodates clone-specific UART services.
        bluetoothCentral.scan(services: nil)

        let attemptID = connectionAttemptID
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.connectionAttemptID == attemptID,
                  self.connectionState.status == .scanning else {
                return
            }
            // An adapter first advertised inside the selection window has a
            // pending selection that would otherwise be cancelled here —
            // drain the collected candidates before declaring failure.
            self.adapterSelectionWorkItem?.cancel()
            self.adapterSelectionWorkItem = nil
            self.connectToBestCandidate()
            guard self.connectionState.status == .scanning else { return }
            self.stopScanInternal()
            self.updateState(.init(
                status: .error(
                    String(localized: "No OBD adapter found nearby")
                )
            ))
            self.scheduleReconnectIfEligible()
        }
        scanTimeout = timeout
        scheduleAfter(discoveryTimeout, timeout)
    }

    private func connectToRecoveredPeripheralIfAvailable(
        allowRememberedIdentifier: Bool = true
    ) -> Bool {
        if allowRememberedIdentifier,
           let preferredAdapterIdentifier,
           let remembered = bluetoothCentral.retrievePeripherals(
               withIdentifiers: [preferredAdapterIdentifier]
           ).first {
            beginConnecting(
                to: remembered,
                name: remembered.name ??
                    String(localized: "OBD adapter"),
                signalStrength: nil,
                isRememberedAdapter: true
            )
            return true
        }

        let serviceUUIDs = BLEAdapterProfileResolver.knownServiceUUIDs
            .sorted()
            .map(CBUUID.init(string:))
        let connected = bluetoothCentral.retrieveConnectedPeripherals(
            services: serviceUUIDs
        )
        let eligibleConnected = connected.filter {
            // `cancelPeripheralConnection` is asynchronous, so the adapter that
            // just timed out is still reported as system-connected here. The
            // exclusion has to cover this branch too, or the fallback would
            // immediately restart the identical attempt it was created to skip.
            guard allowRememberedIdentifier ||
                    $0.identifier != preferredAdapterIdentifier else {
                return false
            }
            return AdapterCandidateRanking.matchesKnownAdapterName($0.name ?? "")
        }
        let rankedConnected = eligibleConnected.sorted { left, right in
            let leftName = left.name ?? ""
            let rightName = right.name ?? ""
            if leftName != rightName {
                return leftName < rightName
            }
            return left.identifier.uuidString < right.identifier.uuidString
        }
        guard let candidate = rankedConnected.first else {
            return false
        }

        beginConnecting(
            to: candidate,
            name: candidate.name ?? String(localized: "OBD adapter"),
            signalStrength: nil,
            // Reaching the remembered adapter through this branch is still a
            // remembered connect. Tagging it routes a timeout to the scan
            // fallback rather than to `failConnection`, whose preference-erasure
            // rule would delete a stored adapter that was never disproven.
            isRememberedAdapter: candidate.identifier == preferredAdapterIdentifier
        )
        return true
    }

    private func stopScanInternal() {
        scanTimeout?.cancel()
        scanTimeout = nil
        adapterSelectionWorkItem?.cancel()
        adapterSelectionWorkItem = nil
        // Teardown must never be the first radio touch.
        if let central = _bluetoothCentral, central.isScanning {
            central.stopScan()
        }
    }

    private func clearDiscoveryState() {
        discoveredAdapters.removeAll(keepingCapacity: false)
        discoveredPeripherals.removeAll(keepingCapacity: false)
        discoveryCounter = 0
    }

    private func scheduleConnectionTimeout() {
        cancelConnectionTimeout()
        let attemptID = connectionAttemptID
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.connectionAttemptID == attemptID,
                  self.connectionState.status == .connecting else {
                return
            }
            if self.connectingToRememberedAdapter {
                self.scanAfterRememberedAdapterTimedOut()
                return
            }
            self.failConnection(
                with: OBDError.bluetoothUnavailable(
                    String(
                        localized:
                            "The adapter did not finish Bluetooth setup in time"
                    )
                )
            )
        }
        connectionTimeoutWorkItem = timeout
        scheduleAfter(connectionTimeout, timeout)
    }

    private func cancelConnectionTimeout() {
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
    }

    /// `retrievePeripherals` hands back the remembered adapter even when it is
    /// unpowered or out of range, so a timeout there is no evidence about which
    /// adapter belongs to this vehicle. Release it, keep the stored preference,
    /// and run the scan the fast path skipped instead of failing the attempt.
    ///
    /// The suppression outlives this one rescan on purpose: `retrievePeripherals`
    /// would keep returning the same unreachable peripheral, so every automatic
    /// reconnect attempt would spend a full `connectionTimeout` before it ever
    /// scanned. Only an explicit `connect()`/`startScanning()` or a session that
    /// reaches transport-ready re-enables the fast path.
    private func scanAfterRememberedAdapterTimedOut() {
        connectingToRememberedAdapter = false
        rememberedAdapterFastPathSuppressed = true
        activeAdapterName = nil
        activeSignalStrength = nil
        discardSilentlyDeadTransport()
        beginScan(allowRememberedAdapter: false)
    }

    private func clearEndpointState() {
        writeEndpoint = nil
        notifyEndpoint = nil
        resolvedProfile = nil
        discoveredCandidates.removeAll(keepingCapacity: false)
        characteristicDiscoveryError = nil
    }

    private func abandonConnectedPeripheral() {
        guard let peripheral = connectedPeripheral else { return }
        bluetoothCentral.cancelConnection(id: peripheral.identifier)
        connectedPeripheral = nil
    }

    private func retireCommandTransport(with error: Error) {
        mutatePublicSnapshot {
            $0.transportGeneration &+= 1
            $0.transportIsUsable = false
        }
        failAllCommands(with: error)
    }

    private func failConnection(with error: Error) {
        stopScanInternal()
        cancelConnectionTimeout()
        retireCommandTransport(with: error)
        connectionAttemptID = UUID()
        publishTransportUsability(false)

        let peripheral = connectedPeripheral
        connectedPeripheral = nil
        if let peripheral {
            // A remembered adapter that fails during setup must not keep
            // winning the pick over a working adapter on the next scan; it
            // re-earns the preference by completing setup again. Failures on
            // an established session (status already .connected) keep it —
            // stream hiccups say nothing about which adapter to prefer.
            if peripheral.identifier == preferredAdapterIdentifier,
               connectionState.status == .connecting {
                preferredAdapterIdentifier = nil
                defaults.removeObject(forKey: Self.lastAdapterIdentifierKey)
            }
            bluetoothCentral.cancelConnection(id: peripheral.identifier)
        }
#if canImport(ExternalAccessory)
        teardownAccessorySession()
#endif
        activeConnectionType = nil
        clearEndpointState()
        clearDiscoveryState()

        let state = ConnectionState(
            status: .error(error.localizedDescription),
            adapterName: activeAdapterName,
            signalStrength: activeSignalStrength
        )
        updateState(state)
        delegate?.connectionManager(self, didReceiveError: error)
        scheduleReconnectIfEligible()
    }

    private func markTransportReady() {
        guard let peripheral = connectedPeripheral,
              writeEndpoint != nil,
              let notifyEndpoint,
              bluetoothCentral.isNotifying(
                  id: peripheral.identifier,
                  endpoint: notifyEndpoint
              ),
              resolvedProfile != nil else {
            return
        }
        activeConnectionType = .ble
        cancelConnectionTimeout()
        cancelReconnect()
        publishTransportUsability(true)
        // A session that reached transport-ready is the evidence the earlier
        // fast-path timeout lacked, so the retrieve shortcut is trustworthy
        // again for the adapter remembered below.
        rememberedAdapterFastPathSuppressed = false
        rememberPreferredAdapter(peripheral.identifier)
        updateState(ConnectionState(
            status: .connected,
            adapterName: activeAdapterName ?? peripheral.name ??
                String(localized: "OBD adapter"),
            signalStrength: activeSignalStrength
        ))
    }

    private func cancelReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }

    private func scheduleReconnectIfEligible() {
        guard reconnectWorkItem == nil,
              let attempt = reconnectTracker.consumeAttemptIfEligible(
                  automaticReconnectEnabled: automaticReconnectEnabled,
                  wasIntentionalDisconnect: intentionalDisconnect
              ) else {
            return
        }

        let expectedAttemptID = connectionAttemptID
        let reconnect = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            guard self.connectionAttemptID == expectedAttemptID,
                  self.automaticReconnectEnabled,
                  !self.intentionalDisconnect,
                  self.connectionState.status != .connected else {
                return
            }
            self.startConnectionDiscovery()
        }
        reconnectWorkItem = reconnect
        scheduleAfter(
            OBDTransportPolicy.reconnectDelay(
                attempt: attempt,
                baseDelay: reconnectBaseDelay
            ),
            reconnect
        )
    }

    // MARK: - Adapter selection

    /// Remembers the adapter that finished Bluetooth setup. A later scan in a
    /// crowded lot then reconnects to this vehicle's adapter instead of ranking
    /// signal strength alone.
    private func rememberPreferredAdapter(_ identifier: UUID) {
        preferredAdapterIdentifier = identifier
        defaults.set(identifier.uuidString, forKey: Self.lastAdapterIdentifierKey)
    }

    private func discoveryOrder(for identifier: UUID) -> Int {
        if let existing = discoveredAdapters[identifier]?.discoveryOrder {
            return existing
        }
        discoveryCounter += 1
        return discoveryCounter
    }

    /// Holds the scan open briefly so every adapter in range is ranked, rather
    /// than connecting to whichever advertisement happened to arrive first.
    private func scheduleAdapterSelection() {
        guard adapterSelectionWorkItem == nil else { return }
        let attemptID = connectionAttemptID
        let selection = DispatchWorkItem { [weak self] in
            guard let self,
                  self.connectionAttemptID == attemptID,
                  self.connectionState.status == .scanning else {
                return
            }
            self.adapterSelectionWorkItem = nil
            self.connectToBestCandidate()
        }
        adapterSelectionWorkItem = selection
        scheduleAfter(selectionWindow, selection)
    }

    private func connectToBestCandidate() {
        guard connectionState.status == .scanning,
              connectedPeripheral == nil else {
            return
        }
        guard let selection = AdapterCandidateRanking.best(
            of: Array(discoveredAdapters.values),
            preferredIdentifier: preferredAdapterIdentifier
        ),
        let peripheral = discoveredPeripherals[selection.identifier] else {
            return
        }

        beginConnecting(
            to: peripheral,
            name: selection.name.isEmpty
                ? String(localized: "OBD adapter")
                : selection.name,
            signalStrength: selection.hasUsableSignalStrength
                ? selection.signalStrength
                : nil
        )
    }

    private func beginConnecting(
        to peripheral: BLEPeripheralIdentity,
        name: String,
        signalStrength: Int?,
        isRememberedAdapter: Bool = false
    ) {
        connectingToRememberedAdapter = isRememberedAdapter
        cancelReconnect()
        stopScanInternal()
        clearDiscoveryState()
        if let existing = connectedPeripheral,
           existing.identifier != peripheral.identifier {
            bluetoothCentral.cancelConnection(id: existing.identifier)
        }
        retireCommandTransport(with: OBDError.notConnected)
        publishTransportUsability(false)
        clearEndpointState()
        connectedPeripheral = peripheral
        activeConnectionType = .ble
        activeAdapterName = name
        activeSignalStrength = signalStrength
        connectionAttemptID = UUID()
        updateState(.init(
            status: .connecting,
            adapterName: activeAdapterName,
            signalStrength: activeSignalStrength
        ))
        scheduleConnectionTimeout()
        bluetoothCentral.connect(id: peripheral.identifier)
    }

    // MARK: - Commands

    public func sendCommand(_ command: ELM327Command) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            runOnMain { [weak self] in
                guard let self,
                      self.isConnected else {
                    continuation.resume(throwing: OBDError.notConnected)
                    return
                }

                self.commandQueue.append(QueuedCommand(
                    command: command,
                    expectedTransportGeneration: self.transportGeneration,
                    continuation: continuation
                ))
                self.processNextCommand()
            }
        }
    }

    private func processNextCommand() {
        guard !isProcessingCommand else { return }
        // A quarantined stream still carries a timed-out command's bytes.
        // Writing now would put two commands on a half-duplex link at once, so
        // the queue waits until the drain has proven the adapter is back at a
        // prompt and quiet. `finishResponseDrain` resumes it.
        guard !drainState.isDraining else { return }

        while let stale = commandQueue.first,
              !OBDTransportPolicy.generationIsCurrent(
                  expected: stale.expectedTransportGeneration,
                  active: transportGeneration
              ) {
            commandQueue.removeFirst()
            stale.continuation.resume(throwing: OBDError.notConnected)
        }

        guard let next = commandQueue.first else { return }
        guard let data = "\(next.command.raw)\r".data(using: .ascii),
              !next.command.raw.isEmpty else {
            completeCurrentCommand(.failure(OBDError.invalidResponse))
            return
        }

        isProcessingCommand = true
        currentCommandGeneration &+= 1
        currentCommandTransportGeneration = next.expectedTransportGeneration
        responseBuffer = ""
        completedResponse = nil
        awaitingWriteAcknowledgement = false
        commandDeadlineState.beginWrite()
        startWriteDeadline(for: next)

        switch activeConnectionType {
        case .ble:
            guard let peripheral = connectedPeripheral,
                  writeEndpoint != nil,
                  let profile = resolvedProfile else {
                failConnection(with: OBDError.notConnected)
                return
            }
            let writesWithResponse = profile.writeStrategy == .withResponse
            let chunkSize = max(
                1,
                bluetoothCentral.maximumWriteValueLength(
                    id: peripheral.identifier,
                    withResponse: writesWithResponse
                )
            )
            pendingWriteChunks = stride(from: 0, to: data.count, by: chunkSize).map {
                data.subdata(in: $0..<min($0 + chunkSize, data.count))
            }
            sendAvailableWriteChunks()

        case .mfi:
#if canImport(ExternalAccessory)
            guard case .mfi? = activeConnectionType,
                  let session = accessorySession,
                  let output = session.outputStream,
                  hasUsableAccessorySession else {
                failConnection(with: OBDError.notConnected)
                return
            }
            pendingAccessoryWrite = data
            pendingAccessoryWriteOffset = 0
            pendingAccessoryWriteSessionGeneration = accessorySessionGeneration
            if output.hasSpaceAvailable {
                flushPendingAccessoryWrite()
            }
#else
            failConnection(with: OBDError.notConnected)
#endif

        case .wifi, .none:
            failConnection(with: OBDError.notConnected)
        }
    }

    private func startWriteDeadline(for queued: QueuedCommand) {
        currentWriteTimeout?.cancel()
        let commandGeneration = currentCommandGeneration
        let expectedTransportGeneration = queued.expectedTransportGeneration
        let deadline = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isProcessingCommand,
                  self.currentCommandGeneration == commandGeneration,
                  self.transportGeneration == expectedTransportGeneration,
                  self.commandDeadlineState.isWriting else {
                return
            }
            // A timed-out or partially accepted write leaves command framing
            // unknowable. Retire the byte stream before any later command.
            self.failConnection(
                with: OBDError.commandTimedOut(queued.command.raw)
            )
        }
        currentWriteTimeout = deadline
        scheduleAfter(commandWriteTimeout, deadline)
    }

    private func markCurrentWritesComplete() {
        guard isProcessingCommand,
              commandDeadlineState.markAllBytesAccepted() else {
            return
        }
        currentWriteTimeout?.cancel()
        currentWriteTimeout = nil

        if commandDeadlineState.transactionCanComplete {
            completeIfTransactionReady()
            return
        }

        guard commandDeadlineState.responseDeadlineCanRun,
              let queued = commandQueue.first,
              let expectedTransportGeneration = currentCommandTransportGeneration else {
            failConnection(with: OBDError.invalidResponse)
            return
        }
        let commandGeneration = currentCommandGeneration
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isProcessingCommand,
                  self.currentCommandGeneration == commandGeneration,
                  self.transportGeneration == expectedTransportGeneration,
                  self.completedResponse == nil else {
                return
            }
            // The prompt boundary never arrived, but a slow command is not a
            // dead link: only this command fails. The quarantine opened here —
            // not a retired transport — is what stops a late response from
            // being mistaken for the next command's, because every byte is
            // discarded until the adapter's own prompt and a quiet window prove
            // the stream is idle again.
            self.quarantineStreamAfterResponseTimeout(for: queued.command)
        }
        currentResponseTimeout = timeout
        scheduleAfter(queued.command.timeout, timeout)
    }

    // MARK: - Response-timeout quarantine

    /// Fails only the timed-out command and takes ownership of the byte stream
    /// until the adapter is proven to be back at a clean prompt.
    private func quarantineStreamAfterResponseTimeout(for command: ELM327Command) {
        let generation = drainState.begin()
        scheduleDrainDeadline(for: command, generation: generation)
        // The drain is opened first because completing the command drives the
        // queue forward: an already-draining stream is what makes the next
        // command wait instead of writing over these bytes.
        completeCurrentCommand(.failure(OBDError.commandTimedOut(command.raw)))
    }

    /// Bounds how long a quarantine may wait for the prompt. An adapter that
    /// never produces one is not slow, it has stopped framing responses.
    private func scheduleDrainDeadline(
        for command: ELM327Command,
        generation: UInt64
    ) {
        drainDeadline?.cancel()
        let expectedTransportGeneration = transportGeneration
        let deadline = DispatchWorkItem { [weak self] in
            guard let self,
                  self.drainState.isDraining,
                  self.drainState.generation == generation,
                  self.transportGeneration == expectedTransportGeneration else {
                return
            }
            // No prompt inside the budget: retiring the stream is the only
            // remaining way to guarantee that whatever arrives next cannot
            // complete another command. This is the pre-quarantine behavior,
            // kept for the case it was always right for.
            self.failConnection(
                with: OBDError.commandTimedOut(command.raw)
            )
        }
        drainDeadline = deadline
        scheduleAfter(responseDrainTimeout, deadline)
    }

    /// Discards a timed-out command's late bytes. Nothing here can complete a
    /// command: the drain reads the stream only for its prompt boundary.
    private func ingestQuarantinedData(_ text: String) {
        let wasSettling = drainState.phase == .settling
        guard drainState.ingest(text) else {
            // Still mid-response, or the adapter resumed talking after a
            // prompt. The quiet window has to start over; the drain deadline
            // remains the bound on how long that may continue.
            cancelDrainSettle()
            return
        }
        // A whitespace-only chunk while already settled is not renewed
        // chatter — serial bridges emit bare CR keepalives, and letting each
        // one restart the quiet window would walk a transport sitting at a
        // clean prompt into the drain deadline and retire it. Only a fresh
        // prompt (more stale traffic just ended) restarts the window.
        if wasSettling, !text.contains(">") { return }
        scheduleDrainSettle()
    }

    /// Arms the quiet window that ends a drain. A late response and the
    /// adapter's own prompt both end in `>`, so silence — not the prompt
    /// alone — is what proves the stale traffic is over.
    private func scheduleDrainSettle() {
        cancelDrainSettle()
        let generation = drainState.generation
        let expectedTransportGeneration = transportGeneration
        let settle = DispatchWorkItem { [weak self] in
            guard let self,
                  self.transportGeneration == expectedTransportGeneration,
                  self.drainState.finishSettling(generation: generation) else {
                return
            }
            self.finishResponseDrain()
        }
        drainSettleWork = settle
        scheduleAfter(responseDrainSettleWindow, settle)
    }

    private func cancelDrainSettle() {
        drainSettleWork?.cancel()
        drainSettleWork = nil
    }

    /// The stream has been silent since the prompt, so it belongs to the next
    /// command. The transport generation is deliberately untouched: this
    /// connection was never retired.
    private func finishResponseDrain() {
        drainDeadline?.cancel()
        drainDeadline = nil
        cancelDrainSettle()
        processNextCommand()
    }

    /// Abandons a quarantine. Only transport retirement calls this: the drain
    /// exists to protect the next command on a live stream, and a retired
    /// generation already denies late bytes any command to complete.
    private func cancelResponseDrain() {
        drainDeadline?.cancel()
        drainDeadline = nil
        cancelDrainSettle()
        drainState.reset()
    }

    private func sendAvailableWriteChunks() {
        guard isProcessingCommand,
              activeConnectionType == .ble,
              currentCommandTransportGeneration == transportGeneration,
              let peripheral = connectedPeripheral,
              let endpoint = writeEndpoint,
              let profile = resolvedProfile else {
            return
        }

        switch profile.writeStrategy {
        case .withResponse:
            // `BLEAdapterProfileResolver` selects this strategy whenever the
            // characteristic advertises `.write`, because the write
            // acknowledgement paces the transfer: no chunk can be dropped by a
            // full buffer.
            guard !awaitingWriteAcknowledgement else { return }
            guard !pendingWriteChunks.isEmpty else {
                markCurrentWritesComplete()
                return
            }
            let chunk = pendingWriteChunks.removeFirst()
            awaitingWriteAcknowledgement = true
            bluetoothCentral.write(
                id: peripheral.identifier,
                data: chunk,
                endpoint: endpoint,
                withResponse: true
            )

        case .withoutResponse:
            // Unacknowledged writes are silently discarded once the buffer is
            // full, so only hand over chunks the peripheral says it can take.
            while !pendingWriteChunks.isEmpty &&
                    bluetoothCentral.canSendWriteWithoutResponse(
                        id: peripheral.identifier
                    ) {
                let chunk = pendingWriteChunks.removeFirst()
                bluetoothCentral.write(
                    id: peripheral.identifier,
                    data: chunk,
                    endpoint: endpoint,
                    withResponse: false
                )
            }
            if pendingWriteChunks.isEmpty {
                cancelWriteFlushRetry()
                markCurrentWritesComplete()
            } else {
                // The write-readiness event
                // (`peripheralIsReady(toSendWriteWithoutResponse:)`) is
                // documented to follow a write that CoreBluetooth could not
                // take, so a buffer that was already full when this transaction
                // started leaves no callback to resume from. Poll until it
                // drains instead of stalling into the command timeout.
                scheduleWriteFlushRetry()
            }
        }
    }

    private func scheduleWriteFlushRetry() {
        guard writeFlushRetry == nil else { return }
        let expectedTransportGeneration = transportGeneration
        let commandGeneration = currentCommandGeneration
        let retry = DispatchWorkItem { [weak self] in
            guard let self,
                  self.transportGeneration == expectedTransportGeneration,
                  self.currentCommandGeneration == commandGeneration else {
                return
            }
            self.writeFlushRetry = nil
            self.sendAvailableWriteChunks()
        }
        writeFlushRetry = retry
        scheduleAfter(writeFlushRetryInterval, retry)
    }

    private func cancelWriteFlushRetry() {
        writeFlushRetry?.cancel()
        writeFlushRetry = nil
    }

    private func completeIfTransactionReady() {
        guard commandDeadlineState.transactionCanComplete,
              let response = completedResponse else {
            return
        }
        completeCurrentCommand(.success(response))
    }

    private func completeCurrentCommand(_ result: Result<String, Error>) {
        guard !commandQueue.isEmpty else {
            resetCurrentTransaction()
            return
        }

        currentWriteTimeout?.cancel()
        currentWriteTimeout = nil
        currentResponseTimeout?.cancel()
        currentResponseTimeout = nil
        let queued = commandQueue.removeFirst()
        resetCurrentTransaction()

        switch result {
        case .success(let response):
            queued.continuation.resume(returning: response)
            delegate?.connectionManager(self, didReceiveResponse: response, for: queued.command)
            onResponse?(response, queued.command)
        case .failure(let error):
            queued.continuation.resume(throwing: error)
            delegate?.connectionManager(self, didReceiveError: error)
        }

        processNextCommand()
    }

    private func resetCurrentTransaction() {
        cancelWriteFlushRetry()
        isProcessingCommand = false
        responseBuffer = ""
        completedResponse = nil
        currentCommandTransportGeneration = nil
        pendingWriteChunks.removeAll(keepingCapacity: false)
        awaitingWriteAcknowledgement = false
        commandDeadlineState.reset()
#if canImport(ExternalAccessory)
        pendingAccessoryWrite = nil
        pendingAccessoryWriteOffset = 0
        pendingAccessoryWriteSessionGeneration = nil
#endif
    }

    private func failAllCommands(with error: Error) {
        cancelResponseDrain()
        currentWriteTimeout?.cancel()
        currentWriteTimeout = nil
        currentResponseTimeout?.cancel()
        currentResponseTimeout = nil
        resetCurrentTransaction()

        let pending = commandQueue
        commandQueue.removeAll()
        pending.forEach { $0.continuation.resume(throwing: error) }
    }

    private func ingestIncomingData(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        // A quarantined stream is checked first: these bytes belong to a
        // command that already failed, and `isProcessingCommand` alone cannot
        // tell them apart from the next command's response.
        if drainState.isDraining {
            ingestQuarantinedData(text)
            return
        }

        guard isProcessingCommand,
              currentCommandTransportGeneration == transportGeneration else {
            return
        }
        responseBuffer += text
        if responseBuffer.utf8.count > maximumResponseBytes {
            // An unbounded/noisy stream has lost command framing. Reconnect
            // before accepting another response from it.
            failConnection(with: OBDError.invalidResponse)
            return
        }

        if let prompt = responseBuffer.firstIndex(of: ">") {
            completedResponse = cleanedResponse(String(responseBuffer[..<prompt]))
            commandDeadlineState.markResponseReceived()
            completeIfTransactionReady()
        }
    }

    private func cleanedResponse(_ response: String) -> String {
        response
            .replacingOccurrences(of: ">", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateState(_ state: ConnectionState) {
        connectionState = state
        delegate?.connectionManager(self, didUpdateState: state)
        onConnectionStateChange?(state)
    }

    static func shouldSurfaceCentralFailure(
        status: ConnectionState.Status,
        pendingScanRequest: Bool,
        activeConnectionType: ConnectionType? = nil
    ) -> Bool {
        // CoreBluetooth authorization/reset state is not authority over an
        // ExternalAccessory session. Its own stream/disconnect callbacks own
        // MFi retirement.
        if activeConnectionType == .mfi {
            return false
        }
        if pendingScanRequest {
            return true
        }

        switch status {
        case .scanning, .connecting, .connected:
            return true
        case .disconnected, .disconnecting, .error:
            return false
        }
    }

    private func failActiveConnectionIfNeeded(with error: Error) {
        guard Self.shouldSurfaceCentralFailure(
            status: connectionState.status,
            pendingScanRequest: pendingScanRequest,
            activeConnectionType: activeConnectionType
        ) else {
            return
        }
        failConnection(with: error)
    }

    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

// MARK: - Bluetooth central events

extension OBDConnectionManager {
    /// Events arrive on the main queue, where the rest of the manager already
    /// runs, so they are handled without a further hop.
    private func handle(_ event: OBDBluetoothCentralEvent) {
        switch event {
        case .stateChanged(let state):
            handleCentralStateChange(state)
        case .discovered(
            let peripheral,
            let advertisedLocalName,
            let rssi,
            let advertisedServiceUUIDs
        ):
            handleDiscovery(
                of: peripheral,
                advertisedLocalName: advertisedLocalName,
                rssi: rssi,
                advertisedServiceUUIDs: advertisedServiceUUIDs
            )
        case .connected(let id):
            handleConnection(to: id)
        case .failedToConnect(let id, let error):
            handleConnectionFailure(for: id, error: error)
        case .disconnected(let id, let error):
            handleDisconnection(of: id, error: error)
        case .characteristicsResolved(let id, let candidates, let discoveryError):
            handleResolvedCharacteristics(
                for: id,
                candidates: candidates,
                discoveryError: discoveryError
            )
        case .characteristicDiscoveryFailed(let id, let error):
            handleCharacteristicDiscoveryFailure(for: id, error: error)
        case .notificationState(let id, let endpoint, let isNotifying, let error):
            handleNotificationState(
                for: id,
                endpoint: endpoint,
                isNotifying: isNotifying,
                error: error
            )
        case .receivedData(let data):
            handleReceivedData(data)
        case .writeAcknowledged(let id, let endpoint, let error):
            handleWriteAcknowledgement(
                for: id,
                endpoint: endpoint,
                error: error
            )
        case .readyForWriteWithoutResponse:
            handleReadyForWriteWithoutResponse()
        }
    }

    private func handleCentralStateChange(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            if pendingScanRequest {
                beginScan()
            }
        case .poweredOff:
            failActiveConnectionIfNeeded(
                with: OBDError.bluetoothUnavailable(
                    String(localized: "Bluetooth is powered off")
                )
            )
        case .unauthorized:
            failActiveConnectionIfNeeded(
                with: OBDError.bluetoothUnavailable(
                    String(localized: "Bluetooth permission denied")
                )
            )
        case .unsupported:
            failActiveConnectionIfNeeded(
                with: OBDError.bluetoothUnavailable(
                    String(
                        localized:
                            "Bluetooth is not supported on this device"
                    )
                )
            )
        case .resetting:
            failActiveConnectionIfNeeded(
                with: OBDError.bluetoothUnavailable(
                    String(localized: "Bluetooth is resetting")
                )
            )
        case .unknown:
            break
        @unknown default:
            failActiveConnectionIfNeeded(
                with: OBDError.bluetoothUnavailable(
                    String(localized: "Bluetooth is unavailable")
                )
            )
        }
    }

    private func handleDiscovery(
        of peripheral: BLEPeripheralIdentity,
        advertisedLocalName: String?,
        rssi: Int,
        advertisedServiceUUIDs: [CBUUID]
    ) {
        guard connectionState.status == .scanning,
              connectedPeripheral == nil else {
            return
        }

        let name = peripheral.name ?? advertisedLocalName ?? ""
        let advertisedServiceIDs = Set(advertisedServiceUUIDs.map {
            BLECharacteristicCandidate.canonicalUUID($0.uuidString)
        })
        let hasKnownService = !advertisedServiceIDs.isDisjoint(
            with: BLEAdapterProfileResolver.knownServiceUUIDs
        )
        guard AdapterCandidateRanking.matchesKnownAdapterName(name) ||
                hasKnownService else {
            return
        }

        let identifier = peripheral.identifier
        discoveredPeripherals[identifier] = peripheral
        discoveredAdapters[identifier] = DiscoveredAdapterCandidate(
            identifier: identifier,
            name: name,
            signalStrength: rssi,
            discoveryOrder: discoveryOrder(for: identifier)
        )

        // The adapter this device last used is unambiguous, so there is nothing
        // left to disambiguate by waiting.
        if identifier == preferredAdapterIdentifier {
            connectToBestCandidate()
            return
        }

        // Otherwise let the discovery window collect the other adapters in
        // range so ranking - not advertisement arrival order - decides which
        // vehicle's adapter this is.
        scheduleAdapterSelection()
    }

    private func handleConnection(to id: UUID) {
        guard id == connectedPeripheral?.identifier,
              connectionState.status == .connecting,
              activeConnectionType == .ble else {
            bluetoothCentral.cancelConnection(id: id)
            return
        }
        clearEndpointState()
        bluetoothCentral.discoverEndpoints(id: id)
    }

    private func handleConnectionFailure(for id: UUID, error: Error?) {
        guard id == connectedPeripheral?.identifier else { return }
        failConnection(with: error ?? OBDError.bluetoothUnavailable(
            String(localized: "Failed to connect to the OBD adapter")
        ))
    }

    private func handleDisconnection(of id: UUID, error: Error?) {
        guard id == connectedPeripheral?.identifier else { return }
        failConnection(with: error ?? OBDError.notConnected)
    }

    /// A per-service characteristic failure is not fatal by itself: the
    /// remaining services may still carry a usable profile, so the error is
    /// only reported if resolution then fails.
    private func handleResolvedCharacteristics(
        for id: UUID,
        candidates: [BLECharacteristicCandidate],
        discoveryError: Error?
    ) {
        guard let peripheral = connectedPeripheral,
              id == peripheral.identifier,
              connectionState.status == .connecting,
              activeConnectionType == .ble else {
            return
        }
        discoveredCandidates = candidates
        characteristicDiscoveryError = discoveryError
        finishCharacteristicDiscovery(on: peripheral)
    }

    private func handleCharacteristicDiscoveryFailure(
        for id: UUID,
        error: Error?
    ) {
        guard id == connectedPeripheral?.identifier,
              connectionState.status == .connecting,
              activeConnectionType == .ble else {
            return
        }
        failConnection(with: error ?? OBDError.adapterNotSupported)
    }

    private func finishCharacteristicDiscovery(on peripheral: BLEPeripheralIdentity) {
        guard resolvedProfile == nil else { return }
        guard let profile = BLEAdapterProfileResolver.resolve(discoveredCandidates) else {
            failConnection(with: characteristicDiscoveryError ?? OBDError.adapterNotSupported)
            return
        }

        let writerKey = BLEEndpoint(
            serviceUUID: profile.serviceUUID,
            characteristicUUID: profile.writeUUID
        )
        let notifierKey = BLEEndpoint(
            serviceUUID: profile.serviceUUID,
            characteristicUUID: profile.notifyUUID
        )
        let discoveredEndpoints = Set(discoveredCandidates.map(BLEEndpoint.init(candidate:)))
        guard discoveredEndpoints.contains(writerKey),
              discoveredEndpoints.contains(notifierKey) else {
            failConnection(with: OBDError.adapterNotSupported)
            return
        }

        resolvedProfile = profile
        writeEndpoint = writerKey
        notifyEndpoint = notifierKey

        // An endpoint that already notifies reports its state without a round
        // trip, so this is also the path that completes an adapter which never
        // stopped notifying.
        bluetoothCentral.enableNotifications(
            id: peripheral.identifier,
            endpoint: notifierKey
        )
    }

    private func handleNotificationState(
        for id: UUID,
        endpoint: BLEEndpoint,
        isNotifying: Bool,
        error: Error?
    ) {
        guard id == connectedPeripheral?.identifier,
              endpoint == notifyEndpoint,
              activeConnectionType == .ble else {
            return
        }
        if let error {
            failConnection(with: error)
            return
        }
        guard isNotifying else {
            failConnection(with: OBDError.bluetoothUnavailable(
                String(
                    localized:
                        "The adapter stopped sending Bluetooth notifications"
                )
            ))
            return
        }
        markTransportReady()
    }

    private func handleReceivedData(_ data: Data) {
        guard connectedPeripheral != nil,
              activeConnectionType == .ble else {
            return
        }
        ingestIncomingData(data)
    }

    private func handleWriteAcknowledgement(
        for id: UUID,
        endpoint: BLEEndpoint,
        error: Error?
    ) {
        guard id == connectedPeripheral?.identifier,
              endpoint == writeEndpoint,
              activeConnectionType == .ble,
              isProcessingCommand,
              awaitingWriteAcknowledgement,
              currentCommandTransportGeneration == transportGeneration else {
            return
        }
        if let error {
            failConnection(with: error)
            return
        }

        awaitingWriteAcknowledgement = false
        sendAvailableWriteChunks()
    }

    private func handleReadyForWriteWithoutResponse() {
        guard connectedPeripheral != nil,
              activeConnectionType == .ble,
              isProcessingCommand,
              resolvedProfile?.writeStrategy == .withoutResponse,
              currentCommandTransportGeneration == transportGeneration else {
            return
        }
        // The readiness event supersedes the polling backstop; a still-full
        // buffer re-arms it.
        cancelWriteFlushRetry()
        sendAvailableWriteChunks()
    }
}

#if canImport(ExternalAccessory)
// MARK: - ExternalAccessory transport (OBDLink MX+ / MFi)

extension OBDConnectionManager: StreamDelegate {
    /// Opens the already-paired OBDLink MX+ route before BLE discovery. MFi
    /// Bluetooth Classic accessories do not advertise through CoreBluetooth,
    /// so being visible in iOS Settings is intentionally handled here.
    private func connectToAttachedAccessoryIfAvailable() -> Bool {
        let compatible = EAAccessoryManager.shared().connectedAccessories
            .filter {
                OBDTransportPolicy.matchingAccessoryProtocol(
                    from: $0.protocolStrings
                ) != nil
            }
            .sorted { $0.connectionID < $1.connectionID }
        guard !OBDTransportPolicy.mfiAccessorySelectionIsAmbiguous(
            compatibleAccessoryCount: compatible.count
        ) else {
            stopScanInternal()
            cancelConnectionTimeout()
            updateState(.init(
                status: .error(
                    String(
                        localized:
                            "Multiple paired OBDLink adapters are available. Disconnect all but the vehicle you want, then retry."
                    )
                )
            ))
            return true
        }
        guard let selected = compatible.first else { return false }
        connectToAccessory(selected)
        return true
    }

    private func connectToAccessory(_ selectedAccessory: EAAccessory) {
        guard let protocolString = OBDTransportPolicy.matchingAccessoryProtocol(
            from: selectedAccessory.protocolStrings
        ) else {
            return
        }

        if accessory?.connectionID == selectedAccessory.connectionID,
           accessorySession != nil,
           activeConnectionType == .mfi {
            // iOS permits one EASession for an accessory/protocol pair. Reuse
            // the opening/open session instead of racing it with a duplicate.
            return
        }

        connectingToRememberedAdapter = false
        cancelReconnect()
        pendingScanRequest = false
        stopScanInternal()
        cancelConnectionTimeout()
        if let peripheral = connectedPeripheral {
            bluetoothCentral.cancelConnection(id: peripheral.identifier)
            connectedPeripheral = nil
        }
        clearEndpointState()
        teardownAccessorySession()
        retireCommandTransport(with: OBDError.notConnected)
        publishTransportUsability(false)

        connectionAttemptID = UUID()
        activeConnectionType = .mfi
        activeAdapterName = selectedAccessory.name.isEmpty
            ? "OBDLink MX+"
            : selectedAccessory.name
        activeSignalStrength = nil
        updateState(.init(
            status: .connecting,
            adapterName: activeAdapterName
        ))

        guard let session = EASession(
            accessory: selectedAccessory,
            forProtocol: protocolString
        ) else {
            failConnection(with: OBDError.bluetoothUnavailable(
                String(localized: "Could not open the paired OBDLink session")
            ))
            return
        }

        accessorySessionGeneration &+= 1
        accessory = selectedAccessory
        accessorySession = session
        openAccessoryStreams.removeAll()

        for stream in [
            session.inputStream as Stream?,
            session.outputStream as Stream?,
        ].compactMap({ $0 }) {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .common)
            stream.open()
        }
        scheduleConnectionTimeout()
    }

    private var hasUsableAccessorySession: Bool {
        guard let input = accessorySession?.inputStream,
              let output = accessorySession?.outputStream else {
            return false
        }
        return OBDTransportPolicy.accessoryStreamsAreUsable(
            input: input.streamStatus,
            output: output.streamStatus
        )
    }

    private var accessoryTransportIsReady: Bool {
        guard let input = accessorySession?.inputStream,
              let output = accessorySession?.outputStream else {
            return false
        }
        return openAccessoryStreams.contains(ObjectIdentifier(input)) &&
            openAccessoryStreams.contains(ObjectIdentifier(output)) &&
            hasUsableAccessorySession
    }

    private func markAccessoryTransportReady() {
        guard activeConnectionType == .mfi,
              accessoryTransportIsReady else {
            return
        }
        cancelConnectionTimeout()
        cancelReconnect()
        publishTransportUsability(true)
        updateState(.init(
            status: .connected,
            adapterName: activeAdapterName ?? "OBDLink MX+"
        ))
    }

    /// Closes both streams and invalidates any callbacks or writes owned by
    /// the retired session. Main-queue confined with the rest of the manager.
    private func teardownAccessorySession() {
        if let session = accessorySession {
            for stream in [
                session.inputStream as Stream?,
                session.outputStream as Stream?,
            ].compactMap({ $0 }) {
                stream.close()
                stream.remove(from: .main, forMode: .common)
                stream.delegate = nil
            }
        }
        accessorySessionGeneration &+= 1
        accessorySession = nil
        accessory = nil
        openAccessoryStreams.removeAll()
        pendingAccessoryWrite = nil
        pendingAccessoryWriteOffset = 0
        pendingAccessoryWriteSessionGeneration = nil
    }

    private func flushPendingAccessoryWrite() {
        guard isProcessingCommand,
              activeConnectionType == .mfi,
              currentCommandTransportGeneration == transportGeneration,
              let data = pendingAccessoryWrite,
              let expectedSessionGeneration =
                pendingAccessoryWriteSessionGeneration,
              expectedSessionGeneration == accessorySessionGeneration,
              let output = accessorySession?.outputStream else {
            return
        }

        guard OBDTransportPolicy.streamCanCarryBytes(output.streamStatus) else {
            failConnection(with: OBDError.notConnected)
            return
        }

        while pendingAccessoryWriteOffset < data.count,
              output.hasSpaceAvailable {
            let remaining = data.count - pendingAccessoryWriteOffset
            let accepted = data.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer
                    .bindMemory(to: UInt8.self)
                    .baseAddress else {
                    return -1
                }
                return output.write(
                    base + pendingAccessoryWriteOffset,
                    maxLength: remaining
                )
            }

            guard accepted >= 0 else {
                failConnection(with: output.streamError ?? OBDError.notConnected)
                return
            }
            // A zero-byte write is backpressure, not success. Wait for the
            // next `.hasSpaceAvailable` event while the write deadline runs.
            guard accepted > 0 else { return }
            guard let nextOffset = OBDTransportPolicy.accessoryWriteProgress(
                totalBytes: data.count,
                currentOffset: pendingAccessoryWriteOffset,
                acceptedBytes: accepted
            ) else {
                failConnection(with: OBDError.invalidResponse)
                return
            }
            pendingAccessoryWriteOffset = nextOffset
        }

        guard OBDTransportPolicy.accessoryWriteCompleted(
            totalBytes: data.count,
            offset: pendingAccessoryWriteOffset
        ) else {
            return
        }
        pendingAccessoryWrite = nil
        pendingAccessoryWriteOffset = 0
        pendingAccessoryWriteSessionGeneration = nil
        markCurrentWritesComplete()
    }

    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard aStream === accessorySession?.inputStream ||
                aStream === accessorySession?.outputStream else {
            return
        }

        switch eventCode {
        case .openCompleted:
            openAccessoryStreams.insert(ObjectIdentifier(aStream))
            markAccessoryTransportReady()

        case .hasBytesAvailable:
            guard aStream === accessorySession?.inputStream,
                  let input = aStream as? InputStream else {
                return
            }
            var buffer = [UInt8](repeating: 0, count: 512)
            while input.hasBytesAvailable {
                let count = input.read(&buffer, maxLength: buffer.count)
                if count < 0 {
                    failConnection(with: input.streamError ?? OBDError.notConnected)
                    return
                }
                guard count > 0 else { break }
                ingestIncomingData(Data(buffer[0..<count]))
            }

        case .hasSpaceAvailable:
            guard aStream === accessorySession?.outputStream else { return }
            flushPendingAccessoryWrite()

        case .errorOccurred, .endEncountered:
            let streamError = aStream.streamError ?? OBDError.notConnected
            failConnection(with: streamError)

        default:
            break
        }
    }

    // Selector-based observers run on whichever thread posts the
    // notification, so both handlers hop to the main queue before touching
    // connection state.
    @objc private func accessoryDidConnect(_ notification: Notification) {
        runOnMain { [weak self] in
            guard let self,
                  self.automaticReconnectEnabled,
                  !self.intentionalDisconnect,
                  self.accessorySession == nil,
                  let attached = notification.userInfo?[EAAccessoryKey]
                    as? EAAccessory,
                  OBDTransportPolicy.matchingAccessoryProtocol(
                      from: attached.protocolStrings
                  ) != nil else {
                return
            }

            switch self.connectionState.status {
            case .disconnected, .scanning, .error:
                // Re-enumerate instead of trusting the notification's
                // accessory: another paired adapter may already be attached.
                _ = self.connectToAttachedAccessoryIfAvailable()
            case .connecting, .connected, .disconnecting:
                break
            }
        }
    }

    @objc private func accessoryDidDisconnect(_ notification: Notification) {
        runOnMain { [weak self] in
            guard let self,
                  let detached = notification.userInfo?[EAAccessoryKey]
                    as? EAAccessory,
                  detached.connectionID == self.accessory?.connectionID else {
                return
            }
            self.failConnection(with: OBDError.notConnected)
        }
    }
}
#endif

public enum OBDError: LocalizedError, Equatable {
    case notConnected
    case bluetoothUnavailable(String)
    case commandFailed(String)
    case commandTimedOut(String)
    case invalidResponse
    case adapterNotSupported

    /// Marks a request the connected vehicle itself does not support (NO DATA,
    /// an unrecognized command, or a negative response with an unsupported-NRC
    /// code). The wrapped error keeps the user-facing message; classification
    /// must key off this case, never off localized display text, so behavior
    /// stays identical in every app locale.
    indirect case unsupportedByVehicle(OBDError)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "No OBD adapter is connected")
        case .bluetoothUnavailable(let message):
            return message
        case .commandFailed(let message):
            return String(
                format: String(localized: "Command failed: %@"),
                locale: .current,
                message
            )
        case .commandTimedOut(let command):
            return String(
                format: String(
                    localized:
                        "The adapter timed out while running %@"
                ),
                locale: .current,
                command
            )
        case .invalidResponse:
            return String(
                localized:
                    "The vehicle returned an invalid or unsupported response"
            )
        case .adapterNotSupported:
            return String(localized: "This OBD adapter is not supported")
        case .unsupportedByVehicle(let base):
            return base.errorDescription
        }
    }
}
