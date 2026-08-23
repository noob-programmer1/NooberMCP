# Noober MCP

An MCP server that lets an AI coding agent see inside your **running iOS app** — network
calls, WebSocket frames, logs, UserDefaults, Keychain, screen layout — and act on it:
tap, swipe, type, mock an API response, switch environments, replay a request.

It pairs with the [Noober SDK](https://github.com/noob-programmer1/Noober-iOS), which you
add to your app's DEBUG build. The SDK opens a local socket; this server talks to it.

```
Claude Code ──MCP──> noober-mcp ──TCP/Bonjour──> Noober SDK in your app
```

## Requirements

- macOS (iOS simulators and Xcode live there)
- The Noober SDK integrated in a DEBUG build of your app
- Node 18+ if installing via `npx`

## Install

### Claude Code plugin

```
/plugin marketplace add noob-programmer1/NooberMCP
/plugin install noober@noobqa
```

The plugin ships a `/noober:setup` skill that adds the SDK to your app and wires up
`start()` in the right place — run it once after installing.

### Any MCP client

```bash
claude mcp add noober -- npx -y noober-mcp
```

Cursor / Windsurf / Codex (`.cursor/mcp.json`, `mcp.json`):

```json
{
  "mcpServers": {
    "noober": { "command": "npx", "args": ["-y", "noober-mcp"] }
  }
}
```

The first run downloads a release archive to `~/.noober-mcp/`. Set `NOOBER_MCP_BIN` to
point at a local build instead.

## Add the SDK to your app

```swift
// Package.swift
.package(url: "https://github.com/noob-programmer1/Noober-iOS.git", from: "1.2.0")

// App startup — needs a live window scene, so call it from
// didFinishLaunching or a root view's onAppear, not App.init.
#if DEBUG
import Noober
Noober.shared.start()
#endif
```

## What the agent can do

| Capability | Tool |
| --- | --- |
| Read screen layout as HTML with tap coordinates | `noober_screen_html` |
| Find an element / read visible text | `noober_find_element`, `noober_screen_text` |
| Inspect network traffic | `noober_get_network_logs`, `noober_get_request_detail` |
| Assert an API call happened | `noober_assert_request` |
| Inspect WebSocket frames | `noober_get_websocket_logs` |
| Read app logs | `noober_get_app_logs` |
| Browse UserDefaults / Keychain / cookies | `noober_get_user_defaults`, `noober_get_cookies` |
| Mock or intercept responses | `noober_add_mock_rule`, `noober_add_intercept_rule` |
| Switch API environment | `noober_get_environment`, `noober_switch_environment` |
| Replay a request | `noober_replay_request` |
| Drive the UI | `tap`, `swipe`, `type_text`, `button` |
| Simulator lifecycle | `list_sims`, `boot_sim`, `launch_app_sim`, `stop_app_sim` |

Point the session at a simulator and app first:

```
session_set_defaults(simulatorId: "<udid>", bundleId: "com.example.app")
```

## How it works

The SDK advertises `_noober._tcp` over Bonjour and also listens on TCP port 54321. Messages
are length-prefixed JSON (4-byte big-endian length + body). On connect the app pushes a
full state snapshot, then streams events. Commands travel the same socket, so `tap` and
`type_text` work on physical devices over a USB tunnel, not just simulators.

Simulator-only operations (screenshots, boot/launch, and the fast tap path) shell out to
[AXe](https://github.com/cameroncooke/AXe), which ships inside the release archive next to
the server binary.

## Troubleshooting

**"Noober not connected"** — the app must be running a DEBUG build with
`Noober.shared.start()` called after the window scene exists, and the debug bubble should
be visible.

**Simulator tools unavailable** — the server looks for `Bundled/axe` next to its own
binary. If you built from source, run from the repo root so `Bundled/` is alongside it.

**Two apps at once** — port 54321 is claimed by the first app; the second falls back to
Bonjour. Connect to one app at a time for predictable results.

**Two servers at once** — the HTTP API starts on 8686 and scans up to 8695 if that's
taken, so a second instance still gets an API. The live port is written to
`~/.noober-mcp/port`. Set `NOOBER_PORT` to pin it and skip the scan.

## Build from source

```bash
git clone https://github.com/noob-programmer1/NooberMCP.git
cd NooberMCP
swift build -c release
NOOBER_MCP_BIN=$PWD/.build/release/NooberMCP npx noober-mcp
```

To develop against a local checkout of the SDK:

```bash
swift package edit noober-ios --path ../Noober
```

## License

MIT — see [LICENSE](LICENSE). Bundled third-party components are listed in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
