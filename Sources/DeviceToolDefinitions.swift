import Foundation

/// Schemas for device-level tools (simulator, physical device, Android, Xcode).
extension MCPServer {
    private func dtool(_ name: String, _ desc: String, _ props: [String: [String: Any]] = [:], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": props]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": desc, "inputSchema": schema]
    }

    private static let observeProp: [String: Any] = [
        "type": "boolean",
        "description": "Report what changed after the action — screen, API calls, error logs, or visible-text diff (default true). Set false to skip the ~0.4–1s settle wait.",
    ]
    private static func n(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
    private static func s(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    private static func b(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }

    func deviceToolDefinitions() -> [[String: Any]] {
        typealias M = MCPServer
        return [
            dtool("session_set_defaults", "Choose the target: a simulator (simulatorId), a physical iPhone (deviceId — UDID or name; auto-connects to the Noober SDK over the CoreDevice tunnel, no iproxy) or an Android emulator (androidSerial). Also sets bundleId/scheme. With nothing set, the first booted simulator is used.", [
                "simulatorId": M.s("Simulator UDID"),
                "deviceId": M.s("Physical iOS device UDID, CoreDevice id or name (see list_devices)"),
                "bundleId": M.s("App bundle identifier"),
                "scheme": M.s("Xcode scheme (for noober_rebuild_app)"),
                "projectPath": M.s("Path to .xcodeproj"),
                "workspacePath": M.s("Path to .xcworkspace"),
                "androidSerial": M.s("Android emulator serial (e.g. emulator-5554); empty string to leave Android mode"),
                "connectMode": M.s("'usb' = legacy iproxy connection on 127.0.0.1:54321 (not needed on Xcode 15+ — use deviceId)"),
            ]),
            dtool("session_show_defaults", "Show the current target device, app and connection state"),
            dtool("list_devices", "List booted simulators and paired physical iPhones (with tunnel state) in one compact view.", [
                "all": M.b("Include shut-down simulators"),
            ]),
            dtool("list_sims", "List all available simulators (alias of list_devices all:true)"),
            dtool("boot_sim", "Boot a simulator and wait until it is ready", ["simulatorId": M.s("Simulator UDID")], required: ["simulatorId"]),
            dtool("open_sim", "Open Device Hub (Xcode 27) / Simulator.app so the screen is visible"),
            dtool("launch_app_sim", "Launch (or relaunch) the app on the current target. Simulators: the Noober probe is injected automatically, so network/logs/screen tools work even without the SDK. Physical devices: launched with devicectl, then Noober connects over the tunnel.", [
                "bundleId": M.s("Bundle identifier (defaults to session bundleId)"),
                "simulatorId": M.s("Simulator UDID (defaults to session target)"),
                "inject_probe": M.b("Inject NooberProbe on simulators (default true)"),
                "env": ["type": "object", "description": "Environment variables for the app", "additionalProperties": ["type": "string"]],
                "args": ["type": "array", "items": ["type": "string"], "description": "Launch arguments"],
            ]),
            dtool("stop_app_sim", "Terminate the app on the current target", ["bundleId": M.s("Bundle identifier")]),
            dtool("install_app", "Install a .app (simulator) or .app/.ipa (physical device) on the current target", ["path": M.s("Path to the app bundle")], required: ["path"]),
            dtool("open_url", "Open a URL or deep link on the current target", ["url": M.s("URL / deep link"), "observe": M.observeProp], required: ["url"]),
            dtool("set_appearance", "Switch light/dark mode on the current target", ["style": M.s("light or dark")]),
            dtool("set_location", "Simulate GPS location on the current target", ["latitude": M.n("Latitude"), "longitude": M.n("Longitude")], required: ["latitude", "longitude"]),

            dtool("tap", "Tap an element. Prefer ref (from snapshot_ui) or label — they resolve to the element centre via the accessibility tree; x/y are iOS points. Returns what changed (screen, API calls, errors) so a follow-up screenshot is rarely needed.", [
                "ref": M.s("Element ref from snapshot_ui, e.g. \"e7\""),
                "label": M.s("Visible text / accessibility label / identifier to tap (best match)"),
                "x": M.n("X in points"), "y": M.n("Y in points"),
                "hold": M.n("Hold seconds — 0.6+ makes a long press"),
                "double": M.b("Double tap"),
                "observe": M.observeProp,
                "settle": M.n("Max seconds to wait for network/UI to settle (default 3)"),
            ]),
            dtool("swipe", "Swipe/scroll. Either direction (up/down/left/right — finger direction) or explicit points.", [
                "direction": M.s("up, down, left or right"),
                "distance": M.n("Fraction of the screen for direction swipes (default 0.5)"),
                "x1": M.n("Start X"), "y1": M.n("Start Y"), "x2": M.n("End X"), "y2": M.n("End Y"),
                "duration": M.n("Seconds (default 0.3)"),
                "observe": M.observeProp,
            ]),
            dtool("type_text", "Type into the focused field. With Noober attached the text is inserted in-process (any Unicode); otherwise sent as HID keystrokes.", [
                "text": M.s("Text to type"),
                "submit": M.b("Press Return afterwards"),
                "observe": M.observeProp,
            ], required: ["text"]),
            dtool("press_key", "Press a keyboard key (return, escape, backspace, tab, space, up/down/left/right, or a single character), optionally with modifiers.", [
                "key": M.s("Key name"),
                "modifiers": ["type": "array", "items": ["type": "string"], "description": "cmd, shift, ctrl, alt"],
                "observe": M.observeProp,
            ], required: ["key"]),
            dtool("touch", "Low-level touch at a point; delay = hold time (legacy — prefer tap with hold)", [
                "x": M.n("X"), "y": M.n("Y"), "down": M.b("Touch down"), "up": M.b("Touch up"), "delay": M.n("Hold seconds"),
            ]),
            dtool("button", "Press a hardware button: home, lock, side, siri, volume_up, volume_down", [
                "buttonType": M.s("Button name"),
                "duration": M.n("Hold seconds"),
                "observe": M.observeProp,
            ]),
            dtool("screenshot", "Screenshot of the current target. Default is a compact JPEG at point resolution (same coordinate space as tap). Works on physical devices via devicectl.", [
                "quality": M.s("'fast' (default, ~100KB JPEG) or 'full' (native-resolution PNG)"),
            ]),
            dtool("snapshot_ui", "Accessibility outline of the whole screen (any app, system alerts included) with element refs and centre coordinates. Much cheaper than a screenshot — use it to decide what to tap."),
            dtool("wait_for", "Wait until something happens instead of sleeping: text appears/disappears, an API request matching a URL substring completes, or the screen name changes.", [
                "text": M.s("Text to wait for"),
                "gone": M.b("Wait for the text to disappear instead"),
                "request": M.s("URL substring of an API call to wait for (needs Noober attached)"),
                "screen": M.s("Screen name to wait for (needs Noober attached)"),
                "timeout": M.n("Seconds (default 10)"),
            ]),
            dtool("doctor", "Diagnose the environment: Xcode version, simulator HID transport, accessibility, probe, physical devices, Noober connection and Xcode MCP availability."),
            dtool("xcode_tools", "List the tools Xcode itself exposes over MCP (xcrun mcpbridge, Xcode 26.3+): BuildProject, GetBuildLog, RunSomeTests, RenderPreview, DocumentationSearch, navigator issues and — on Xcode 27 — DeviceInteraction* (XCTest-backed taps and UI hierarchy that also work on physical devices). Requires Xcode running with external agents allowed."),
            dtool("xcode_call", "Call one of Xcode's MCP tools by name (see xcode_tools).", [
                "tool": M.s("Xcode tool name, e.g. BuildProject"),
                "arguments": ["type": "object", "description": "Tool arguments"],
                "timeout": M.n("Seconds (default 600)"),
            ], required: ["tool"]),
        ]
    }
}
