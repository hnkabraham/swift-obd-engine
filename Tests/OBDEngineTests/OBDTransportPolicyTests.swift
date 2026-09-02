import Foundation
import XCTest

#if SWIFT_PACKAGE
@testable import OBDEngine
#else
#endif

final class OBDTransportPolicyTests: XCTestCase {
    func testResponseDeadlineCannotRunUntilFinalByteIsAccepted() {
        var state = OBDCommandDeadlineState()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.responseDeadlineCanRun)

        state.beginWrite()
        XCTAssertTrue(state.isWriting)
        XCTAssertFalse(state.responseDeadlineCanRun)

        XCTAssertTrue(state.markAllBytesAccepted())
        XCTAssertFalse(state.isWriting)
        XCTAssertTrue(state.responseDeadlineCanRun)
        XCTAssertFalse(state.transactionCanComplete)

        state.markResponseReceived()
        XCTAssertFalse(state.responseDeadlineCanRun)
        XCTAssertTrue(state.transactionCanComplete)
        XCTAssertFalse(state.markAllBytesAccepted())

        state.reset()
        XCTAssertEqual(state.phase, .idle)
    }

    func testEarlyResponseWaitsForFinalWriteAcknowledgement() {
        var state = OBDCommandDeadlineState()
        state.beginWrite()

        state.markResponseReceived()

        XCTAssertTrue(state.isWriting)
        XCTAssertFalse(state.responseDeadlineCanRun)
        XCTAssertFalse(state.transactionCanComplete)

        XCTAssertTrue(state.markAllBytesAccepted())
        XCTAssertFalse(state.responseDeadlineCanRun)
        XCTAssertTrue(state.transactionCanComplete)
    }

    func testAccessoryProtocolMatchReturnsAccessoryDeclaredCasing() {
        XCTAssertEqual(
            OBDTransportPolicy.matchingAccessoryProtocol(
                from: ["other.protocol", "COM.OBDLINK"]
            ),
            "COM.OBDLINK"
        )
        XCTAssertNil(
            OBDTransportPolicy.matchingAccessoryProtocol(
                from: ["com.example.serial"]
            )
        )
    }

    func testMultipleCompatibleMFiAccessoriesFailClosed() {
        XCTAssertFalse(
            OBDTransportPolicy.mfiAccessorySelectionIsAmbiguous(
                compatibleAccessoryCount: 0
            )
        )
        XCTAssertFalse(
            OBDTransportPolicy.mfiAccessorySelectionIsAmbiguous(
                compatibleAccessoryCount: 1
            )
        )
        XCTAssertTrue(
            OBDTransportPolicy.mfiAccessorySelectionIsAmbiguous(
                compatibleAccessoryCount: 2
            )
        )
    }

    func testAccessoryRequiresTwoUsableStreams() {
        for usable in [
            Stream.Status.opening,
            .open,
            .reading,
            .writing,
        ] {
            XCTAssertTrue(OBDTransportPolicy.accessoryStreamsAreUsable(
                input: usable,
                output: .open
            ))
        }

        for unusable in [
            Stream.Status.notOpen,
            .atEnd,
            .closed,
            .error,
        ] {
            XCTAssertFalse(OBDTransportPolicy.accessoryStreamsAreUsable(
                input: .open,
                output: unusable
            ))
        }
    }

    func testAccessoryPartialWritesAdvanceWithoutDroppingRemainder() {
        XCTAssertEqual(
            OBDTransportPolicy.accessoryWriteProgress(
                totalBytes: 8,
                currentOffset: 0,
                acceptedBytes: 3
            ),
            3
        )
        XCTAssertEqual(
            OBDTransportPolicy.accessoryWriteProgress(
                totalBytes: 8,
                currentOffset: 3,
                acceptedBytes: 5
            ),
            8
        )
        XCTAssertTrue(OBDTransportPolicy.accessoryWriteCompleted(
            totalBytes: 8,
            offset: 8
        ))
        XCTAssertNil(OBDTransportPolicy.accessoryWriteProgress(
            totalBytes: 8,
            currentOffset: 7,
            acceptedBytes: 2
        ))
    }

    func testAccessoryZeroByteWriteIsBackpressureAndNegativeReturnIsRejected() {
        // A zero-byte `Stream.write` is backpressure: the offset must not move
        // and the command must not be treated as delivered, so the caller parks
        // the remainder for the next `.hasSpaceAvailable` event.
        XCTAssertEqual(
            OBDTransportPolicy.accessoryWriteProgress(
                totalBytes: 8,
                currentOffset: 3,
                acceptedBytes: 0
            ),
            3
        )
        XCTAssertFalse(OBDTransportPolicy.accessoryWriteCompleted(
            totalBytes: 8,
            offset: 3
        ))
        // A negative return is a stream error or an unbindable buffer, never a
        // write offset.
        XCTAssertNil(OBDTransportPolicy.accessoryWriteProgress(
            totalBytes: 8,
            currentOffset: 3,
            acceptedBytes: -1
        ))
        XCTAssertNil(OBDTransportPolicy.accessoryWriteProgress(
            totalBytes: 8,
            currentOffset: 0,
            acceptedBytes: -8
        ))
    }

    func testGenerationGateRejectsCallbacksFromRetiredTransport() {
        XCTAssertTrue(OBDTransportPolicy.generationIsCurrent(
            expected: 41,
            active: 41
        ))
        XCTAssertFalse(OBDTransportPolicy.generationIsCurrent(
            expected: 41,
            active: 42
        ))
    }

    func testPublishedConnectedStateReconcilesAgainstTransportUsability() {
        XCTAssertTrue(OBDTransportPolicy.publishedConnectionNeedsRediscovery(
            publishedConnected: true,
            transportIsUsable: false
        ))
        XCTAssertFalse(OBDTransportPolicy.publishedConnectionNeedsRediscovery(
            publishedConnected: true,
            transportIsUsable: true
        ))
        XCTAssertTrue(OBDTransportPolicy.healthyConnectionShouldBeRepublished(
            publishedConnected: true,
            transportIsUsable: true
        ))
        XCTAssertFalse(OBDTransportPolicy.healthyConnectionShouldBeRepublished(
            publishedConnected: false,
            transportIsUsable: true
        ))
    }

    func testFatalRetirementRequiresLiveMatchingGeneration() {
        XCTAssertTrue(OBDTransportPolicy.fatalRetirementIsEligible(
            expectedGeneration: 12,
            activeGeneration: 12,
            hasLiveTransport: true
        ))
        XCTAssertFalse(OBDTransportPolicy.fatalRetirementIsEligible(
            expectedGeneration: 12,
            activeGeneration: 13,
            hasLiveTransport: true
        ))
        XCTAssertFalse(OBDTransportPolicy.fatalRetirementIsEligible(
            expectedGeneration: 12,
            activeGeneration: 12,
            hasLiveTransport: false
        ))
    }

    func testReconnectBudgetStaysBoundedUntilVehicleCommunicationIsConfirmed() {
        var tracker = OBDReconnectTracker(maximumAttempts: 3)

        XCTAssertEqual(tracker.consumeAttemptIfEligible(
            automaticReconnectEnabled: true,
            wasIntentionalDisconnect: false
        ), 0)
        // Merely reopening the physical adapter does not reset the tracker.
        XCTAssertEqual(tracker.consumeAttemptIfEligible(
            automaticReconnectEnabled: true,
            wasIntentionalDisconnect: false
        ), 1)
        XCTAssertEqual(tracker.consumeAttemptIfEligible(
            automaticReconnectEnabled: true,
            wasIntentionalDisconnect: false
        ), 2)
        XCTAssertNil(tracker.consumeAttemptIfEligible(
            automaticReconnectEnabled: true,
            wasIntentionalDisconnect: false
        ))

        XCTAssertFalse(tracker.confirmVehicleCommunication(
            expectedGeneration: 40,
            activeGeneration: 41
        ))
        XCTAssertEqual(tracker.attempts, 3)
        XCTAssertTrue(tracker.confirmVehicleCommunication(
            expectedGeneration: 41,
            activeGeneration: 41
        ))
        XCTAssertEqual(tracker.attempts, 0)
        XCTAssertEqual(tracker.consumeAttemptIfEligible(
            automaticReconnectEnabled: true,
            wasIntentionalDisconnect: false
        ), 0)
    }

    func testExplicitReconnectTrackerResetRestoresFullBudget() {
        var tracker = OBDReconnectTracker(maximumAttempts: 2)

        XCTAssertEqual(tracker.consumeAttemptIfEligible(
            automaticReconnectEnabled: true,
            wasIntentionalDisconnect: false
        ), 0)
        XCTAssertEqual(tracker.consumeAttemptIfEligible(
            automaticReconnectEnabled: true,
            wasIntentionalDisconnect: false
        ), 1)
        XCTAssertNil(tracker.consumeAttemptIfEligible(
            automaticReconnectEnabled: true,
            wasIntentionalDisconnect: false
        ))

        tracker.reset()

        XCTAssertEqual(tracker.attempts, 0)
        XCTAssertEqual(tracker.consumeAttemptIfEligible(
            automaticReconnectEnabled: true,
            wasIntentionalDisconnect: false
        ), 0)
    }

    func testReconnectHonorsIntentAndBound() {
        XCTAssertTrue(OBDTransportPolicy.shouldReconnect(
            automaticReconnectEnabled: true,
            wasIntentionalDisconnect: false,
            attempt: 0,
            maximumAttempts: 3
        ))
        XCTAssertFalse(OBDTransportPolicy.shouldReconnect(
            automaticReconnectEnabled: true,
            wasIntentionalDisconnect: true,
            attempt: 0,
            maximumAttempts: 3
        ))
        XCTAssertFalse(OBDTransportPolicy.shouldReconnect(
            automaticReconnectEnabled: false,
            wasIntentionalDisconnect: false,
            attempt: 0,
            maximumAttempts: 3
        ))
        XCTAssertFalse(OBDTransportPolicy.shouldReconnect(
            automaticReconnectEnabled: true,
            wasIntentionalDisconnect: false,
            attempt: 3,
            maximumAttempts: 3
        ))
    }

    func testReconnectBackoffIsBounded() {
        XCTAssertEqual(
            OBDTransportPolicy.reconnectDelay(
                attempt: 0,
                baseDelay: 0.5
            ),
            0.5
        )
        XCTAssertEqual(
            OBDTransportPolicy.reconnectDelay(
                attempt: 2,
                baseDelay: 0.5
            ),
            2
        )
        XCTAssertEqual(
            OBDTransportPolicy.reconnectDelay(
                attempt: 8,
                baseDelay: 0.5
            ),
            4
        )
    }
}
