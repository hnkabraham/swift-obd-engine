import XCTest

#if SWIFT_PACKAGE
@testable import OBDEngine
#else
#endif

final class AdapterSelectionRankingTests: XCTestCase {
    private let ownAdapter = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let neighborAdapter = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let bayAdapter = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    func testStrongestSignalWinsWithoutARememberedAdapter() throws {
        let selection = try XCTUnwrap(AdapterCandidateRanking.best(of: [
            candidate(neighborAdapter, "OBDII", rssi: -80, order: 1),
            candidate(ownAdapter, "Vgate iCar Pro", rssi: -47, order: 2),
            candidate(bayAdapter, "OBDLink CX", rssi: -63, order: 3),
        ]))

        XCTAssertEqual(selection.identifier, ownAdapter)
    }

    func testRememberedAdapterWinsOverAStrongerNeighbor() throws {
        let candidates = [
            candidate(neighborAdapter, "OBDII", rssi: -38, order: 1),
            candidate(ownAdapter, "Vgate iCar Pro", rssi: -84, order: 2),
        ]

        let selection = try XCTUnwrap(AdapterCandidateRanking.best(
            of: candidates,
            preferredIdentifier: ownAdapter
        ))

        XCTAssertEqual(selection.identifier, ownAdapter)
        XCTAssertEqual(
            AdapterCandidateRanking.best(of: candidates)?.identifier,
            neighborAdapter
        )
    }

    func testRememberedAdapterOutOfRangeFallsBackToStrongestSignal() throws {
        let selection = try XCTUnwrap(AdapterCandidateRanking.best(
            of: [
                candidate(neighborAdapter, "OBDII", rssi: -71, order: 1),
                candidate(bayAdapter, "ScanTool", rssi: -55, order: 2),
            ],
            preferredIdentifier: ownAdapter
        ))

        XCTAssertEqual(selection.identifier, bayAdapter)
    }

    func testSelectionIsIndependentOfAdvertisementArrivalOrder() {
        // Discovery order is a dictionary walk away from being arbitrary, so
        // every arrival permutation has to produce the same adapter.
        let candidates = [
            candidate(neighborAdapter, "OBDII", rssi: -80, order: 1),
            candidate(ownAdapter, "Vgate iCar Pro", rssi: -47, order: 2),
            candidate(bayAdapter, "OBDLink CX", rssi: -63, order: 3),
        ]

        for ordering in permutations(candidates) {
            XCTAssertEqual(
                AdapterCandidateRanking.best(of: ordering)?.identifier,
                ownAdapter
            )
            XCTAssertEqual(
                AdapterCandidateRanking.ranked(ordering).map(\.identifier),
                [ownAdapter, bayAdapter, neighborAdapter]
            )
        }
    }

    func testEqualSignalStrengthIsBrokenByDiscoveryOrder() {
        let candidates = [
            candidate(bayAdapter, "OBDLink CX", rssi: -60, order: 4),
            candidate(ownAdapter, "Vgate iCar Pro", rssi: -60, order: 2),
        ]

        for ordering in permutations(candidates) {
            XCTAssertEqual(
                AdapterCandidateRanking.best(of: ordering)?.identifier,
                ownAdapter
            )
        }
    }

    func testUnavailableSignalReadingsRankBelowEveryMeasurement() {
        // CoreBluetooth uses 127 for "no reading"; treating it as a strong
        // signal would make the least-known adapter the automatic winner.
        let unavailable = candidate(neighborAdapter, "OBDII", rssi: 127, order: 1)
        let weak = candidate(ownAdapter, "Vgate iCar Pro", rssi: -97, order: 2)

        XCTAssertFalse(unavailable.hasUsableSignalStrength)
        XCTAssertTrue(weak.hasUsableSignalStrength)
        XCTAssertEqual(
            AdapterCandidateRanking.best(of: [unavailable, weak])?.identifier,
            ownAdapter
        )
        XCTAssertEqual(
            AdapterCandidateRanking.best(of: [weak, unavailable])?.identifier,
            ownAdapter
        )
    }

    func testUnusableReadingsStillProduceADeterministicWinner() {
        let candidates = [
            candidate(neighborAdapter, "OBDII", rssi: 127, order: 2),
            candidate(ownAdapter, "Vgate iCar Pro", rssi: 0, order: 1),
        ]

        for ordering in permutations(candidates) {
            XCTAssertEqual(
                AdapterCandidateRanking.best(of: ordering)?.identifier,
                ownAdapter
            )
        }
    }

    func testRankedKeepsEveryCandidate() {
        let candidates = [
            candidate(neighborAdapter, "OBDII", rssi: -80, order: 1),
            candidate(ownAdapter, "Vgate iCar Pro", rssi: -47, order: 2),
            candidate(bayAdapter, "OBDLink CX", rssi: -63, order: 3),
        ]

        let ranked = AdapterCandidateRanking.ranked(
            candidates,
            preferredIdentifier: bayAdapter
        )

        XCTAssertEqual(ranked.count, candidates.count)
        XCTAssertEqual(Set(ranked.map(\.identifier)), Set(candidates.map(\.identifier)))
        XCTAssertEqual(ranked.map(\.identifier), [bayAdapter, ownAdapter, neighborAdapter])
    }

    func testNoCandidatesYieldsNoSelection() {
        XCTAssertNil(AdapterCandidateRanking.best(of: []))
        XCTAssertNil(AdapterCandidateRanking.best(of: [], preferredIdentifier: ownAdapter))
    }

    func testAdapterNameMatchingIgnoresCaseAndRejectsUnrelatedDevices() {
        for name in ["OBDII", "obdlink cx", "Vgate iCar Pro", "VEEPEAK", "V-Link"] {
            XCTAssertTrue(
                AdapterCandidateRanking.matchesKnownAdapterName(name),
                "\(name) should be treated as an adapter"
            )
        }

        for name in ["", "AirPods Pro", "Tire Sensor", "Living Room TV"] {
            XCTAssertFalse(
                AdapterCandidateRanking.matchesKnownAdapterName(name),
                "\(name) should not be treated as an adapter"
            )
        }
    }

    private func candidate(
        _ identifier: UUID,
        _ name: String,
        rssi: Int,
        order: Int
    ) -> DiscoveredAdapterCandidate {
        DiscoveredAdapterCandidate(
            identifier: identifier,
            name: name,
            signalStrength: rssi,
            discoveryOrder: order
        )
    }

    private func permutations<Element>(_ elements: [Element]) -> [[Element]] {
        guard elements.count > 1 else { return [elements] }
        return elements.indices.flatMap { index -> [[Element]] in
            var remaining = elements
            let element = remaining.remove(at: index)
            return permutations(remaining).map { [element] + $0 }
        }
    }
}
