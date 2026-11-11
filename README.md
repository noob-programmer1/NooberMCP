# Noober MCP

An MCP server that lets an AI coding agent **drive** an iOS app — simulator or real iPhone —
and **see inside it**: network calls, WebSocket frames, logs, UserDefaults, Keychain, screen
layout. Tap, swipe, type, mock an API response, switch environments, replay a request.

```
Claude Code ──MCP──> noober-mcp ─┬─ CoreSimulator (in-process HID + accessibility)   simulators
                                 ├─ devicectl + CoreDevice tunnel                      real iPhones
                                 ├─ xcrun mcpbridge                                    Xcode's own tools
                                 └─ TCP/Bonjour ──> Noober SDK / probe in your app     network, logs, storage
```

### What's new in 2.0

- **Works on Xcode 27.** Xcode 27 moved SimulatorKit and routes input through Device Hub's
  `dtuhidd`, which broke AXe/idb-based tools. Noober now talks to the simulator natively.
- **No AXe, no idb, no Node child processes.** Input goes over XPC to the guest's
  `dtuhidd` (Indigo HID fallback on Xcode ≤ 26). The release is ~13 MB lighter.
- **Fast.** Connections stay warm: a tap is sub-millisecond to inject; `snapshot_ui` is
  ~50–500 ms instead of spawning a CLI per call.
- **Act → observe.** `tap`, `swipe`, `type_text`, `button` and `open_url` return what the
  action caused — screen change, API calls with status codes, error logs, or a visible-text
  diff — so the agent rarely needs a follow-up screenshot.
- **Element refs.** `snapshot_ui` returns a compact outline with refs (`e7`) and centre
  points for any app, SpringBoard alerts included. `tap(ref:"e7")` or `tap(label:"Pay")`.
- **Real iPhones.** Screenshots, launch, terminate, install, deep links, appearance and
  location via Xcode 27's `devicectl`. With the SDK in the app, taps/typing/network/logs work
  over the CoreDevice tunnel — **no iproxy**.
- **Xcode's own MCP tools.** `xcode_tools` / `xcode_call` proxy `xcrun mcpbridge`:
  BuildProject, RunSomeTests, RenderPreview, DocumentationSearch, navigator issues and
  Xcode 27's DeviceInteraction tools.
- `wait_for` (text / API call / screen) instead of sleeps, and `doctor` to diagnose setups.

## Requirements

- macOS with Xcode (26.x or 27.x; 27 recommended for physical-device screenshots)
- Node 18+ if installing via `npx`
- An app to look at. A simulator build works as-is — no code changes. Adding the
  [Noober SDK](https://github.com/noob-programmer1/Noober-iOS) (one line, DEBUG only)
  unlocks storage writes and in-app access on real devices.

## Install

### Claude Code plugin

```
/plugin marketplace add noob-programmer1/NooberMCP
/plugin install noober@noobqa
```

The plugin ships a `/noober:setup` skill that adds the SDK to your app.

### Any MCP client

```bash
claude mcp add noober -- npx -y noober-mcp
```

Cursor / Windsurf / Codex:

```json
{ "mcpServers": { "noober": { "command": "npx", "args": ["-y", "noober-mcp"] } } }
```

The first run downloads a release archive to `~/.noober-mcp/`. Set `NOOBER_MCP_BIN` to
point at a local build instead.

## Connecting to your app

### Simulator, no SDK

```
launch_app_sim(bundleId: "com.example.app")
```

The Noober probe is injected at launch (`DYLD_INSERT_LIBRARIES`), giving network capture,
screen reading, logs, crash reports and mocking on an app that has never heard of Noober.
The app must be launched by the tool, since injection happens at process start.

### Real iPhone

```
list_devices
session_set_defaults(deviceId: "My iPhone", bundleId: "com.example.app")
launch_app_sim
```

Screenshots and app lifecycle work on any paired device (Xcode 27 `devicectl`). For taps,
typing and in-app data, the app needs the SDK in its DEBUG build; Noober connects to it
through the device's CoreDevice tunnel automatically. Without the SDK, Xcode 27's
DeviceInteraction tools are reachable through `xcode_call`.

### With the SDK (optional)

```swift
// Package.swift
.package(url: "https://github.com/noob-programmer1/Noober-iOS.git", from: "1.4.1")

// After a window scene exists (didFinishLaunching or a root view's onAppear)
#if DEBUG
import Noober
Noober.shared.start()
#endif
```

## Tools

| Area | Tools |
| --- | --- |
| Target & lifecycle | `list_devices`, `session_set_defaults`, `boot_sim`, `open_sim`, `launch_app_sim`, `stop_app_sim`, `install_app`, `open_url`, `set_appearance`, `set_location` |
| See the screen | `snapshot_ui` (refs + coordinates), `screenshot` (compact JPEG, `quality:"full"` for PNG), `wait_for` |
| Drive the UI | `tap` (ref / label / x,y, `hold`, `double`), `swipe` (direction or points), `type_text`, `press_key`, `button` |
| Inside the app | `noober_get_network_logs`, `noober_get_request_detail`, `noober_assert_request`, `noober_assert_flow`, `noober_timeline`, `noober_get_app_logs`, `noober_check_event`, `noober_screen_html`, `noober_find_element`, … |
| Change app state | `noober_add_mock_rule`, `noober_add_intercept_rule`, `noober_switch_environment`, `noober_set_user_default`, `noober_set_keychain`, `noober_set_cookie`, `noober_replay_request` |
| Xcode | `xcode_tools`, `xcode_call`, `noober_rebuild_app` |
| Diagnostics | `doctor`, `noober_status` |

Coordinates are always iOS **points**, shared by `snapshot_ui`, `screenshot` and `tap`.

## How it works

**Simulator input.** Noober loads CoreSimulator and SimulatorKit from the active Xcode
(`xcode-select -p`), looks up the guest service
`com.apple.coredevice.feature.remote.hid.digitizer` and sends `IndigoDigitizerEvent` /
`IndigoKeyboardButtonEvent` / `IndigoButtonEvent` messages over XPC — the path Device Hub
itself uses. If `dtuhidd` is absent (Xcode ≤ 26), it falls back to `SimDeviceLegacyHIDClient`.
Force a transport with `NOOBER_HID_TRANSPORT=dtuhid|indigo`.

**Accessibility.** `AXPTranslator` requests are bridged to
`SimDevice.sendAccessibilityRequestAsync`, plus a point-grid pass that picks up SpringBoard
alerts and containers that hide their children. `NOOBER_AX_GRID=0` disables the grid pass.

**In-app.** The SDK/probe advertises `_noober._tcp` over Bonjour and listens on TCP 54321
(length-prefixed JSON). Physical devices are reached at their CoreDevice tunnel address.

## Troubleshooting

Run `doctor` first — it reports the Xcode in use, HID transport, accessibility, probe,
devices, Noober connection and Xcode MCP status.

- **"Noober not connected"** — launch the app with `launch_app_sim` (simulator), or use a
  DEBUG build that calls `Noober.shared.start()` after the window scene exists.
- **Physical device screenshot is black** — the phone is locked or its display is off.
- **Physical device "tunnel unavailable"** — unlock the phone and reconnect; check it with
  `xcrun devicectl list devices`.
- **`xcode_tools` fails** — open the project in Xcode and enable Settings › Intelligence ›
  "Allow external agents to use Xcode tools".
- **Ports** — the HTTP API starts on 8686 and scans to 8695; the live port is written to
  `~/.noober-mcp/port`. Set `NOOBER_PORT` to pin it.

## Build from source

```bash
git clone https://github.com/noob-programmer1/NooberMCP.git
cd NooberMCP
swift build -c release
NOOBER_MCP_BIN=$PWD/.build/release/NooberMCP npx noober-mcp
```

Rebuild the probe with `NooberProbe/build.sh`. To develop against a local SDK checkout:
`swift package edit noober-ios --path ../Noober`.

## Credits

The native simulator layer follows techniques documented by
[meta/idb](https://github.com/meta/idb) (MIT) — notably its dtuhid transport — and
[EvanBacon/serve-sim](https://github.com/EvanBacon/serve-sim) (Apache-2.0). See
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

## License

MIT — see [LICENSE](LICENSE).
