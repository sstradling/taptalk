// State/GameState.swift
//
// Pure value type that mirrors the subset of server state the UI needs to
// render, plus a few client-only fields (e.g. local pairing-provider status,
// whether the user has granted Bluetooth permission).
//
// `GameStore` (next file) wraps this in an Observable so SwiftUI can bind to
// it. The reduction itself is a pure function so it's trivially unit-tested.

import Foundation

public struct GameState: Equatable, Sendable {
    public enum Connection: Equatable, Sendable {
        case disconnected, connecting, connected, helloed(sessionId: String)
    }

    public var connection: Connection = .disconnected
    public var serverClockSkewMs: Int64 = 0
    public var room: ServerMessage.RoomState? = nil
    public var lastAssignment: ServerMessage.PairAssigned? = nil
    public var lastConfirmation: PairConfirmation? = nil
    public var lastResolution: RoundResolution? = nil
    public var lastError: String? = nil
    public var enabledCapabilities: Set<Capability> = [.ble, .bump]

    public init() {}

    public struct PairConfirmation: Equatable, Sendable {
        public var roundId: Int
        public var partnerDisplayName: String
        public var elapsedMs: Int64
    }

    public struct RoundResolution: Equatable, Sendable {
        public var roundId: Int
        public var results: [RoundResult]
        public var nextPhase: RoundPhase
    }
}
