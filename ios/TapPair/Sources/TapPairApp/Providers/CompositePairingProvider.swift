// Providers/CompositePairingProvider.swift
//
// Owns one or more child PairingProviders and merges their evidence streams
// into a single AsyncStream. The app composes this at startup based on
// device capability + user setting.
//
// Adding/removing a child does not require code changes elsewhere.

#if canImport(Foundation)
import Foundation
import TapPairCore

public final class CompositePairingProvider: PairingProvider, @unchecked Sendable {

    public let capability: Capability = .ble // arbitrary; advertised separately
    public var isAvailable: Bool { children.contains(where: { $0.isAvailable }) }

    public let evidence: AsyncStream<EvidenceChannel>
    private let continuation: AsyncStream<EvidenceChannel>.Continuation
    private let children: [PairingProvider]
    private var pumps: [Task<Void, Never>] = []

    public init(children: [PairingProvider]) {
        self.children = children
        var cont: AsyncStream<EvidenceChannel>.Continuation!
        self.evidence = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    public func start(roundId: Int, selfToken: String) async throws {
        // Pump every child's evidence into the merged stream.
        for child in children where child.isAvailable {
            let stream = child.evidence
            let cont = continuation
            pumps.append(Task {
                for await ev in stream { cont.yield(ev) }
            })
            try await child.start(roundId: roundId, selfToken: selfToken)
        }
    }

    public func stop() async {
        for child in children { await child.stop() }
        for p in pumps { p.cancel() }
        pumps = []
    }
}
#endif
