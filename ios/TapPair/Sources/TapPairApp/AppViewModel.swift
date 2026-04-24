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
import Observation
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
    @ObservationIgnored private var client: WebSocketClient
    private var provider: (any PairingProvider)?
    private var coalescer: EvidenceCoalescer?
    private var inboxTask: Task<Void, Never>?
    private var providerPumpTask: Task<Void, Never>?
    private var subscription: UUID?
    private var activeProviderRoundId: Int?
    private var activeSelfToken: String?

    public init() {
        self.client = WebSocketClient(transport: URLSessionWebSocketTransport())
    }

    public func start() async {
        // Wire store -> Observable state.
        let id = await store.subscribe { [weak self] s in
            Task { @MainActor in self?.state = s }
        }
        self.subscription = id

        await connectAndHello()
    }

    /// Best-effort reconnect. Used from start() and from the lobby when the
    /// user retries a join after a previous failure.
    public func connectAndHello() async {
        logDebug("connectAndHello start url=\(serverURL.absoluteString)")
        state.connection = .connecting
        state.lastError = nil

        inboxTask?.cancel()
        inboxTask = nil
        await client.disconnect()
        client = WebSocketClient(transport: URLSessionWebSocketTransport())

        do {
            try await client.connect(url: serverURL)
        } catch {
            state.connection = .disconnected
            state.lastError = "Connect failed: \(error.localizedDescription)"
            logDebug("connect failed error=\(error.localizedDescription)")
            return
        }
        logDebug("connect returned")
        state.connection = .connected

        // Pump messages. If the socket dies, mark disconnected so the UI can
        // show it instead of silently failing the next user action.
        let stream = client.messages
        inboxTask?.cancel()
        inboxTask = Task { [weak self] in
            for await msg in stream {
                await MainActor.run {
                    self?.logDebug("received server message type=\(msg.debugType)")
                }
                await self?.store.apply(msg)
                await MainActor.run {
                    self?.handleServerMessage(msg)
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.state.connection = .disconnected
                if self.state.lastError == nil {
                    self.state.lastError = "Server connection closed."
                }
                self.logDebug("receive loop ended")
            }
        }

        let deviceId = Self.persistentDeviceId()
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let caps = currentCapabilities()
        do {
            logDebug("sending hello displayName=\(displayName)")
            try await client.send(.hello(.init(
                deviceId: deviceId,
                displayName: displayName,
                appVersion: "0.1.0",
                platform: .ios,
                osVersion: osVersion,
                capabilities: caps
            )))
        } catch {
            state.connection = .disconnected
            state.lastError = "Hello failed: \(error.localizedDescription)"
            logDebug("hello failed error=\(error.localizedDescription)")
            return
        }
        logDebug("hello sent")
        rebuildProvider()
    }

    /// Whether outbound user actions (create/join/start) can be sent right now.
    public var canSendUserActions: Bool {
        switch state.connection {
        case .connected, .helloed: return true
        case .disconnected, .connecting: return false
        }
    }

    // MARK: - User intents

    public func createRoom(mode: GameMode) async {
        logDebug("createRoom tapped mode=\(mode.rawValue)")
        await sendOrSurface(.createRoom(.init(mode: mode, settings: RoomSettings())))
    }

    public func joinRoom(code: String) async {
        logDebug("joinRoom tapped code=\(code.uppercased())")
        await sendOrSurface(.joinRoom(.init(roomCode: code.uppercased())))
    }

    public func startRound() async {
        await sendOrSurface(.startRound)
    }

    public func leaveRoom() async {
        await sendOrSurface(.leaveRoom)
    }

    /// Send a client message and surface any error to the UI. Returns true on
    /// best-effort send, false if the call threw (which means the socket is
    /// almost certainly closed).
    @discardableResult
    private func sendOrSurface(_ msg: ClientMessage) async -> Bool {
        do {
            logDebug("sending client message type=\(msg.debugType)")
            try await client.send(msg)
            logDebug("sent client message type=\(msg.debugType)")
            return true
        } catch {
            state.lastError = "Send failed: \(error.localizedDescription). Try Reconnect."
            state.connection = .disconnected
            logDebug("send failed type=\(msg.debugType) error=\(error.localizedDescription)")
            return false
        }
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

    private func logDebug(_ message: String) {
        print("[TapPair] \(message)")
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

private extension ClientMessage {
    var debugType: String {
        switch self {
        case .hello: "hello"
        case .createRoom: "create_room"
        case .joinRoom: "join_room"
        case .leaveRoom: "leave_room"
        case .ready: "ready"
        case .startRound: "start_round"
        case .pairEvidence: "pair_evidence"
        case .cueAck: "cue_ack"
        case .ping: "ping"
        }
    }
}

private extension ServerMessage {
    var debugType: String {
        switch self {
        case .helloAck: "hello_ack"
        case .pong: "pong"
        case .roomState: "room_state"
        case .roundStarted: "round_started"
        case .pairAssigned: "pair_assigned"
        case .pairConfirmed: "pair_confirmed"
        case .pairRejected: "pair_rejected"
        case .roundResolved: "round_resolved"
        case .error: "error"
        }
    }
}
#endif
