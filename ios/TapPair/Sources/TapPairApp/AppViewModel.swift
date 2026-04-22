// AppViewModel.swift
//
// Glue between the platform-agnostic `GameStore` (TapPairCore) and SwiftUI's
// `@Observable`. Also owns the WebSocketClient, the composed PairingProvider,
// and the EvidenceCoalescer.
//
// Routing of user actions:
//   View -> AppViewModel.send(_:)            // user intent
//        -> WebSocketClient.send(.foo)        // wire encoding
//        ...
//   Server push -> WebSocketClient.messages   // AsyncStream
//             -> GameStore.apply(msg)         // pure reduction
//             -> AppViewModel.state           // SwiftUI re-renders

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import TapPairCore

@MainActor
@Observable
public final class AppViewModel {

    public var state: GameState = GameState()
    public var serverURL: URL = URL(string: "ws://127.0.0.1:8080")!
    public var displayName: String = "Player"
    public var uwbEnabled: Bool = true {
        didSet { rebuildProvider() }
    }

    private let store = GameStore()
    private let transport = URLSessionWebSocketTransport()
    private lazy var client: WebSocketClient = WebSocketClient(transport: transport)
    private var provider: (any PairingProvider)?
    private var coalescer: EvidenceCoalescer?
    private var inboxTask: Task<Void, Never>?
    private var subscription: UUID?

    public init() {}

    public func start() async {
        // Wire store -> Observable state.
        let id = await store.subscribe { [weak self] s in
            Task { @MainActor in self?.state = s }
        }
        self.subscription = id

        // Connect & send hello.
        do {
            try await client.connect(url: serverURL)
        } catch {
            await MainActor.run { self.state.lastError = "Connect failed: \(error)" }
            return
        }

        // Pump messages.
        let stream = client.messages
        inboxTask = Task { [weak self] in
            for await msg in stream {
                await self?.store.apply(msg)
            }
        }

        let deviceId = Self.persistentDeviceId()
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let caps = currentCapabilities()
        try? await client.send(.hello(.init(
            deviceId: deviceId,
            displayName: displayName,
            appVersion: "0.1.0",
            platform: .ios,
            osVersion: osVersion,
            capabilities: caps
        )))
        rebuildProvider()
    }

    // MARK: - User intents

    public func createRoom(mode: GameMode) async {
        try? await client.send(.createRoom(.init(mode: mode, settings: RoomSettings())))
    }

    public func joinRoom(code: String) async {
        try? await client.send(.joinRoom(.init(roomCode: code.uppercased())))
    }

    public func startRound() async {
        try? await client.send(.startRound)
    }

    public func leaveRoom() async {
        try? await client.send(.leaveRoom)
    }

    /// Debug-only "fake tap" so the prototype is testable without two phones.
    public func injectFakeTouch(peerToken: String) async {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let ev = EvidenceChannel(kind: .uwb, observedAtMs: now, peerToken: peerToken, distanceM: 0.05)
        await coalescer?.ingest(ev)
        await coalescer?.flush()
    }

    // MARK: - Private

    private func rebuildProvider() {
        Task { await provider?.stop() }
        var children: [any PairingProvider] = []
        #if canImport(CoreBluetooth) && canImport(CoreMotion)
        children.append(BleBumpPairingProvider())
        #endif
        #if canImport(NearbyInteraction)
        if uwbEnabled, #available(iOS 14.0, *) {
            let uwb = UwbPairingProvider()
            if uwb.isAvailable { children.append(uwb) }
        }
        #endif
        let comp = CompositePairingProvider(children: children)
        provider = comp

        let coalescer = EvidenceCoalescer { [weak self] batch in
            guard let self else { return }
            let roundId = await MainActor.run { self.state.lastAssignment?.roundId ?? self.state.room?.currentRoundId ?? 0 }
            let token = Self.persistentDeviceId() // simplified self-token
            try? await self.client.send(.pairEvidence(.init(
                roundId: roundId,
                phase: "confirm",
                selfToken: token,
                channels: batch
            )))
        }
        self.coalescer = coalescer

        Task { [weak self] in
            guard let self, let provider = self.provider else { return }
            for await ev in provider.evidence {
                await coalescer.ingest(ev)
            }
        }
    }

    private func currentCapabilities() -> [Capability] {
        var caps: [Capability] = [.ble, .bump]
        #if canImport(NearbyInteraction)
        if #available(iOS 14.0, *), NISession.isSupported, uwbEnabled {
            if #available(iOS 16.0, *), NISession.deviceCapabilities.supportsPreciseDistanceMeasurement {
                caps.append(.uwb)
            }
        }
        #endif
        return caps
    }

    private static func persistentDeviceId() -> String {
        let key = "tappair.deviceId"
        if let s = UserDefaults.standard.string(forKey: key) { return s }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }
}
#endif
