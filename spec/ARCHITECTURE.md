# TapPair Architecture v0.1

## 1. Goals (in order)

1. **Server-authoritative pairing.** Phones report sensor *evidence*; the server decides who paired with whom. This dodges every iOS↔Android peer-protocol problem and gives anti-cheat for free.
2. **Pluggable proximity providers.** Adding/removing a radio backend (BLE, bump, UWB, audio, QR) must not touch game logic.
3. **Cross-platform-ready.** v1 ships iOS-only, but the server protocol and the radio choices must permit an Android client later with no protocol change.
4. **iPhone SE 2 is a first-class device.** UWB is an optional accelerator, never required.
5. **Small, testable modules.** Game logic is pure functions. Radios are isolated behind a `PairingProvider` interface.

## 2. High-level shape

```
+-----------------------------+        wss://       +---------------------------+
|  iOS app  (SwiftUI)         | <-----------------> |  Node + TS WebSocket      |
|                             |                     |  server (single process,  |
|  +-----------------------+  |                     |  in-memory rooms)         |
|  |  TapPairCore (SPM)    |  |                     |                           |
|  |  - protocol models    |  |                     |  +---------------------+  |
|  |  - WebSocketClient    |  |                     |  | LobbyManager        |  |
|  |  - GameStore (state)  |  |                     |  | RoundEngine         |  |
|  |  - PairingProvider    |  |                     |  | EvidenceMatcher     |  |
|  |    protocol           |  |                     |  | CueDispatcher       |  |
|  +-----------------------+  |                     |  +---------------------+  |
|                             |                     |                           |
|  +-----------------------+  |                     +---------------------------+
|  |  PairingProviders     |  |
|  |   - BleBumpProvider   |<-+----- default
|  |   - UwbProvider       |<-+----- toggleable, iPhone 11+
|  +-----------------------+  |
+-----------------------------+
```

## 3. iOS module layout

```
ios/TapPair/
  Sources/
    TapPairCore/                 # platform-agnostic logic, fully unit-tested
      Protocol/                  # Codable models that mirror spec/PROTOCOL.md
      Networking/                # WebSocketClient (URLSessionWebSocketTask)
      State/                     # GameStore (Observable), reducer-style updates
      Pairing/                   # PairingProvider protocol, EvidenceCoalescer
      Cues/                      # CueRenderer (text/audio/image abstractions)
    TapPairApp/                  # SwiftUI app, depends on TapPairCore
      Views/
        LobbyView.swift
        RoundView.swift
        SettingsView.swift       # contains UWB toggle
        ResultsView.swift
      Providers/                 # platform-specific PairingProvider impls
        BleBumpPairingProvider.swift   # default, works on every iPhone
        UwbPairingProvider.swift       # NearbyInteraction, iPhone 11+
        CompositePairingProvider.swift # fans out to enabled providers
      App.swift
  Tests/
    TapPairCoreTests/            # XCTest, no UIKit/CoreBluetooth deps
```

The `TapPairCore` target is a pure Swift Package. It contains zero references to `CoreBluetooth`, `NearbyInteraction`, `AVFoundation`, or `UIKit`. This is what makes it testable and what would let it be reused by a watchOS/macOS extension or an Android port (via swift-on-android or as a reference implementation).

## 4. Pairing provider abstraction

```swift
public struct PairingEvidenceChannel: Codable, Equatable {
    public enum Kind: String, Codable { case bump, ble, uwb, audio }
    public let kind: Kind
    public let peerToken: String?
    public let observedAtMs: Int64
    public let rssiDbm: Double?
    public let distanceM: Double?
    public let magnitudeG: Double?
    public let snrDb: Double?
    public let confidence: Double?
}

public protocol PairingProvider: AnyObject {
    var kind: PairingEvidenceChannel.Kind { get }
    var isAvailable: Bool { get }
    func start(roundId: Int, selfToken: String) async throws
    func stop() async
    var evidenceStream: AsyncStream<PairingEvidenceChannel> { get }
}
```

- `BleBumpPairingProvider` actually implements TWO channels (BLE and bump) because they're naturally co-located on a single tap event; it emits one `PairingEvidenceChannel` per channel observed.
- `UwbPairingProvider` is gated behind both a runtime capability check (`NIDeviceCapability.supportsPreciseDistance`) and a user-facing toggle in `SettingsView`.
- `CompositePairingProvider` simply forwards `start`/`stop` and merges streams.

The app composes providers at startup based on:
- device capability (UWB present?)
- user setting (UWB enabled?)
- always include BLE+bump (the baseline that lets every device play)

## 5. Server module layout

```
server/
  src/
    index.ts            # bootstrap, ws server
    protocol.ts         # zod schemas for every message in spec/PROTOCOL.md
    LobbyManager.ts     # room lifecycle, codes, players
    RoundEngine.ts      # phase state machine per round
    EvidenceMatcher.ts  # the §7 algorithm from the protocol spec
    CueDispatcher.ts    # picks cue pairs from a content bank
    cueBank.ts          # seed content (text-only for prototype)
    log.ts
  test/
    EvidenceMatcher.test.ts
    RoundEngine.test.ts
    integration.test.ts # spins up server, drives two fake clients
  package.json
  tsconfig.json
```

Stateless-ish per process: rooms live in memory. Horizontal scale-out is out of scope for v1; one process comfortably handles thousands of rooms. When we need multi-process, the natural seam is a Redis pub/sub adapter behind `LobbyManager`.

## 6. State machines

### 6.1 Round phase (server)

```
lobby --start_round--> registering --register_deadline--> finding --all_pairs_found_or_deadline--> resolving --emit round_resolved--> between_rounds
                                                                                                                                          \
                                                                                                                                           --game_over--> ended
```

### 6.2 Client GameStore

The client mirrors a subset of server state and adds local-only fields (e.g. "did the user grant Bluetooth permission?"). Updates are reducer-style: every server message becomes an `Action`, applied to a single `GameState` value.

## 7. Why this shape scales/maintains well

- **One source of truth (the server) for game-correctness state**, one source of truth (the device) for sensor evidence. Each side has clear ownership.
- **The protocol document is the contract.** Both client (Swift `Codable`) and server (TS `zod`) parse against it, and the integration test exercises both. Drift between the two is catchable in CI.
- **Adding Android later is mechanical**, not architectural: implement Kotlin equivalents of `PairingProvider` (BLE + accel-bump are the only required ones for a baseline) and a Kotlin `WebSocketClient` against the same protocol.
- **Game-mode rules live in `RoundEngine` only.** Adding "scavenger hunt" or a new mode is a single-file change; the protocol and matcher don't move.
- **Cue content lives in `cueBank.ts`** and is loaded from JSON. Designers can iterate without code changes; later this becomes a CMS-fronted service.
