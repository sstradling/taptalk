# Manual device testing — TapPair

The unit tests cover the wire protocol, the reducer, and the evidence-coalescing
logic. They cannot cover the radio actually working. This document is the
two-/three-/six-phone playtest script.

## Prerequisites

- A reachable TapPair server (default `ws://192.168.x.x:8080`). For local
  testing, run `npm run dev` from `server/` and edit `serverURL` in
  `AppViewModel.swift` to your laptop's LAN IP.
- Two iPhones on the same Wi-Fi (and within Bluetooth range — same room).
- UWB hardware is detected in Settings, but active UWB ranging is disabled
  until the WebSocket protocol relays `NIDiscoveryToken` values (PLAN.md
  phase 4). Current device tests should focus on BLE+bump.

## Two-phone happy path (BLE + bump only — the SE-2 path)

1. On both phones, open Settings (gear icon) and toggle UWB **OFF**.
2. On phone A, enter a display name and tap "Musical Chairs".
3. On phone B, enter a display name; type the 4-letter room code from A; tap "Join".
4. On phone A, tap "Start round".
5. Both phones show their cue. Bring them physically together and tap them.
6. **Expected:** within ~750 ms both phones show "Paired with <name>".
7. **Expected:** within a few more seconds both phones move to the Results screen.

## UWB readiness check

1. Open Settings on an iPhone 11 or newer.
2. **Expected:** the UI reports that UWB hardware is available, but the toggle
   is disabled because server-side `NIDiscoveryToken` relay is not implemented.
3. Run the BLE+bump happy path above; UWB should not emit evidence yet.

## Wrong-partner test

1. Three phones in the room, one round started.
2. Player A taps Player C (who is not A's assigned partner).
3. **Expected:** both A and C see a transient "Wrong partner — try again"
   message; neither is confirmed.

## Disconnect / reconnect

1. Mid-round, force-quit the app on phone B.
2. Re-open phone B.
3. **Expected:** phone B reconnects, sends a fresh `hello`, receives the
   current `room_state` and rejoins the in-progress round if still alive.

## Telemetry to capture during manual tests

Track these in a shared sheet for each test session:

| Test                 | Devices              | Pass/Fail | Median latency tap → confirm | Notes |
|----------------------|----------------------|-----------|-------------------------------|-------|
| Two-phone BLE+bump   | SE2 + 13             |           |                               |       |
| UWB readiness check  | 13 + 14 Pro          |           |                               |       |
| Six-phone musical    | mixed                |           |                               |       |
| Wrong partner reject | 3 phones             |           |                               |       |
| Disconnect mid-round | 2 phones             |           |                               |       |
