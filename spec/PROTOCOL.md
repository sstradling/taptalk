# TapPair WebSocket Protocol v0.1

Status: **Draft**. Wire format frozen for the v1 prototype; semantics may evolve.

## 1. Transport

- WebSocket over TLS (`wss://`). Plain `ws://` permitted for local dev only.
- One persistent connection per client (mobile device).
- Text frames, JSON-encoded, UTF-8.
- Heartbeat: client sends `{"type":"ping"}` every 15 s; server replies `{"type":"pong"}`. Connection considered stale after 30 s of no traffic.

## 2. Identity

- Each device has a stable, app-generated `deviceId` (UUID v4, persisted in Keychain on iOS / EncryptedSharedPreferences on Android).
- Each connection is assigned an ephemeral `sessionId` by the server on `hello`.
- Each lobby has a 4-letter `roomCode` (uppercase A–Z, no I/O/0/1 to avoid confusion).
- Each round has a monotonically increasing `roundId` scoped to the room.
- Each player in a round has a `playerId` scoped to the room (stable across rounds for that device).

## 3. Message envelope

All messages share an envelope:

```json
{
  "type": "<message-type>",
  "v": 1,
  "ts": 1713650000000,
  "...": "type-specific fields"
}
```

- `type`: snake_case string discriminator.
- `v`: protocol version. Clients reject mismatched major versions.
- `ts`: client- or server-side wall-clock millis (informational; the server's clock is authoritative for ordering).

## 4. Connection lifecycle

```
client                                  server
  | -- hello ------------------------->  |
  | <-- hello_ack ---------------------- |
  | -- create_room | join_room -------->  |
  | <-- room_state -------------------- |
  | -- ready -------------------------->  |
  | <-- round_started ----------------- |
  | <-- pair_assigned ----------------- |  (private, addressed to one player)
  | -- pair_evidence ------------------>  |
  | <-- pair_confirmed | pair_rejected - |
  | <-- round_resolved ---------------- |
```

## 5. Client -> Server messages

### 5.1 `hello`
```json
{ "type": "hello", "v": 1, "deviceId": "uuid", "displayName": "Aleks", "appVersion": "0.1.0", "platform": "ios", "osVersion": "17.5", "capabilities": ["ble", "bump", "uwb"] }
```
- `capabilities` declares which evidence channels the device can produce. Server uses this to gate which providers to request.

### 5.2 `create_room`
```json
{ "type": "create_room", "v": 1, "mode": "musical_chairs" | "poison_apple" | "scavenger_hunt", "settings": { "roundSeconds": 60, "maxPlayers": 16 } }
```

### 5.3 `join_room`
```json
{ "type": "join_room", "v": 1, "roomCode": "BQRT" }
```

### 5.4 `leave_room`
```json
{ "type": "leave_room", "v": 1 }
```

### 5.5 `ready`
Player declares ready to start the next round (host-gated start).
```json
{ "type": "ready", "v": 1, "ready": true }
```

### 5.6 `start_round`
Host only.
```json
{ "type": "start_round", "v": 1 }
```

### 5.7 `pair_evidence`
The single most important client message. Sent when the device believes it just touched / came close to another device. The server, not the client, decides whether the touch counts.

```json
{
  "type": "pair_evidence",
  "v": 1,
  "roundId": 42,
  "phase": "register" | "confirm",
  "channels": [
    { "kind": "bump",  "tHitMs": 1713650001234, "magnitudeG": 6.4, "confidence": 0.83 },
    { "kind": "ble",   "peerToken": "ab12...", "rssiDbm": -42, "observedAtMs": 1713650001230 },
    { "kind": "uwb",   "peerToken": "ab12...", "distanceM": 0.05, "observedAtMs": 1713650001236 },
    { "kind": "audio", "peerChirpId": 17, "snrDb": 18.0, "observedAtMs": 1713650001231 }
  ],
  "selfToken": "cd34..."
}
```

- `selfToken` is the round-scoped 64-bit token the device is currently advertising over BLE / UWB / audio. The server already knows which `playerId` owns which token.
- A device MAY emit multiple `pair_evidence` messages in quick succession (one per channel that fires). The server coalesces evidence within a 750 ms window per device.

### 5.8 `cue_ack`
Acknowledge receipt of a cue (for telemetry / retry).
```json
{ "type": "cue_ack", "v": 1, "roundId": 42, "cueId": "cue_dog_bark_a" }
```

## 6. Server -> Client messages

### 6.1 `hello_ack`
```json
{ "type": "hello_ack", "v": 1, "sessionId": "...", "serverTimeMs": 1713650000123 }
```
- Client computes `clockSkew = serverTimeMs - localTimeMs` and applies it to all timestamps it sends.

### 6.2 `room_state`
Pushed on every meaningful change. Full snapshot, not a delta — rooms are small (<=16 players).
```json
{
  "type": "room_state",
  "v": 1,
  "roomCode": "BQRT",
  "mode": "poison_apple",
  "phase": "lobby" | "registering" | "finding" | "resolving" | "between_rounds" | "ended",
  "hostPlayerId": "p_1",
  "players": [
    { "playerId": "p_1", "displayName": "Aleks", "ready": true,  "alive": true,  "score": 0, "connected": true,  "capabilities": ["ble","bump"] },
    { "playerId": "p_2", "displayName": "Sam",   "ready": false, "alive": true,  "score": 0, "connected": true,  "capabilities": ["ble","bump","uwb"] }
  ],
  "currentRoundId": 42,
  "settings": { "roundSeconds": 60, "maxPlayers": 16 }
}
```

### 6.3 `round_started`
Broadcast.
```json
{ "type": "round_started", "v": 1, "roundId": 42, "phase": "registering", "registerDeadlineMs": 1713650015000 }
```

### 6.4 `pair_assigned`
**Private** — sent only to the player it concerns. Contains the cue but NOT the partner's identity (the whole game is finding them).
```json
{
  "type": "pair_assigned",
  "v": 1,
  "roundId": 42,
  "role": "pair" | "poison_apple",
  "cue": {
    "cueId": "cue_dog_bark_a",
    "kind": "audio" | "image" | "text" | "task",
    "modality": ["audio", "haptic", "text"],
    "payload": { "text": "Bark like a dog", "audioUrl": "https://.../bark.mp3" },
    "complementHint": "Find the player imitating you"
  },
  "findDeadlineMs": 1713650075000
}
```

### 6.5 `pair_confirmed`
Sent to both members of a confirmed pair when their `pair_evidence` matches the server's expectation.
```json
{ "type": "pair_confirmed", "v": 1, "roundId": 42, "partnerPlayerId": "p_7", "partnerDisplayName": "Sam", "elapsedMs": 14230 }
```

### 6.6 `pair_rejected`
Sent privately when evidence is received but does not match the assigned partner (typical when a player taps the wrong person).
```json
{ "type": "pair_rejected", "v": 1, "roundId": 42, "reason": "wrong_partner" | "stale_evidence" | "phase_mismatch" }
```

### 6.7 `round_resolved`
Broadcast when the round ends (timer expired or all pairs confirmed).
```json
{
  "type": "round_resolved",
  "v": 1,
  "roundId": 42,
  "results": [
    { "playerId": "p_1", "outcome": "found",      "rankInRound": 1, "scoreDelta": 100, "totalScore": 300 },
    { "playerId": "p_2", "outcome": "found",      "rankInRound": 1, "scoreDelta": 100, "totalScore": 300 },
    { "playerId": "p_7", "outcome": "eliminated", "rankInRound": 4, "scoreDelta": 0,   "totalScore": 150 },
    { "playerId": "p_9", "outcome": "poison_won", "rankInRound": 1, "scoreDelta": 200, "totalScore": 200 }
  ],
  "nextPhase": "between_rounds" | "ended"
}
```

### 6.8 `error`
```json
{ "type": "error", "v": 1, "code": "room_full" | "bad_room_code" | "not_host" | "phase_mismatch" | "rate_limited" | "internal", "message": "human readable" }
```

## 7. Pair-evidence matching algorithm (server-side, normative)

Within a 750 ms window the server collects all `pair_evidence` messages from all devices in the room currently in the same phase. Then for each ordered pair `(A, B)` of devices it computes a score:

```
score(A,B) =
   3.0 * I(A and B each report a bump within ±200 ms of each other)
 + 2.0 * I(A reports BLE seeing B.selfToken AND/OR vice versa, with RSSI > -55 dBm)
 + 4.0 * I(A reports UWB distance to B.selfToken < 0.20 m AND/OR vice versa)
 + 2.0 * I(A reports hearing B's chirp AND/OR vice versa, SNR > 10 dB)
```

A pair is considered *touched* if `score >= 4.0`. The server then:

1. Greedily picks the highest-scoring touch claim.
2. If the touched pair matches the assigned pair for the round, emits `pair_confirmed` to both.
3. Otherwise emits `pair_rejected` privately to both, and removes their evidence from this window so they can re-tap.

Rationale: any single channel can be spoofed or noisy. Requiring score >= 4.0 means at least UWB alone, OR BLE + bump, OR BLE + audio, OR bump + audio. This keeps the SE 2 (no UWB) playable while making UWB devices have a single-channel "magic" path.

## 8. Versioning

- This document is `v=1`. Any breaking change increments the major. Additive changes (new optional fields, new channel kinds) keep `v=1` and clients ignore unknown fields.
- Server announces supported protocol versions in `hello_ack`. Mismatched clients receive `error` code `"protocol_version"` and disconnect.

## 9. Security & privacy notes

- The `selfToken` rotates each round and is meaningless outside the round. It is NOT a stable device identifier.
- `displayName` is the only PII transmitted; users are warned at first launch.
- All radio adverts contain only the round-scoped token, never the deviceId or displayName.
- Server logs evidence for the duration of a round only; logs are purged at room end.
