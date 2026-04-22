// Pairing/EvidenceCoalescer.swift
//
// Collects raw `EvidenceChannel` records from one or more PairingProviders
// and emits a single `pair_evidence` message per "touch event" (defined as a
// burst of activity inside a 750 ms window, anchored on a bump or a strong
// proximity reading).
//
// Why coalesce on the client: a single tap legitimately produces ~5–10
// observations (BLE scan tick + bump spike + UWB ranging update). Sending
// each one as its own pair_evidence would (a) flood the websocket and (b)
// require the server to do harder time-window matching. Coalescing here
// keeps the server-side matcher table-driven and predictable.

import Foundation

public actor EvidenceCoalescer {
    private let windowMs: Int64
    private var buffer: [EvidenceChannel] = []
    private var flushTask: Task<Void, Never>?
    private let onFlush: @Sendable ([EvidenceChannel]) async -> Void

    public init(windowMs: Int64 = 750, onFlush: @Sendable @escaping ([EvidenceChannel]) async -> Void) {
        self.windowMs = windowMs
        self.onFlush = onFlush
    }

    /// Accept a new observation. Schedules a flush if one isn't already pending.
    public func ingest(_ channel: EvidenceChannel) {
        buffer.append(channel)
        if flushTask == nil {
            let delay = windowMs
            flushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                await self?.flush()
            }
        }
    }

    /// Force a flush now (e.g. when the round ends or a confirmation arrives).
    public func flush() async {
        flushTask?.cancel()
        flushTask = nil
        let toSend = buffer
        buffer = []
        if !toSend.isEmpty {
            await onFlush(toSend)
        }
    }

    /// Drop everything without sending. Used when phase changes or round resets.
    public func reset() {
        flushTask?.cancel()
        flushTask = nil
        buffer = []
    }
}
