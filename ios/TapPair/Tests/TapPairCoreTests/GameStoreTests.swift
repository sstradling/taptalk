// GameStoreTests.swift
//
// Pure-function reducer tests. Each test is "given state + message, expect
// new state has X". No actor instantiation needed.

import XCTest
@testable import TapPairCore

final class GameStoreTests: XCTestCase {

    func testHelloAckUpdatesConnectionAndClockSkew() {
        var s = GameState()
        s.connection = .connecting
        let msg = ServerMessage.helloAck(sessionId: "sess-1", serverTimeMs: 1_000_000_000_000)
        let out = GameStore.reduce(s, msg, nowMs: 1_000_000_000_500)
        if case .helloed(let id) = out.connection {
            XCTAssertEqual(id, "sess-1")
        } else {
            XCTFail("expected helloed")
        }
        XCTAssertEqual(out.serverClockSkewMs, -500)
    }

    func testRoomStateOverrides() {
        let s = GameState()
        let rs = ServerMessage.RoomState(
            roomCode: "BQRT", mode: .poison_apple, phase: .registering,
            hostPlayerId: "p1", players: [], currentRoundId: 3,
            settings: .init(roundSeconds: 45, maxPlayers: 8)
        )
        let out = GameStore.reduce(s, .roomState(rs), nowMs: 0)
        XCTAssertEqual(out.room?.roomCode, "BQRT")
        XCTAssertEqual(out.room?.mode, .poison_apple)
        XCTAssertEqual(out.room?.settings.roundSeconds, 45)
    }

    func testRoundStartedClearsPerRoundTransients() {
        var s = GameState()
        s.lastConfirmation = .init(roundId: 1, partnerDisplayName: "X", elapsedMs: 1000)
        s.lastResolution = .init(roundId: 1, results: [], nextPhase: .between_rounds)
        s.lastAssignment = .init(roundId: 1, role: .pair, cue: .init(cueId: "c", kind: .text, modality: [.text], payload: [:], complementHint: "h"), findDeadlineMs: 0)
        let out = GameStore.reduce(s, .roundStarted(roundId: 2, registerDeadlineMs: 1234), nowMs: 0)
        XCTAssertNil(out.lastAssignment)
        XCTAssertNil(out.lastConfirmation)
        XCTAssertNil(out.lastResolution)
    }

    func testPairConfirmedSetsConfirmation() {
        let s = GameState()
        let out = GameStore.reduce(s, .pairConfirmed(roundId: 5, partnerPlayerId: "p2", partnerDisplayName: "Bob", elapsedMs: 2200), nowMs: 0)
        XCTAssertEqual(out.lastConfirmation?.roundId, 5)
        XCTAssertEqual(out.lastConfirmation?.partnerDisplayName, "Bob")
        XCTAssertEqual(out.lastConfirmation?.elapsedMs, 2200)
    }

    func testPairRejectedSetsErrorMessage() {
        let s = GameState()
        let out = GameStore.reduce(s, .pairRejected(roundId: 5, reason: .wrong_partner), nowMs: 0)
        XCTAssertNotNil(out.lastError)
    }

    func testErrorIsSurfacedToUI() {
        let s = GameState()
        let out = GameStore.reduce(s, .error(code: .bad_room_code, message: "no such room"), nowMs: 0)
        XCTAssertEqual(out.lastError, "no such room")
    }
}
