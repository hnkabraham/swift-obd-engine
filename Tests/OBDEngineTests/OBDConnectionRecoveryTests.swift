import CoreBluetooth
import Foundation
import XCTest

#if SWIFT_PACKAGE
@testable import OBDModels
@testable import OBDEngine
#else
#endif

// MARK: - Fixtures

/// A scripted stand-in for `CoreBluetoothCentral`.
///
/// It records every call the manager makes, answers the two retrieve methods
/// from test-supplied scripts, and never produces an event on its own: the test
/// emits them through `emit(_:)`, synchronously on the main thread, exactly
/// where the real central would have called back. Peripheral-state queries
/// (`isConnected`, `isNotifying`) are backed by the same bookkeeping the
/// `report…` helpers update, so `markTransportReady()` sees a coherent view
/// rather than a hard-coded `true`.
final class ScriptedBluetoothCentral: OBDBluetoothCentral {
    struct RecordedNotificationEnable: Equatable {
        let id: UUID
        let endpoint: BLEEndpoint
    }

    struct RecordedWrite: Equatable {
        let id: UUID
        let data: Data
        let endpoint: BLEEndpoint
        let withResponse: Bool
    }

    // Scripted responses.
    var state: CBManagerState = .poweredOn
    /// What `retrievePeripherals(withIdentifiers:)` may hand back — iOS's cache
    /// of peripherals this device has connected to before.
    var retrievablePeripherals: [BLEPeripheralIdentity] = []
    /// What `retrieveConnectedPeripherals(services:)` hands back — peripherals
    /// the system already holds a connection to.
    var systemConnectedPeripherals: [BLEPeripheralIdentity] = []
    var maximumWriteLength = 20
    var writeWithoutResponseIsReady = true

    // Recorded calls.
    private(set) var isScanning = false
    private(set) var scanCalls: [[CBUUID]?] = []
    private(set) var stopScanCalls = 0
    private(set) var connectCalls: [UUID] = []
    private(set) var cancelConnectionCalls: [UUID] = []
    private(set) var retrievePeripheralCalls: [[UUID]] = []
    private(set) var retrieveConnectedPeripheralCalls: [[CBUUID]] = []
    private(set) var discoverEndpointCalls: [UUID] = []
    private(set) var enableNotificationCalls: [RecordedNotificationEnable] = []
    private(set) var writes: [RecordedWrite] = []

    private var connectedIdentifiers: Set<UUID> = []
    private var notifyingEndpoints: [UUID: Set<BLEEndpoint>] = [:]

    var onEvent: ((OBDBluetoothCentralEvent) -> Void)?

    // MARK: OBDBluetoothCentral

    func scan(services: [CBUUID]?) {
        scanCalls.append(services)
        isScanning = true
    }

    func stopScan() {
        stopScanCalls += 1
        isScanning = false
    }

    func connect(id: UUID) {
        connectCalls.append(id)
    }

    func cancelConnection(id: UUID) {
        cancelConnectionCalls.append(id)
        connectedIdentifiers.remove(id)
        notifyingEndpoints[id] = nil
    }

    func retrievePeripherals(
        withIdentifiers identifiers: [UUID]
    ) -> [BLEPeripheralIdentity] {
        retrievePeripheralCalls.append(identifiers)
        return retrievablePeripherals.filter {
            identifiers.contains($0.identifier)
        }
    }

    func retrieveConnectedPeripherals(
        services: [CBUUID]
    ) -> [BLEPeripheralIdentity] {
        retrieveConnectedPeripheralCalls.append(services)
        return systemConnectedPeripherals
    }

    func discoverEndpoints(id: UUID) {
        discoverEndpointCalls.append(id)
    }

    func enableNotifications(id: UUID, endpoint: BLEEndpoint) {
        enableNotificationCalls.append(
            RecordedNotificationEnable(id: id, endpoint: endpoint)
        )
    }

    func write(id: UUID, data: Data, endpoint: BLEEndpoint, withResponse: Bool) {
        writes.append(RecordedWrite(
            id: id,
            data: data,
            endpoint: endpoint,
            withResponse: withResponse
        ))
    }

    func canSendWriteWithoutResponse(id: UUID) -> Bool {
        writeWithoutResponseIsReady
    }

    func maximumWriteValueLength(id: UUID, withResponse: Bool) -> Int {
        maximumWriteLength
    }

    func isConnected(id: UUID) -> Bool {
        connectedIdentifiers.contains(id)
    }

    func isNotifying(id: UUID, endpoint: BLEEndpoint) -> Bool {
        notifyingEndpoints[id]?.contains(endpoint) == true
    }

    // MARK: Test-driven events

    func emit(
        _ event: OBDBluetoothCentralEvent,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let onEvent else {
            XCTFail(
                "The manager never subscribed to the central's event sink.",
                file: file,
                line: line
            )
            return
        }
        onEvent(event)
    }

    /// Mirrors `didConnect`: the peripheral is live before the event lands, so
    /// a later `isConnected` check agrees with the callback.
    func reportConnected(_ id: UUID) {
        connectedIdentifiers.insert(id)
        emit(.connected(id: id))
    }

    /// Mirrors `didUpdateNotificationStateFor` for the endpoint the manager
    /// most recently asked to enable.
    func reportNotificationsEnabled(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let request = enableNotificationCalls.last else {
            XCTFail(
                "The manager never asked to enable notifications.",
                file: file,
                line: line
            )
            return
        }
        notifyingEndpoints[request.id, default: []].insert(request.endpoint)
        emit(.notificationState(
            id: request.id,
            endpoint: request.endpoint,
            isNotifying: true,
            error: nil
        ), file: file, line: line)
    }
}

/// Captures the manager's deferred work instead of running it.
///
/// Nothing here uses wall-clock time: a test fires the exact deadline it means
/// to by naming that deadline's delay, which also proves the manager scheduled
/// the timer it was supposed to.
final class CapturedTimerScheduler {
    struct Entry {
        let delay: TimeInterval
        let work: DispatchWorkItem
    }

    private(set) var entries: [Entry] = []

    var delays: [TimeInterval] { entries.map(\.delay) }

    func record(_ delay: TimeInterval, _ work: DispatchWorkItem) {
        entries.append(Entry(delay: delay, work: work))
    }

    /// Runs the one work item scheduled at `delay`. The item is removed first
    /// so work it schedules in turn is visible to the next assertion.
    func fire(
        _ delay: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let matches = entries.enumerated().filter {
            abs($0.element.delay - delay) < 0.000_001
        }
        guard matches.count == 1, let match = matches.first else {
            XCTFail(
                """
                Expected exactly one work item scheduled at \(delay)s, \
                found \(matches.count). Scheduled delays: \(delays).
                """,
                file: file,
                line: line
            )
            return
        }
        entries.remove(at: match.offset)
        match.element.work.perform()
    }

    /// Runs the live work item at `delay` where the manager legitimately
    /// re-arms that deadline: every superseded item is still recorded here, so
    /// `fire(_:)`'s "exactly one" rule would report the cancelled ones as
    /// ambiguity. Matching entries are dropped either way — a cancelled item
    /// could not have run.
    func fireLatest(
        _ delay: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let matches = entries.filter { abs($0.delay - delay) < 0.000_001 }
        entries.removeAll { abs($0.delay - delay) < 0.000_001 }
        guard let live = matches.last(where: { !$0.work.isCancelled }) else {
            XCTFail(
                """
                Expected a live work item scheduled at \(delay)s, found \
                \(matches.count) (all cancelled). Scheduled delays: \(delays).
                """,
                file: file,
                line: line
            )
            return
        }
        live.work.perform()
    }

    /// The work item scheduled at `delay`, left armed. Used to assert on the
    /// item itself — the manager's only cancellation token is the work item, so
    /// "this deadline was cancelled" is checked through `isCancelled`.
    func work(
        at delay: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> DispatchWorkItem? {
        let matches = entries.filter { abs($0.delay - delay) < 0.000_001 }
        guard matches.count == 1, let match = matches.first else {
            XCTFail(
                """
                Expected exactly one work item scheduled at \(delay)s, \
                found \(matches.count). Scheduled delays: \(delays).
                """,
                file: file,
                line: line
            )
            return nil
        }
        return match.work
    }

    func assertNothingScheduled(
        at delay: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let matches = entries.filter { abs($0.delay - delay) < 0.000_001 }
        XCTAssertTrue(
            matches.isEmpty,
            "Expected no work item at \(delay)s. Scheduled delays: \(delays).",
            file: file,
            line: line
        )
    }
}

/// Deadlines are deliberately distinct so `fire(_:)` can name one unambiguously.
private enum Deadline {
    static let discovery: TimeInterval = 9
    static let connection: TimeInterval = 5
    static let selectionWindow: TimeInterval = 1.5
    /// `reconnectBaseDelay * pow(2, attempt)` for the first and second attempt.
    static let firstReconnect: TimeInterval = 0.5
    static let secondReconnect: TimeInterval = 1
}

// MARK: - Tests

/// Fixture coverage for the BLE recovery rules on `OBDConnectionManager`:
/// the remembered-adapter fast path, its timeout fallback and cooling-off, the
/// system-connected recovery branch, preference erasure, the reconnect budget,
/// and radio-state gating.
///
/// Every manager here is built through the `OBDBluetoothCentral` seam with a
/// scripted central and a captured clock. That is not a convenience: building
/// the production central constructs a `CBCentralManager`, and touching
/// Bluetooth in the `swift test` host is a TCC kill. No test sleeps or waits —
/// events and timers are driven explicitly on the main thread.
///
/// `discoveredAdapters` is `private` on the manager, so scan bookkeeping is
/// asserted through its observable consequences instead: which identifier the
/// seam is asked to connect to, and the adapter name published on
/// `connectionState`.
final class OBDConnectionRecoveryTests: XCTestCase {
    private final class Fixture {
        let central: ScriptedBluetoothCentral
        let scheduler: CapturedTimerScheduler
        let defaults: UserDefaults
        let manager: OBDConnectionManager

        init(
            central: ScriptedBluetoothCentral,
            scheduler: CapturedTimerScheduler,
            defaults: UserDefaults,
            manager: OBDConnectionManager
        ) {
            self.central = central
            self.scheduler = scheduler
            self.defaults = defaults
            self.manager = manager
        }

        var storedPreference: String? {
            defaults.string(forKey: OBDConnectionManager.lastAdapterIdentifierKey)
        }
    }

    private func makeFixture(
        _ name: String = #function,
        rememberedAdapter: UUID? = nil,
        maximumReconnectAttempts: Int = 1
    ) -> Fixture {
        let suiteName = "OBDConnectionRecoveryTests."
            + name.filter { $0.isLetter || $0.isNumber }
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        if let rememberedAdapter {
            // Seeded through defaults rather than the initializer argument, so
            // "the stored preference survives" is a claim about the persisted
            // key and not about an in-memory value nothing ever wrote.
            defaults.set(
                rememberedAdapter.uuidString,
                forKey: OBDConnectionManager.lastAdapterIdentifierKey
            )
        }

        let central = ScriptedBluetoothCentral()
        let scheduler = CapturedTimerScheduler()
        let manager = OBDConnectionManager(
            discoveryTimeout: Deadline.discovery,
            connectionTimeout: Deadline.connection,
            selectionWindow: Deadline.selectionWindow,
            maximumReconnectAttempts: maximumReconnectAttempts,
            reconnectBaseDelay: Deadline.firstReconnect,
            defaults: defaults,
            makeBluetoothCentral: { central },
            scheduleAfter: { scheduler.record($0, $1) }
        )
        return Fixture(
            central: central,
            scheduler: scheduler,
            defaults: defaults,
            manager: manager
        )
    }

    private func adapter(
        _ name: String,
        id: UUID = UUID()
    ) -> BLEPeripheralIdentity {
        BLEPeripheralIdentity(identifier: id, name: name)
    }

    private func isError(_ status: ConnectionState.Status) -> Bool {
        if case .error = status { return true }
        return false
    }

    // MARK: 1. Remembered-adapter fast path

    /// The remembered adapter is reached through `retrievePeripherals`, which
    /// works even when the adapter is not advertising at that instant. Scanning
    /// first would cost the whole discovery window on every launch.
    @MainActor
    func testRememberedAdapterConnectsThroughRetrieveWithoutScanning() {
        let remembered = adapter("Carista Bluetooth")
        let fixture = makeFixture(rememberedAdapter: remembered.identifier)
        fixture.central.retrievablePeripherals = [remembered]

        fixture.manager.connect()

        XCTAssertEqual(
            fixture.central.retrievePeripheralCalls,
            [[remembered.identifier]]
        )
        XCTAssertEqual(fixture.central.connectCalls, [remembered.identifier])
        XCTAssertTrue(
            fixture.central.scanCalls.isEmpty,
            "The fast path must not spend a scan on an adapter iOS can hand back."
        )
        XCTAssertTrue(
            fixture.central.retrieveConnectedPeripheralCalls.isEmpty,
            "A successful fast path short-circuits the system-connected branch."
        )
        XCTAssertEqual(fixture.manager.connectionState.status, .connecting)
        XCTAssertEqual(
            fixture.manager.connectionState.adapterName,
            "Carista Bluetooth"
        )
        XCTAssertEqual(fixture.manager.activeConnectionType, .ble)
        // One attempt retires exactly one command transport.
        XCTAssertEqual(fixture.manager.transportGeneration, 1)
        XCTAssertFalse(fixture.manager.isConnected)
        // The only deadline armed is this attempt's connection timeout.
        XCTAssertEqual(fixture.scheduler.delays, [Deadline.connection])
    }

    // MARK: 2. Fast-path timeout falls back to a scan

    /// `retrievePeripherals` hands back the remembered adapter even when it is
    /// unpowered or out of range, so a timeout there proves nothing about which
    /// adapter belongs to this vehicle. The attempt must release the peripheral
    /// and run the scan it skipped — without failing the connection, without
    /// erasing the stored preference, and without spending reconnect budget.
    @MainActor
    func testRememberedFastPathTimeoutRescansAndKeepsThePreference() {
        let remembered = adapter("Carista Bluetooth")
        let fixture = makeFixture(
            rememberedAdapter: remembered.identifier,
            maximumReconnectAttempts: 1
        )
        fixture.central.retrievablePeripherals = [remembered]
        // The peripheral that just timed out is still reported as
        // system-connected, because `cancelPeripheralConnection` is async.
        fixture.central.systemConnectedPeripherals = [remembered]

        fixture.manager.connect()
        XCTAssertEqual(fixture.central.connectCalls, [remembered.identifier])

        fixture.scheduler.fire(Deadline.connection)

        XCTAssertEqual(
            fixture.central.cancelConnectionCalls,
            [remembered.identifier],
            "The unreachable peripheral has to be released before rescanning."
        )
        XCTAssertEqual(fixture.central.scanCalls.count, 1)
        XCTAssertNil(
            fixture.central.scanCalls.first ?? nil,
            "Clone adapters use vendor UART services, so the scan stays "
                + "unrestricted and names are filtered on discovery."
        )
        XCTAssertEqual(fixture.manager.connectionState.status, .scanning)
        XCTAssertNil(fixture.manager.activeConnectionType)
        XCTAssertFalse(
            isError(fixture.manager.connectionState.status),
            "A fast-path timeout is a fallback, not a connection failure."
        )
        XCTAssertEqual(
            fixture.storedPreference,
            remembered.identifier.uuidString,
            "An unreachable adapter was never disproven, so it stays preferred."
        )
        // The fallback's recovery pass saw the remembered peripheral among the
        // system-connected ones and still refused it; otherwise it would have
        // restarted the identical attempt it was created to skip.
        XCTAssertEqual(fixture.central.retrieveConnectedPeripheralCalls.count, 1)
        XCTAssertEqual(
            fixture.central.connectCalls,
            [remembered.identifier],
            "The excluded identifier must not be connected to a second time."
        )
        // Only the discovery deadline is armed: no reconnect was scheduled, so
        // the fallback consumed no budget.
        XCTAssertEqual(fixture.scheduler.delays, [Deadline.discovery])

        // Proof the budget is genuinely intact: the single permitted reconnect
        // is still available to the next real failure.
        fixture.scheduler.fire(Deadline.discovery)
        XCTAssertTrue(isError(fixture.manager.connectionState.status))
        XCTAssertEqual(fixture.scheduler.delays, [Deadline.firstReconnect])
    }

    // MARK: 3. Cooling-off after a fast-path timeout

    /// `retrievePeripherals` would keep returning the same unreachable
    /// peripheral, so an automatic reconnect that used the fast path again
    /// would burn a full connection timeout before it ever scanned. Only an
    /// explicit user connect re-enables it.
    @MainActor
    func testAutomaticReconnectSkipsTheFastPathUntilAnExplicitConnect() {
        let remembered = adapter("Carista Bluetooth")
        let fixture = makeFixture(
            rememberedAdapter: remembered.identifier,
            maximumReconnectAttempts: 1
        )
        fixture.central.retrievablePeripherals = [remembered]
        fixture.central.systemConnectedPeripherals = [remembered]

        fixture.manager.connect()
        fixture.scheduler.fire(Deadline.connection)
        XCTAssertEqual(fixture.central.retrievePeripheralCalls.count, 1)

        // Fail the fallback scan so the automatic reconnect runs.
        fixture.scheduler.fire(Deadline.discovery)
        fixture.scheduler.fire(Deadline.firstReconnect)

        XCTAssertEqual(
            fixture.central.retrievePeripheralCalls.count,
            1,
            "The reconnect must not pay another connection timeout on the same "
                + "unreachable peripheral."
        )
        XCTAssertEqual(
            fixture.central.connectCalls,
            [remembered.identifier],
            "Suppression also covers the system-connected recovery branch."
        )
        XCTAssertEqual(fixture.central.scanCalls.count, 2)
        XCTAssertEqual(fixture.manager.connectionState.status, .scanning)

        // An explicit connect is the user asserting the adapter is present.
        fixture.manager.connect()

        XCTAssertEqual(fixture.central.retrievePeripheralCalls.count, 2)
        XCTAssertEqual(
            fixture.central.connectCalls,
            [remembered.identifier, remembered.identifier]
        )
        XCTAssertEqual(fixture.central.scanCalls.count, 2)
        XCTAssertEqual(fixture.manager.connectionState.status, .connecting)
    }

    /// `startScanning()` is the other explicit entry point and clears the same
    /// suppression.
    @MainActor
    func testExplicitStartScanningAlsoReenablesTheFastPath() {
        let remembered = adapter("Carista Bluetooth")
        let fixture = makeFixture(
            rememberedAdapter: remembered.identifier,
            maximumReconnectAttempts: 1
        )
        fixture.central.retrievablePeripherals = [remembered]

        fixture.manager.connect()
        fixture.scheduler.fire(Deadline.connection)
        XCTAssertEqual(fixture.central.scanCalls.count, 1)

        fixture.manager.startScanning()

        XCTAssertEqual(fixture.central.retrievePeripheralCalls.count, 2)
        XCTAssertEqual(
            fixture.central.connectCalls,
            [remembered.identifier, remembered.identifier]
        )
        XCTAssertEqual(fixture.central.scanCalls.count, 1)
    }

    // MARK: 4. System-connected recovery branch

    /// While the remembered adapter is suppressed, the branch that connects to
    /// peripherals iOS already holds must skip it too — and must still pick a
    /// different adapter that qualifies. The remembered name sorts first here,
    /// so it would win the ranking if the exclusion regressed.
    @MainActor
    func testSuppressedFastPathExcludesRememberedFromConnectedRecovery() {
        let remembered = adapter("Carista Bluetooth")
        let other = adapter("OBDII Pro")
        let fixture = makeFixture(rememberedAdapter: remembered.identifier)
        fixture.central.retrievablePeripherals = [remembered]
        fixture.central.systemConnectedPeripherals = [remembered, other]

        fixture.manager.connect()
        fixture.scheduler.fire(Deadline.connection)

        XCTAssertEqual(
            fixture.central.connectCalls,
            [remembered.identifier, other.identifier]
        )
        XCTAssertEqual(fixture.manager.connectionState.status, .connecting)
        XCTAssertEqual(fixture.manager.connectionState.adapterName, "OBDII Pro")
        XCTAssertEqual(fixture.manager.activeConnectionType, .ble)
        XCTAssertTrue(
            fixture.central.scanCalls.isEmpty,
            "A usable system-connected adapter is taken before scanning."
        )
        XCTAssertEqual(
            fixture.storedPreference,
            remembered.identifier.uuidString,
            "Connecting to a different adapter does not disprove the stored one."
        )
        XCTAssertEqual(fixture.scheduler.delays, [Deadline.connection])
    }

    /// Reaching the remembered adapter through the system-connected branch is
    /// still a remembered connect. A timeout there has to route to the scan
    /// fallback; letting it reach `failConnection` would delete a stored
    /// adapter that was never disproven.
    @MainActor
    func testConnectedRecoveryToRememberedAdapterTimesOutIntoTheScanFallback() {
        let remembered = adapter("Carista Bluetooth")
        let fixture = makeFixture(rememberedAdapter: remembered.identifier)
        // iOS has no cached peripheral object, but it does hold a connection.
        fixture.central.retrievablePeripherals = []
        fixture.central.systemConnectedPeripherals = [remembered]

        fixture.manager.connect()
        XCTAssertEqual(fixture.central.retrievePeripheralCalls.count, 1)
        XCTAssertEqual(fixture.central.connectCalls, [remembered.identifier])
        XCTAssertEqual(fixture.manager.connectionState.status, .connecting)

        fixture.scheduler.fire(Deadline.connection)

        XCTAssertEqual(
            fixture.manager.connectionState.status,
            .scanning,
            "The timeout must fall back to a scan, not fail the connection."
        )
        XCTAssertEqual(
            fixture.storedPreference,
            remembered.identifier.uuidString,
            "A timeout on a remembered connect never erases the preference."
        )
        XCTAssertEqual(
            fixture.central.cancelConnectionCalls,
            [remembered.identifier]
        )
        XCTAssertEqual(fixture.central.scanCalls.count, 1)
        XCTAssertEqual(
            fixture.central.connectCalls,
            [remembered.identifier],
            "The fallback excludes the identifier it just released."
        )
        XCTAssertEqual(fixture.scheduler.delays, [Deadline.discovery])
    }

    // MARK: 5. Preference erasure

    /// `failConnection` erases the stored preference in exactly one case: the
    /// peripheral that failed is the preferred one and the failure arrived
    /// while the status was still `.connecting`. A scan-discovered preferred
    /// adapter is not tagged as a remembered connect, so its setup failure does
    /// take that path — it must not keep winning the pick over an adapter that
    /// works.
    @MainActor
    func testSetupFailureOnAScanDiscoveredPreferredAdapterErasesThePreference() {
        let preferred = adapter("OBDII Pro")
        let fixture = makeFixture(rememberedAdapter: preferred.identifier)
        // Neither recovery branch can produce it, so it has to be scanned for.
        fixture.central.retrievablePeripherals = []
        fixture.central.systemConnectedPeripherals = []

        fixture.manager.connect()
        XCTAssertEqual(fixture.central.scanCalls.count, 1)

        fixture.central.emit(.discovered(
            peripheral: preferred,
            advertisedLocalName: nil,
            rssi: -52,
            advertisedServiceUUIDs: []
        ))

        // The remembered adapter is unambiguous, so ranking has nothing left to
        // wait for: no selection window is armed.
        fixture.scheduler.assertNothingScheduled(at: Deadline.selectionWindow)
        XCTAssertEqual(fixture.central.connectCalls, [preferred.identifier])
        XCTAssertEqual(fixture.manager.connectionState.status, .connecting)
        XCTAssertEqual(fixture.manager.connectionState.signalStrength, -52)
        XCTAssertEqual(fixture.storedPreference, preferred.identifier.uuidString)

        fixture.central.emit(.failedToConnect(id: preferred.identifier, error: nil))

        XCTAssertNil(
            fixture.storedPreference,
            "An adapter that fails Bluetooth setup re-earns the preference by "
                + "completing setup again."
        )
        XCTAssertTrue(isError(fixture.manager.connectionState.status))
        XCTAssertNil(fixture.manager.activeConnectionType)
        XCTAssertFalse(fixture.manager.isConnected)
        XCTAssertEqual(
            fixture.central.cancelConnectionCalls,
            [preferred.identifier]
        )
    }

    /// The other half of the same rule: a failure on an established session
    /// keeps the preference. A stream hiccup says nothing about which adapter
    /// belongs to this vehicle. This also covers the write of the preference —
    /// it is `markTransportReady` that stores it.
    @MainActor
    func testDropOnAnEstablishedSessionKeepsThePreferenceItJustStored() {
        let running = adapter("OBDII Pro")
        let fixture = makeFixture(maximumReconnectAttempts: 1)
        XCTAssertNil(fixture.storedPreference)

        fixture.manager.connect()
        fixture.central.emit(.discovered(
            peripheral: running,
            advertisedLocalName: nil,
            rssi: -44,
            advertisedServiceUUIDs: []
        ))
        // No stored preference, so ranking holds the scan open first.
        fixture.scheduler.fire(Deadline.selectionWindow)
        XCTAssertEqual(fixture.central.connectCalls, [running.identifier])

        fixture.central.reportConnected(running.identifier)
        XCTAssertEqual(
            fixture.central.discoverEndpointCalls,
            [running.identifier]
        )

        fixture.central.emit(.characteristicsResolved(
            id: running.identifier,
            candidates: [
                BLECharacteristicCandidate(
                    serviceUUID: "FFE0",
                    characteristicUUID: "FFE1",
                    canWriteWithResponse: true,
                    canNotify: true
                ),
            ],
            discoveryError: nil
        ))
        XCTAssertEqual(
            fixture.central.enableNotificationCalls,
            [ScriptedBluetoothCentral.RecordedNotificationEnable(
                id: running.identifier,
                endpoint: BLEEndpoint(
                    serviceUUID: "FFE0",
                    characteristicUUID: "FFE1"
                )
            )]
        )

        fixture.central.reportNotificationsEnabled()

        XCTAssertEqual(fixture.manager.connectionState.status, .connected)
        XCTAssertTrue(fixture.manager.isConnected)
        XCTAssertEqual(
            fixture.storedPreference,
            running.identifier.uuidString,
            "Completing Bluetooth setup is what earns the preference."
        )
        let connectedGeneration = fixture.manager.transportGeneration

        fixture.central.emit(.disconnected(id: running.identifier, error: nil))

        XCTAssertEqual(
            fixture.storedPreference,
            running.identifier.uuidString,
            "Losing an established session does not disprove the adapter."
        )
        XCTAssertTrue(isError(fixture.manager.connectionState.status))
        XCTAssertFalse(fixture.manager.isConnected)
        XCTAssertNil(fixture.manager.activeConnectionType)
        XCTAssertGreaterThan(
            fixture.manager.transportGeneration,
            connectedGeneration,
            "The dead byte stream's generation has to be retired."
        )
    }

    // MARK: 6. Reconnect budget, foreground reconciliation, intentional disconnect

    @MainActor
    func testReconnectBudgetIsBoundedRestoredOnForegroundAndDroppedOnDisconnect() {
        let fixture = makeFixture(maximumReconnectAttempts: 1)

        fixture.manager.connect()
        XCTAssertEqual(fixture.central.scanCalls.count, 1)

        // A discovery timeout with nothing in range is a failure, and the first
        // (and only) attempt in the budget pays for the retry.
        fixture.scheduler.fire(Deadline.discovery)
        XCTAssertTrue(isError(fixture.manager.connectionState.status))
        XCTAssertEqual(fixture.scheduler.delays, [Deadline.firstReconnect])

        fixture.scheduler.fire(Deadline.firstReconnect)
        XCTAssertEqual(fixture.central.scanCalls.count, 2)
        XCTAssertEqual(fixture.manager.connectionState.status, .scanning)

        // Budget spent: the second failure must not schedule anything.
        fixture.scheduler.fire(Deadline.discovery)
        XCTAssertTrue(isError(fixture.manager.connectionState.status))
        XCTAssertTrue(
            fixture.scheduler.entries.isEmpty,
            "An exhausted budget must stop retrying. Scheduled delays: "
                + "\(fixture.scheduler.delays)."
        )
        fixture.scheduler.assertNothingScheduled(at: Deadline.secondReconnect)

        // Attempts spent while the app was suspended — where scanning barely
        // runs — must not leave the session permanently unable to retry.
        fixture.manager.reconcileConnectionOnForeground()
        XCTAssertEqual(fixture.central.scanCalls.count, 3)
        XCTAssertEqual(fixture.manager.connectionState.status, .scanning)

        fixture.scheduler.fire(Deadline.discovery)
        XCTAssertEqual(
            fixture.scheduler.delays,
            [Deadline.firstReconnect],
            "Foregrounding restores the budget, so a retry is eligible again."
        )

        // An intentional disconnect withdraws the session: the armed retry is
        // cancelled outright, and firing it anyway must not scan.
        let armedRetry = fixture.scheduler.work(at: Deadline.firstReconnect)
        XCTAssertEqual(armedRetry?.isCancelled, false)

        fixture.manager.disconnect()
        XCTAssertEqual(fixture.manager.connectionState, .disconnected)
        XCTAssertEqual(
            armedRetry?.isCancelled,
            true,
            "disconnect() must cancel the pending retry, not just decline it "
                + "when its deadline elapses."
        )

        fixture.scheduler.fire(Deadline.firstReconnect)
        XCTAssertEqual(
            fixture.central.scanCalls.count,
            3,
            "A cancelled reconnect must not scan after an intentional disconnect."
        )
        XCTAssertEqual(fixture.manager.connectionState, .disconnected)
        XCTAssertNil(fixture.manager.activeConnectionType)

        // Reconciliation must not resurrect a session the user ended either.
        fixture.manager.reconcileConnectionOnForeground()
        XCTAssertEqual(fixture.central.scanCalls.count, 3)
        XCTAssertEqual(fixture.manager.connectionState, .disconnected)
    }

    // MARK: 7. Radio-state gating

    /// `connect()` before CoreBluetooth has reported a state must not be lost:
    /// the intent is parked and the radio's own `poweredOn` report starts the
    /// scan.
    @MainActor
    func testConnectBeforeThePoweredOnReportParksTheScanUntilTheRadioIsReady() {
        let fixture = makeFixture()
        fixture.central.state = .unknown

        fixture.manager.connect()

        XCTAssertTrue(
            fixture.central.scanCalls.isEmpty,
            "Scanning an unknown-state central is a no-op that loses the intent."
        )
        XCTAssertEqual(fixture.manager.connectionState.status, .scanning)
        XCTAssertTrue(fixture.scheduler.entries.isEmpty)

        fixture.central.state = .poweredOn
        fixture.central.emit(.stateChanged(.poweredOn))

        XCTAssertEqual(fixture.central.scanCalls.count, 1)
        XCTAssertEqual(fixture.manager.connectionState.status, .scanning)
        XCTAssertEqual(fixture.scheduler.delays, [Deadline.discovery])

        // The parked request is consumed, so a later radio report is inert.
        fixture.central.emit(.stateChanged(.poweredOn))
        XCTAssertEqual(fixture.central.scanCalls.count, 1)
    }

    /// A powered-off radio surfaces an error but keeps the connection intent,
    /// so the user does not have to tap connect again after enabling Bluetooth.
    @MainActor
    func testConnectWhilePoweredOffKeepsTheIntentUntilTheRadioComesBack() {
        let fixture = makeFixture()
        fixture.central.state = .poweredOff

        fixture.manager.connect()

        XCTAssertTrue(fixture.central.scanCalls.isEmpty)
        XCTAssertTrue(isError(fixture.manager.connectionState.status))

        fixture.central.state = .poweredOn
        fixture.central.emit(.stateChanged(.poweredOn))

        XCTAssertEqual(fixture.central.scanCalls.count, 1)
        XCTAssertEqual(fixture.manager.connectionState.status, .scanning)
    }

    // MARK: Seam laziness

    /// Every test above depends on the fake being the only central this process
    /// ever builds. The manager therefore has to defer construction to the
    /// first radio use: an eagerly built `CBCentralManager` would be a TCC kill
    /// in the `swift test` host and a launch-time permission prompt in the app.
    @MainActor
    func testTheCentralIsBuiltOnlyOnTheFirstRadioUse() {
        let suiteName = "OBDConnectionRecoveryTests.laziness"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        var builds = 0
        let manager = OBDConnectionManager(
            maximumReconnectAttempts: 0,
            defaults: defaults,
            makeBluetoothCentral: {
                builds += 1
                return ScriptedBluetoothCentral()
            },
            scheduleAfter: { _, _ in }
        )

        XCTAssertEqual(builds, 0, "Initialization must not touch the radio.")

        manager.stopScanning()
        manager.disconnect()
        manager.retireAfterFatalInitializationFailure()
        XCTAssertEqual(
            builds,
            0,
            "Teardown of a session that never started must not touch the radio."
        )

        manager.connect()
        XCTAssertEqual(builds, 1)
        manager.connect()
        XCTAssertEqual(builds, 1, "The central is built once and reused.")
    }
}


// MARK: - Response-timeout quarantine

/// Fixture coverage for what a command's response deadline does now: it fails
/// that one command and quarantines the byte stream, instead of retiring the
/// whole BLE link because a single command was slow.
///
/// The quarantine has to carry the guarantee retirement used to provide — a
/// late response must never complete the next command — so these tests deliver
/// the stale bytes explicitly through the scripted central and assert which
/// command each response ends up completing.
///
/// `sendCommand` is `async` and posts its queue work back to the main queue, so
/// unlike the recovery tests above these run the main run loop to observe that
/// hop. No adapter deadline is ever waited on: every timer is still fired by
/// name through the captured scheduler, and each wait below is bounded and
/// followed by an assertion that only holds if the awaited work really landed.
final class OBDResponseQuarantineTests: XCTestCase {
    /// Distinct so `fire(_:)` can name one deadline unambiguously, and distinct
    /// from the two command deadlines below.
    private enum Deadline {
        static let discovery: TimeInterval = 9
        static let connection: TimeInterval = 5
        static let selectionWindow: TimeInterval = 1.5
        static let write: TimeInterval = 2.75
        static let drain: TimeInterval = 2.25
        static let settle: TimeInterval = 0.35
    }

    private static let slowRead = ELM327Command(
        raw: "0100",
        description: "Supported PIDs",
        timeout: 3.25
    )
    private static let followUp = ELM327Command(
        raw: "010C",
        description: "Engine RPM",
        timeout: 4.5
    )

    /// Records what the manager published, so "failed exactly once" is a claim
    /// about observed callbacks and not only about a continuation that would
    /// have trapped on a second resume.
    private final class RecordingDelegate: OBDConnectionManagerDelegate {
        private(set) var states: [ConnectionState] = []
        private(set) var errors: [Error] = []
        private(set) var responses: [(String, ELM327Command)] = []

        func connectionManager(
            _ manager: OBDConnectionManager,
            didUpdateState state: ConnectionState
        ) {
            states.append(state)
        }

        func connectionManager(
            _ manager: OBDConnectionManager,
            didReceiveError error: Error
        ) {
            errors.append(error)
        }

        func connectionManager(
            _ manager: OBDConnectionManager,
            didReceiveResponse response: String,
            for command: ELM327Command
        ) {
            responses.append((response, command))
        }
    }

    /// One in-flight `sendCommand`. The command task runs off the main thread,
    /// so its outcome is published under a lock.
    private final class CommandProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var outcome: Result<String, Error>?

        var hasStarted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return started
        }

        var result: Result<String, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return outcome
        }

        var value: String? {
            guard case .success(let response)? = result else { return nil }
            return response
        }

        var error: Error? {
            guard case .failure(let error)? = result else { return nil }
            return error
        }

        func markStarted() {
            lock.lock()
            started = true
            lock.unlock()
        }

        func finish(_ outcome: Result<String, Error>) {
            lock.lock()
            self.outcome = outcome
            lock.unlock()
        }
    }

    private final class Fixture {
        let central: ScriptedBluetoothCentral
        let scheduler: CapturedTimerScheduler
        let manager: OBDConnectionManager
        let delegate: RecordingDelegate
        let adapter: BLEPeripheralIdentity

        init(
            central: ScriptedBluetoothCentral,
            scheduler: CapturedTimerScheduler,
            manager: OBDConnectionManager,
            delegate: RecordingDelegate,
            adapter: BLEPeripheralIdentity
        ) {
            self.central = central
            self.scheduler = scheduler
            self.manager = manager
            self.delegate = delegate
            self.adapter = adapter
        }

        var written: [String] {
            central.writes.map { String(decoding: $0.data, as: UTF8.self) }
        }

        /// Mirrors `didWriteValueFor`: this profile writes with response, so the
        /// acknowledgement is what releases the next chunk and, once the last
        /// one lands, arms the response deadline.
        func acknowledgeWrite() {
            central.emit(.writeAcknowledged(
                id: adapter.identifier,
                endpoint: BLEEndpoint(
                    serviceUUID: "FFE0",
                    characteristicUUID: "FFE1"
                ),
                error: nil
            ))
        }

        func deliver(_ text: String) {
            central.emit(.receivedData(Data(text.utf8)))
        }
    }

    /// Builds a manager that has completed BLE setup and is ready for commands.
    @MainActor
    private func makeConnectedFixture(_ name: String = #function) -> Fixture {
        let suiteName = "OBDResponseQuarantineTests."
            + name.filter { $0.isLetter || $0.isNumber }
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }

        let central = ScriptedBluetoothCentral()
        let scheduler = CapturedTimerScheduler()
        let manager = OBDConnectionManager(
            discoveryTimeout: Deadline.discovery,
            connectionTimeout: Deadline.connection,
            selectionWindow: Deadline.selectionWindow,
            commandWriteTimeout: Deadline.write,
            responseDrainTimeout: Deadline.drain,
            responseDrainSettleWindow: Deadline.settle,
            maximumReconnectAttempts: 1,
            reconnectBaseDelay: 0.5,
            defaults: defaults,
            makeBluetoothCentral: { central },
            scheduleAfter: { scheduler.record($0, $1) }
        )
        let delegate = RecordingDelegate()
        manager.delegate = delegate

        let adapter = BLEPeripheralIdentity(identifier: UUID(), name: "OBDII Pro")
        manager.connect()
        central.emit(.discovered(
            peripheral: adapter,
            advertisedLocalName: nil,
            rssi: -44,
            advertisedServiceUUIDs: []
        ))
        scheduler.fire(Deadline.selectionWindow)
        central.reportConnected(adapter.identifier)
        central.emit(.characteristicsResolved(
            id: adapter.identifier,
            candidates: [
                BLECharacteristicCandidate(
                    serviceUUID: "FFE0",
                    characteristicUUID: "FFE1",
                    canWriteWithResponse: true,
                    canNotify: true
                ),
            ],
            discoveryError: nil
        ))
        central.reportNotificationsEnabled()
        XCTAssertEqual(manager.connectionState.status, .connected)

        return Fixture(
            central: central,
            scheduler: scheduler,
            manager: manager,
            delegate: delegate,
            adapter: adapter
        )
    }

    /// Runs the main run loop — where the manager's queue work lands — until
    /// `condition` holds, then reports if it never did.
    private func spin(
        until condition: () -> Bool,
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let limit = Date().addingTimeInterval(timeout)
        while !condition(), Date() < limit {
            RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.002)
            )
        }
        XCTAssertTrue(
            condition(),
            "Timed out waiting for \(description).",
            file: file,
            line: line
        )
    }

    /// Lets a command that has to *wait* reach the manager's queue: there is no
    /// observable effect to wait on precisely, because waiting is the point.
    /// Each test that uses this then proves the command really was queued —
    /// through the write that the drain releases synchronously, or through the
    /// failure that only a queued command can receive.
    private func spinUntilQueued(_ probe: CommandProbe) {
        spin(until: { probe.hasStarted }, "the command task to start")
        let limit = Date().addingTimeInterval(0.05)
        while Date() < limit {
            RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.002)
            )
        }
    }

    private func send(
        _ command: ELM327Command,
        on fixture: Fixture
    ) -> CommandProbe {
        let probe = CommandProbe()
        let manager = fixture.manager
        Task {
            probe.markStarted()
            do {
                probe.finish(.success(try await manager.sendCommand(command)))
            } catch {
                probe.finish(.failure(error))
            }
        }
        return probe
    }

    /// Sends a command and drives it to the point where its response deadline
    /// is armed: written, and every byte acknowledged by the peripheral.
    @MainActor
    private func startCommand(
        _ command: ELM327Command,
        on fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CommandProbe {
        let expectedWrites = fixture.central.writes.count + 1
        let probe = send(command, on: fixture)
        spin(
            until: { fixture.central.writes.count == expectedWrites },
            "\(command.raw) to be written",
            file: file,
            line: line
        )
        fixture.acknowledgeWrite()
        return probe
    }

    private func timedOutCommand(_ error: Error?) -> String? {
        guard case .commandTimedOut(let raw)? = error as? OBDError else {
            return nil
        }
        return raw
    }

    // MARK: 1. The deadline fails the command, not the transport

    @MainActor
    func testResponseDeadlineFailsOnlyTheInFlightCommand() {
        let fixture = makeConnectedFixture()
        let connectedGeneration = fixture.manager.transportGeneration
        let probe = startCommand(Self.slowRead, on: fixture)

        fixture.scheduler.fire(Self.slowRead.timeout)

        spin(until: { probe.result != nil }, "the caller to be resumed")
        XCTAssertEqual(
            timedOutCommand(probe.error),
            Self.slowRead.raw,
            "The timed-out command has to name itself in its failure."
        )
        XCTAssertEqual(
            fixture.delegate.errors.count,
            1,
            "The command may be failed exactly once."
        )
        XCTAssertEqual(
            fixture.manager.transportGeneration,
            connectedGeneration,
            "A slow command must not retire the byte stream."
        )
        XCTAssertTrue(fixture.manager.isConnected)
        XCTAssertEqual(fixture.manager.connectionState.status, .connected)
        XCTAssertEqual(fixture.manager.activeConnectionType, .ble)
        XCTAssertTrue(
            fixture.central.cancelConnectionCalls.isEmpty,
            "The peripheral is still the one this session is talking to."
        )
        // The quarantine is armed in its place, and cannot settle before the
        // adapter has produced anything.
        XCTAssertEqual(
            fixture.scheduler.work(at: Deadline.drain)?.isCancelled,
            false
        )
        fixture.scheduler.assertNothingScheduled(at: Deadline.settle)
    }

    // MARK: 2. Late bytes are discarded and cannot complete the next command

    @MainActor
    func testLateResponseIsDiscardedAndTheNextCommandGetsItsOwnResponse() {
        let fixture = makeConnectedFixture()
        let connectedGeneration = fixture.manager.transportGeneration
        let timedOut = startCommand(Self.slowRead, on: fixture)
        fixture.scheduler.fire(Self.slowRead.timeout)
        spin(until: { timedOut.result != nil }, "the slow command to fail")
        XCTAssertEqual(fixture.written, ["0100\r"])

        // The next command is enqueued while the stream is still quarantined.
        let next = send(Self.followUp, on: fixture)
        spinUntilQueued(next)
        XCTAssertEqual(
            fixture.written,
            ["0100\r"],
            "A queued command must not write while another command's bytes "
                + "still own the stream."
        )

        // The stale response finally arrives. Every byte of it belongs to the
        // command that already failed.
        fixture.deliver("41 00 BE 3F A8 13\r")
        XCTAssertNil(
            next.result,
            "A late response must not complete the next command."
        )
        XCTAssertEqual(fixture.written, ["0100\r"])
        fixture.scheduler.assertNothingScheduled(at: Deadline.settle)

        // Its prompt closes the stale response; the quiet window then has to
        // prove the adapter has stopped talking.
        fixture.deliver(">")
        XCTAssertEqual(
            fixture.scheduler.work(at: Deadline.settle)?.isCancelled,
            false
        )
        XCTAssertEqual(
            fixture.written,
            ["0100\r"],
            "The prompt alone does not release the queue."
        )

        fixture.scheduler.fire(Deadline.settle)

        // Synchronous with the settle: the queued command was waiting on the
        // drain, which is also what proves it was queued during the assertions
        // above rather than arriving late.
        XCTAssertEqual(
            fixture.written,
            ["0100\r", "010C\r"],
            "A settled stream belongs to the next command."
        )
        XCTAssertEqual(
            fixture.scheduler.work(at: Deadline.drain)?.isCancelled,
            true,
            "A completed drain must disarm its own fallback, so a late timer "
                + "cannot retire a transport that recovered."
        )
        fixture.acknowledgeWrite()
        fixture.deliver("41 0C 1A F8\r>")

        spin(until: { next.result != nil }, "the second command to complete")
        XCTAssertEqual(
            next.value,
            "41 0C 1A F8",
            "The second command must complete with its own response."
        )
        XCTAssertEqual(
            fixture.manager.transportGeneration,
            connectedGeneration,
            "Recovering from a slow command must not cost a reconnection."
        )
        XCTAssertEqual(fixture.delegate.errors.count, 1)
        XCTAssertEqual(fixture.delegate.responses.count, 1)
        XCTAssertEqual(fixture.delegate.responses.first?.1, Self.followUp)
    }

    /// The stale response and the adapter's own prompt both end in `>`, so the
    /// quiet window — not the first prompt — is what releases the queue. Bytes
    /// after a prompt reopen the drain.
    @MainActor
    func testAdapterChatterAfterThePromptRestartsTheQuietWindow() {
        let fixture = makeConnectedFixture()
        let timedOut = startCommand(Self.slowRead, on: fixture)
        fixture.scheduler.fire(Self.slowRead.timeout)
        spin(until: { timedOut.result != nil }, "the slow command to fail")

        let next = send(Self.followUp, on: fixture)
        spinUntilQueued(next)

        fixture.deliver("41 00 BE 3F A8 13\r>")
        let firstWindow = fixture.scheduler.work(at: Deadline.settle)
        XCTAssertEqual(firstWindow?.isCancelled, false)

        // A second buffered line was still on its way.
        fixture.deliver("SEARCHING...\r")
        XCTAssertEqual(
            firstWindow?.isCancelled,
            true,
            "New bytes after a prompt must restart the quiet window."
        )
        XCTAssertEqual(fixture.written, ["0100\r"])

        fixture.deliver("NO DATA\r>")
        fixture.scheduler.fireLatest(Deadline.settle)

        XCTAssertEqual(
            fixture.written,
            ["0100\r", "010C\r"],
            "Once the adapter is quiet the queue resumes."
        )
        fixture.acknowledgeWrite()
        fixture.deliver("41 0C 1A F8\r>")
        spin(until: { next.result != nil }, "the second command to complete")
        XCTAssertEqual(next.value, "41 0C 1A F8")
    }

    /// Serial bridges emit bare CR keepalives. If each one restarted the
    /// quiet window, a transport sitting at a clean prompt would walk into
    /// the drain deadline and be retired while demonstrably alive.
    @MainActor
    func testBlankKeepalivesWhileSettlingDoNotRestartTheQuietWindow() {
        let fixture = makeConnectedFixture()
        let timedOut = startCommand(Self.slowRead, on: fixture)
        fixture.scheduler.fire(Self.slowRead.timeout)
        spin(until: { timedOut.result != nil }, "the slow command to fail")

        let next = send(Self.followUp, on: fixture)
        spinUntilQueued(next)

        fixture.deliver("41 00 BE 3F A8 13\r>")
        let window = fixture.scheduler.work(at: Deadline.settle)
        XCTAssertEqual(window?.isCancelled, false)

        fixture.deliver("\r\n")
        fixture.deliver("\r")
        XCTAssertEqual(
            window?.isCancelled,
            false,
            "A whitespace-only chunk after the prompt is not renewed chatter."
        )

        fixture.scheduler.fireLatest(Deadline.settle)
        XCTAssertEqual(
            fixture.written,
            ["0100\r", "010C\r"],
            "The originally armed quiet window still closes the drain."
        )
        fixture.acknowledgeWrite()
        fixture.deliver("41 0C 1A F8\r>")
        spin(until: { next.result != nil }, "the second command to complete")
        XCTAssertEqual(next.value, "41 0C 1A F8")
    }

    // MARK: 3. A drain that never reaches a prompt falls back to retirement

    @MainActor
    func testDrainTimeoutRetiresTheTransportAndFailsPendingCommandsOnce() {
        let fixture = makeConnectedFixture()
        let connectedGeneration = fixture.manager.transportGeneration
        let timedOut = startCommand(Self.slowRead, on: fixture)
        fixture.scheduler.fire(Self.slowRead.timeout)
        spin(until: { timedOut.result != nil }, "the slow command to fail")
        XCTAssertEqual(timedOutCommand(timedOut.error), Self.slowRead.raw)

        let pending = send(Self.followUp, on: fixture)
        let alsoPending = send(.readVoltage, on: fixture)
        spinUntilQueued(pending)
        spinUntilQueued(alsoPending)
        // An adapter that answers with nothing framed is the case retirement
        // was always right for.
        fixture.deliver("\r\r")

        fixture.scheduler.fire(Deadline.drain)

        spin(
            until: { pending.result != nil && alsoPending.result != nil },
            "both queued commands to fail"
        )
        for probe in [pending, alsoPending] {
            XCTAssertEqual(
                timedOutCommand(probe.error),
                Self.slowRead.raw,
                "Retirement reports the command whose response never came — "
                    + "which only a queued command can be failed with."
            )
        }
        XCTAssertGreaterThan(
            fixture.manager.transportGeneration,
            connectedGeneration,
            "An adapter that never returns to a prompt has to be retired."
        )
        XCTAssertFalse(fixture.manager.isConnected)
        XCTAssertNil(fixture.manager.activeConnectionType)
        XCTAssertEqual(
            fixture.central.cancelConnectionCalls,
            [fixture.adapter.identifier]
        )
        if case .error = fixture.manager.connectionState.status {} else {
            XCTFail(
                "A retired transport must surface an error state, got "
                    + "\(fixture.manager.connectionState.status)."
            )
        }
        // Exactly two delegate errors: the timed-out command, then the
        // connection. Pending commands are failed through their continuations
        // alone — and each of those resumed exactly once above, since a second
        // resume of a checked continuation traps rather than being observed.
        XCTAssertEqual(fixture.delegate.errors.count, 2)
        XCTAssertTrue(fixture.delegate.responses.isEmpty)
    }

    // MARK: 4. Bytes that arrive after a completed drain are still inert

    @MainActor
    func testBytesArrivingWithNoCommandInFlightCannotSeedTheNextResponse() {
        let fixture = makeConnectedFixture()
        let timedOut = startCommand(Self.slowRead, on: fixture)
        fixture.scheduler.fire(Self.slowRead.timeout)
        spin(until: { timedOut.result != nil }, "the slow command to fail")

        fixture.deliver("41 00 BE 3F A8 13\r>")
        fixture.scheduler.fire(Deadline.settle)

        // Unsolicited chatter with an idle queue.
        fixture.deliver("41 00 DE AD BE EF\r>")

        let next = startCommand(Self.followUp, on: fixture)
        fixture.deliver("41 0C 1A F8\r>")

        spin(until: { next.result != nil }, "the next command to complete")
        XCTAssertEqual(
            next.value,
            "41 0C 1A F8",
            "Bytes received with no command in flight are not response state."
        )
    }
}
