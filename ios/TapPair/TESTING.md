# Manual device testing — TapPair

The unit tests cover the wire protocol, the reducer, and the evidence-coalescing
logic. They cannot cover the radio actually working. This document is the
two-/three-/six-phone playtest script.

## Prerequisites

- A reachable TapPair server (default `ws://192.168.x.x:8080`). For local
  testing, run `npm run dev` from `server/` and edit `serverURL` in
  `AppViewModel.swift` to your laptop's LAN IP.
- Two iPhones on the same Wi-Fi (and within Bluetooth range — same room).
- For the UWB test: at least one of the phones must be iPhone 11 or later.

## Two-phone happy path (BLE + bump only — the SE-2 path)

1. On both phones, open Settings (gear icon) and toggle UWB **OFF**.
2. On phone A, enter a display name and tap "Musical Chairs".
3. On phone B, enter a display name; type the 4-letter room code from A; tap "Join".
4. On phone A, tap "Start round".
5. Both phones show their cue. Bring them physically together and tap them.
6. **Expected:** within ~750 ms both phones show "Paired with <name>".
7. **Expected:** within a few more seconds both phones move to the Results screen.

## Two-phone UWB-accelerated path

1. Both phones running iOS 17+ with U1/U2 chips.
2. In Settings on both, toggle UWB **ON** (default for capable devices).
3. Run the two-phone happy path above.
4. **Expected:** confirmation feels noticeably crisper (sub-200 ms) and the
   phones do not need to actually touch — bringing them within ~10 cm is enough.

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
| Two-phone UWB        | 13 + 14 Pro          |           |                               |       |
| Six-phone musical    | mixed                |           |                               |       |
| Wrong partner reject | 3 phones             |           |                               |       |
| Disconnect mid-round | 2 phones             |           |                               |       |
