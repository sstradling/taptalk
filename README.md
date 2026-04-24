# TapPair

A multiplayer party game whose core mechanic is **two phones touching**. One
player starts a game; everyone else joins; players are randomly paired each
round and have to find their partner using complementary cues (sounds, prompts,
short tasks). Modes include musical chairs, poison apple, and scavenger hunt.

This repo contains the phase-0 prototype:

- **`spec/`** — wire protocol and architecture documents that pin down the
  server/client contract.
- **`server/`** — Node + TypeScript WebSocket server: lobby manager, round
  state machine, evidence matcher.
- **`ios/TapPair/`** — iOS 17+ SwiftUI app:
  - `TapPairCore` — platform-agnostic Swift package (Codable models,
    WebSocket client, GameStore reducer, PairingProvider abstraction).
  - `TapPairApp` — iOS-only target with the SwiftUI views and the radio
    implementations (`BleBumpPairingProvider`, `UwbPairingProvider`,
    `CompositePairingProvider`).
- **`PLAN.md`** — phased implementation plan from prototype to launch.

## Reading order

1. `spec/PROTOCOL.md` — what the wire looks like.
2. `spec/ARCHITECTURE.md` — how the modules fit together.
3. `PLAN.md` — sequenced work, exit criteria, risks.
4. `server/src/EvidenceMatcher.ts` — the algorithm that decides "who touched
   whom" from raw sensor reports.

## Running the server

```bash
cd server
npm install
npm test          # 15 tests, ~300 ms
npm run dev       # listens on ws://0.0.0.0:8080
```

## Running the iOS core tests (no Xcode required)

```bash
cd ios/TapPair
swift test        # 14 tests on Linux/macOS
```

## Building the iOS app (Xcode)

```bash
brew install xcodegen
cd ios/TapPair
xcodegen generate
open TapPair.xcodeproj
```

Then edit `serverURL` in `Sources/TapPairApp/AppViewModel.swift` to point at
your dev server, and run on a device (the BLE provider and motion sensing do
not function meaningfully in the iOS simulator).

## What the recommended-architecture default looks like

By default the iOS app composes a `BleBumpPairingProvider` (works on every
iPhone, including the iPhone SE 2nd gen) and submits sensor *evidence* to the
server, which decides who paired with whom. The app generates a fresh
round-scoped 64-bit token for each round, advertises exactly that token over
BLE, and sends the same token in `pair_evidence.selfToken`.

The `UwbPairingProvider` source is scaffolded, and Settings shows whether the
device has UWB-capable hardware, but active NearbyInteraction pairing is gated
off until the protocol adds a server relay for `NIDiscoveryToken` exchange
(`PLAN.md` phase 4). This keeps the prototype honest: the current working path
is BLE + accelerometer bump.

This shape is intentional: the server is the source of truth for pairing
decisions, the radios on each phone are merely evidence sources. That means:

- a future Android client implements only `BleBumpPairingProvider`-equivalent
  classes and talks the same WebSocket protocol — no architectural change;
- the iPhone SE 2 is a first-class device, not an afterthought;
- adding/removing a radio backend is a one-file change.

## Status

Phase 0 in `PLAN.md` is complete: protocol locked, server passes 16 tests
(unit + integration), and iOS core is covered by Swift package tests. The iOS
app target is source-scaffolded for Xcode/device validation. Next: phase 3
(hardware-tune BLE/bump) and phase 4 (UWB token exchange via the server).
