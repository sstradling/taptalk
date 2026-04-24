# AGENTS.md

Notes for AI coding agents working on this repository.

## iOS / Swift specialization is available

This project has a working iOS client (`ios/TapPair/`) and is the primary target
platform. **Use the iOS- and Swift-specific skills when doing development work
on this repo.** That includes:

- Xcode-aware reasoning (project, scheme, signing, simulator vs device).
- Swift 6 strict concurrency (`Sendable`, `@preconcurrency`, `nonisolated`,
  actor isolation, `@MainActor`).
- SwiftUI + the `@Observable` macro and its constraints
  (e.g. tracked properties cannot be `lazy` or computed).
- Apple frameworks used here: `CoreBluetooth`, `CoreMotion`,
  `NearbyInteraction`, `URLSessionWebSocketTask`, `Security`/Keychain,
  `CoreHaptics`.
- `CBCentralManager` / `CBPeripheralManager` advertising/scanning patterns,
  RSSI tuning, BLE service-UUID design, foreground vs backgrounded behavior.
- iOS permission UX (Bluetooth, Local Network, Motion, NearbyInteraction).
- Swift Package Manager layout (`TapPairCore` is intentionally portable),
  `xcodegen` for the `TapPairApp` target.
- iOS testing (`XCTest`, async tests, `swift test` from the package).

When in doubt, prefer iOS-native APIs and Swift 6 best practices over
generic Foundation patterns.

## Repo layout reminders

- `spec/` is the source of truth for the wire protocol and architecture.
  Update `spec/PROTOCOL.md` and `spec/ARCHITECTURE.md` whenever the wire
  format or module shape changes.
- `server/` (Node + TypeScript) and `ios/TapPair/` (Swift) must stay in
  sync via the spec; the integration test in `server/test/integration.test.ts`
  is the cross-language safety net.
- `TapPairCore` must remain platform-agnostic (no UIKit / CoreBluetooth /
  NearbyInteraction). Anything Apple-specific belongs in `TapPairApp`.

## Local verification

```bash
cd server && npm test && npm run lint
cd ios/TapPair && swift test         # requires Swift toolchain
```

Cloud agent VMs do not always have a Swift toolchain installed; if `swift
test` is unavailable, say so explicitly in your summary instead of claiming
the iOS tests passed.

## Conventions

- Follow the user rules in this repo: small files, small functions, document
  public surface, add unit tests for business logic, integration tests for
  cross-service flows.
- Do not estimate calendar time in plans; describe technical scope instead.
- Do not silently broaden scope. Stick to the requested change and call out
  follow-ups separately.
