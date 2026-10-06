# Naki（鳴き）

**English** | [繁體中文](README.md)

**Your AI mahjong companion for Mahjong Soul. A native macOS and iOS app, with on-device inference by default.**

<p align="center">
  <img src="docs/images/macos-decision.png" width="760" alt="Naki on macOS: Mahjong Soul with an AI decision sidebar">
</p>

<p align="center">
  <a href="https://github.com/Sunalamye/Naki/releases/latest"><img src="https://img.shields.io/github/v/release/Sunalamye/Naki?color=green" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-26.0+-blue" alt="macOS 26.0 or later">
  <img src="https://img.shields.io/badge/iOS-17.0+-blue" alt="iOS 17.0 or later">
  <img src="https://img.shields.io/badge/Mac-Apple%20Silicon-red" alt="Apple Silicon required on Mac">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0%20%2B%20Commons%20Clause-lightgrey" alt="AGPL-3.0 with Commons Clause"></a>
</p>

<p align="center">
  <a href="https://github.com/Sunalamye/Naki/releases/latest"><b>Download</b></a> ·
  <a href="#quick-start"><b>Quick start</b></a> ·
  <a href="#features"><b>Features</b></a> ·
  <a href="#optional-cloud-inference"><b>Cloud inference</b></a> ·
  <a href="#for-developers"><b>For developers</b></a>
</p>

---

> [!WARNING]
> **For learning and research only.** Using Naki may violate Mahjong Soul's terms of service and may result in account suspension or a permanent ban.
>
> **Do not use your main account.** A secondary account is not exempt from these risks. The author is not responsible for losses arising from use of this software.

## What is Naki?

*Naki* (鳴き) is the Japanese mahjong term for calling tiles, such as chi, pon, and kan. When a call is worth considering, Naki helps you see your options.

Naki brings Mahjong Soul and a mahjong AI into one window. **No Python environment, Docker container, browser extension, or proxy server is required to use the app.** Open it, sign in, and view recommendations alongside the table, with suggested tiles highlighted in the game.

The local engine is based on [Mortal](https://github.com/Equim-chan/Mortal), running through Core ML on the Apple Neural Engine. **Local inference is the default:** model computation stays on your device and does not require an external inference service. Mahjong Soul itself still requires an internet connection.

You can optionally connect to an [Akagi](https://github.com/shinkuan/Akagi)-compatible inference server for hosted models, including dedicated three-player models. Cloud inference is **off by default** and has different privacy and availability implications; see [Cloud inference](#optional-cloud-inference).

---

## Quick start

### Requirements

| Platform | Minimum OS | Hardware | Automatic actions |
|---|---|---|---|
| macOS | 26.0+ | Apple Silicon | Supported |
| iOS / iPadOS | 17.0+ | A12 or later | Supported on iOS / iPadOS 26+; recommendations only on 17–25 |

Intel Macs are not supported by the current app. Local inference targets the Apple Neural Engine.

> [!IMPORTANT]
> iOS 17–25 uses the legacy `WKWebView` backend. **It displays recommendations but does not automatically submit actions.** The newer `WebPage` backend is used on macOS and iOS 26+. The legacy path has not been validated through a complete match on a physical device; see [Current status](#current-status).

### Install

Download a build from [Releases](https://github.com/Sunalamye/Naki/releases/latest).

| Platform | File | Installation |
|---|---|---|
| macOS | `Naki.dmg` | Open the disk image and drag Naki into Applications. |
| macOS | `Naki.zip` | Extract the app and move it into Applications. |
| iPhone / iPad | `Naki-M.ipa` | Sign and sideload the IPA using your own signing setup. Follow the release notes for the build you download. |

The published macOS build is not notarized, and the IPA is unsigned. macOS may require approval in System Settings before the app can open. Only approve a build from a source you trust; see the release notes for installation details.

### Start a session

1. Open Naki and select your Mahjong Soul server: Chinese, Japanese, or International.
2. Sign in with a **secondary account**, after reading the account-risk warning above.
3. Select **Recommend** to keep manual control, or choose an automatic mode on a supported platform.
4. Start a match. The sidebar shows the preferred action, alternatives, and expandable round details.

Your mode selection is saved across launches. **On a fresh installation, Auto is the default on supported platforms**, so switch to Recommend before starting a match when you only want advice. Legacy iOS devices restrict the available modes to Off and Recommend.

---

## Features

<table>
<tr>
<td width="52%">

### Recommendations where you need them

Suggested tiles are highlighted on the table, while the sidebar explains the decision.

- Read from top to bottom: best choice → alternatives → expandable round details.
- Recognizable tile artwork, with separate assets for red fives.
- Action support includes discards, chi, pon, kan, riichi, wins, north extraction, and the nine-terminals abortive draw, subject to the game mode and server-authorized actions.

</td>
<td width="48%">
<img src="docs/images/macos-details.png" width="100%" alt="Expanded round details and model information on macOS">
</td>
</tr>
<tr>
<td width="52%">
<img src="docs/images/ios-decision.png" width="100%" alt="Naki on a landscape iPhone: full-height table and right-hand decision panel">
</td>
<td width="48%">

### A layout built around the table

- **Mac:** a decision sidebar, with automatic actions and between-round confirmation on supported modes.
- **iPhone / iPad:** a full-height table with controls and decisions in a persistent right-hand panel.
- Dark mode and responsive layouts.

On a landscape iPhone, vertical space is the constraint. The layout gives that height back to the table and uses the spare width beside Mahjong Soul's 16:9 view for the panel.

</td>
</tr>
<tr>
<td width="52%">

### Round details without the clutter

Expand the summary row to inspect server-authorized actions, player scores, dora indicators, and whether the current recommendation came from the local or cloud model. Collapse it back to a single row when you are done.

</td>
<td width="48%">
<img src="docs/images/ios-details.png" width="100%" alt="Expanded round and model details on iPhone">
</td>
</tr>
</table>

<sub>The iPhone gameplay images were captured from the app running in an iOS 26 simulator. Player names are concealed using Naki's built-in name-hiding feature. The images retain the interface language used when they were captured.</sub>

### Choose your Mahjong Soul server

Naki supports the **Chinese, Japanese, and International** servers. By default, it asks which server to use at each launch. Accounts are separate across regions, so selecting the correct server matters for signing in.

Select the option to always use the chosen server to skip the prompt. You can change servers or restore the launch prompt in Advanced Settings.

<table>
<tr>
<td width="50%">
<img src="docs/images/server-picker-macos.png" width="100%" alt="Mahjong Soul server selection on macOS">
</td>
<td width="50%">
<img src="docs/images/server-picker-ios.png" width="100%" alt="Mahjong Soul server selection on iPhone">
</td>
</tr>
</table>

### Control how Naki assists you

| Mode | Behavior |
|---|---|
| **Off** | Hides recommendations and clears in-game highlights. No automatic actions are submitted. Inference continues in the background so recommendations can resume when you switch modes. |
| **Recommend** | Shows suggestions; you decide which actions to take. |
| **Auto** | Automatically submits actions through the decision and legality checks, and confirms the transition to the next round. |
| **Full Auto** | Adds automatic matchmaking for another match after the current match ends. Unlike Auto, this mode also authorizes starting the next match. |

Auto and Full Auto are available only on platforms that support automatic actions. The current mode definitions and platform restrictions are in [`AutoPlayMode.swift`](command/Services/Bot/AutoPlayMode.swift).

The toolbar also offers a **delay baseline** control, from 0.5 to 3.0 seconds. This scales a randomized action-delay distribution; it does not set a fixed delay for every action. A value of 1.0 seconds uses the baseline behavior, with higher values slowing it down and lower values speeding it up.

### Other tools

- **Hide player names:** protocol-level rewriting replaces names with `Player 1`–`Player 4` for matches started after enabling the option. Render-level hiding can take effect immediately. If the relevant render layer cannot be identified, the app leaves the display unchanged rather than hiding unrelated UI. This is a display feature, not a guarantee of anonymity.
- **Protocol-level emotes:** MCP tools can send emotes and inspect received broadcasts. The older automatic-reply path is not available with the Unity client.
- **MCP integration:** connect an AI assistant such as Claude Code to inspect state and use the app's exposed tools.
- **Local Debug API:** the HTTP server binds to loopback, not to other devices on your network.

---

## Optional cloud inference

Open **Advanced Settings → Cloud Inference** and supply your own API key. The default endpoint is Akagi's `mjapi.shinkuan.me`; an Akagi-compatible self-hosted endpoint can also be configured.

> [!IMPORTANT]
> **Enabling cloud inference sends the current round's accumulated game events, including your own hand, to the configured inference server at decision points.** It is not a local-only mode. The sidebar keeps the destination host visible while cloud inference is active.

| Area | Behavior |
|---|---|
| Opt-in | Disabled by default. Obtain your own key; the app does not include a purchase or redemption flow. |
| Key storage | Stored in Keychain. Logs show only the last four characters of the key. |
| Four-player fallback | The local model remains available. Timeouts, rate limits, or connection failures fall back to local decisions, with exponential retry backoff from 5 to 120 seconds. |
| Decision source | The sidebar and `/bot/status` identify the effective source as `local` or `cloud:<model>`. |
| Failure visibility | A prominent warning indicates degraded cloud service and consecutive fallback decisions. The API exposes `cloudDegraded` and `cloudFallbackStreak`. |
| Key status | After a key is entered, settings query `/v3/key` to show the plan, expiry, remaining days, and daily usage. |
| Model selection | Test Connection checks the endpoint and key, and lists the models available to the plan, including three-player models where available. |
| Live changes | The toolbar can switch cloud inference on or off during a match. Changes to the key or model take effect without restarting the match. |

### Three-player mahjong requires a cloud model

**Naki does not ship a local three-player model.** Three-player and four-player models use different observation layouts, so a four-player model is not a valid substitute. The local four-player model is not started for a three-player match.

Without an effective cloud result, there is no AI recommendation for that decision and no local-model fallback. North extraction is wired through the action pipeline, but three-player live-match validation remains incomplete. Do not interpret cloud integration as proof of fully validated three-player play; see [`AUDIT.md`](AUDIT.md).

### Settings on Mac and iPhone

<p align="center">
  <img src="docs/images/settings.png" width="760" alt="Illustration of the two-column Advanced Settings layout on macOS">
</p>

Mac settings use two columns: device and automation settings on the left, cloud inference on the right. Key status appears after a key is entered, without requiring Test Connection.

<sub>The macOS settings image is a design reference from <code>docs/ui-reference/</code>, not a screenshot of a fully rendered live settings sheet. The in-app screenshot API has limitations when capturing sheets; see the comments on <code>CaptureScreenshotAction.windowScreenshot</code>.</sub>

On iPhone, the same form uses a single-column layout:

<table>
<tr>
<td width="50%">
<img src="docs/images/ios-settings-general.png" width="100%" alt="General and automation settings on iPhone">
</td>
<td width="50%">
<img src="docs/images/ios-settings-cloud.png" width="100%" alt="Cloud inference settings on iPhone">
</td>
</tr>
</table>

The floating status message bar at the bottom of the table is **off by default**. It is intended for transient feedback and diagnostics. Persistent errors use a top banner and are not hidden by this setting.

For optional macOS notifications about cloud failures, reconnects, or stalled action submission, see [`scripts/cloud-watch.sh`](scripts/cloud-watch.sh). Cloud implementation and verification notes are tracked in [`AUDIT.md`](AUDIT.md) and [`docs/cloud-inference-plan.md`](docs/cloud-inference-plan.md).

---

## For developers

<details>
<summary><b>Architecture: protocol-driven, not screen-coordinate automation</b></summary>

```text
Mahjong Soul · Unity WebGL
          │
          │ WebSocket traffic / WebGL highlighting
          ▼
JavaScript bridge · naki-core / naki-websocket
          │
          ▼
Swift services
  MajsoulBridge → NativeBotController → LiqiActionSender
   Liqi → MJAI     Swift + Core ML       Protobuf actions
          │
  AutoPlayEngine → AutoPlayDecisionResolver
   Gates / delay     Legality / mode checks
          │
          ▼
GameStore ↔ SwiftUI views / MCP tools
```

The Unity WebGL client keeps game logic in WebAssembly rather than exposing the old JavaScript game objects. Naki therefore reads state from WebSocket messages and constructs protocol messages for actions. Protocol field definitions come from the game's published `res/proto/liqi.json` resource.

Tile highlighting hooks WebGL draw calls, identifies tile types from atlas UV coordinates, and temporarily changes draw colors. It does not depend on fixed screen coordinates. The hook is implemented, but screenshot-regression coverage has not established correct targeting for every tile and button.

**The server's available-action list, not the model, determines action legality.** The decision resolver fails closed when that list is missing and gives server-authorized wins priority over model suggestions. Regression fixtures cover important integration paths, but an adversarial live sequence that overrides a discard suggestion with a win and verifies the resulting server action has not been fully reproduced. This is not a claim that every missed-win issue has been eliminated.

The legacy backend shares decision logic but disables automatic action submission pending validation.

Further reading: [`docs/majsoul-unity-protocol.md`](docs/majsoul-unity-protocol.md), [`docs/architecture-deep-dive.md`](docs/architecture-deep-dive.md), and [`AUDIT.md`](AUDIT.md).

</details>

<details>
<summary><b>Debug API: local HTTP server on port 8765</b></summary>

The HTTP server uses the loopback interface (`127.0.0.1` / `::1`). Treat it as trusted local developer tooling, especially endpoints that execute JavaScript or submit game actions.

```bash
# Bot state, hand, and recommendations
curl http://localhost:8765/bot/status

# Actions currently allowed by the game protocol
curl http://localhost:8765/bot/ops

# Manually trigger an automatic-play cycle; this can submit a game action
curl -X POST http://localhost:8765/bot/trigger

# Execute JavaScript in the game page; use return to retrieve a value
curl -X POST http://localhost:8765/js -d 'return window.location.href'
```

`/status` reports the log path. Full log directories are retained for the eight most recent launches; older directories retain only game recordings under `games/`.

</details>

<details>
<summary><b>MCP server: connect Claude Code or another MCP client</b></summary>

The built-in [Model Context Protocol](https://modelcontextprotocol.io/) server shares port 8765 with the Debug API. Tool results use `structuredContent`, and non-loopback Origin requests are rejected.

```bash
claude mcp add --transport http naki http://localhost:8765/mcp
```

Discover the current tool inventory with `tools/list` or inspect `get_status.toolsCount`; a static count can become outdated as tools change.

| Area | Example tools |
|---|---|
| System | `get_status`, `get_logs`, `replay_game` |
| Bot control | `bot_status`, `bot_ops`, `bot_trigger` |
| Game state and actions | `game_state`, `game_action`, `game_confirm_new_round` |
| Lobby | `lobby_start_match`, `lobby_account_info` |
| Friendly rooms | `room_create`, `room_add_robot`, `room_quick_test` |
| Emotes | `game_emoji`, `game_emoji_listen` |
| Utilities | `execute_js`, `lobby_anti_idle` |

`room_quick_test` creates a room, adds bots, and starts a test match. It does **not** validate reconnection, AI decisions, server responses, or authoritative game actions by itself.

`game_vote_game_end` is a destructive operation that votes to end a match. It is exposed for manual invocation only and is not part of an automatic workflow.

</details>

<details>
<summary><b>Build from source</b></summary>

Requires **Xcode 26 or later**.

```bash
git clone https://github.com/Sunalamye/Naki.git
cd Naki

# Build the macOS app
xcodebuild build -project Naki.xcodeproj -scheme Naki

# Run the macOS unit-test target
xcodebuild test -project Naki.xcodeproj -scheme Naki -only-testing:NakiTests
```

Use a **Release build for actual gameplay**. Core ML and expected-value calculations are affected by optimization settings; no fixed latency claim is made here.

```bash
xcodebuild build -project Naki.xcodeproj -scheme Naki -configuration Release
```

In Xcode, the run configuration is under **Product → Scheme → Edit Scheme → Run → Build Configuration**. Device builds also require your own signing configuration.

</details>

---

## Current status

Feature availability is not the same as complete end-to-end verification. [`AUDIT.md`](AUDIT.md) records the evidence and remaining gaps in more detail.

| Feature | Status / limitation |
|---|---|
| Four-player AI recommendations | Available with the local model. |
| Automatic play and between-round confirmation | Available on macOS / iOS 26+; live validation gaps remain. |
| Full Auto rematching | Implemented as a separate opt-in mode from Auto. |
| In-game tile highlighting | Implemented; complete visual-regression coverage is still missing. |
| Optional cloud inference | Available, with explicit upload disclosure and four-player local fallback. |
| Three-player mahjong | Cloud-model inference only; no local fallback and incomplete live-match validation. |
| Hide player names | Protocol-level rewriting and render-level hiding. |
| MCP server and Debug API | Available through the local loopback server. |
| iOS 17–25 | Recommendations only; automatic action submission is disabled. |
| Game-record review and analysis | Not yet implemented as a user-facing analysis workflow. |

---

## Acknowledgments

- [Mortal](https://github.com/Equim-chan/Mortal) — mahjong AI engine and libriichi.
- [Akagi](https://github.com/shinkuan/Akagi) — reference implementation, optional cloud inference, and the `/v3` protocol.
- [riichi-mahjong-tiles](https://github.com/FluffyStuff/riichi-mahjong-tiles) by FluffyStuff — tile artwork used in the sidebar, released under CC0 1.0.
- Mahjong Soul (Majsoul) — the mahjong game Naki integrates with.

### Tile artwork

The sidebar uses 40 SVG assets from FluffyStuff's tile set: 27 numbered tiles, 3 red fives, 7 honor tiles, and 3 additional assets such as tile backs.

These replace the earlier Unicode mahjong symbols, which depended on system-font rendering and could not represent red fives as distinct tiles. Asset names follow the same MJAI convention as `Tile.mjaiString`, including `5mr`, `5pr`, and `5sr`.

Import notes and the asset mapping are documented in [`docs/third-party/riichi-mahjong-tiles.md`](docs/third-party/riichi-mahjong-tiles.md). Attribution is included for traceability, even though CC0 does not require it.

## License

The repository specifies **[AGPL-3.0 with Commons Clause](LICENSE)**. The additional Commons Clause restricts selling the software as defined in that license condition. Read the repository's license before using or redistributing it; it is not an unrestricted AGPL-only grant.

## Disclaimer

**Purpose.** This project is intended for learning and research in Swift / SwiftUI development, Core ML integration, and WebSocket / Protobuf protocol handling.

**Account risk.** Use may violate Mahjong Soul's terms of service and may result in suspension or a permanent ban. Do not use your main account. No account or operating mode is guaranteed to avoid enforcement.

**Your responsibility.** You are responsible for checking the applicable game rules, terms, and local legal requirements before use.

**No warranty.** The software is provided “as is,” without express or implied warranties. The author accepts no responsibility for claims, damages, or other liabilities arising from its use.

**No affiliation.** Naki is an independent project and is not affiliated with or endorsed by Mahjong Soul, Catfood Studio, or Yostar. Third-party names and assets belong to their respective owners.

By using this software, you acknowledge the risks and the applicable license terms.

---

<p align="center">
  <a href="https://star-history.com/#Sunalamye/Naki&Date">
    <img src="https://api.star-history.com/svg?repos=Sunalamye/Naki&type=Date" width="500" alt="Naki star history">
  </a>
</p>
