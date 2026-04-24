// Pairing/PairingProvider.swift
//
// Abstraction over a single proximity-evidence channel (BLE+bump, UWB, audio,
// QR, etc.). The app composes one or more providers at startup based on:
//   - device capability (does the phone have a U1 chip?)
//   - user preference (is the UWB toggle ON in Settings?)
//
// Every provider emits `EvidenceChannel` records into an AsyncStream. The
// `EvidenceCoalescer` collects them per round and posts a single
// `pair_evidence` message per touch event over the websocket.
//
// Important: the provider does NOT decide who is paired with whom. It only
// reports observations. The server (RoundEngine) decides.

import Foundation

public protocol PairingProvider: AnyObject, Sendable {
    /// Which channel kind this provider produces. Used for capability ads
    /// during `hello`.
    var capability: Capability { get }

    /// Whether this provider can run on the current device right now.
    /// E.g. UWB returns false on iPhone SE 2 and below.
    var isAvailable: Bool { get }

    /// Begin advertising / scanning for the given round.
    /// `selfToken` is the round-scoped opaque identifier this device should
    /// broadcast (BLE service-data, UWB peer token exchange, audio chirp id).
    func start(roundId: Int, selfToken: String) async throws

    /// Stop all I/O and tear down sessions.
    func stop() async

    /// Stream of evidence observations. Must be non-blocking; the consumer
    /// reads at its own pace and may drop on backpressure.
    var evidence: AsyncStream<EvidenceChannel> { get }
}

/// A no-op provider used in unit tests and previews.
public final class NoopPairingProvider: PairingProvider, @unchecked Sendable {
    public let capability: Capability
    public let isAvailable: Bool = true
    public let evidence: AsyncStream<EvidenceChannel>
    private let continuation: AsyncStream<EvidenceChannel>.Continuation

    public init(capability: Capability = .ble) {
        self.capability = capability
        var cont: AsyncStream<EvidenceChannel>.Continuation!
        self.evidence = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    public func start(roundId: Int, selfToken: String) async throws {}
    public func stop() async {}

    /// Test helper: inject an evidence record manually.
    public func inject(_ ev: EvidenceChannel) {
        continuation.yield(ev)
    }
}
