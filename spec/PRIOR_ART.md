# TapPair Prior Art & Similar Apps

Status: **Informational**. This is a research summary, not a contract. It records
existing products and platform mechanisms that overlap with TapPair, so design
and positioning decisions can reference prior work instead of re-deriving it.

Scope note: this is a targeted survey from public web sources (see **Sources**),
not an exhaustive market study. Player counts, pricing, and feature details
change; verify before quoting externally.

## 1. Why this document exists

TapPair combines four layers that most party apps use only one or two of:

| Layer | TapPair choice | See |
|-------|----------------|-----|
| Proximity / touch | BLE token sighting + accelerometer bump, optional UWB distance | `spec/PROTOCOL.md` §7 |
| Authority | Server (or planned LAN host) decides "who touched whom" from evidence | `spec/ARCHITECTURE.md` §1 |
| Social loop | Same-room party rules (assign, timer, eliminate, vote) | `RoundEngine` |
| Transport | WebSocket to central node or LAN host — **not** game state carried on BLE alone | `TapPairCore/Networking` |

The value of surveying prior art is to (a) confirm TapPair is not re-inventing
"phones in a party game" (Jackbox owns that category), and (b) identify the
thinner lane TapPair actually occupies: **physical, in-room confirmation that two
specific handsets came together**, arbitrated by a trusted process, with party
rules layered on top.

## 2. Categories of prior art

### 2.1 Phone-as-controller + shared screen (Jackbox model)

One screen everyone watches; phones send input only. No phone-to-phone touch.

| Product | Mechanism | Touch / proximity? |
|---------|-----------|--------------------|
| Jackbox Party Packs | Game runs on PC/console/TV; players join at `jackbox.tv` via room code | No |
| AirConsole | Browser on TV/laptop is the console; phone is a gamepad | No |
| Gaming Couch / PlayCloud | QR / code join; browser host + phone controllers | No |
| Kahoot | Host screen + phones answer | No |

Overlap with TapPair: room codes, private per-player prompts, voting (relevant to
the proposed mafia / Fakin'-It-style modes). Key difference: these treat the phone
as a **dumb pad** and require a **shared display**; TapPair's differentiator is the
physical touch between handsets and no required central screen.

### 2.2 Local multiplayer over LAN / Wi‑Fi / hotspot (no cloud required)

| Product | Mechanism |
|---------|-----------|
| Spaceteam | Same-room co-op; Wi‑Fi (Bonjour/multicast) or same-OS Bluetooth; optional internet "team password" room for remote play |
| DUAL! | Two phones over Wi‑Fi or Bluetooth; action passes between screens |

Overlap: local room, no cloud needed, party energy. Spaceteam is the strongest
**engineering** reference for the "player 1 hosts on the local network" question —
its client/server auto-election on iOS and explicit Host/Join on Android map
directly onto the "host-as-server" option discussed for TapPair. Difference:
Spaceteam is per-screen co-op chaos, not touch-to-identify.

### 2.3 OS peer frameworks: Apple Multipeer / Android Nearby

| Example | Notes |
|---------|-------|
| Multipeer Connectivity | Wi‑Fi P2P + Bluetooth; ~8 peers; used in local indie games |
| Android Nearby Connections | Bluetooth/Wi‑Fi discovery + connect; used for "nearby battle" features |
| CultureTap | NFC tap to handshake, then Multipeer for data exchange |

Overlap: player 1 can be the hub with no central TapPair server. Difference:
TapPair currently standardizes on WebSocket + a server-side evidence matcher;
MPC/Nearby are alternative transports, and MPC in particular complicates the
Android parity goal (`spec/ARCHITECTURE.md` §3).

### 2.4 Tap phones together (NFC / bump) to connect or play

| Product | Mechanism |
|---------|-----------|
| Car Trumps (Windows Phone 8) | NFC touch to deal cards, compare stats, pass turns between two phones |
| CultureTap | NFC handshake + Multipeer data |
| Bump™ (legacy) | Tap phones to pair for sharing (not party rules) |
| Windows Phone Proximity APIs | Tap-or-browse local matchmaking abstraction over BT/NFC/Wi‑Fi |

Overlap: the **strongest** conceptual parallel to "phones touching is the verb."
Difference: these are almost always **2-player**, NFC-era handshakes; TapPair uses
BLE tokens + bump scoring for **many** players and a server-side matcher rather
than a direct point-to-point NFC link (Apple does not expose phone-to-phone NFC to
third-party apps, which is why TapPair uses BLE+bump; see `PLAN.md`).

### 2.5 Bluetooth "who is nearby" discovery (not necessarily touch)

| Example | Mechanism |
|---------|-----------|
| Nearby-battle mobile games | Room codes + Nearby Connections to find players in the room |
| Legacy Android Bluetooth games (e.g. Battleships + Bump identity libs) | BT multiplayer, optional bump for identity |

Overlap: BLE/RSSI to answer "who is in the room." Difference: TapPair uses that
same signal as **evidence for a specific touch claim**, not merely lobby discovery.

### 2.6 UWB / precise distance (TapPair's optional accelerator)

| Context | Notes |
|---------|-------|
| Apple Nearby Interaction | U1/UWB distance + direction, iPhone 11+; WWDC demos include spatial two-phone games |
| Shipped party titles | Rare as a core mechanic; mostly demos, accessories, AR experiments |

Overlap: TapPair's planned `UwbPairingProvider`. Difference: few consumer party
games productize UWB; TapPair treats it as an accelerator over the BLE+bump
baseline, never a requirement (`PLAN.md` phase 4).

### 2.7 Same-room social / co-op without touch as the core verb

| Product | Mechanism |
|---------|-----------|
| Keep Talking and Nobody Explodes | One bomb screen; friends read a manual on their phones — voice, not touch |
| Heads Up! | One phone as a prop; others shout clues |
| Among Us / Werewolf / mafia apps | Roles + votes on phone; discussion in person; no touch pairing |

Overlap: the **social design** relevant to proposed mafia / Fakin'-It modes.
Difference: communication and UI carry the game, not proximity evidence.

## 3. Closeness to the full TapPair stack

```
                    Touch / proximity as gameplay
                              |
         Car Trumps (NFC)     |     TapPair (target)
         CultureTap (NFC+MPC) |
                              |
    BLE "nearby" only --------+-------- Jackbox / AirConsole
    (nearby-battle games)              (phones = pads only)
                              |
              Spaceteam / DUAL! (local net, no touch-match)
```

No widely known mass-market title appears to combine all of: 8–16 players in one
room; complementary secret assignments; server-authoritative "did these two phones
touch" from BLE + bump (+ UWB); and multiple party rule sets on one stack. The
nearest relatives, by dimension:

- **Business / product shape:** Jackbox, AirConsole (party, room code, private
  phone UI) — different physical mechanic.
- **Local-network / no-cloud engineering:** Spaceteam — different gameplay.
- **Touch-to-proceed interaction:** Car Trumps and other NFC tap games,
  CultureTap — usually 2-player and simpler rules.
- **Host-less / LAN topology:** Multipeer / Nearby Connections indies — rarely the
  evidence-matcher pattern.

## 4. Implications for TapPair

1. **Positioning:** Do not market against Jackbox on breadth of content; market on
   the in-room physical mechanic (touch + proximity + trusted arbiter). The
   category "phones in a party game" is taken; "phones confirming real-world
   proximity for party rules" is thinner and defensible.
2. **Local-host feasibility:** Spaceteam demonstrates that same-room, no-internet
   play with auto host election is a shipped, proven pattern. This de-risks the
   "player 1 runs the authority on-device over LAN/hotspot" direction; the open
   work is host lifecycle (discovery, foreground, crash) and where `RoundEngine`
   executes, not the game rules.
3. **Touch handshake precedent:** NFC tap games validate the "touch to proceed"
   feel, but Apple's lack of third-party phone-to-phone NFC is why TapPair's
   BLE+bump choice is correct; cite this when justifying the sensor stack.
4. **Mode fit:** Mafia and Fakin'-It-style modes align with the Jackbox/among-us
   lineage (votes, private roles/prompts), not with the touch-pairing lineage.
   They are compatible with the platform but are a separate engine family; touch
   is optional garnish for them.
5. **UWB is a differentiator, not a dependency:** Because shipped party games
   rarely use UWB, a polished UWB-accelerated pairing path is a marketing angle —
   but the baseline must remain BLE+bump so the iPhone SE 2 stays first-class.

## 5. Open questions this survey did not resolve

- Whether any current App Store / Play Store title already ships BLE+bump
  many-player touch matching (not found, but absence of evidence is not proof).
- Cross-platform (iOS↔Android) local play: every surveyed same-OS Bluetooth game
  (e.g. Spaceteam) falls back to Wi‑Fi for cross-platform, which supports
  TapPair's LAN-WebSocket direction over MPC for the Android goal.
- UWB interop across vendors on Android (deferred in `PLAN.md` phase 7).

## 6. Sources

Accessed 2026-07-01 via web search; URLs may drift.

- Jackbox Games — https://www.jackboxgames.com/ ; Fakin' It — https://www.jackboxgames.com/games/fakin-it ; Jackboxpedia Fakin' It — https://jackbox.wiki/wiki/Fakin%27_It
- AirConsole — https://apps.apple.com/gb/app/airconsole/id1017688554
- Gaming Couch — https://gamingcouch.com/ ; PlayCloud — https://play.google.com/store/apps/details?id=com.playcloud.console
- Spaceteam — https://spaceteam.ca/ ; FAQ — https://spaceteam.ca/faq/ ; networking write-up — http://spaceteamadmirals.club/blog/the-spaceteam-networking-post/
- DUAL! — https://play.google.com/store/apps/details?id=com.Seabaa.Dual
- Multipeer Connectivity — https://developer.apple.com/documentation/multipeerconnectivity ; games overview — https://www.objc.io/issues/18-games/multipeer-connectivity-for-games
- CultureTap — https://devpost.com/software/culturetap
- Car Trumps (NFC, WP8) — https://github.com/microsoft/car-trumps
- Windows Phone Proximity APIs — https://blogs.windows.com/windowsdeveloper/2013/07/24/proximity-in-windows-phone-8/
- Nearby Interaction (UWB) — https://developer.apple.com/documentation/nearbyinteraction ; WWDC20 — https://developer.apple.com/videos/play/wwdc2020/10668/
- Keep Talking and Nobody Explodes — https://keeptalkinggame.com/mobile/
