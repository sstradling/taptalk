// State/GameStore.swift
//
// `GameStore` holds the canonical client-side `GameState` and reduces every
// inbound `ServerMessage` into a new state value. The reduction is exposed
// as a static pure function (`GameStore.reduce`) so unit tests can verify
// every transition without instantiating the actor or wiring a websocket.
//
// The Observable/iOS-specific glue (publishing changes for SwiftUI) is added
// in TapPairApp via a lightweight wrapper, so this module stays buildable on
// non-Apple platforms (Linux CI).

import Foundation

public actor GameStore {
    public private(set) var state: GameState = GameState()

    /// Subscribers receive the new state on every reduction. Useful for the
    /// Observable wrapper in the iOS app target.
    public typealias Listener = @Sendable (GameState) -> Void
    private var listeners: [UUID: Listener] = [:]

    public init() {}

    public func subscribe(_ listener: @escaping Listener) -> UUID {
        let id = UUID()
        listeners[id] = listener
        listener(state)
        return id
    }

    public func unsubscribe(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    /// Apply a server message. Returns the new state for callers that prefer
    /// pull over push.
    @discardableResult
    public func apply(_ message: ServerMessage, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> GameState {
        state = Self.reduce(state, message, nowMs: now)
        broadcast()
        return state
    }

    /// Manually mutate (used by view layer for setting toggles like UWB on/off).
    public func mutate(_ block: @Sendable (inout GameState) -> Void) {
        block(&state)
        broadcast()
    }

    private func broadcast() {
        let snapshot = state
        for l in listeners.values {
            l(snapshot)
        }
    }

    /// Pure reducer. Exposed for unit tests.
    public static func reduce(_ s: GameState, _ msg: ServerMessage, nowMs: Int64) -> GameState {
        var out = s
        switch msg {
        case .helloAck(let sessionId, let serverTimeMs):
            out.connection = .helloed(sessionId: sessionId)
            out.serverClockSkewMs = serverTimeMs - nowMs
        case .pong:
            break
        case .roomState(let rs):
            out.room = rs
        case .roundStarted(let rid, _):
            // Entering a new round wipes per-round transients.
            out.lastAssignment = nil
            out.lastConfirmation = nil
            out.lastResolution = nil
            // currentRoundId is also pushed via room_state; keep both consistent.
            if var r = out.room { r.currentRoundId = rid; out.room = r }
        case .pairAssigned(let pa):
            out.lastAssignment = pa
        case .pairConfirmed(let rid, _, let name, let elapsed):
            out.lastConfirmation = .init(roundId: rid, partnerDisplayName: name, elapsedMs: elapsed)
        case .pairRejected:
            // Surface as transient error string; UI clears on next user action.
            out.lastError = "Wrong partner — try again."
        case .roundResolved(let rid, let results, let next):
            out.lastResolution = .init(roundId: rid, results: results, nextPhase: next)
        case .error(_, let message):
            out.lastError = message
        }
        return out
    }
}
