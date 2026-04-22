# TapPair — Full Implementation Plan

This plan turns the proposed party game into a shippable iOS app + a small backend, with a clear path to an Android client. Phases are sized by *technical scope*, not calendar time. Each phase has explicit exit criteria and is independently demoable.

## Reading order

1. `spec/PROTOCOL.md` — the wire contract.
2. `spec/ARCHITECTURE.md` — the module shape and why.
3. This document — the sequence of work and the test/release strategy.

---

## Phase 0 — Spec & scaffold (this PR)

**Scope:** lock the wire protocol; stand up empty-but-buildable iOS app and Node server that exchange a `hello`/`hello_ack` and nothing more.

**Deliverables**
- `spec/PROTOCOL.md`, `spec/ARCHITECTURE.md`, `PLAN.md`.
- `server/` with `npm test` green.
- `ios/TapPair/` with `swift test` green for the `TapPairCore` package.
- This PR.

**Exit criteria**
- A reviewer can read the spec and understand what the server expects.
- `swift test` and `npm test` both pass in CI on a clean clone.

**Risk:** none material; this is structural.

---

## Phase 1 — Server: lobby + round skeleton

**Scope**
- `LobbyManager`: create/join/leave, host election, room codes.
- `RoundEngine`: state machine through `lobby → registering → finding → resolving → between_rounds`.
- `EvidenceMatcher`: the algorithm from §7 of the protocol, behind a pure-function interface.
- `CueDispatcher`: picks pairs from a static text-only `cueBank.ts` (e.g. "Bark like a dog" / "Meow like a cat").
- Modes: `musical_chairs` only. `poison_apple` and `scavenger_hunt` deferred to phase 5.

**Tests**
- Unit: `EvidenceMatcher` table-driven cases for every score combination at boundaries (3.99 vs 4.00).
- Unit: `RoundEngine` transitions on each event.
- Integration: spin server, connect two `ws` clients, simulate a full round end-to-end, assert `pair_confirmed` arrives.

**Exit criteria**
- Two `wscat` shells can: create a room, join it, start a round, post fake evidence, receive `pair_confirmed`.

**Risks**
- Off-by-one in the 750 ms coalescing window. Mitigated by table-driven tests.

---

## Phase 2 — iOS core (no radios yet)

**Scope**
- `TapPairCore` Swift package: `Codable` models for every message, `WebSocketClient`, `GameStore` (using iOS 17 `@Observable`), `PairingProvider` protocol.
- `MockPairingProvider` for tests and for a "tap the button to fake a touch" debug build flavor.
- A minimal SwiftUI app with three screens: lobby, in-round, results. Wired to a real server URL via `Settings.bundle`.

**Tests**
- Codable round-trip for every message in the protocol against fixture JSON shared with the server.
- `GameStore` reducer tests: server message in, expected state out.

**Exit criteria**
- On a real iPhone (or simulator), two app instances can join a room, start a round, and confirm a pair *via on-screen "fake tap" button*. No real radios involved.

**Risks**
- iOS 17 `@Observable` quirks with deep nested state. Mitigated by keeping `GameState` flat.

---

## Phase 3 — BLE + Bump pairing provider (the default)

**Scope**
- `BleBumpPairingProvider`:
  - `CoreBluetooth`: advertise a custom 128-bit service UUID with a 16-byte payload = `selfToken`. Scan for the same service UUID; for each peripheral discovered above an RSSI threshold, emit a `ble` evidence record.
  - `CoreMotion`: 100 Hz accelerometer; detect a sharp magnitude spike > 5 G with the right shape (rise then fall < 80 ms); emit a `bump` record.
  - Coalesce both channels for ~750 ms after a bump and submit a single `pair_evidence`.
- Permission flow: prompt for Bluetooth on lobby entry; prompt for Motion on first round; explainer screen *before* each system prompt.
- Background-mode plist entries (`bluetooth-central`, `bluetooth-peripheral`) — but app is foreground-only by design; backgrounded play is out of scope.

**Tests**
- `EvidenceCoalescer` unit tests with synthetic streams.
- Manual two-device test plan in `ios/TapPair/TESTING.md`.

**Exit criteria**
- Two iPhones in the same room can complete a round by physically tapping. Works on iPhone SE 2.

**Risks**
- iOS Local Network prompt isn't required for BLE-only, but if we later add Multipeer for discovery, it is. Document this if/when it arises.
- BLE service UUID overflow when backgrounded — not relevant for foreground play.
- RSSI varies wildly by device pose; threshold may need to be adaptive. Track RSSI distribution in telemetry.

---

## Phase 4 — UWB NearbyInteraction provider (toggleable)

**Scope**
- `UwbPairingProvider`:
  - On round start, exchange UWB `NIDiscoveryToken` between candidate peers via the WebSocket server (server relays opaque blobs; it doesn't parse them).
  - Start `NISession`s; emit `uwb` evidence whenever `nearbyObject.distance < 0.20 m`.
  - Tear down sessions on round end.
- `SettingsView` toggle: "Use UWB precise pairing (iPhone 11+)". Default ON when `NIDeviceCapability.supportsPreciseDistance` is true.
- `CompositePairingProvider` runs UWB *alongside* BLE+bump, never instead of it. UWB just makes the `score` cross the threshold faster.

**Tests**
- `UwbPairingProvider` is gated behind a protocol so it can be mocked.
- Manual test on UWB hardware (iPhone 11+) and a non-UWB device (SE 2) to confirm graceful absence.

**Exit criteria**
- Toggle works: with UWB on, two iPhone 11+ devices pair from a single touch with sub-200ms latency. With UWB off (or on SE 2), pairing falls back to BLE+bump and still works.

**Risks**
- UWB peer-token exchange must be round-scoped or it leaks across rounds.
- Power: UWB sessions are not free; stop them aggressively at round end.

---

## Phase 5 — Game modes & cue content

**Scope**
- Implement `poison_apple` and `scavenger_hunt` modes in `RoundEngine`. Each is one `switch` arm in `resolveRound()`.
- Expand `cueBank.ts` to ~50 cue pairs across categories (animal sounds, complete-the-phrase, picture-pair, complementary-prompt). Add a tiny content schema (JSON) and a CLI to validate it.
- Add per-modality variants (text + audio + visual) so each cue pair is accessibility-clean.
- Add the "round timer", "standings", and "spectator/eliminated" UI states.

**Tests**
- Mode-specific rule unit tests.
- Cue bank schema validation in CI.

**Exit criteria**
- A 6-player playtest with mixed devices (some SE 2, some iPhone 14+) can complete a full match in each of three modes.

**Risks**
- Cue tuning is an empirical, content-design problem, not a code problem. Build the playtest harness early.

---

## Phase 6 — Polish & robustness

**Scope**
- Reconnection: client preserves session token across socket drops; server holds state for 30 s.
- Onboarding: first-run permission rationale screens; one-round practice game.
- Haptics on tap confirmation (`CoreHaptics`).
- Telemetry: anonymized round metrics to a self-hosted endpoint (opt-in).
- Crash reporting (e.g. Sentry) with no PII.
- Anti-grief: rate-limit `pair_evidence` to 5/sec/device; rate-limit `join_room` per IP.
- Localization scaffolding (English only at launch, but `String Catalog`-ready).

**Exit criteria**
- TestFlight build with no P1 bugs from a 20-person internal test session.

---

## Phase 7 — Android client (optional, post-launch)

**Scope**
- Kotlin app, Jetpack Compose, targeting Android 10+ (API 29).
- `BleBumpPairingProvider` equivalent on Android (`BluetoothLeAdvertiser`, `BluetoothLeScanner`, `SensorManager`).
- Same WebSocket protocol; share JSON fixtures with iOS for parity tests.
- UWB on Android deferred until cross-vendor interop is real (`androidx.core.uwb`).

**Exit criteria**
- An Android phone can play in a room with iPhones using BLE+bump only. Confirmed on a Pixel and a Samsung mid-range.

**Risks**
- Android BLE advertising has manufacturer-specific quirks; build the device-test matrix early.
- Android requires `BLUETOOTH_SCAN`/`BLUETOOTH_ADVERTISE` runtime permissions on API 31+ and `ACCESS_FINE_LOCATION` on older.

---

## Cross-cutting concerns

### Testing pyramid
- **Unit (fast, every commit):** `EvidenceMatcher`, `RoundEngine`, `GameStore` reducer, every `Codable` model.
- **Integration (every commit):** server in-process + ws clients driven from TS tests; iOS `TapPairCore` against a fake server.
- **Device (manual, per release):** documented two-/three-/six-phone test scripts in `ios/TapPair/TESTING.md`.

### CI
- GitHub Actions matrix:
  - `server`: Node 20 LTS, `npm ci && npm test`.
  - `ios`: macOS runner, `xcodebuild test` on `TapPairCore` package.
  - `lint`: `swift-format`, `eslint`.

### Observability
- Structured JSON logs from the server (room id, round id, phase, latency).
- Client emits one telemetry blob per round (opt-in): mode, duration, evidence channel mix, success/failure.

### Security & privacy
- No account system in v1. `deviceId` is a Keychain-stored UUID, rotatable from settings.
- Only `displayName` is PII; explained at first launch.
- Server purges round logs at room end; retains only aggregate counts.
- TLS for `wss://` mandatory in prod.

### Deployment
- Server: single container, deployable to Fly.io/Railway/Render. No DB in v1.
- iOS: TestFlight → App Store. Minimum iOS 17, devices iPhone SE 2 and newer (covered by iOS 17 floor).

---

## What we're explicitly NOT doing in v1

- No accounts, no friends list, no persistent leaderboards. Rooms are ephemeral.
- No cross-room matchmaking. You play with the people in your room.
- No background play. App must be foregrounded.
- No NFC anything. Apple does not allow phone-to-phone NFC.
- No UWB on Android. Standards exist but interop isn't ready.
- No Apple Watch or AirPods integration. Both are interesting follow-ups.
- No user-generated cues. Curated content only at launch.

---

## Reflection

This plan deliberately sequences risk: the protocol and the matcher (the load-bearing decisions) are validated in phases 0–1 before any radio code is written, and the BLE+bump baseline (phase 3) is proven before the UWB enhancement (phase 4) is added. That ordering means we discover any wire-format mistake on day one rather than after committing to a sensor stack, and it also means the iPhone SE 2 path is the *first* path that ships, not an afterthought. The same ordering keeps the Android port (phase 7) cheap because nothing about phases 1–6 assumes an iOS-specific peer protocol.

The biggest unaddressed risk is content: a party game lives or dies by its cue bank, and the plan currently treats cue authoring as a single phase-5 task. A realistic next iteration of this plan should split phase 5 into "rules engine" and "content pipeline" workstreams, possibly with the content pipeline starting in parallel with phase 3 so that real cues are available the first time the radios light up.
