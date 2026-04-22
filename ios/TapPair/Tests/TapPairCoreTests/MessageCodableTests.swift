// MessageCodableTests.swift
//
// Round-trip every protocol message through Codable. Catches drift between
// `spec/PROTOCOL.md` and the iOS Codable models. Where reasonable, the JSON
// fixtures here should match the server's zod-validated shape exactly.

import XCTest
@testable import TapPairCore

final class MessageCodableTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    func testHelloEncodesExpectedShape() throws {
        let msg = ClientMessage.hello(.init(
            deviceId: "00000000-0000-0000-0000-000000000001",
            displayName: "Alice",
            appVersion: "0.1",
            platform: .ios,
            osVersion: "17.5",
            capabilities: [.ble, .bump]
        ))
        let data = try encoder.encode(msg)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"type\":\"hello\""))
        XCTAssertTrue(json.contains("\"v\":1"))
        XCTAssertTrue(json.contains("\"capabilities\":[\"ble\",\"bump\"]"))
    }

    func testPairEvidenceRoundTrip() throws {
        let msg = ClientMessage.pairEvidence(.init(
            roundId: 42,
            phase: "confirm",
            selfToken: "abcd",
            channels: [
                .init(kind: .uwb, observedAtMs: 1000, peerToken: "efgh", distanceM: 0.05),
                .init(kind: .ble, observedAtMs: 999,  peerToken: "efgh", rssiDbm: -42),
                .init(kind: .bump, observedAtMs: 1001, magnitudeG: 7.2, tHitMs: 1001),
            ]
        ))
        let data = try encoder.encode(msg)
        let back = try decoder.decode(ClientMessage.self, from: data)
        XCTAssertEqual(msg, back)
    }

    func testServerRoomStateDecodes() throws {
        let json = """
        {
          "type": "room_state",
          "v": 1,
          "roomCode": "BQRT",
          "mode": "musical_chairs",
          "phase": "lobby",
          "hostPlayerId": "p1",
          "players": [
            {"playerId":"p1","displayName":"A","ready":false,"alive":true,"score":0,"connected":true,"capabilities":["ble","bump"]}
          ],
          "currentRoundId": 0,
          "settings": {"roundSeconds":60,"maxPlayers":16}
        }
        """.data(using: .utf8)!
        let msg = try decoder.decode(ServerMessage.self, from: json)
        guard case .roomState(let rs) = msg else { return XCTFail("wrong case") }
        XCTAssertEqual(rs.roomCode, "BQRT")
        XCTAssertEqual(rs.mode, .musical_chairs)
        XCTAssertEqual(rs.phase, .lobby)
        XCTAssertEqual(rs.players.count, 1)
        XCTAssertEqual(rs.players.first?.displayName, "A")
    }

    func testServerPairAssignedDecodes() throws {
        let json = """
        {
          "type": "pair_assigned",
          "v": 1,
          "roundId": 7,
          "role": "pair",
          "cue": {
            "cueId": "animal_dog_cat",
            "kind": "text",
            "modality": ["text","audio"],
            "payload": {"text":"Bark like a dog"},
            "complementHint": "Find the cat."
          },
          "findDeadlineMs": 1700000000000
        }
        """.data(using: .utf8)!
        let msg = try decoder.decode(ServerMessage.self, from: json)
        guard case .pairAssigned(let pa) = msg else { return XCTFail("wrong case") }
        XCTAssertEqual(pa.roundId, 7)
        XCTAssertEqual(pa.role, .pair)
        XCTAssertEqual(pa.cue.cueId, "animal_dog_cat")
    }

    func testUnknownMessageTypeThrows() {
        let json = "{\"type\":\"unknown_thing\",\"v\":1}".data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(ServerMessage.self, from: json))
    }
}
