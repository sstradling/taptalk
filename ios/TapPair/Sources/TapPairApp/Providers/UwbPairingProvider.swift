// Providers/UwbPairingProvider.swift
//
// UWB pairing accelerator (NearbyInteraction). Available on iPhone 11+.
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
//   before ranging starts. We do this through the server: each device
//   serializes its token, sends it inside a `pair_evidence` channel
//   (kind: "uwb", peerToken: <our base64 token>) so the server can relay it
//   to the assigned partner via `pair_assigned`. The server treats the
//   token as opaque bytes — it does not parse it.
//
//   For this prototype we keep the wire interaction minimal: each device
//   advertises its `NIDiscoveryToken` over BLE (in the same advertisement
//   used by BleBumpPairingProvider, with an extended data field). A real
//   implementation would prefer the server-relay path because it works even
//   when BLE is heavily congested.

#if canImport(NearbyInteraction)
import Foundation
import NearbyInteraction
import TapPairCore

@available(iOS 14.0, *)
public final class UwbPairingProvider: NSObject, PairingProvider, @unchecked Sendable {

    public let capability: Capability = .uwb

    public var isAvailable: Bool {
        if #available(iOS 16.0, *) {
            return NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
        } else {
            return NISession.isSupported
        }
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
