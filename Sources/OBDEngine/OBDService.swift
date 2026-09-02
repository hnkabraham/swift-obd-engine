import Foundation
#if SWIFT_PACKAGE
import OBDModels
#endif

protocol OBDCommandTransport: Sendable {
    var isConnected: Bool { get }
    /// Changes whenever the underlying peripheral/session is replaced.
    var transportGeneration: UInt64 { get }
    func sendCommand(_ command: ELM327Command) async throws -> String
    /// Tears down a transport that failed adapter initialization so stale
    /// streams cannot block the next connection attempt.
    func retireAfterFatalInitializationFailure(
        expectedTransportGeneration: UInt64
    )
    /// A completed ECU probe confirms that reconnect budgeting can restart.
    func confirmVehicleCommunication(
        expectedTransportGeneration: UInt64
    )
}

extension OBDCommandTransport {
    var transportGeneration: UInt64 { 0 }
    func retireAfterFatalInitializationFailure(
        expectedTransportGeneration: UInt64
    ) {}
    func confirmVehicleCommunication(
        expectedTransportGeneration: UInt64
    ) {}
}

extension OBDConnectionManager: OBDCommandTransport {}

/// Serializes every OBDService operation and can reserve the wire for an
/// entire initialization transaction. The lower-level coordinator still owns
/// enhanced-header restoration behavior.
private actor OBDServiceCommandExecutor {
    private let transport: any OBDCommandTransport
    private let coordinator: OBDCommandCoordinator
    private var isReserved = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(transport: any OBDCommandTransport) {
        // Wrapped once, at the point every send is already serialized: single
        // commands, exclusive batches, and the whole-transport operations
        // handed to `performExclusive` (adapter setup and protocol selection —
        // where an interrupted protocol search is most likely) all reach the
        // adapter through this reference, so each gets the single `STOPPED`
        // retry without any of them being able to interleave with it.
        let retryingTransport = OBDStoppedRetryingTransport(base: transport)
        self.transport = retryingTransport
        coordinator = OBDCommandCoordinator(transport: retryingTransport)
    }

    func send(_ command: ELM327Command) async throws -> String {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await coordinator.send(command)
    }

    func sendExclusive(
        preparation: [ELM327Command],
        request: ELM327Command,
        restoration: [ELM327Command]
    ) async throws -> String {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await coordinator.sendExclusive(
            preparation: preparation,
            request: request,
            restoration: restoration
        )
    }

    func performExclusive<Result: Sendable>(
        _ operation: @Sendable
            (any OBDCommandTransport) async throws -> Result
    ) async throws -> Result {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation(transport)
    }

    private func acquire() async {
        if !isReserved {
            isReserved = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isReserved = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Shares one initialization flight across VIN verification, scans, and UI
/// actions that arrive concurrently.
private actor OBDInitializationFlight {
    struct Key: Hashable, Sendable {
        let vehicleID: UUID?
        let forceAutomaticProtocol: Bool
        let useWarmStart: Bool
        let transportGeneration: UInt64
        let vehicleSelectionGeneration: UInt64
    }

    private struct ActiveFlight {
        let id: UUID
        let key: Key
        let task: Task<Void, Error>
    }

    private var active: ActiveFlight?

    func run(
        key: Key,
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        while true {
            if let active {
                if active.key == key {
                    try await active.task.value
                    return
                }

                // A request for another vehicle, a forced automatic retry, or
                // a repair must never inherit the prior flight's outcome.
                active.task.cancel()
                _ = try? await active.task.value
                if self.active?.id == active.id {
                    self.active = nil
                }
                continue
            }

            let id = UUID()
            let task = Task(operation: operation)
            active = ActiveFlight(id: id, key: key, task: task)
            do {
                try await task.value
                if active?.id == id {
                    active = nil
                }
                return
            } catch {
                if active?.id == id {
                    active = nil
                }
                throw error
            }
        }
    }

    func cancel() {
        active?.task.cancel()
    }
}

/// High-level OBD-II operations used by the app.
///
/// The service keeps hardware concerns in `OBDConnectionManager`, validates
/// adapter responses before parsing them, and offers a deterministic demo mode
/// so every app screen can be exercised without a vehicle nearby.
// `@unchecked` is load-bearing: every mutable stored property below is
// guarded by `stateLock`, which the compiler cannot verify for us.
public final class OBDService: @unchecked Sendable {
    public let connectionManager: OBDConnectionManager

    /// Callback sinks. Assignment races main-queue invocations, so both the
    /// stored closures and their reads are guarded by `stateLock`; handlers
    /// are always invoked after the lock is released.
    public var onConnectionStateChange: ((ConnectionState) -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _onConnectionStateChange
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _onConnectionStateChange = newValue
        }
    }
    public var onVehicleLinkStateChange:
        ((OBDVehicleLinkState) -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _onVehicleLinkStateChange
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _onVehicleLinkStateChange = newValue
        }
    }

    // MARK: Synchronized mutable state
    //
    // These are written from two places that are not the same thread: the
    // CoreBluetooth delegate callbacks arrive on the central manager's queue,
    // while `initialize()` and the scan tasks run on the cooperative pool. A
    // recursive lock is used because several accessors read one another.
    private let stateLock = NSRecursiveLock()
    private var _onConnectionStateChange: ((ConnectionState) -> Void)?
    private var _onVehicleLinkStateChange: ((OBDVehicleLinkState) -> Void)?
    private var _isDemoMode = false
    private var _selectedVehicle: Vehicle?
    private var _detectedProtocolIdentifier: String?
    private var _vehicleLinkState: OBDVehicleLinkState = .disconnected
    private var _initializedVehicleID: UUID?
    private var _supportedMode01PIDs: Set<UInt8> = []
    private var _protocolProbeLatency: TimeInterval?
    private var _vehicleSelectionGeneration: UInt64 = 0

    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    public private(set) var isDemoMode: Bool {
        get { withStateLock { _isDemoMode } }
        set { withStateLock { _isDemoMode = newValue } }
    }
    public private(set) var selectedVehicle: Vehicle? {
        get { withStateLock { _selectedVehicle } }
        set {
            withStateLock {
                if _selectedVehicle?.id != newValue?.id {
                    _vehicleSelectionGeneration &+= 1
                }
                _selectedVehicle = newValue
            }
        }
    }
    /// The normalized ELM protocol identifier reported by `ATDPN` after a
    /// successful vehicle probe (for example `A6` for auto-selected CAN).
    public private(set) var detectedProtocolIdentifier: String? {
        get { withStateLock { _detectedProtocolIdentifier } }
        set { withStateLock { _detectedProtocolIdentifier = newValue } }
    }
    public private(set) var vehicleLinkState: OBDVehicleLinkState {
        get { withStateLock { _vehicleLinkState } }
        set { withStateLock { _vehicleLinkState = newValue } }
    }
    public var connectionState: ConnectionState {
        demoConnectionState ?? connectionManager.connectionState
    }

    private let parser: OBDParser
    private let commandTransport: any OBDCommandTransport
    private let commandCoordinator: OBDServiceCommandExecutor
    private let initializationFlight = OBDInitializationFlight()
    private let capabilityCache: any OBDVehicleCapabilityStoring
    private let now: @Sendable () -> Date
    private var _isInitialized = false
    private var _demoDTCsWereCleared = false
    private var _demoConnectionState: ConnectionState?

    private var isInitialized: Bool {
        get { withStateLock { _isInitialized } }
        set { withStateLock { _isInitialized = newValue } }
    }
    private var demoDTCsWereCleared: Bool {
        get { withStateLock { _demoDTCsWereCleared } }
        set { withStateLock { _demoDTCsWereCleared = newValue } }
    }
    private var demoConnectionState: ConnectionState? {
        get { withStateLock { _demoConnectionState } }
        set { withStateLock { _demoConnectionState = newValue } }
    }
    private var initializedVehicleID: UUID? {
        get { withStateLock { _initializedVehicleID } }
        set { withStateLock { _initializedVehicleID = newValue } }
    }
    private var supportedMode01PIDs: Set<UInt8> {
        get { withStateLock { _supportedMode01PIDs } }
        set { withStateLock { _supportedMode01PIDs = newValue } }
    }
    private var protocolProbeLatency: TimeInterval? {
        get { withStateLock { _protocolProbeLatency } }
        set { withStateLock { _protocolProbeLatency = newValue } }
    }
    private var vehicleSelectionGeneration: UInt64 {
        withStateLock { _vehicleSelectionGeneration }
    }

    public init(
        connectionManager: OBDConnectionManager = OBDConnectionManager(),
        parser: OBDParser = OBDParser()
    ) {
        self.connectionManager = connectionManager
        self.parser = parser
        self.commandTransport = connectionManager
        self.commandCoordinator = OBDServiceCommandExecutor(
            transport: connectionManager
        )
        self.capabilityCache = OBDVehicleCapabilityCache()
        self.now = { Date() }
        connectionManager.delegate = self
    }

    init(
        connectionManager: OBDConnectionManager = OBDConnectionManager(),
        parser: OBDParser = OBDParser(),
        commandTransport: any OBDCommandTransport,
        capabilityCache: any OBDVehicleCapabilityStoring =
            OBDVehicleCapabilityCache(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.connectionManager = connectionManager
        self.parser = parser
        self.commandTransport = commandTransport
        self.commandCoordinator = OBDServiceCommandExecutor(
            transport: commandTransport
        )
        self.capabilityCache = capabilityCache
        self.now = now
        connectionManager.delegate = self
    }

    // MARK: - Connection

    public func connect() {
        Task { await initializationFlight.cancel() }
        connectionManager.delegate = self
        demoConnectionState = nil
        isDemoMode = false
        demoDTCsWereCleared = false
        resetVehicleLink()
        updateVehicleLinkState(.disconnected)
        connectionManager.connect()
    }

    /// Reconciles the published state with the live Apple transport whenever
    /// the app returns to the foreground. This repairs MFi streams or BLE
    /// notification sessions that iOS invalidated while the app was suspended.
    public func reconcileConnectionOnForeground() {
        guard !isDemoMode else { return }
        invalidateVehicleReadinessForForegroundReconciliation()
        connectionManager.delegate = self
        connectionManager.reconcileConnectionOnForeground()
    }

    public func connectDemo(vehicle: Vehicle) {
        // Ignore late CoreBluetooth state callbacks while the simulator owns
        // the connection state (important on Macs without BLE support).
        connectionManager.delegate = nil
        connectionManager.disconnect()
        isDemoMode = true
        selectedVehicle = vehicle
        demoDTCsWereCleared = false
        demoConnectionState = ConnectionState(
            status: .connected,
            adapterName: "OBDEngine Demo Adapter",
            adapterFirmware: "Simulator 1.0",
            signalStrength: -42
        )
        publishDemoVehicleSession()
        onConnectionStateChange?(connectionState)
    }

    public func disconnect() {
        Task { await initializationFlight.cancel() }
        let wasDemo = isDemoMode
        isDemoMode = false
        selectedVehicle = nil
        demoDTCsWereCleared = false
        resetVehicleLink()
        updateVehicleLinkState(.disconnected)

        if wasDemo {
            demoConnectionState = .disconnected
            onConnectionStateChange?(.disconnected)
        } else {
            connectionManager.disconnect()
        }
    }

    /// Clears vehicle attribution while preserving a live adapter transport.
    ///
    /// This is used when the selected garage vehicle is deleted. Keeping the
    /// prior ECU-ready state after that point could allow a later action to use
    /// evidence or capabilities learned for a vehicle that is no longer
    /// selected.
    public func deselectVehicle() {
        Task { await initializationFlight.cancel() }
        selectedVehicle = nil
        resetVehicleLink()
        updateVehicleLinkState(
            (isDemoMode || commandTransport.isConnected)
                ? .adapterConnected
                : .disconnected
        )
    }

    /// Returns whether the current live ECU session was initialized for this
    /// exact saved vehicle, rather than merely whether an adapter is attached.
    public func isVehicleReady(for vehicle: Vehicle) -> Bool {
        let matchesReadySession = withStateLock {
            guard _isInitialized,
                  _initializedVehicleID == vehicle.id else {
                return false
            }
            if case .vehicleReady = _vehicleLinkState {
                return true
            }
            return false
        }
        return matchesReadySession &&
            (isDemoMode || commandTransport.isConnected)
    }

    // MARK: - Initialization

    public func initialize() async throws {
        try await initialize(
            vehicleID: selectedVehicle?.id,
            forceAutomaticProtocol: false,
            useWarmStart: false
        )
    }

    public func initialize(
        for vehicle: Vehicle,
        forceAutomaticProtocol: Bool = false
    ) async throws {
        selectedVehicle = vehicle
        try await initialize(
            vehicleID: vehicle.id,
            forceAutomaticProtocol: forceAutomaticProtocol,
            useWarmStart: false
        )
    }

    /// Discards any fast-path protocol lock and performs one exclusive,
    /// 30-second automatic protocol search.
    public func retryAutomaticProtocol(
        for vehicle: Vehicle? = nil
    ) async throws {
        // The simulator has no protocol to search for, and re-pointing it at
        // another vehicle would attribute synthetic readiness to a real car.
        if isDemoMode {
            publishDemoVehicleSession()
            return
        }
        if let vehicle {
            selectedVehicle = vehicle
        }
        isInitialized = false
        initializedVehicleID = nil
        detectedProtocolIdentifier = nil
        supportedMode01PIDs = []
        protocolProbeLatency = nil
        try await initialize(
            vehicleID: vehicle?.id ?? selectedVehicle?.id,
            forceAutomaticProtocol: true,
            useWarmStart: false
        )
    }

    /// Performs a non-destructive adapter warm start, reapplies safe settings,
    /// and reruns automatic vehicle discovery.
    public func softRepair(
        for vehicle: Vehicle? = nil
    ) async throws {
        // The simulator has no adapter to warm start, so clearing readiness
        // here would strand the link in `.repairing`: the initialization that
        // is supposed to republish a terminal state never runs in demo mode.
        if isDemoMode {
            publishDemoVehicleSession()
            return
        }
        if let vehicle {
            selectedVehicle = vehicle
        }
        isInitialized = false
        initializedVehicleID = nil
        detectedProtocolIdentifier = nil
        supportedMode01PIDs = []
        protocolProbeLatency = nil
        updateVehicleLinkState(.repairing)
        try await initialize(
            vehicleID: vehicle?.id ?? selectedVehicle?.id,
            forceAutomaticProtocol: true,
            useWarmStart: true
        )
    }

    /// Returns the latest persisted protocol/PID discovery for one stable
    /// vehicle identifier.
    public func vehicleCapabilities(
        for vehicleID: UUID
    ) -> OBDVehicleCapabilities? {
        capabilityCache.capabilities(for: vehicleID)
    }

    private struct InitializationOutcome: Sendable {
        let protocolIdentifier: String
        let supportedPIDs: Set<UInt8>
        let probeLatency: TimeInterval
    }

    private func initialize(
        vehicleID: UUID?,
        forceAutomaticProtocol: Bool,
        useWarmStart: Bool
    ) async throws {
        if isDemoMode {
            isInitialized = true
            return
        }
        guard commandTransport.isConnected else { throw OBDError.notConnected }
        if isInitialized, !forceAutomaticProtocol {
            if initializedVehicleID == vehicleID || vehicleID == nil {
                return
            }
        }

        let selectionGeneration = vehicleSelectionGeneration
        let cached = forceAutomaticProtocol
            ? nil
            : vehicleID.flatMap {
                capabilityCache.capabilities(for: $0)
            }
        let generation = commandTransport.transportGeneration
        let flightKey = OBDInitializationFlight.Key(
            vehicleID: vehicleID,
            forceAutomaticProtocol: forceAutomaticProtocol,
            useWarmStart: useWarmStart,
            transportGeneration: generation,
            vehicleSelectionGeneration: selectionGeneration
        )

        try await initializationFlight.run(
            key: flightKey
        ) { [weak self] in
            guard let self else { throw CancellationError() }
            let outcome: InitializationOutcome
            do {
                outcome = try await self.commandCoordinator
                    .performExclusive { [weak self] transport in
                        guard let self else {
                            throw CancellationError()
                        }
                        return try await self.performInitialization(
                            transport: transport,
                            generation: generation,
                            cached: cached,
                            forceAutomaticProtocol:
                                forceAutomaticProtocol,
                            useWarmStart: useWarmStart
                        )
                    }
            } catch {
                // A failure is only this flight's to publish while the flight
                // still owns the session. `connectDemo(vehicle:)` installs a
                // ready session without running a flight, so a late failure
                // must be discarded exactly like a late success.
                let ownsSession = self.withStateLock {
                    guard !self._isDemoMode,
                          self._vehicleSelectionGeneration ==
                            selectionGeneration else {
                        return false
                    }
                    if let vehicleID,
                       self._selectedVehicle?.id != vehicleID {
                        return false
                    }
                    self._isInitialized = false
                    self._detectedProtocolIdentifier = nil
                    self._initializedVehicleID = nil
                    self._supportedMode01PIDs = []
                    self._protocolProbeLatency = nil
                    return true
                }
                guard ownsSession else {
                    throw CancellationError()
                }
                if error is CancellationError {
                    self.updateVehicleLinkState(
                        self.commandTransport.isConnected
                            ? .adapterConnected
                            : .disconnected
                    )
                } else {
                    self.updateVehicleLinkState(
                        .error(
                            message: error.localizedDescription,
                            adapterConnected:
                                self.commandTransport.isConnected
                        )
                    )
                }
                throw error
            }

            let readyState = OBDVehicleLinkState.vehicleReady(
                protocolIdentifier: outcome.protocolIdentifier
            )
            let didCommit = self.withStateLock {
                guard !self._isDemoMode,
                      self._vehicleSelectionGeneration ==
                        selectionGeneration else {
                    return false
                }
                if let vehicleID,
                   self._selectedVehicle?.id != vehicleID {
                    return false
                }
                self._detectedProtocolIdentifier =
                    outcome.protocolIdentifier
                self._supportedMode01PIDs = outcome.supportedPIDs
                self._protocolProbeLatency = outcome.probeLatency
                self._initializedVehicleID = vehicleID
                self._isInitialized = true
                self._vehicleLinkState = readyState
                return true
            }
            guard didCommit else {
                throw CancellationError()
            }
            self.commandTransport.confirmVehicleCommunication(
                expectedTransportGeneration: generation
            )
            if let vehicleID {
                self.capabilityCache.save(
                    OBDVehicleCapabilities(
                        vehicleID: vehicleID,
                        protocolIdentifier:
                            outcome.protocolIdentifier,
                        supportedMode01PIDs:
                            outcome.supportedPIDs,
                        probeLatency: outcome.probeLatency,
                        updatedAt: self.now()
                    )
                )
            }
            self.onVehicleLinkStateChange?(readyState)
        }
    }

    private func performInitialization(
        transport: any OBDCommandTransport,
        generation: UInt64,
        cached: OBDVehicleCapabilities?,
        forceAutomaticProtocol: Bool,
        useWarmStart: Bool
    ) async throws -> InitializationOutcome {
        try ensureCurrentTransport(
            transport,
            generation: generation
        )
        if !useWarmStart {
            updateVehicleLinkState(.initializingAdapter)
        }

        let setupCommands: [ELM327Command]
        if useWarmStart {
            setupCommands = [.warmStart] +
                Array(ELM327Command.adapterSetupSequence.dropFirst())
        } else {
            setupCommands = ELM327Command.adapterSetupSequence
        }

        do {
            for command in setupCommands {
                try ensureCurrentTransport(
                    transport,
                    generation: generation
                )
                let response = try await transport.sendCommand(command)
                try ensureCurrentTransport(
                    transport,
                    generation: generation
                )
                try validateInitializationControlResponse(
                    response,
                    command: command
                )
            }
        } catch {
            if !(error is CancellationError) {
                transport.retireAfterFatalInitializationFailure(
                    expectedTransportGeneration: generation
                )
            }
            throw error
        }

        updateVehicleLinkState(.searchingVehicleProtocol)

        var probeResponse: String?
        var probeLatency: TimeInterval = 0
        if !forceAutomaticProtocol,
           let cached,
           let savedProtocolCommand = ELM327Command.setProtocol(
               cached.protocolIdentifier
           ) {
            do {
                let selectionResponse = try await transport.sendCommand(
                    savedProtocolCommand
                )
                try ensureCurrentTransport(
                    transport,
                    generation: generation
                )
                try validateInitializationControlResponse(
                    selectionResponse,
                    command: savedProtocolCommand
                )
                let startedAt = now()
                let response = try await transport.sendCommand(
                    .savedProtocolProbe
                )
                probeLatency = max(
                    0,
                    now().timeIntervalSince(startedAt)
                )
                try ensureCurrentTransport(
                    transport,
                    generation: generation
                )
                try validateProtocolProbe(
                    response,
                    requestedBasePID: 0x00,
                    command: .savedProtocolProbe
                )
                probeResponse = response
            } catch {
                if error is CancellationError {
                    throw error
                }
                try ensureCurrentTransport(
                    transport,
                    generation: generation
                )
                // A saved protocol is an optimization, never authority. Any
                // stale lock immediately falls through to ATSP0.
                probeResponse = nil
            }
        }

        if probeResponse == nil {
            do {
                let automaticResponse = try await transport.sendCommand(
                    .setProtocolAuto
                )
                try ensureCurrentTransport(
                    transport,
                    generation: generation
                )
                try validateInitializationControlResponse(
                    automaticResponse,
                    command: .setProtocolAuto
                )
            } catch {
                if !(error is CancellationError) {
                    transport.retireAfterFatalInitializationFailure(
                        expectedTransportGeneration: generation
                    )
                }
                throw error
            }

            let startedAt = now()
            let response = try await transport.sendCommand(.protocolProbe)
            probeLatency = max(
                0,
                now().timeIntervalSince(startedAt)
            )
            try ensureCurrentTransport(
                transport,
                generation: generation
            )
            try validateProtocolProbe(
                response,
                requestedBasePID: 0x00,
                command: .protocolProbe
            )
            probeResponse = response
        }

        var supportedPIDs = Self.supportedMode01PIDs(
            from: probeResponse ?? "",
            requestedBasePID: 0x00,
            parser: parser
        )
        // Every page is discovered even without a selected vehicle: the
        // result gates `readPID` for this session regardless of whether it
        // is persisted, and stopping at page 0 would reject every PID above
        // 0x20 as unsupported.
        var basePID: UInt8 = 0x00
        while basePID < 0xE0 {
            let nextBase = basePID &+ 0x20
            guard supportedPIDs.contains(nextBase) else { break }
            let command = ELM327Command.readSupportedPIDs(
                range: Int(nextBase)
            )
            do {
                let response = try await transport.sendCommand(command)
                try ensureCurrentTransport(
                    transport,
                    generation: generation
                )
                try validateProtocolProbe(
                    response,
                    requestedBasePID: nextBase,
                    command: command
                )
                supportedPIDs.formUnion(
                    Self.supportedMode01PIDs(
                        from: response,
                        requestedBasePID: nextBase,
                        parser: parser
                    )
                )
                basePID = nextBase
            } catch {
                if error is CancellationError {
                    throw error
                }
                try ensureCurrentTransport(
                    transport,
                    generation: generation
                )
                // Later capability pages are optional. Keep the positively
                // confirmed lower pages and stop discovery.
                break
            }
        }

        let protocolIdentifier: String
        do {
            let protocolResponse = try await transport.sendCommand(
                .protocolName
            )
            try ensureCurrentTransport(
                transport,
                generation: generation
            )
            try validateAdapterResponse(
                protocolResponse,
                command: ELM327Command.protocolName.raw,
                allowNoData: false
            )
            guard let value = Self.protocolIdentifier(
                from: protocolResponse
            ) else {
                throw OBDError.invalidResponse
            }
            protocolIdentifier = value
        } catch {
            if !(error is CancellationError) {
                transport.retireAfterFatalInitializationFailure(
                    expectedTransportGeneration: generation
                )
            }
            throw error
        }

        return InitializationOutcome(
            protocolIdentifier: protocolIdentifier,
            supportedPIDs: supportedPIDs,
            probeLatency: probeLatency
        )
    }

    private func ensureCurrentTransport(
        _ transport: any OBDCommandTransport,
        generation: UInt64
    ) throws {
        try Task.checkCancellation()
        guard transport.transportGeneration == generation else {
            throw CancellationError()
        }
        guard transport.isConnected else {
            throw OBDError.notConnected
        }
    }

    private func validateInitializationControlResponse(
        _ response: String,
        command: ELM327Command
    ) throws {
        try validateAdapterResponse(
            response,
            command: command.raw,
            allowNoData: false
        )
        let lines = response
            .uppercased()
            .replacingOccurrences(of: ">", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter {
                !$0.isEmpty && $0 != command.raw
            }
        if lines.contains("OK") {
            return
        }

        if command == .reset || command == .warmStart {
            let bannerTokens = [
                "ELM", "OBDLINK", "STN", "VGATE", "V-GATE", "VLINK",
            ]
            if lines.contains(where: { line in
                bannerTokens.contains(where: line.contains)
            }) {
                return
            }
        }
        throw OBDError.commandFailed(
            String(
                format: String(
                    localized: "Adapter did not acknowledge %@"
                ),
                locale: .current,
                command.raw
            )
        )
    }

    private func validateProtocolProbe(
        _ response: String,
        requestedBasePID: UInt8,
        command: ELM327Command
    ) throws {
        try validateAdapterResponse(
            response,
            command: command.raw,
            allowNoData: false
        )
        guard parser.responsePayloads(from: response).contains(where: {
            guard let serviceIndex = $0.firstIndex(of: 0x41) else {
                return false
            }
            return $0.indices.contains(serviceIndex + 5) &&
                $0[serviceIndex + 1] == requestedBasePID
        }) else {
            throw OBDError.invalidResponse
        }
    }

    private static func supportedMode01PIDs(
        from response: String,
        requestedBasePID: UInt8,
        parser: OBDParser
    ) -> Set<UInt8> {
        var supported = Set<UInt8>()
        for payload in parser.responsePayloads(from: response) {
            guard let serviceIndex = payload.firstIndex(of: 0x41),
                  payload.indices.contains(serviceIndex + 5),
                  payload[serviceIndex + 1] == requestedBasePID else {
                continue
            }
            let bitmap = payload[(serviceIndex + 2)...(serviceIndex + 5)]
                .reduce(UInt32(0)) {
                    ($0 << 8) | UInt32($1)
                }
            for offset in 1...32 where
                bitmap & (UInt32(1) << UInt32(32 - offset)) != 0 {
                let value = Int(requestedBasePID) + offset
                if let pid = UInt8(exactly: value) {
                    supported.insert(pid)
                }
            }
        }
        return supported
    }

    // MARK: - DTC operations

    public func readStoredDTCs() async throws -> [DiagnosticTroubleCode] {
        if isDemoMode {
            return demoDTCs(for: selectedVehicle, status: .confirmed)
        }
        return try await readDTCs(
            command: .readStoredDTCs(),
            status: .confirmed,
            fallbackSeverity: .medium
        )
    }

    public func readPendingDTCs() async throws -> [DiagnosticTroubleCode] {
        if isDemoMode {
            return demoDTCs(for: selectedVehicle, status: .pending)
        }
        return try await readDTCs(
            command: .readPendingDTCs(),
            status: .pending,
            fallbackSeverity: .low
        )
    }

    public func readPermanentDTCs() async throws -> [DiagnosticTroubleCode] {
        if isDemoMode {
            return []
        }
        return try await readDTCs(
            command: .readPermanentDTCs(),
            status: .permanent,
            fallbackSeverity: .medium
        )
    }

    public func clearDTCs() async throws {
        guard let vehicle = selectedVehicle else {
            throw OBDError.commandFailed(
                String(
                    localized:
                        "Select a vehicle before clearing diagnostic codes"
                )
            )
        }
        try await clearDTCs(for: vehicle)
    }

    /// Sends destructive SAE Mode 04 only after this exact saved vehicle has
    /// a live ECU-ready session and its VIN has been freshly re-read.
    ///
    /// Mode 09 VIN support is optional for read-only scans, but clearing codes
    /// erases diagnostic evidence and emissions readiness. The destructive
    /// operation therefore fails closed when either side lacks a valid VIN.
    public func clearDTCs(for vehicle: Vehicle) async throws {
        if isDemoMode {
            guard isVehicleReady(for: vehicle) else {
                throw OBDError.commandFailed(
                    String(
                        localized:
                            "The selected vehicle does not have a live ECU session"
                    )
                )
            }
            demoDTCsWereCleared = true
            return
        }

        try await initialize(for: vehicle)
        guard isVehicleReady(for: vehicle) else {
            throw OBDError.commandFailed(
                String(
                    localized:
                        "The selected vehicle does not have a live ECU session"
                )
            )
        }

        let generation = commandTransport.transportGeneration
        try await commandCoordinator.performExclusive {
            [weak self] transport in
            guard let self else { throw CancellationError() }
            try self.ensureCurrentTransport(
                transport,
                generation: generation
            )
            try await self.verifyFreshVehicleIdentity(
                for: vehicle,
                transport: transport,
                generation: generation,
                action: String(localized: "Clearing diagnostic codes")
            )
            try self.ensureCurrentTransport(
                transport,
                generation: generation
            )
            guard self.isVehicleReady(for: vehicle),
                  self.selectedVehicle?.id == vehicle.id else {
                throw OBDError.commandFailed(
                    String(
                        localized:
                            "The selected vehicle changed before codes could be cleared"
                    )
                )
            }

            let command = ELM327Command.clearDTCs()
            let response = try await transport.sendCommand(command)
            try self.ensureCurrentTransport(
                transport,
                generation: generation
            )
            try self.validateAdapterResponse(
                response,
                command: command.raw,
                allowNoData: false
            )
            guard self.parser.responsePayloads(from: response)
                .contains(where: { $0.contains(0x44) }) else {
                throw OBDError.invalidResponse
            }
        }
    }

    private func readDTCs(
        command: ELM327Command,
        status: DiagnosticTroubleCode.CodeStatus,
        fallbackSeverity: DiagnosticTroubleCode.CodeSeverity
    ) async throws -> [DiagnosticTroubleCode] {
        let response = try await commandCoordinator.send(command)
        if isNoDataResponse(response) { return [] }
        try validateAdapterResponse(response, command: command.raw)
        let expectedService: UInt8
        switch status {
        case .confirmed: expectedService = 0x43
        case .pending: expectedService = 0x47
        case .permanent: expectedService = 0x4A
        case .historical: expectedService = 0x43
        }
        // A conformant ISO 15765-4 reply is `43 <count> <count × 2 bytes>`,
        // which is always an even number of bytes; the previous odd-length
        // (legacy-only) parity gate rejected every CAN vehicle, including the
        // two-byte `43 00` that a healthy car returns for "no codes".
        guard parser.responsePayloads(from: response).contains(where: {
            $0.first == expectedService && $0.count >= 2
        }) else {
            throw OBDError.invalidResponse
        }
        return parser.parseDTCs(from: response).map {
            makeDTC(code: $0, status: status, fallbackSeverity: fallbackSeverity)
        }
    }

    private func makeDTC(
        code: String,
        status: DiagnosticTroubleCode.CodeStatus,
        fallbackSeverity: DiagnosticTroubleCode.CodeSeverity
    ) -> DiagnosticTroubleCode {
        let info = KnownDTCs.lookup(code)
        let system: DiagnosticTroubleCode.VehicleSystem
        switch code.first {
        case "C": system = .chassis
        case "B": system = .body
        case "U": system = .network
        default: system = .powertrain
        }

        return DiagnosticTroubleCode(
            code: code,
            description: info?.description ?? "Unrecognized diagnostic code \(code)",
            system: system,
            severity: info?.severity ?? fallbackSeverity,
            status: status,
            // A code absent from the table has not been assessed. The fallback
            // severity is a placeholder for ordering, not a judgement, and the
            // UI must not present it as one.
            isSeverityClassified: info != nil
        )
    }

    // MARK: - PID operations

    public func readPID(_ definition: PIDDefinition) async throws -> PIDValue {
        if isDemoMode {
            return demoPIDValue(for: definition, vehicle: selectedVehicle)
        }
        if isInitialized,
           let pid = UInt8(definition.hexCode, radix: 16),
           !supportedMode01PIDs.contains(pid) {
            throw OBDError.unsupportedByVehicle(.commandFailed(
                String(
                    format: String(
                        localized:
                            "Mode 01 PID %@ is not supported by the connected vehicle"
                    ),
                    locale: .current,
                    definition.hexCode
                )
            ))
        }

        let command = ELM327Command.readPID(definition.hexCode)
        let response = try await commandCoordinator.send(command)
        try validateAdapterResponse(response, command: command.raw)
        guard let value = parser.parsePIDResponse(response, definition: definition) else {
            throw OBDError.invalidResponse
        }
        return value
    }

    public func readMultiplePIDs(_ definitions: [PIDDefinition]) async throws -> [PIDValue] {
        var results: [PIDValue] = []
        results.reserveCapacity(definitions.count)

        for definition in definitions {
            try Task.checkCancellation()
            if isInitialized,
               let pid = UInt8(definition.hexCode, radix: 16),
               !supportedMode01PIDs.contains(pid) {
                continue
            }
            do {
                results.append(try await readPID(definition))
            } catch {
                if isExplicitlyUnsupported(error) { continue }
                throw error
            }
        }
        return results
    }

    /// Executes a validated, read-only custom PID definition.
    ///
    /// Imported definitions cannot represent clear/programming services and
    /// their bounded formula is evaluated only after the response service,
    /// parameter bytes, and exact payload length have been verified. The
    /// reading carries its range status so an excursion reaches the display
    /// instead of being flattened into a bare number.
    public func readCustomPID(
        _ definition: CustomPIDDefinition
    ) async throws -> CustomPIDReading {
        if isDemoMode {
            let seed = stableHash(
                "\(definition.request.key)|\(definition.name)"
            )
            let fraction = Double(seed % 10_000) / 10_000
            let range = definition.valueRange.maximum -
                definition.valueRange.minimum
            let simulated = definition.valueRange.minimum + (range * fraction)
            return CustomPIDReading(
                value: simulated,
                rangeStatus: definition.valueRange.status(for: simulated)
            )
        }

        let request = definition.request
        let commandTokens = [request.service] +
            stride(from: 0, to: request.parameter.count, by: 2).map {
                let start = request.parameter.index(
                    request.parameter.startIndex,
                    offsetBy: $0
                )
                let end = request.parameter.index(
                    start,
                    offsetBy: 2
                )
                return String(request.parameter[start..<end])
            }
        let command = ELM327Command(
            raw: commandTokens.joined(separator: " "),
            description: "Read validated custom PID \(definition.name)",
            timeout: 3
        )
        let response = try await commandCoordinator.send(command)
        try validateAdapterResponse(response, command: command.raw)

        guard let service = UInt8(request.service, radix: 16) else {
            throw OBDError.invalidResponse
        }
        let positiveService = service &+ 0x40
        let parameterBytes = stride(
            from: 0,
            to: request.parameter.count,
            by: 2
        ).compactMap { offset -> UInt8? in
            let start = request.parameter.index(
                request.parameter.startIndex,
                offsetBy: offset
            )
            let end = request.parameter.index(start, offsetBy: 2)
            return UInt8(request.parameter[start..<end], radix: 16)
        }
        guard parameterBytes.count * 2 == request.parameter.count else {
            throw OBDError.invalidResponse
        }

        let matchingValues = parser.responsePayloads(from: response)
            .compactMap { payload -> [UInt8]? in
                let prefix = [positiveService] + parameterBytes
                guard payload.count == prefix.count +
                        definition.responseByteCount,
                      Array(payload.prefix(prefix.count)) == prefix else {
                    return nil
                }
                return Array(payload.dropFirst(prefix.count))
            }
        guard let responseBytes = matchingValues.first else {
            throw OBDError.invalidResponse
        }
        // A functional Mode 01 request can receive replies from more than one
        // ECU. Never display an arbitrary module's value when those replies
        // disagree; manufacturer-specific routing belongs to a physically
        // addressed enhanced profile.
        guard matchingValues.dropFirst().allSatisfy({
            $0 == responseBytes
        }) else {
            throw OBDError.invalidResponse
        }
        return try definition.reading(from: responseBytes)
    }

    // MARK: - Vehicle information

    public func readVIN() async throws -> String? {
        if isDemoMode {
            return selectedVehicle?.vin
        }

        let command = ELM327Command.readVIN()
        let response = try await commandCoordinator.send(command)
        if isNoDataResponse(response) { return nil }
        try validateAdapterResponse(response, command: command.raw)
        return parser.parseVIN(from: response)
    }

    public func readECUName() async throws -> String {
        if isDemoMode { return "OBDEngine SIMULATED ECU" }

        let command = ELM327Command.readECUName()
        let response = try await commandCoordinator.send(command)
        try validateAdapterResponse(response, command: command.raw)

        let ascii = parser.responsePayloads(from: response)
            .flatMap { $0 }
            .filter { $0 >= 0x20 && $0 <= 0x7E }
        let decoded = String(bytes: ascii, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded?.isEmpty == false ? decoded! : cleanedAdapterText(response)
    }

    public func readVoltage() async throws -> Double {
        if isDemoMode { return 12.6 }

        let response = try await commandCoordinator.send(.readVoltage)
        try validateAdapterResponse(response, command: ELM327Command.readVoltage.raw)
        let candidates = response
            .replacingOccurrences(of: "V", with: " ", options: .caseInsensitive)
            .components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
            .compactMap(Double.init)
        guard let voltage = candidates.first(where: { (5...30).contains($0) }) else {
            throw OBDError.invalidResponse
        }
        return voltage
    }

    // MARK: - Emissions and freeze frame

    public func readReadinessMonitors() async throws -> [ReadinessMonitor] {
        if isDemoMode {
            return demoReadiness(for: selectedVehicle)
        }

        let command = ELM327Command.readPID("01")
        let response = try await commandCoordinator.send(command)
        try validateAdapterResponse(response, command: command.raw)
        guard let monitors = parser.parseReadinessMonitors(from: response) else {
            throw OBDError.invalidResponse
        }
        return monitors
    }

    /// Reads one Mode 02 freeze-frame record and attributes it using PID 02.
    ///
    /// A freeze-frame number identifies a record, not a requested DTC. When the
    /// ECU does not implement PID 02, any returned PID values are kept under an
    /// explicit unattributed label rather than copied onto every scan code.
    public func readFreezeFrame(frameNumber: UInt8 = 0) async throws -> FreezeFrameData? {
        let definitions: [PIDDefinition] = [
            StandardPIDLibrary.calculatedLoad,
            StandardPIDLibrary.coolantTemp,
            StandardPIDLibrary.engineRPM,
            StandardPIDLibrary.vehicleSpeed,
            StandardPIDLibrary.fuelTrimShortTerm1,
            StandardPIDLibrary.fuelTrimLongTerm1,
        ]

        if isDemoMode {
            // Demo vehicles present the single SAE-required record.
            guard frameNumber == 0 else { return nil }
            let actualCode = demoDTCs(
                for: selectedVehicle,
                status: .confirmed
            ).first?.code ?? FreezeFrameData.unattributedDTCCode
            return FreezeFrameData(
                pids: definitions.map { demoPIDValue(for: $0, vehicle: selectedVehicle) },
                dtcCode: actualCode,
                frameNumber: 0
            )
        }

        let attributedCode = try await readFreezeFrameDTC(
            frameNumber: frameNumber
        )
        // A stored record answers PID 02, so a silent frame beyond the
        // SAE-required one means the record does not exist — probing six
        // value PIDs against it would cost six NO DATA timeouts per scan on
        // every single-frame vehicle. Frame 0 keeps full probing for ECUs
        // that store data without implementing PID 02.
        if frameNumber > 0, attributedCode == nil {
            return nil
        }
        let actualCode = attributedCode ?? FreezeFrameData.unattributedDTCCode
        var values: [PIDValue] = []
        for definition in definitions {
            // The frame number must reach every PID read: requesting frame 1's
            // attribution but frame 0's values would label one record's DTC
            // with a different record's data.
            let command = ELM327Command.readFreezeFramePID(
                definition.hexCode,
                frameNumber: frameNumber
            )
            do {
                let response = try await commandCoordinator.send(command)
                if isNoDataResponse(response) { continue }
                try validateAdapterResponse(response, command: command.raw)
                guard let value = parser.parsePIDResponse(
                    response,
                    definition: definition,
                    responseService: 0x42,
                    frameNumber: frameNumber
                ) else {
                    throw OBDError.invalidResponse
                }
                values.append(value)
            } catch {
                if isExplicitlyUnsupported(error) { continue }
                throw error
            }
        }

        // A record whose stored parameters fall outside the six standard
        // PIDs still exists — its PID 02 attribution is evidence on its own
        // and must not be conflated with "no record here".
        if values.isEmpty, attributedCode == nil {
            return nil
        }
        return FreezeFrameData(
            pids: values,
            dtcCode: actualCode,
            frameNumber: frameNumber
        )
    }

    /// Reads consecutive Mode 02 records starting at frame 0.
    ///
    /// Frame 0 is the SAE-required record; some ECUs store additional
    /// manufacturer frames behind it. Enumeration stops at the first frame
    /// that returns no data, and `maximumFrames` bounds the probing so a
    /// permissive adapter cannot stretch a scan indefinitely.
    public func readFreezeFrames(
        maximumFrames: UInt8 = 3
    ) async throws -> [FreezeFrameData] {
        guard maximumFrames > 0 else { return [] }
        var frames: [FreezeFrameData] = []
        if let primary = try await readFreezeFrame(frameNumber: 0) {
            frames.append(primary)
        } else {
            return frames
        }
        for frameNumber in 1..<maximumFrames {
            // Probing beyond the SAE-required record is best-effort. Clone
            // adapters commonly ignore the record byte and re-serve frame 0
            // (which correctly fails the frame-echo check), and ECUs answer
            // nonexistent frames with negative-response codes the shared
            // unsupported-classifier does not cover. None of that may abort
            // a scan whose essential evidence is already in hand — an error
            // here ends enumeration, nothing more.
            do {
                guard let frame = try await readFreezeFrame(
                    frameNumber: frameNumber
                ) else {
                    break
                }
                frames.append(frame)
            } catch {
                break
            }
        }
        return frames
    }

    /// Reads the freeze-frame record attributed to the requested code.
    ///
    /// Mode 02 PID 02 remains the authority for attribution: the stored
    /// frames are probed in order and the first record whose own attribution
    /// matches the requested code is returned. When no stored record names
    /// the code, frame 0 is returned as the vehicle's primary fault-time
    /// evidence — still carrying its own attribution, never relabeled with
    /// the requested code.
    public func readFreezeFrame(for dtcCode: String) async throws -> FreezeFrameData? {
        let frames = try await readFreezeFrames()
        return frames.first { $0.dtcCode == dtcCode } ?? frames.first
    }

    private func readFreezeFrameDTC(frameNumber: UInt8) async throws -> String? {
        let command = ELM327Command.readFreezeFramePID("02", frameNumber: frameNumber)
        do {
            let response = try await commandCoordinator.send(command)
            if isNoDataResponse(response) { return nil }
            try validateAdapterResponse(response, command: command.raw)

            let hasPIDResponse = parser.responsePayloads(from: response).contains { payload in
                guard let index = payload.indices.first(where: { index in
                    index + 4 < payload.endIndex &&
                        payload[index] == 0x42 &&
                        payload[index + 1] == 0x02
                }) else {
                    return false
                }
                return payload[index + 2] == frameNumber
            }
            guard hasPIDResponse else { throw OBDError.invalidResponse }
            return parser.parseFreezeFrameDTC(
                from: response,
                frameNumber: frameNumber
            )
        } catch {
            if isExplicitlyUnsupported(error) { return nil }
            throw error
        }
    }

    // MARK: - Advanced read-only diagnostics

    /// Reads raw SAE Mode 06 monitor results while preserving ECU attribution.
    ///
    /// The service does not guess SAE/OEM scaling. Raw values and limits are
    /// retained for a sourced definition to evaluate later.
    public func readMode06Results(
        maximumMonitorCount: Int = 64
    ) async throws -> Mode06ResultReport {
        try await readMode06Results(
            maximumMonitorCount: maximumMonitorCount,
            deadline: nil
        )
    }

    private func readMode06Results(
        maximumMonitorCount: Int,
        deadline: Date?
    ) async throws -> Mode06ResultReport {
        let boundedMaximum = min(max(maximumMonitorCount, 1), 224)
        let mode06Parser = Mode06Parser(obdParser: parser)

        if isDemoMode {
            let source = DiagnosticSourceAddress(rawValue: "7E8")
            return Mode06ResultReport(
                results: [
                    Mode06MonitorResult(
                        sourceAddress: source,
                        format: .can,
                        monitorID: 0x01,
                        testID: 0x01,
                        componentID: nil,
                        unitAndScalingID: 0x01,
                        rawTestValue: 108,
                        rawMinimum: 0,
                        rawMaximum: 255
                    ),
                    Mode06MonitorResult(
                        sourceAddress: source,
                        format: .can,
                        monitorID: 0x21,
                        testID: 0x02,
                        componentID: nil,
                        unitAndScalingID: 0x01,
                        rawTestValue: 24,
                        rawMinimum: 0,
                        rawMaximum: 100
                    ),
                ],
                evidence: [
                    AdvancedDiagnosticEvidence(
                        kind: .capability,
                        requestService: 0x06,
                        sourceAddress: source,
                        detail: "Simulated Mode 06 evidence for demo mode"
                    ),
                ]
            )
        }

        if !isInitialized {
            try await initialize()
        }
        try enforceAdvancedDeadline(deadline)

        let protocolCode = detectedProtocolIdentifier.map {
            $0.hasPrefix("A") ? String($0.dropFirst()) : $0
        }
        let isCAN = ["6", "7", "8", "9"].contains(
            protocolCode ?? ""
        )
        guard isCAN else {
            try enforceAdvancedDeadline(deadline)
            let response = try await commandCoordinator.send(
                Mode06CommandFactory.legacyAllResults
            )
            return mode06Parser.parseResults(
                from: response,
                format: .legacy
            )
        }

        var monitorIDs = Set<UInt8>()
        var evidence: [AdvancedDiagnosticEvidence] = []
        var baseMonitorID: UInt8 = 0

        for _ in 0..<8 {
            try enforceAdvancedDeadline(deadline)
            let command = try Mode06CommandFactory.capabilityPage(
                baseMonitorID: baseMonitorID
            )
            let response = try await commandCoordinator.send(command)
            let report = mode06Parser.parseCapabilityPage(
                from: response,
                requestedBaseMonitorID: baseMonitorID
            )
            evidence.append(contentsOf: report.evidence)
            report.pages.forEach {
                monitorIDs.formUnion($0.supportedMonitorIDs)
            }

            guard report.pages.contains(where: \.hasContinuationPage),
                  let next = UInt8(
                    exactly: Int(baseMonitorID) + 0x20
                  ) else {
                break
            }
            baseMonitorID = next
        }

        let actualMonitorIDs = monitorIDs
            .filter { $0 % 0x20 != 0 }
            .sorted()
        let selectedMonitorIDs = Array(
            actualMonitorIDs.prefix(boundedMaximum)
        )
        if actualMonitorIDs.count > selectedMonitorIDs.count {
            evidence.append(
                AdvancedDiagnosticEvidence(
                    kind: .boundsExceeded,
                    requestService: 0x06,
                    detail: "Mode 06 scan was limited to \(boundedMaximum) monitor IDs"
                )
            )
        }

        var results: [Mode06MonitorResult] = []
        for monitorID in selectedMonitorIDs {
            try enforceAdvancedDeadline(deadline)
            let command = Mode06CommandFactory.monitorResults(
                monitorID: monitorID
            )
            let response = try await commandCoordinator.send(command)
            let report = mode06Parser.parseResults(
                from: response,
                format: .can,
                expectedMonitorID: monitorID
            )
            results.append(contentsOf: report.results)
            evidence.append(contentsOf: report.evidence)
            if results.count >= Mode06Parser.maximumRecords {
                results = Array(
                    results.prefix(Mode06Parser.maximumRecords)
                )
                evidence.append(
                    AdvancedDiagnosticEvidence(
                        kind: .boundsExceeded,
                        requestService: 0x06,
                        detail: "Mode 06 record limit reached"
                    )
                )
                break
            }
        }
        return Mode06ResultReport(
            results: results,
            evidence: evidence
        )
    }

    /// Executes only the read operations authorized by a validated enhanced
    /// profile. Each physical-address transaction is exclusive and its
    /// functional OBD header is restored even when the request fails.
    public func readEnhancedDiagnostics(
        profile: EnhancedDiagnosticProfile,
        maximumDataIdentifiers: Int = 64
    ) async throws -> EnhancedDiagnosticExecutionReport {
        try await readEnhancedDiagnostics(
            profile: profile,
            maximumDataIdentifiers: maximumDataIdentifiers,
            deadline: nil
        )
    }

    private func readEnhancedDiagnostics(
        profile: EnhancedDiagnosticProfile,
        maximumDataIdentifiers: Int,
        deadline: Date?
    ) async throws -> EnhancedDiagnosticExecutionReport {
        let issues = profile.validationIssues()
        guard issues.isEmpty else {
            throw AdvancedDiagnosticRequestError.invalidProfile(issues)
        }
        let boundedMaximum = min(max(maximumDataIdentifiers, 1), 256)
        var values: [EnhancedDataIdentifierValue] = []
        var dtcs: [EnhancedDTCRecord] = []
        var evidence: [AdvancedDiagnosticEvidence] = []

        if isDemoMode {
            evidence.append(
                AdvancedDiagnosticEvidence(
                    kind: .unsupportedTransport,
                    requestService: 0x22,
                    detail: "Demo mode does not execute imported manufacturer-specific definitions"
                )
            )
            return EnhancedDiagnosticExecutionReport(
                profileID: profile.id,
                profileName: profile.displayName,
                values: [],
                dtcs: [],
                evidence: evidence
            )
        }
        if !isInitialized {
            try await initialize()
        }
        try enforceAdvancedDeadline(deadline)

        let enhancedParser = EnhancedDiagnosticParser(obdParser: parser)
        var definitionCount = 0
        var shouldStop = false

        for module in profile.modules where !shouldStop {
            for definition in module.dataIdentifiers {
                guard definitionCount < boundedMaximum else {
                    evidence.append(
                        AdvancedDiagnosticEvidence(
                            kind: .boundsExceeded,
                            requestService: 0x22,
                            detail: "Enhanced scan was limited to \(boundedMaximum) data identifiers"
                        )
                    )
                    shouldStop = true
                    break
                }
                try enforceAdvancedDeadline(deadline)
                definitionCount += 1
                let plan = try EnhancedDiagnosticCommandFactory
                    .readDataIdentifier(
                        profile: profile,
                        moduleID: module.id,
                        dataIdentifier: definition.dataIdentifier,
                        detectedProtocolIdentifier:
                            detectedProtocolIdentifier
                    )
                evidence.append(plan.capabilityEvidence)
                guard plan.transportSupport.isExecutable else {
                    continue
                }
                do {
                    let response = try await commandCoordinator.sendExclusive(
                        preparation: plan.preparationCommands,
                        request: plan.requestCommand,
                        restoration: plan.restorationCommands
                    )
                    let report = enhancedParser.parseDataIdentifier(
                        from: response,
                        module: module,
                        definition: definition
                    )
                    values.append(contentsOf: report.values)
                    evidence.append(contentsOf: report.evidence)
                } catch {
                    if error is CancellationError { throw error }
                    evidence.append(
                        transportEvidence(
                            error,
                            service: plan.requestService
                        )
                    )
                    if error is OBDCommandCoordinatorError {
                        disconnect()
                        shouldStop = true
                        break
                    }
                }
            }

            guard !shouldStop,
                  let subfunction =
                    module.allowedDTCReadSubfunctions.first else {
                continue
            }
            try enforceAdvancedDeadline(deadline)
            let plan = try EnhancedDiagnosticCommandFactory.readDTCs(
                profile: profile,
                moduleID: module.id,
                subfunction: subfunction,
                detectedProtocolIdentifier: detectedProtocolIdentifier
            )
            evidence.append(plan.capabilityEvidence)
            guard plan.transportSupport.isExecutable else {
                continue
            }
            do {
                let response = try await commandCoordinator.sendExclusive(
                    preparation: plan.preparationCommands,
                    request: plan.requestCommand,
                    restoration: plan.restorationCommands
                )
                let report = enhancedParser.parseDTCs(
                    from: response,
                    module: module,
                    subfunction: subfunction
                )
                dtcs.append(contentsOf: report.records)
                evidence.append(contentsOf: report.evidence)
            } catch {
                if error is CancellationError { throw error }
                evidence.append(
                    transportEvidence(
                        error,
                        service: plan.requestService
                    )
                )
                if error is OBDCommandCoordinatorError {
                    disconnect()
                    shouldStop = true
                }
            }
        }

        return EnhancedDiagnosticExecutionReport(
            profileID: profile.id,
            profileName: profile.displayName,
            values: Array(values.prefix(512)),
            dtcs: Array(dtcs.prefix(512)),
            evidence: Array(evidence.prefix(512))
        )
    }

    /// Captures advanced evidence only after binding the live ECU to the exact
    /// vehicle that owns the destination scan.
    public func readAdvancedDiagnostics(
        for vehicle: Vehicle,
        profile: EnhancedDiagnosticProfile? = nil,
        maximumMode06Monitors: Int = 32,
        maximumEnhancedDataIdentifiers: Int = 64,
        maximumDuration: TimeInterval = 45
    ) async throws -> AdvancedDiagnosticSnapshot {
        try await initialize(for: vehicle)
        guard isVehicleReady(for: vehicle) else {
            throw OBDError.commandFailed(
                String(
                    localized:
                        "The selected vehicle does not have a live ECU session"
                )
            )
        }

        let verifiedGeneration = isDemoMode
            ? nil
            : commandTransport.transportGeneration
        if let generation = verifiedGeneration {
            try await commandCoordinator.performExclusive {
                [weak self] transport in
                guard let self else { throw CancellationError() }
                try self.ensureCurrentTransport(
                    transport,
                    generation: generation
                )
                try await self.verifyFreshVehicleIdentity(
                    for: vehicle,
                    transport: transport,
                    generation: generation,
                    action: String(
                        localized: "Capturing advanced diagnostics"
                    )
                )
            }
        }

        let snapshot = try await readAdvancedDiagnostics(
            profile: profile,
            maximumMode06Monitors: maximumMode06Monitors,
            maximumEnhancedDataIdentifiers:
                maximumEnhancedDataIdentifiers,
            maximumDuration: maximumDuration
        )
        if let generation = verifiedGeneration {
            try await commandCoordinator.performExclusive {
                [weak self] transport in
                guard let self else { throw CancellationError() }
                try self.ensureCurrentTransport(
                    transport,
                    generation: generation
                )
                try await self.verifyFreshVehicleIdentity(
                    for: vehicle,
                    transport: transport,
                    generation: generation,
                    action: String(
                        localized: "Saving advanced diagnostics"
                    )
                )
            }
        }
        guard isVehicleReady(for: vehicle),
              selectedVehicle?.id == vehicle.id else {
            throw OBDError.commandFailed(
                String(
                    localized:
                        "The selected vehicle changed while advanced diagnostics were running"
                )
            )
        }
        return snapshot
    }

    public func readAdvancedDiagnostics(
        profile: EnhancedDiagnosticProfile? = nil,
        maximumMode06Monitors: Int = 32,
        maximumEnhancedDataIdentifiers: Int = 64,
        maximumDuration: TimeInterval = 45
    ) async throws -> AdvancedDiagnosticSnapshot {
        let boundedDuration = min(max(maximumDuration, 5), 120)
        let deadline = Date().addingTimeInterval(boundedDuration)
        var mode06Results: [Mode06MonitorResult] = []
        var enhancedValues: [EnhancedDataIdentifierValue] = []
        var enhancedDTCs: [EnhancedDTCRecord] = []
        var evidence: [AdvancedDiagnosticEvidence] = []

        do {
            let report = try await readMode06Results(
                maximumMonitorCount: maximumMode06Monitors,
                deadline: deadline
            )
            mode06Results = report.results
            evidence.append(contentsOf: report.evidence)
        } catch {
            if error is CancellationError { throw error }
            if error as? AdvancedDiagnosticRequestError ==
                .timeBudgetExceeded {
                throw error
            }
            evidence.append(transportEvidence(error, service: 0x06))
        }

        if let profile {
            do {
                let report = try await readEnhancedDiagnostics(
                    profile: profile,
                    maximumDataIdentifiers:
                        maximumEnhancedDataIdentifiers,
                    deadline: deadline
                )
                enhancedValues = report.values
                enhancedDTCs = report.dtcs
                evidence.append(contentsOf: report.evidence)
            } catch {
                if error is CancellationError { throw error }
                if error as? AdvancedDiagnosticRequestError ==
                    .timeBudgetExceeded {
                    throw error
                }
                evidence.append(transportEvidence(error, service: 0x22))
            }
        }

        return AdvancedDiagnosticSnapshot(
            mode06Results: mode06Results,
            enhancedProfileID: profile?.id,
            enhancedProfileName: profile?.displayName,
            enhancedValues: enhancedValues,
            enhancedDTCs: enhancedDTCs,
            evidence: evidence.map(\.persistableNote)
        )
    }

    private func enforceAdvancedDeadline(_ deadline: Date?) throws {
        try Task.checkCancellation()
        if let deadline, Date() >= deadline {
            throw AdvancedDiagnosticRequestError.timeBudgetExceeded
        }
    }

    // MARK: - Full scan

    public func performFullScan(vehicle: Vehicle) async throws -> OBDScanResult {
        selectedVehicle = vehicle

        if isDemoMode {
            return demoScan(for: vehicle)
        }
        if !isVehicleReady(for: vehicle) {
            try await initialize(for: vehicle)
        }

        // Confirm identity before any diagnostic evidence can be attributed to
        // the selected vehicle. Unsupported or malformed Mode 09 data remains
        // optional, but two different structurally valid VINs are decisive.
        let vin = try await optionalServiceValue {
            try await readVIN()
        }
        try validateConnectedVehicleIdentity(
            selectedVIN: vehicle.vin,
            ecuVIN: vin
        )

        // Stored DTCs and readiness are the essential health evidence. A
        // transport failure or malformed response must fail the scan instead
        // of being converted into an apparently clean result.
        let stored = try await readStoredDTCs()
        let pending = try await optionalService {
            try await readPendingDTCs()
        } ?? []
        let permanent = try await optionalService {
            try await readPermanentDTCs()
        } ?? []
        let dtcs = mergeDTCs(stored + pending + permanent)
        let monitors = try await readReadinessMonitors()

        var scannedVehicle = vehicle
        if scannedVehicle.vin == nil, let vin {
            scannedVehicle.vin = vin
        }

        let freezeFrames = try await optionalService {
            try await readFreezeFrames()
        } ?? []

        let liveDefinitions: [PIDDefinition] = [
            StandardPIDLibrary.engineRPM,
            StandardPIDLibrary.vehicleSpeed,
            StandardPIDLibrary.coolantTemp,
            StandardPIDLibrary.calculatedLoad,
            StandardPIDLibrary.fuelTrimShortTerm1,
            StandardPIDLibrary.fuelTrimLongTerm1,
            StandardPIDLibrary.mafRate,
            StandardPIDLibrary.throttlePosition,
            StandardPIDLibrary.controlModuleVoltage,
            StandardPIDLibrary.intakeAirTemp,
        ]
        let liveData = try await readMultiplePIDs(liveDefinitions)

        return OBDScanResult(
            vehicle: scannedVehicle,
            dtcs: dtcs,
            readinessMonitors: monitors,
            freezeFrames: freezeFrames,
            liveData: liveData
        )
    }

    /// Compatibility overload for existing app code. New call sites should pass
    /// the selected vehicle so scan history is never assigned to a placeholder.
    public func performFullScan() async throws -> OBDScanResult {
        let vehicle = selectedVehicle ?? Vehicle(
            make: "Unknown",
            model: "Vehicle",
            year: Calendar.current.component(.year, from: Date())
        )
        return try await performFullScan(vehicle: vehicle)
    }

    // MARK: - Adapter health and repair

    public func readAdapterHealth() async throws
        -> OBDAdapterHealthReport {
        if isDemoMode {
            return OBDAdapterHealthReport(
                status: .healthy,
                adapterIdentity: "OBDEngine Demo Adapter / Simulator 1.0",
                supplyVoltage: 13.8,
                protocolIdentifier: "DEMO",
                roundTripLatency: 0,
                measuredAt: now()
            )
        }
        guard commandTransport.isConnected else {
            throw OBDError.notConnected
        }
        let generation = commandTransport.transportGeneration

        return try await commandCoordinator.performExclusive {
            [weak self] transport in
            guard let self else { throw CancellationError() }
            var identity: String?
            var voltage: Double?
            var protocolIdentifier: String?
            var roundTripLatency: TimeInterval?
            var issues: [String] = []

            do {
                let response = try await transport.sendCommand(.version)
                try self.ensureCurrentTransport(
                    transport,
                    generation: generation
                )
                try self.validateAdapterResponse(
                    response,
                    command: ELM327Command.version.raw
                )
                let text = self.cleanedAdapterText(response)
                if !text.isEmpty {
                    identity = text
                } else {
                    issues.append(
                        String(localized: "Adapter identity was empty")
                    )
                }
            } catch {
                if error is CancellationError ||
                    !transport.isConnected {
                    throw error
                }
                issues.append(
                    String(localized: "Adapter identity did not respond")
                )
            }

            do {
                let startedAt = self.now()
                let response = try await transport.sendCommand(
                    .readVoltage
                )
                roundTripLatency = max(
                    0,
                    self.now().timeIntervalSince(startedAt)
                )
                try self.ensureCurrentTransport(
                    transport,
                    generation: generation
                )
                try self.validateAdapterResponse(
                    response,
                    command: ELM327Command.readVoltage.raw
                )
                voltage = Self.voltage(from: response)
                if voltage == nil {
                    issues.append(
                        String(localized: "Adapter voltage was malformed")
                    )
                }
            } catch {
                if error is CancellationError ||
                    !transport.isConnected {
                    throw error
                }
                issues.append(
                    String(localized: "Adapter voltage did not respond")
                )
            }

            do {
                let response = try await transport.sendCommand(
                    .protocolName
                )
                try self.ensureCurrentTransport(
                    transport,
                    generation: generation
                )
                try self.validateAdapterResponse(
                    response,
                    command: ELM327Command.protocolName.raw
                )
                protocolIdentifier = Self.protocolIdentifier(
                    from: response
                )
                if protocolIdentifier == nil {
                    issues.append(
                        String(localized: "Vehicle protocol was unavailable")
                    )
                }
            } catch {
                if error is CancellationError ||
                    !transport.isConnected {
                    throw error
                }
                issues.append(
                    String(localized: "Vehicle protocol did not respond")
                )
            }

            if let voltage, !(10...16.5).contains(voltage) {
                issues.append(
                    String(
                        format: "Supply voltage %.1f V is outside the expected range",
                        voltage
                    )
                )
            }
            let status: OBDAdapterHealthReport.Status
            if identity == nil,
               voltage == nil,
               protocolIdentifier == nil {
                status = .unavailable
            } else if issues.isEmpty {
                status = .healthy
            } else {
                status = .degraded
            }
            return OBDAdapterHealthReport(
                status: status,
                adapterIdentity: identity,
                supplyVoltage: voltage,
                protocolIdentifier: protocolIdentifier,
                roundTripLatency: roundTripLatency,
                issues: issues,
                measuredAt: self.now()
            )
        }
    }

    // MARK: - Raw access and state

    public func sendRawCommand(_ command: String) async throws -> String {
        if isDemoMode {
            return command.uppercased().hasPrefix("AT") ? "OK" : "DEMO DATA"
        }
        return try await commandCoordinator.send(ELM327Command(raw: command))
    }

    public func getConnectionState() -> ConnectionState {
        connectionState
    }

    // MARK: - Demo data

    private func demoScan(for vehicle: Vehicle) -> OBDScanResult {
        let dtcs = demoDTCs(for: vehicle, status: .confirmed) +
            demoDTCs(for: vehicle, status: .pending)
        let liveDefinitions: [PIDDefinition] = [
            StandardPIDLibrary.engineRPM,
            StandardPIDLibrary.vehicleSpeed,
            StandardPIDLibrary.coolantTemp,
            StandardPIDLibrary.calculatedLoad,
            StandardPIDLibrary.fuelTrimShortTerm1,
            StandardPIDLibrary.fuelTrimLongTerm1,
            StandardPIDLibrary.mafRate,
            StandardPIDLibrary.throttlePosition,
            StandardPIDLibrary.controlModuleVoltage,
            StandardPIDLibrary.intakeAirTemp,
        ]
        let liveData = liveDefinitions.map { demoPIDValue(for: $0, vehicle: vehicle) }
        let freezeFrames = dtcs.first.map {
            [FreezeFrameData(pids: Array(liveData.prefix(6)), dtcCode: $0.code)]
        } ?? []

        return OBDScanResult(
            vehicle: vehicle,
            dtcs: dtcs,
            readinessMonitors: demoReadiness(for: vehicle),
            freezeFrames: freezeFrames,
            liveData: liveData,
            // Marked at the point of fabrication so the flag survives into
            // saved history, reports, and CarPlay.
            isSimulated: true
        )
    }

    private func demoDTCs(
        for vehicle: Vehicle?,
        status: DiagnosticTroubleCode.CodeStatus
    ) -> [DiagnosticTroubleCode] {
        guard !demoDTCsWereCleared, let vehicle else { return [] }
        let profile = Int(stableHash(vehicleKey(vehicle)) % 4)
        let storedCodes: [[String]] = [
            ["P0301"],
            ["P0420"],
            ["P0562"],
            ["C0035"],
        ]
        let pendingCodes: [[String]] = [
            ["P0171"],
            [],
            [],
            ["U0121"],
        ]

        let codes: [String]
        switch status {
        case .confirmed: codes = storedCodes[profile]
        case .pending: codes = pendingCodes[profile]
        case .permanent, .historical: codes = []
        }
        let fallback: DiagnosticTroubleCode.CodeSeverity =
            status == .pending ? .low : .medium
        return codes.map {
            makeDTC(code: $0, status: status, fallbackSeverity: fallback)
        }
    }

    private func demoPIDValue(
        for definition: PIDDefinition,
        vehicle: Vehicle?
    ) -> PIDValue {
        let key = vehicle.map(vehicleKey) ?? "demo"
        let jitter = Double(stableHash("\(key)|\(definition.hexCode)") % 10) / 10
        let value: Double

        switch definition.hexCode {
        case "0C": value = 742 + (jitter * 60)
        case "0D": value = 0
        case "05": value = 88 + jitter
        case "04": value = 21 + jitter
        case "06": value = 2.3 + jitter
        case "07": value = 4.7 + jitter
        case "10": value = 3.4 + jitter
        case "11": value = 12 + jitter
        case "42": value = 13.8 + (jitter / 10)
        case "0F": value = 27 + jitter
        case "2F": value = 64 + jitter
        case "0B": value = 31 + jitter
        default:
            value = definition.minValue +
                ((definition.maxValue - definition.minValue) * 0.35)
        }
        return PIDValue(pid: definition, value: value)
    }

    private func demoReadiness(for vehicle: Vehicle?) -> [ReadinessMonitor] {
        let notReadyName: String?
        if let vehicle, stableHash(vehicleKey(vehicle)) % 3 == 0 {
            notReadyName = "EVAP System"
        } else {
            notReadyName = nil
        }

        let supported = [
            "Misfire", "Fuel System", "Comprehensive Component",
            "Catalyst", "EVAP System", "Oxygen Sensor",
            "Oxygen Sensor Heater", "EGR System",
        ]
        return supported.map {
            ReadinessMonitor(name: $0, isReady: $0 != notReadyName, isSupported: true)
        }
    }

    private func vehicleKey(_ vehicle: Vehicle) -> String {
        [
            vehicle.vin ?? "",
            String(vehicle.year),
            vehicle.make,
            vehicle.model,
            vehicle.engineType.rawValue,
        ].joined(separator: "|").lowercased()
    }

    private func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
    }

    // MARK: - Helpers

    private func resetVehicleLink() {
        isInitialized = false
        detectedProtocolIdentifier = nil
        initializedVehicleID = nil
        supportedMode01PIDs = []
        protocolProbeLatency = nil
    }

    /// Publishes the session the simulator guarantees for the current
    /// selection.
    ///
    /// Demo mode never runs an initialization flight, so every path that would
    /// otherwise clear readiness has to land back here instead of waiting for
    /// a probe that will never answer.
    private func publishDemoVehicleSession() {
        let nextState = withStateLock { () -> OBDVehicleLinkState in
            guard let vehicle = _selectedVehicle else {
                // Without a selection the simulated adapter stays up but owns
                // no vehicle attribution, matching `deselectVehicle()`.
                _isInitialized = false
                _detectedProtocolIdentifier = nil
                _initializedVehicleID = nil
                _supportedMode01PIDs = []
                _protocolProbeLatency = nil
                _vehicleLinkState = .adapterConnected
                return .adapterConnected
            }
            _isInitialized = true
            _detectedProtocolIdentifier = "DEMO"
            _initializedVehicleID = vehicle.id
            _supportedMode01PIDs = Set(
                StandardPIDLibrary.allPIDs.compactMap {
                    UInt8($0.hexCode, radix: 16)
                }
            )
            _protocolProbeLatency = 0
            let readyState = OBDVehicleLinkState.vehicleReady(
                protocolIdentifier: "DEMO"
            )
            _vehicleLinkState = readyState
            return readyState
        }
        onVehicleLinkStateChange?(nextState)
    }

    private func invalidateVehicleReadinessForForegroundReconciliation() {
        let nextState: OBDVehicleLinkState = commandTransport.isConnected
            ? .adapterConnected
            : .disconnected
        withStateLock {
            // Foregrounding starts a new ECU-validation epoch even when the
            // Apple-owned BLE/MFi route remains healthy. This prevents an
            // initialization started before suspension from committing stale
            // readiness, while preserving the physical adapter connection.
            _vehicleSelectionGeneration &+= 1
            _isInitialized = false
            _detectedProtocolIdentifier = nil
            _initializedVehicleID = nil
            _supportedMode01PIDs = []
            _protocolProbeLatency = nil
            _vehicleLinkState = nextState
        }
        onVehicleLinkStateChange?(nextState)
    }

    private func updateVehicleLinkState(
        _ state: OBDVehicleLinkState
    ) {
        vehicleLinkState = state
        onVehicleLinkStateChange?(state)
    }

    private func validateConnectedVehicleIdentity(
        selectedVIN: String?,
        ecuVIN: String?
    ) throws {
        guard let selected = selectedVIN.flatMap(Self.structuralVIN),
              let connected = ecuVIN.flatMap(Self.structuralVIN) else {
            return
        }
        guard selected == connected else {
            throw OBDError.commandFailed(
                String(
                    localized:
                        "Connected vehicle VIN does not match the selected vehicle VIN"
                )
            )
        }
    }

    /// Requires a fresh, structurally valid Mode 09 VIN before an operation
    /// whose result or side effect must be bound to one saved vehicle.
    ///
    /// This deliberately fails closed on `NO DATA`: unsupported VIN reads are
    /// acceptable during a generic read-only scan, but cannot safely authorize
    /// a destructive clear or attribution of new manufacturer evidence.
    private func verifyFreshVehicleIdentity(
        for vehicle: Vehicle,
        transport: any OBDCommandTransport,
        generation: UInt64,
        action: String
    ) async throws {
        guard let expectedVIN = vehicle.vin.flatMap(Self.structuralVIN) else {
            throw OBDError.commandFailed(
                String(
                    format: String(
                        localized:
                            "%@ requires a valid 17-character VIN for the selected vehicle"
                    ),
                    locale: .current,
                    action
                )
            )
        }
        guard selectedVehicle?.id == vehicle.id else {
            throw OBDError.commandFailed(
                String(
                    localized:
                        "The selected vehicle changed before identity verification"
                )
            )
        }

        let command = ELM327Command.readVIN()
        let response = try await transport.sendCommand(command)
        try ensureCurrentTransport(
            transport,
            generation: generation
        )
        if isNoDataResponse(response) {
            throw OBDError.commandFailed(
                String(
                    format: String(
                        localized:
                            "%@ is disabled because this ECU does not support Mode 09 VIN verification"
                    ),
                    locale: .current,
                    action
                )
            )
        }
        try validateAdapterResponse(
            response,
            command: command.raw,
            allowNoData: false
        )
        guard let connectedVIN = parser.parseVIN(from: response)
                .flatMap(Self.structuralVIN) else {
            throw OBDError.commandFailed(
                String(
                    format: String(
                        localized:
                            "%@ is disabled because the ECU did not return a valid VIN"
                    ),
                    locale: .current,
                    action
                )
            )
        }
        guard connectedVIN == expectedVIN else {
            throw OBDError.commandFailed(
                String(
                    localized:
                        "Connected vehicle VIN does not match the selected vehicle VIN"
                )
            )
        }
    }

    private static func structuralVIN(_ rawValue: String) -> String? {
        let value = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard value.utf8.count == 17,
              value.unicodeScalars.count == 17 else {
            return nil
        }
        let allowed = CharacterSet(
            charactersIn: "0123456789ABCDEFGHJKLMNPRSTUVWXYZ"
        )
        guard value.unicodeScalars.allSatisfy(allowed.contains) else {
            return nil
        }
        return value
    }

    private static func voltage(from response: String) -> Double? {
        let candidates = response
            .uppercased()
            .replacingOccurrences(of: "V", with: " ")
            .replacingOccurrences(of: ">", with: " ")
            .split {
                !$0.isNumber && $0 != "." && $0 != "-"
            }
        return candidates.compactMap {
            Double(String($0))
        }.first {
            (0...100).contains($0)
        }
    }

    private func transportEvidence(
        _ error: Error,
        service: UInt8
    ) -> AdvancedDiagnosticEvidence {
        let kind: AdvancedDiagnosticEvidence.Kind
        if error is OBDCommandCoordinatorError {
            kind = .unsupportedTransport
        } else if isExplicitlyUnsupported(error) {
            kind = .noData
        } else {
            kind = .malformedResponse
        }
        return AdvancedDiagnosticEvidence(
            kind: kind,
            requestService: service,
            detail: String(error.localizedDescription.prefix(220))
        )
    }

    private func optionalService<T>(
        _ operation: () async throws -> T
    ) async throws -> T? {
        do {
            return try await operation()
        } catch {
            if isExplicitlyUnsupported(error) { return nil }
            throw error
        }
    }

    private func optionalServiceValue<T>(
        _ operation: () async throws -> T?
    ) async throws -> T? {
        do {
            return try await operation()
        } catch {
            if isExplicitlyUnsupported(error) { return nil }
            throw error
        }
    }

    private func isExplicitlyUnsupported(_ error: Error) -> Bool {
        // Classification is structural: the wrapped case is applied at the
        // raw-response boundary (validateAdapterResponse and the capability
        // gate), so it cannot drift with the device locale's translations.
        if case .unsupportedByVehicle = error as? OBDError {
            return true
        }
        return false
    }

    private func mergeDTCs(_ values: [DiagnosticTroubleCode]) -> [DiagnosticTroubleCode] {
        var merged: [DiagnosticTroubleCode] = []
        var indexByCode: [String: Int] = [:]

        for value in values {
            guard let index = indexByCode[value.code] else {
                indexByCode[value.code] = merged.count
                merged.append(value)
                continue
            }

            let existing = merged[index]
            let statuses = existing.observedStatuses + value.observedStatuses
            let primary = statuses.min {
                statusPriority($0) < statusPriority($1)
            } ?? existing.status
            let severity = severityPriority(value.severity) >
                severityPriority(existing.severity)
                ? value.severity
                : existing.severity

            merged[index] = DiagnosticTroubleCode(
                id: existing.id,
                code: existing.code,
                description: existing.description,
                system: existing.system,
                severity: severity,
                status: primary,
                freezeFrame: existing.freezeFrame ?? value.freezeFrame,
                possibleFixes: existing.possibleFixes.isEmpty
                    ? value.possibleFixes
                    : existing.possibleFixes,
                relatedTSBs: existing.relatedTSBs.isEmpty
                    ? value.relatedTSBs
                    : existing.relatedTSBs,
                observedStatuses: statuses
            )
        }

        return merged
    }

    private func statusPriority(
        _ status: DiagnosticTroubleCode.CodeStatus
    ) -> Int {
        switch status {
        case .confirmed: return 0
        case .pending: return 1
        case .permanent: return 2
        case .historical: return 3
        }
    }

    private func severityPriority(
        _ severity: DiagnosticTroubleCode.CodeSeverity
    ) -> Int {
        switch severity {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .critical: return 3
        }
    }

    private func validateAdapterResponse(
        _ response: String,
        command: String,
        allowNoData: Bool = false
    ) throws {
        let normalized = response
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        if normalized.isEmpty {
            throw OBDError.invalidResponse
        }
        if normalized.contains("NODATA") {
            if allowNoData { return }
            throw OBDError.unsupportedByVehicle(.commandFailed(
                String(
                    format: String(localized: "NO DATA for %@"),
                    locale: .current,
                    command
                )
            ))
        }

        if let serviceToken = command.split(whereSeparator: \.isWhitespace).first,
           let service = UInt8(serviceToken, radix: 16),
           let negative = parser.responsePayloads(from: response).first(where: {
               $0.count >= 3 && $0[0] == 0x7F && $0[1] == service
           }) {
            let responseCode = negative[2]
            if responseCode == 0x11 ||
                responseCode == 0x12 ||
                responseCode == 0x31 {
                throw OBDError.unsupportedByVehicle(.commandFailed(
                    String(
                        format: String(
                            localized:
                                "Service %02X not supported (NRC 0x%02X)"
                        ),
                        locale: .current,
                        Int(service),
                        Int(responseCode)
                    )
                ))
            }
            throw OBDError.commandFailed(
                String(
                    format: String(
                        localized:
                            "Negative response to %02X (NRC 0x%02X)"
                    ),
                    locale: .current,
                    Int(service),
                    Int(responseCode)
                )
            )
        }

        let errors = [
            "ERROR", "STOPPED", "UNABLETOCONNECT", "CANERROR",
            "BUSERROR", "BUFFERFULL",
        ]
        if let error = errors.first(where: normalized.contains) {
            throw OBDError.commandFailed(
                String(
                    format: String(localized: "%@ while running %@"),
                    locale: .current,
                    error,
                    command
                )
            )
        }
        if normalized == "?" || normalized.hasSuffix("?") {
            throw OBDError.unsupportedByVehicle(.commandFailed(
                String(
                    format: String(
                        localized: "Adapter did not recognize %@"
                    ),
                    locale: .current,
                    command
                )
            ))
        }
    }

    private func isNoDataResponse(_ response: String) -> Bool {
        response
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
            .contains("NODATA")
    }

    private func cleanedAdapterText(_ response: String) -> String {
        response
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isValidProtocolIdentifier(_ value: String) -> Bool {
        let validCodes = Set("0123456789ABC")
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

    private static func protocolIdentifier(from response: String) -> String? {
        let tokens = response
            .uppercased()
            .replacingOccurrences(of: ">", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return tokens.last(where: isValidProtocolIdentifier)
    }
}

extension OBDService: OBDConnectionManagerDelegate {
    public func connectionManager(
        _ manager: OBDConnectionManager,
        didUpdateState state: ConnectionState
    ) {
        guard demoConnectionState == nil else { return }
        switch state.status {
        case .connected:
            if !isInitialized {
                updateVehicleLinkState(.adapterConnected)
            }
        case .error(let message):
            Task { await initializationFlight.cancel() }
            resetVehicleLink()
            updateVehicleLinkState(
                .error(message: message, adapterConnected: false)
            )
        case .disconnected, .scanning, .connecting, .disconnecting:
            Task { await initializationFlight.cancel() }
            resetVehicleLink()
            updateVehicleLinkState(.disconnected)
        }
        onConnectionStateChange?(state)
    }
}
