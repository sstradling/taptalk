// Protocol/Messages.swift
//
// Codable mirrors of every message defined in spec/PROTOCOL.md.
// The wire format is JSON. These types are the single iOS source of truth for
// the protocol; cross-checked against the server's zod schemas via shared
// JSON fixtures in TapPairCoreTests/Fixtures.
//
// Routing of user actions:
//   View -> GameStore.send(action) -> WebSocketClient.send(ClientMessage)
//                                                     |
//                                                     v
//                                          server (validates zod) -> processes
//                                                     |
//                                                     v
//                                           ServerMessage -> WebSocketClient
//                                                     |
//                                                     v
//                                       GameStore.apply(message) -> View update

import Foundation

public enum ProtocolVersion {
    public static let current: Int = 1
}

// MARK: - Shared enums

public enum Platform: String, Codable, Sendable { case ios, android, web }

public enum Capability: String, Codable, Sendable, CaseIterable {
    case ble, bump, uwb, audio, qr
}

public enum GameMode: String, Codable, Sendable, CaseIterable {
    case musical_chairs, poison_apple, scavenger_hunt
}

public enum RoundPhase: String, Codable, Sendable {
    case lobby, registering, finding, resolving, between_rounds, ended
}

public enum PairRole: String, Codable, Sendable { case pair, poison_apple }

public enum PairOutcome: String, Codable, Sendable {
    case found, eliminated, poison_won, poison_lost
}

public enum EvidenceKind: String, Codable, Sendable { case bump, ble, uwb, audio }

public enum CueKind: String, Codable, Sendable { case audio, image, text, task }

public enum Modality: String, Codable, Sendable { case audio, haptic, text, image }

public enum ErrorCode: String, Codable, Sendable {
    case room_full, bad_room_code, not_host, phase_mismatch, rate_limited
    case protocol_version, internal_error = "internal"
}

public enum RejectReason: String, Codable, Sendable {
    case wrong_partner, stale_evidence, phase_mismatch
}

// MARK: - Evidence channel (used inside pair_evidence)

public struct EvidenceChannel: Codable, Equatable, Sendable {
    public var kind: EvidenceKind
    public var observedAtMs: Int64
    public var peerToken: String?
    public var rssiDbm: Double?
    public var distanceM: Double?
    public var magnitudeG: Double?
    public var snrDb: Double?
    public var confidence: Double?
    public var tHitMs: Int64?

    public init(
        kind: EvidenceKind,
        observedAtMs: Int64,
        peerToken: String? = nil,
        rssiDbm: Double? = nil,
        distanceM: Double? = nil,
        magnitudeG: Double? = nil,
        snrDb: Double? = nil,
        confidence: Double? = nil,
        tHitMs: Int64? = nil
    ) {
        self.kind = kind
        self.observedAtMs = observedAtMs
        self.peerToken = peerToken
        self.rssiDbm = rssiDbm
        self.distanceM = distanceM
        self.magnitudeG = magnitudeG
        self.snrDb = snrDb
        self.confidence = confidence
        self.tHitMs = tHitMs
    }
}

// MARK: - Cue payload

public struct Cue: Codable, Equatable, Sendable {
    public var cueId: String
    public var kind: CueKind
    public var modality: [Modality]
    public var payload: [String: String] // simplified for prototype
    public var complementHint: String

    public init(cueId: String, kind: CueKind, modality: [Modality], payload: [String: String], complementHint: String) {
        self.cueId = cueId
        self.kind = kind
        self.modality = modality
        self.payload = payload
        self.complementHint = complementHint
    }
}

// MARK: - Player snapshot (inside room_state)

public struct PlayerSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var playerId: String
    public var displayName: String
    public var ready: Bool
    public var alive: Bool
    public var score: Int
    public var connected: Bool
    public var capabilities: [Capability]

    public var id: String { playerId }
}

// MARK: - Settings

public struct RoomSettings: Codable, Equatable, Sendable {
    public var roundSeconds: Int
    public var maxPlayers: Int

    public init(roundSeconds: Int = 60, maxPlayers: Int = 16) {
        self.roundSeconds = roundSeconds
        self.maxPlayers = maxPlayers
    }
}

// MARK: - Round results

public struct RoundResult: Codable, Equatable, Sendable, Identifiable {
    public var playerId: String
    public var outcome: PairOutcome
    public var rankInRound: Int
    public var scoreDelta: Int
    public var totalScore: Int

    public var id: String { playerId }
}

// MARK: - Client -> Server

public enum ClientMessage: Codable, Equatable, Sendable {
    case hello(Hello)
    case createRoom(CreateRoom)
    case joinRoom(JoinRoom)
    case leaveRoom
    case ready(Bool)
    case startRound
    case pairEvidence(PairEvidence)
    case cueAck(roundId: Int, cueId: String)
    case ping

    public struct Hello: Codable, Equatable, Sendable {
        public var deviceId: String
        public var displayName: String
        public var appVersion: String
        public var platform: Platform
        public var osVersion: String
        public var capabilities: [Capability]

        public init(deviceId: String, displayName: String, appVersion: String, platform: Platform, osVersion: String, capabilities: [Capability]) {
            self.deviceId = deviceId; self.displayName = displayName
            self.appVersion = appVersion; self.platform = platform
            self.osVersion = osVersion; self.capabilities = capabilities
        }
    }

    public struct CreateRoom: Codable, Equatable, Sendable {
        public var mode: GameMode
        public var settings: RoomSettings
        public init(mode: GameMode, settings: RoomSettings) { self.mode = mode; self.settings = settings }
    }

    public struct JoinRoom: Codable, Equatable, Sendable {
        public var roomCode: String
        public init(roomCode: String) { self.roomCode = roomCode }
    }

    public struct PairEvidence: Codable, Equatable, Sendable {
        public var roundId: Int
        public var phase: String // "register" | "confirm"
        public var selfToken: String
        public var channels: [EvidenceChannel]
        public init(roundId: Int, phase: String, selfToken: String, channels: [EvidenceChannel]) {
            self.roundId = roundId; self.phase = phase
            self.selfToken = selfToken; self.channels = channels
        }
    }

    // MARK: encoding

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: GenericKey.self)
        try c.encode(ProtocolVersion.current, forKey: GenericKey("v"))
        switch self {
        case .hello(let h):
            try c.encode("hello", forKey: GenericKey("type"))
            try c.encode(h.deviceId, forKey: GenericKey("deviceId"))
            try c.encode(h.displayName, forKey: GenericKey("displayName"))
            try c.encode(h.appVersion, forKey: GenericKey("appVersion"))
            try c.encode(h.platform, forKey: GenericKey("platform"))
            try c.encode(h.osVersion, forKey: GenericKey("osVersion"))
            try c.encode(h.capabilities, forKey: GenericKey("capabilities"))
        case .createRoom(let cr):
            try c.encode("create_room", forKey: GenericKey("type"))
            try c.encode(cr.mode, forKey: GenericKey("mode"))
            try c.encode(cr.settings, forKey: GenericKey("settings"))
        case .joinRoom(let jr):
            try c.encode("join_room", forKey: GenericKey("type"))
            try c.encode(jr.roomCode, forKey: GenericKey("roomCode"))
        case .leaveRoom:
            try c.encode("leave_room", forKey: GenericKey("type"))
        case .ready(let r):
            try c.encode("ready", forKey: GenericKey("type"))
            try c.encode(r, forKey: GenericKey("ready"))
        case .startRound:
            try c.encode("start_round", forKey: GenericKey("type"))
        case .pairEvidence(let pe):
            try c.encode("pair_evidence", forKey: GenericKey("type"))
            try c.encode(pe.roundId, forKey: GenericKey("roundId"))
            try c.encode(pe.phase, forKey: GenericKey("phase"))
            try c.encode(pe.selfToken, forKey: GenericKey("selfToken"))
            try c.encode(pe.channels, forKey: GenericKey("channels"))
        case .cueAck(let roundId, let cueId):
            try c.encode("cue_ack", forKey: GenericKey("type"))
            try c.encode(roundId, forKey: GenericKey("roundId"))
            try c.encode(cueId, forKey: GenericKey("cueId"))
        case .ping:
            try c.encode("ping", forKey: GenericKey("type"))
        }
    }

    public init(from decoder: Decoder) throws {
        // Decoding client messages on the client side is unusual but supported
        // for completeness (e.g. tests that round-trip).
        let c = try decoder.container(keyedBy: GenericKey.self)
        let type = try c.decode(String.self, forKey: GenericKey("type"))
        switch type {
        case "hello":
            self = .hello(.init(
                deviceId: try c.decode(String.self, forKey: GenericKey("deviceId")),
                displayName: try c.decode(String.self, forKey: GenericKey("displayName")),
                appVersion: try c.decode(String.self, forKey: GenericKey("appVersion")),
                platform: try c.decode(Platform.self, forKey: GenericKey("platform")),
                osVersion: try c.decode(String.self, forKey: GenericKey("osVersion")),
                capabilities: try c.decode([Capability].self, forKey: GenericKey("capabilities"))
            ))
        case "create_room":
            self = .createRoom(.init(
                mode: try c.decode(GameMode.self, forKey: GenericKey("mode")),
                settings: try c.decode(RoomSettings.self, forKey: GenericKey("settings"))
            ))
        case "join_room":
            self = .joinRoom(.init(roomCode: try c.decode(String.self, forKey: GenericKey("roomCode"))))
        case "leave_room": self = .leaveRoom
        case "ready": self = .ready(try c.decode(Bool.self, forKey: GenericKey("ready")))
        case "start_round": self = .startRound
        case "pair_evidence":
            self = .pairEvidence(.init(
                roundId: try c.decode(Int.self, forKey: GenericKey("roundId")),
                phase: try c.decode(String.self, forKey: GenericKey("phase")),
                selfToken: try c.decode(String.self, forKey: GenericKey("selfToken")),
                channels: try c.decode([EvidenceChannel].self, forKey: GenericKey("channels"))
            ))
        case "cue_ack":
            self = .cueAck(
                roundId: try c.decode(Int.self, forKey: GenericKey("roundId")),
                cueId: try c.decode(String.self, forKey: GenericKey("cueId"))
            )
        case "ping": self = .ping
        default:
            throw DecodingError.dataCorruptedError(forKey: GenericKey("type"), in: c, debugDescription: "Unknown type \(type)")
        }
    }
}

// MARK: - Server -> Client

public enum ServerMessage: Codable, Equatable, Sendable {
    case helloAck(sessionId: String, serverTimeMs: Int64)
    case pong
    case roomState(RoomState)
    case roundStarted(roundId: Int, registerDeadlineMs: Int64)
    case pairAssigned(PairAssigned)
    case pairConfirmed(roundId: Int, partnerPlayerId: String, partnerDisplayName: String, elapsedMs: Int64)
    case pairRejected(roundId: Int, reason: RejectReason)
    case roundResolved(roundId: Int, results: [RoundResult], nextPhase: RoundPhase)
    case error(code: ErrorCode, message: String)

    public struct RoomState: Codable, Equatable, Sendable {
        public var roomCode: String
        public var mode: GameMode
        public var phase: RoundPhase
        public var hostPlayerId: String
        public var players: [PlayerSnapshot]
        public var currentRoundId: Int
        public var settings: RoomSettings
    }

    public struct PairAssigned: Codable, Equatable, Sendable {
        public var roundId: Int
        public var role: PairRole
        public var cue: Cue
        public var findDeadlineMs: Int64
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GenericKey.self)
        let type = try c.decode(String.self, forKey: GenericKey("type"))
        switch type {
        case "hello_ack":
            self = .helloAck(
                sessionId: try c.decode(String.self, forKey: GenericKey("sessionId")),
                serverTimeMs: try c.decode(Int64.self, forKey: GenericKey("serverTimeMs"))
            )
        case "pong": self = .pong
        case "room_state":
            self = .roomState(.init(
                roomCode: try c.decode(String.self, forKey: GenericKey("roomCode")),
                mode: try c.decode(GameMode.self, forKey: GenericKey("mode")),
                phase: try c.decode(RoundPhase.self, forKey: GenericKey("phase")),
                hostPlayerId: try c.decode(String.self, forKey: GenericKey("hostPlayerId")),
                players: try c.decode([PlayerSnapshot].self, forKey: GenericKey("players")),
                currentRoundId: try c.decode(Int.self, forKey: GenericKey("currentRoundId")),
                settings: try c.decode(RoomSettings.self, forKey: GenericKey("settings"))
            ))
        case "round_started":
            self = .roundStarted(
                roundId: try c.decode(Int.self, forKey: GenericKey("roundId")),
                registerDeadlineMs: try c.decode(Int64.self, forKey: GenericKey("registerDeadlineMs"))
            )
        case "pair_assigned":
            self = .pairAssigned(.init(
                roundId: try c.decode(Int.self, forKey: GenericKey("roundId")),
                role: try c.decode(PairRole.self, forKey: GenericKey("role")),
                cue: try c.decode(Cue.self, forKey: GenericKey("cue")),
                findDeadlineMs: try c.decode(Int64.self, forKey: GenericKey("findDeadlineMs"))
            ))
        case "pair_confirmed":
            self = .pairConfirmed(
                roundId: try c.decode(Int.self, forKey: GenericKey("roundId")),
                partnerPlayerId: try c.decode(String.self, forKey: GenericKey("partnerPlayerId")),
                partnerDisplayName: try c.decode(String.self, forKey: GenericKey("partnerDisplayName")),
                elapsedMs: try c.decode(Int64.self, forKey: GenericKey("elapsedMs"))
            )
        case "pair_rejected":
            self = .pairRejected(
                roundId: try c.decode(Int.self, forKey: GenericKey("roundId")),
                reason: try c.decode(RejectReason.self, forKey: GenericKey("reason"))
            )
        case "round_resolved":
            self = .roundResolved(
                roundId: try c.decode(Int.self, forKey: GenericKey("roundId")),
                results: try c.decode([RoundResult].self, forKey: GenericKey("results")),
                nextPhase: try c.decode(RoundPhase.self, forKey: GenericKey("nextPhase"))
            )
        case "error":
            self = .error(
                code: try c.decode(ErrorCode.self, forKey: GenericKey("code")),
                message: try c.decode(String.self, forKey: GenericKey("message"))
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: GenericKey("type"), in: c, debugDescription: "Unknown type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        // Encoding server messages from the iOS side is only used in tests.
        var c = encoder.container(keyedBy: GenericKey.self)
        try c.encode(ProtocolVersion.current, forKey: GenericKey("v"))
        switch self {
        case .helloAck(let sid, let t):
            try c.encode("hello_ack", forKey: GenericKey("type"))
            try c.encode(sid, forKey: GenericKey("sessionId"))
            try c.encode(t, forKey: GenericKey("serverTimeMs"))
        case .pong:
            try c.encode("pong", forKey: GenericKey("type"))
        case .roomState(let s):
            try c.encode("room_state", forKey: GenericKey("type"))
            try c.encode(s.roomCode, forKey: GenericKey("roomCode"))
            try c.encode(s.mode, forKey: GenericKey("mode"))
            try c.encode(s.phase, forKey: GenericKey("phase"))
            try c.encode(s.hostPlayerId, forKey: GenericKey("hostPlayerId"))
            try c.encode(s.players, forKey: GenericKey("players"))
            try c.encode(s.currentRoundId, forKey: GenericKey("currentRoundId"))
            try c.encode(s.settings, forKey: GenericKey("settings"))
        case .roundStarted(let r, let d):
            try c.encode("round_started", forKey: GenericKey("type"))
            try c.encode(r, forKey: GenericKey("roundId"))
            try c.encode("registering", forKey: GenericKey("phase"))
            try c.encode(d, forKey: GenericKey("registerDeadlineMs"))
        case .pairAssigned(let p):
            try c.encode("pair_assigned", forKey: GenericKey("type"))
            try c.encode(p.roundId, forKey: GenericKey("roundId"))
            try c.encode(p.role, forKey: GenericKey("role"))
            try c.encode(p.cue, forKey: GenericKey("cue"))
            try c.encode(p.findDeadlineMs, forKey: GenericKey("findDeadlineMs"))
        case .pairConfirmed(let r, let pid, let pname, let e):
            try c.encode("pair_confirmed", forKey: GenericKey("type"))
            try c.encode(r, forKey: GenericKey("roundId"))
            try c.encode(pid, forKey: GenericKey("partnerPlayerId"))
            try c.encode(pname, forKey: GenericKey("partnerDisplayName"))
            try c.encode(e, forKey: GenericKey("elapsedMs"))
        case .pairRejected(let r, let reason):
            try c.encode("pair_rejected", forKey: GenericKey("type"))
            try c.encode(r, forKey: GenericKey("roundId"))
            try c.encode(reason, forKey: GenericKey("reason"))
        case .roundResolved(let r, let results, let next):
            try c.encode("round_resolved", forKey: GenericKey("type"))
            try c.encode(r, forKey: GenericKey("roundId"))
            try c.encode(results, forKey: GenericKey("results"))
            try c.encode(next, forKey: GenericKey("nextPhase"))
        case .error(let code, let msg):
            try c.encode("error", forKey: GenericKey("type"))
            try c.encode(code, forKey: GenericKey("code"))
            try c.encode(msg, forKey: GenericKey("message"))
        }
    }
}

// MARK: - generic codable key helper

public struct GenericKey: CodingKey {
    public var stringValue: String
    public var intValue: Int? { nil }
    public init(_ s: String) { self.stringValue = s }
    public init?(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { return nil }
}
