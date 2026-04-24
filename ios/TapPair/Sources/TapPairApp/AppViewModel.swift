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
import Security
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
    private var providerPumpTask: Task<Void, Never>?
    private var subscription: UUID?
    private var activeProviderRoundId: Int?
    private var activeSelfToken: String?

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
                await MainActor.run {
                    self?.handleServerMessage(msg)
                }
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
        providerPumpTask?.cancel()
        activeProviderRoundId = nil
        activeSelfToken = nil
        var children: [any PairingProvider] = []
        #if canImport(CoreBluetooth) && canImport(CoreMotion)
        children.append(BleBumpPairingProvider())
        #endif
        #if canImport(NearbyInteraction)
        if Self.uwbProviderCompositionEnabled, uwbEnabled, #available(iOS 14.0, *) {
            let uwb = UwbPairingProvider()
            if uwb.isAvailable { children.append(uwb) }
        }
        #endif
        let comp = CompositePairingProvider(children: children)
        provider = comp

        let coalescer = EvidenceCoalescer { [weak self] batch in
            guard let self else { return }
            let (roundId, token) = await MainActor.run {
                (self.state.lastAssignment?.roundId ?? self.state.room?.currentRoundId ?? 0,
                 self.activeSelfToken ?? Self.generateRoundToken())
            }
            try? await self.client.send(.pairEvidence(.init(
                roundId: roundId,
                phase: "confirm",
                selfToken: token,
                channels: batch
            )))
        }
        self.coalescer = coalescer

        providerPumpTask = Task { [weak self] in
            guard let self, let provider = self.provider else { return }
            for await ev in provider.evidence {
                await coalescer.ingest(ev)
            }
        }
        Task { await startProviderForCurrentRoundIfNeeded() }
    }

    private func handleServerMessage(_ message: ServerMessage) {
        switch message {
        case .roundStarted, .pairAssigned:
            Task { await startProviderForCurrentRoundIfNeeded() }
        case .roundResolved:
            Task {
                await provider?.stop()
                activeProviderRoundId = nil
                activeSelfToken = nil
                await coalescer?.reset()
            }
        default:
            break
        }
    }

    private func startProviderForCurrentRoundIfNeeded() async {
        let roundId = state.lastAssignment?.roundId ?? state.room?.currentRoundId ?? 0
        guard roundId > 0, activeProviderRoundId != roundId, let provider else { return }
        let token = Self.generateRoundToken()
        activeProviderRoundId = roundId
        activeSelfToken = token
        do {
            try await provider.start(roundId: roundId, selfToken: token)
        } catch {
            state.lastError = "Pairing start failed: \(error)"
        }
    }

    private func currentCapabilities() -> [Capability] {
        // UWB is intentionally not advertised yet: NearbyInteraction requires
        // an assigned-partner discovery-token relay in the wire protocol. Until
        // that exists, BLE+bump is the only active pairing implementation.
        return [.ble, .bump]
    }

    private static func persistentDeviceId() -> String {
        let key = "tappair.deviceId"
        if let s = KeychainStringStore.read(service: key, account: "deviceId") { return s }
        let new = UUID().uuidString
        KeychainStringStore.write(new, service: key, account: "deviceId")
        return new
    }

    private static func generateRoundToken() -> String {
        RoundToken.generate()
    }

    private static var uwbProviderCompositionEnabled: Bool {
        // Flip this to true only after PLAN.md phase 4 adds server-relayed
        // NIDiscoveryToken exchange. Keeping the code path compiled but gated
        // prevents the Settings toggle from implying active UWB ranging today.
        false
    }
}

private enum KeychainStringStore {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    static func write(_ string: String, service: String, account: String) {
        let data = Data(string.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
#endif
