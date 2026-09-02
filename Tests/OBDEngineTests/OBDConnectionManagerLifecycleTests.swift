import Foundation
import XCTest

#if SWIFT_PACKAGE
@testable import OBDEngine
#else
#endif

/// These tests may construct an `OBDConnectionManager` under macOS
/// `swift test` only because the manager creates its `CBCentralManager`
/// lazily on first radio use, and every path exercised here — retirement and
/// intentional disconnect with no live transport — stays off the radio. Any
/// test that would scan, connect, or reconcile must move to the simulator app
/// target: touching Bluetooth in the `swift test` host is a TCC kill (no
/// `NSBluetoothAlwaysUsageDescription`).
final class OBDConnectionManagerLifecycleTests: XCTestCase {
    @MainActor
    func testFatalInitializationRetirementIsNoOpWithoutLiveTransport() {
        let defaultsName = "OBDConnectionManagerLifecycleTests.noop"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        let manager = OBDConnectionManager(
            maximumReconnectAttempts: 0,
            defaults: defaults
        )

        manager.retireAfterFatalInitializationFailure()

        XCTAssertEqual(manager.connectionState, .disconnected)
        XCTAssertEqual(manager.transportGeneration, 0)
        XCTAssertNil(manager.activeConnectionType)
        defaults.removePersistentDomain(forName: defaultsName)
    }

    @MainActor
    func testGenerationGuardedRetirementIgnoresStaleCaller() {
        let defaultsName = "OBDConnectionManagerLifecycleTests.staleRetirement"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        let manager = OBDConnectionManager(
            maximumReconnectAttempts: 0,
            defaults: defaults
        )
        let generation = manager.transportGeneration

        manager.retireAfterFatalInitializationFailure(
            expectedTransportGeneration: generation &+ 1
        )

        XCTAssertEqual(manager.transportGeneration, generation)
        XCTAssertEqual(manager.connectionState, .disconnected)
        XCTAssertFalse(manager.isConnected)
        defaults.removePersistentDomain(forName: defaultsName)
    }

    @MainActor
    func testIntentionalDisconnectInvalidatesGenerationToken() {
        let defaultsName = "OBDConnectionManagerLifecycleTests.disconnect"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        let manager = OBDConnectionManager(
            maximumReconnectAttempts: 0,
            defaults: defaults
        )
        let originalGeneration = manager.transportGeneration

        manager.disconnect()

        XCTAssertGreaterThan(manager.transportGeneration, originalGeneration)
        XCTAssertEqual(manager.connectionState, .disconnected)
        XCTAssertNil(manager.activeConnectionType)
        defaults.removePersistentDomain(forName: defaultsName)
    }
}
