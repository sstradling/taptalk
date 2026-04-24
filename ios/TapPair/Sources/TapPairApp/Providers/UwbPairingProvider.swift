// Providers/UwbPairingProvider.swift
//
// UWB pairing accelerator scaffold (NearbyInteraction). Hardware is available
// on iPhone 11+, but active ranging is disabled in this prototype until the
// WebSocket protocol relays `NIDiscoveryToken` values between assigned peers.
//
// Why this is *additive*, not a replacement:
//   * Server scoring (spec/PROTOCOL.md §7) gives UWB-close a weight of 4.0
//     which alone clears the threshold. Devices with UWB therefore get a
//     "single-channel" magic tap.
//   * Devices without UWB (iPhone SE 2, etc.) still pair via BLE+bump.
//   * Both providers run concurrently when UWB is enabled; the server picks
//     the highest-scoring claim. There is no scenario where enabling UWB
//     makes pairing slower or worse.
//
// Peer discovery-token exchange:
//   NearbyInteraction needs each peer to know the other's `NIDiscoveryToken`
//   before ranging starts. PLAN.md phase 4 adds an explicit server-relay
//   message for those opaque bytes. Until then this provider reports
//   `isAvailable == false` so the app never emits misleading UWB evidence.

#if canImport(NearbyInteraction)
import Foundation
import NearbyInteraction
import TapPairCore

@available(iOS 14.0, *)
public final class UwbPairingProvider: NSObject, PairingProvider, @unchecked Sendable {

    public let capability: Capability = .uwb

    public var isAvailable: Bool {
        // NearbyInteraction requires a peer NIDiscoveryToken exchange before
        // any ranging session can run. The v1 wire protocol intentionally has
        // no server relay for those opaque tokens yet, so expose this provider
        // as unavailable for active composition. Keeping the scaffold here lets
        // the settings UI explain UWB capability without emitting misleading
        // evidence.
        false
    }

    public let evidence: AsyncStream<EvidenceChannel>
    private let continuation: AsyncStream<EvidenceChannel>.Continuation

    private var session: NISession?
    private var peerToken: String = ""

    public override init() {
        var cont: AsyncStream<EvidenceChannel>.Continuation!
        self.evidence = AsyncStream { c in cont = c }
        self.continuation = cont
        super.init()
    }

    public func start(roundId: Int, selfToken: String) async throws {
        guard isAvailable else { return }
        peerToken = selfToken
        session = NISession()
        session?.delegate = self
        // Real config requires exchanging NIDiscoveryToken with the assigned
        // partner. The exchange protocol is intentionally elided in this
        // prototype — phase 4 of PLAN.md spells out the server-relay path.
        // For demo/testing this provider becomes active but emits no evidence
        // until a partner token is delivered through the server.
    }

    public func stop() async {
        session?.invalidate()
        session = nil
    }
}

@available(iOS 14.0, *)
extension UwbPairingProvider: NISessionDelegate {
    public func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        for obj in nearbyObjects {
            guard let dist = obj.distance else { continue }
            continuation.yield(.init(
                kind: .uwb,
                observedAtMs: nowMs,
                peerToken: peerToken, // see file comment re: real token exchange
                distanceM: Double(dist)
            ))
        }
    }
}
#endif
