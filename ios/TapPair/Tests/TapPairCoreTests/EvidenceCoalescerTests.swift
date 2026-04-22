// EvidenceCoalescerTests.swift
//
// Verifies that:
//   - multiple observations within the window become a single flush
//   - explicit reset() drops without sending
//   - explicit flush() forces an immediate send

import XCTest
@testable import TapPairCore

final class EvidenceCoalescerTests: XCTestCase {

    func testCoalescesMultipleObservationsIntoOneFlush() async throws {
        actor Box { var batches: [[EvidenceChannel]] = []; func add(_ b: [EvidenceChannel]) { batches.append(b) }; func get() -> [[EvidenceChannel]] { batches } }
        let box = Box()
        let coalescer = EvidenceCoalescer(windowMs: 80) { batch in
            await box.add(batch)
        }
        await coalescer.ingest(.init(kind: .ble, observedAtMs: 0, peerToken: "t"))
        await coalescer.ingest(.init(kind: .bump, observedAtMs: 5))
        await coalescer.ingest(.init(kind: .uwb, observedAtMs: 10, peerToken: "t", distanceM: 0.05))

        try await Task.sleep(nanoseconds: 200_000_000) // > windowMs

        let batches = await box.get()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.count, 3)
    }

    func testExplicitFlushFiresImmediately() async throws {
        actor Box { var count = 0; func bump() { count += 1 }; func get() -> Int { count } }
        let box = Box()
        let coalescer = EvidenceCoalescer(windowMs: 5_000) { _ in await box.bump() }
        await coalescer.ingest(.init(kind: .ble, observedAtMs: 0, peerToken: "t"))
        await coalescer.flush()
        let n = await box.get()
        XCTAssertEqual(n, 1)
    }

    func testResetDropsBuffer() async throws {
        actor Box { var fired = false; func mark() { fired = true }; func get() -> Bool { fired } }
        let box = Box()
        let coalescer = EvidenceCoalescer(windowMs: 50) { _ in await box.mark() }
        await coalescer.ingest(.init(kind: .ble, observedAtMs: 0, peerToken: "t"))
        await coalescer.reset()
        try await Task.sleep(nanoseconds: 150_000_000)
        let fired = await box.get()
        XCTAssertFalse(fired)
    }
}
