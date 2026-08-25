import Foundation

/// Minimal MCP server over stdio (JSON-RPC 2.0, newline-delimited).
/// Routes tool calls to NooberClient.
final class MCPServer {
    let client = NooberClient()
    let toolHandler = ToolHandler()
    let sim = SimulatorBridge()

    func run() {
        // Start Noober discovery immediately
        client.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            client.waitForConnection(timeout: 8)
        }

        // Read stdin line by line (MCP stdio transport)
        DispatchQueue.global().async { [self] in
            while let line = readLine(strippingNewline: true) {
                guard !line.isEmpty,
                      let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                let id = json["id"] // can be Int or String
                let method = json["method"] as? String ?? ""
                let params = json["params"] as? [String: Any] ?? [:]

                let response: [String: Any]

                switch method {
                case "initialize":
                    response = handleInitialize(id: id)
                case "notifications/initialized":
                    continue // no response needed
                case "tools/list":
                    response = handleToolsList(id: id)
                case "tools/call":
                    response = handleToolCall(id: id, params: params)
                case "ping":
                    response = jsonRPC(id: id, result: [:])
                default:
                    response = jsonRPCError(id: id, code: -32601, message: "Method not found: \(method)")
                }

                sendResponse(response)
            }
        }
    }

    // MARK: - MCP over HTTP (Streamable HTTP transport)

    /// Handle a JSON-RPC MCP request from HTTP. Same logic as stdin, returns response dict.
    func handleHTTPMCP(body: [String: Any]) -> [String: Any] {
        let id = body["id"]
        let method = body["method"] as? String ?? ""
        let params = body["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return handleInitialize(id: id)
        case "notifications/initialized":
            return jsonRPC(id: id, result: [:])
        case "tools/list":
            return handleToolsList(id: id)
        case "tools/call":
            return handleToolCall(id: id, params: params)
        case "ping":
            return jsonRPC(id: id, result: [:])
        default:
            return jsonRPCError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - MCP Handlers

    private func handleInitialize(id: Any?) -> [String: Any] {
        jsonRPC(id: id, result: [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "tools": [:] as [String: Any]
            ],
            "serverInfo": [
                "name": "NooberMCP",
                "version": "1.0.2"
            ]
        ])
    }

    private func handleToolsList(id: Any?) -> [String: Any] {
        var allTools = toolDefinitions()
        if sim.isAvailable {
            allTools.append(contentsOf: simulatorToolDefinitions())
        }
        return jsonRPC(id: id, result: ["tools": allTools])
    }

    private func handleToolCall(id: Any?, params: [String: Any]) -> [String: Any] {
        let toolName = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]

        // ================================================================
        // ANDROID MODE: All tools route through ADB + Frida bridge
        // No companion client, no session gate, no AXe
        // ================================================================
        if sim.isAndroidMode {
            // session_set_defaults — always handle (sets androidSerial)
            if toolName == "session_set_defaults" {
                return jsonRPC(id: id, result: [
                    "content": [["type": "text", "text": sim.setDefaults(args: args)]]
                ])
            }
            if toolName == "session_show_defaults" {
                return jsonRPC(id: id, result: [
                    "content": [["type": "text", "text": sim.showDefaults()]]
                ])
            }

            // Screenshot — returns image via ADB screencap
            if toolName == "screenshot" {
                let result = sim.screenshot()
                var content: [[String: Any]] = [["type": "text", "text": result.text]]
                if let base64 = result.base64 {
                    content.append(["type": "image", "data": base64, "mimeType": "image/png"])
                }
                return jsonRPC(id: id, result: ["content": content])
            }

            // UI interaction — ADB input commands
            if toolName == "tap" {
                return jsonRPC(id: id, result: ["content": [["type": "text", "text":
                    sim.tap(x: args["x"] as? Int, y: args["y"] as? Int,
                            label: args["label"] as? String, postDelay: args["postDelay"] as? Double)]]])
            }
            if toolName == "swipe" {
                return jsonRPC(id: id, result: ["content": [["type": "text", "text":
                    sim.swipe(startX: args["x1"] as? Int ?? 0, startY: args["y1"] as? Int ?? 0,
                              endX: args["x2"] as? Int ?? 0, endY: args["y2"] as? Int ?? 0,
                              duration: args["duration"] as? Double)]]])
            }
            if toolName == "type_text" {
                return jsonRPC(id: id, result: ["content": [["type": "text", "text":
                    sim.typeText(args["text"] as? String ?? "")]]])
            }
            if toolName == "button" {
                return jsonRPC(id: id, result: ["content": [["type": "text", "text":
                    sim.button(args["buttonType"] as? String ?? "home",
                               duration: args["duration"] as? Double)]]])
            }
            if toolName == "touch" {
                return jsonRPC(id: id, result: ["content": [["type": "text", "text":
                    sim.touch(x: args["x"] as? Int ?? 0, y: args["y"] as? Int ?? 0,
                              down: args["down"] as? Bool ?? true, up: args["up"] as? Bool ?? true,
                              delay: args["delay"] as? Double)]]])
            }

            // All noober_* tools — route through AndroidCapture (Frida bridge file)
            let result = toolHandler.call(tool: toolName, args: args, client: client, bundleId: sim.bundleId, sim: sim)
            return jsonRPC(id: id, result: ["content": [["type": "text", "text": result]]])
        }

        // ================================================================
        // iOS MODE: companion client + AXe
        // ================================================================
        let isNooberTool = toolName.hasPrefix("noober_")
        if isNooberTool {
            let offlineTools: Set<String> = ["noober_get_crash_log", "noober_rebuild_app"]
            if offlineTools.contains(toolName) {
                let result = toolHandler.call(tool: toolName, args: args, client: client, bundleId: sim.bundleId, sim: sim)
                return jsonRPC(id: id, result: ["content": [["type": "text", "text": result]]])
            }

            client.waitForConnection(timeout: 8)

            if toolName == "noober_screenshot" {
                let result = client.requestScreenshot()
                var content: [[String: Any]] = [["type": "text", "text": result.text]]
                if let base64 = result.imageBase64 {
                    content.append(["type": "image", "data": base64, "mimeType": "image/png"])
                }
                return jsonRPC(id: id, result: ["content": content])
            }

            let result = toolHandler.call(tool: toolName, args: args, client: client, bundleId: sim.bundleId, sim: sim)
            return jsonRPC(id: id, result: ["content": [["type": "text", "text": result]]])
        }

        // Not a Noober tool — handle via native SimulatorBridge
        // Screenshot returns image content
        if toolName == "screenshot" {
            let result = sim.screenshot()
            var content: [[String: Any]] = [["type": "text", "text": result.text]]
            if let base64 = result.base64 {
                content.append([
                    "type": "image",
                    "data": base64,
                    "mimeType": "image/png"
                ])
            }
            return jsonRPC(id: id, result: ["content": content])
        }

        let result = handleSimulatorTool(toolName, args: args)
        return jsonRPC(id: id, result: [
            "content": [["type": "text", "text": result]]
        ])
    }

    // MARK: - Tool Definitions

    private func toolDefinitions() -> [[String: Any]] {
        [
            tool("noober_status", "Check if Noober is connected and get summary of available data", [:]),

            tool("noober_get_network_logs", "Get recent HTTP network requests captured by Noober (URL, method, status, duration, screen). Includes native URLSession and WebView (fetch/XHR) traffic.", [
                "limit": ["type": "number", "description": "Max requests to return (default 20)"],
                "screen": ["type": "string", "description": "Filter by screen name (e.g. 'Confirm Booking Details')"],
                "source": ["type": "string", "description": "Filter by source: 'webview' for WebView-only traffic, 'native' for URLSession-only. Omit for all."]
            ]),

            tool("noober_get_request_detail", "Get full details of a specific HTTP request — headers, request body, response body, timing", [
                "request_id": ["type": "string", "description": "UUID of the request (from noober_get_network_logs)"]
            ]),

            tool("noober_get_app_logs", "Get structured app log entries captured by Noober (with level, category, file, line, screen)", [
                "limit": ["type": "number", "description": "Max entries (default 50)"],
                "level": ["type": "string", "description": "Filter by level: DEBUG, INFO, WARN, ERROR"],
                "screen": ["type": "string", "description": "Filter by screen name (e.g. 'Confirm Booking Details')"]
            ]),

            tool("noober_get_environment", "Get current API environment and all registered environments", [:]),

            tool("noober_switch_environment", "Switch the app's API environment (e.g., to staging, production, local)", [
                "environment_name": ["type": "string", "description": "Name of the environment to switch to"]
            ]),

            tool("noober_replay_request", "Replay a previously captured HTTP request", [
                "request_id": ["type": "string", "description": "UUID of the request to replay"]
            ]),

            tool("noober_get_qa_checklist", "Get QA checklist items with pass/fail status", [:]),

            tool("noober_mark_qa", "Mark a QA checklist item as passed or failed", [
                "item_id": ["type": "string", "description": "UUID of the QA item"],
                "status": ["type": "string", "description": "PASSED or FAILED"],
                "notes": ["type": "string", "description": "Optional notes"]
            ]),

            tool("noober_get_user_defaults", "Browse the app's persisted key-value storage. iOS: NSUserDefaults. Android: SharedPreferences (read via adb run-as). Routing is automatic based on the active sim/emulator — call this for both platforms.", [
                "filter": ["type": "string", "description": "Optional key filter (contains match). On Android, can also be the SharedPreferences file name."]
            ]),

            tool("noober_get_websocket_logs", "Get WebSocket connections and recent frames", [
                "limit": ["type": "number", "description": "Max frames per connection (default 20)"]
            ]),

            tool("noober_get_rules", "Get active network rules (URL rewrites, mocks, intercepts)", [:]),

            tool("noober_find_element", "PREFERRED for tapping: Find UI elements by text — returns label, type, exact frame, and center coordinates. Use this before tap/gesture to get accurate coordinates. Faster and more reliable than snapshot_ui.", [
                "text": ["type": "string", "description": "Text to search for (partial match)"],
                "exact": ["type": "boolean", "description": "Exact match only (default: false)"]
            ]),

            tool("noober_screen_text", "PREFERRED for text verification: Get ALL visible text on the current screen — fast, no image needed. Use this to verify text content, check labels, confirm navigation.", [:]),

            tool("noober_screen_html", "PREFERRED for understanding screen layout: Returns the screen as compact HTML with tap coordinates. Each element has c=\"x,y\" for tapping.", [:]),

            tool("noober_check_event", "FASTEST way to verify analytics: Ask 'did event X fire?' — returns PASS/FAIL instantly. Use instead of reading all app logs.", [
                "event_name": ["type": "string", "description": "Event name to search for (partial match, e.g. 'Landed on cart')"],
                "property": ["type": "string", "description": "Optional: check if this property exists in the event"],
                "value": ["type": "string", "description": "Optional: check if property equals this value"],
                "since_seconds": ["type": "number", "description": "Only check events from the last N seconds"],
            ]),

            tool("noober_get_value", "FASTEST way to read a screen value: Ask 'what is Total Payable?' — returns the value instantly. Use instead of screen_html when you just need one value.", [
                "text": ["type": "string", "description": "Text label to find (e.g. 'Total Payable', 'Fare', 'Balance')"],
            ]),

            tool("noober_assert_request", "PREFERRED for API validation: Assert that a specific API call was made with expected results. Returns PASS/FAIL. Use after user actions to verify the correct API was called — e.g. 'confirm POST /bookings returned 201'. This is a key advantage over UI-only testing.", [
                "url_pattern": ["type": "string", "description": "URL substring to match (e.g. '/api/v1/bookings')"],
                "method": ["type": "string", "description": "HTTP method to match (GET, POST, etc.)"],
                "min_status": ["type": "number", "description": "Minimum expected status code (default 200)"],
                "max_status": ["type": "number", "description": "Maximum expected status code (default 299)"],
                "body_contains": ["type": "string", "description": "Assert response body contains this string"],
                "since_seconds": ["type": "number", "description": "Only check requests from the last N seconds"]
            ]),

            tool("noober_current_screen", "PREFERRED for screen checks: Get the current screen name — instant, no UI traversal. Use this to check which screen you're on before taking any action.", [:]),

            tool("noober_screenshot", "Take a screenshot via Noober — captures the app window from inside the process. Use when you need to visually verify something that text/HTML tools can't capture (animations, colors, images). Returns base64 PNG + current screen name.", [:]),

            tool("noober_get_recorded_flows", "Get recorded user flows from Noober — replayable navigation paths recorded on the device", [:]),

            tool("noober_timeline", "Unified timeline: correlates network requests, logs, and screen transitions in chronological order. Best for understanding 'what happened when?' after a user action.", [
                "since_seconds": ["type": "number", "description": "Show events from last N seconds (default 30)"],
                "limit": ["type": "number", "description": "Max events to return (default 50)"],
            ]),
            tool("noober_set_user_default", "Write a UserDefaults value in the running app. Types are detected automatically (numbers, booleans, JSON).", [
                "key": ["type": "string", "description": "UserDefaults key"],
                "value": ["type": "string", "description": "Value to write"]
            ]),
            tool("noober_remove_user_default", "Delete a UserDefaults key in the running app.", [
                "key": ["type": "string", "description": "UserDefaults key to remove"]
            ]),
            tool("noober_set_keychain", "Write a Keychain item in the running app. Replaces an existing item with the same account and service.", [
                "account": ["type": "string", "description": "Account name"],
                "value": ["type": "string", "description": "Secret value"],
                "service": ["type": "string", "description": "Service (defaults to the app's bundle id)"],
                "itemClass": ["type": "string", "description": "genericPassword (default) or internetPassword"]
            ]),
            tool("noober_remove_keychain", "Delete Keychain items for an account in the running app.", [
                "account": ["type": "string", "description": "Account name"],
                "service": ["type": "string", "description": "Optional service filter"]
            ]),
            tool("noober_set_cookie", "Set an HTTP cookie in the running app's shared cookie storage.", [
                "name": ["type": "string", "description": "Cookie name"],
                "value": ["type": "string", "description": "Cookie value"],
                "domain": ["type": "string", "description": "Cookie domain, e.g. api.example.com"],
                "path": ["type": "string", "description": "Path (defaults to /)"],
                "isSecure": ["type": "boolean", "description": "Mark the cookie Secure"],
                "expiresInSeconds": ["type": "number", "description": "Lifetime in seconds; omit for a session cookie"]
            ]),
            tool("noober_remove_cookie", "Delete cookies by name from the running app.", [
                "name": ["type": "string", "description": "Cookie name"],
                "domain": ["type": "string", "description": "Optional domain filter"]
            ]),
            tool("noober_get_cookies", "Get HTTP cookies stored by the app (HTTPCookieStorage)", [:]),
            tool("noober_assert_element", "Assert a UI element exists with expected state. Returns PASS/FAIL. Example: assert_element(text:'Save', state:'enabled')", [
                "text": ["type": "string", "description": "Element text to find"],
                "state": ["type": "string", "description": "Expected state: 'exists', 'enabled', 'disabled', 'selected'"],
            ]),
            tool("noober_verify_screen", "Verify the current screen contains expected text. Returns PASS/FAIL with details.", [
                "contains": ["type": "string", "description": "Text that should be visible on screen"],
                "not_contains": ["type": "string", "description": "Text that should NOT be visible"],
            ]),
            tool("noober_assert_flow", "Assert a sequence of expected API calls and events in order. Each step is checked against cached data. Returns structured PASS/FAIL per step. Use after a user action to verify the entire expected backend flow.", [
                "steps": ["type": "string", "description": "JSON array of steps. Each: {\"type\":\"request\",\"url_pattern\":\"/api/x\",\"method\":\"POST\",\"status\":201} or {\"type\":\"event\",\"event_name\":\"booking_created\"} or {\"type\":\"screen\",\"screen_name\":\"Confirmation\"}"],
            ]),

            tool("noober_add_mock_rule", "Add a mock rule: intercept matching API requests and return a fake response. Use this to test error handling, simulate API failures, or unblock blocked APIs. The mock stays active until removed.", [
                "url_pattern": ["type": "string", "description": "URL substring to match (e.g. '/api/init', '/v1/bookings')"],
                "status_code": ["type": "number", "description": "HTTP status code to return (e.g. 200, 404, 500)"],
                "response_body": ["type": "string", "description": "Response body JSON string to return"],
                "method": ["type": "string", "description": "HTTP method to match (GET, POST, etc.). Omit to match all methods."],
                "name": ["type": "string", "description": "Human-readable name for this mock rule"],
            ]),
            tool("noober_remove_mock_rule", "Remove a mock rule by its ID (get IDs from noober_get_rules)", [
                "rule_id": ["type": "string", "description": "UUID of the rule to remove"],
            ]),
            tool("noober_add_intercept_rule", "Add an intercept rule: hold matching requests until manually approved. Use to test timeout handling or inspect request payloads before they're sent.", [
                "url_pattern": ["type": "string", "description": "URL substring to match"],
                "method": ["type": "string", "description": "HTTP method to match. Omit to match all."],
                "name": ["type": "string", "description": "Human-readable name"],
            ]),
            tool("noober_remove_intercept_rule", "Remove an intercept rule by its ID", [
                "rule_id": ["type": "string", "description": "UUID of the rule to remove"],
            ]),
            tool("noober_perf_snapshot", "Get a performance snapshot: current FPS, memory usage (MB), average FPS, and peak memory. Use to detect jank, memory leaks, or performance regressions after user actions.", [:]),
            tool("noober_accessibility_audit", "Run an accessibility audit on the current screen. Checks for missing labels on buttons, undersized touch targets (<44x44), and images without descriptions. Returns issues with severity and element coordinates.", [:]),
            tool("noober_visual_check", "Compare current screen with a saved baseline screenshot. First run saves baseline, subsequent runs compare. Returns diff percentage and PASS/FAIL.", [
                "screen_name": ["type": "string", "description": "Screen name for baseline (uses current if omitted)"],
                "threshold": ["type": "number", "description": "Max diff percentage to pass (default 5)"],
                "save_baseline": ["type": "boolean", "description": "Force save current as new baseline"],
            ]),
            tool("noober_webview_console", "Get JavaScript console logs from WebViews in the app. Returns console.log, console.error, console.warn messages.", [
                "level": ["type": "string", "description": "Filter by level: 'log', 'error', 'warn', 'debug'. Omit for all."],
                "limit": ["type": "number", "description": "Max entries to return (default 50)"],
            ]),
            tool("noober_get_crash_log", "Read the last crash log from the app. Returns stack trace, exception type, last screen, and last API call. Use after the app crashes during testing.", [:]),
            tool("noober_rebuild_app", "Rebuild and redeploy the app to simulator. Use after making code fixes in dev mode. Stops app, builds with xcodebuild, installs, relaunches with probe.", [
                "scheme": ["type": "string", "description": "Xcode scheme name"],
                "project_path": ["type": "string", "description": "Path to .xcodeproj or .xcworkspace"],
            ]),
        ]
    }

    private func tool(_ name: String, _ desc: String, _ props: [String: [String: String]]) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": props]
        if props.isEmpty { schema["properties"] = [:] as [String: Any] }
        return ["name": name, "description": desc, "inputSchema": schema]
    }

    // MARK: - Simulator Tool Definitions (native — no Node.js)

    private func simulatorToolDefinitions() -> [[String: Any]] {
        [
            tool("session_set_defaults", "Set simulator and app defaults for this session", [
                "simulatorId": ["type": "string", "description": "Simulator UDID (iOS)"],
                "bundleId": ["type": "string", "description": "App bundle identifier"],
                "scheme": ["type": "string", "description": "Xcode scheme name"],
                "connectMode": ["type": "string", "description": "'bonjour' (default) or 'usb' (direct TCP on port 54321 for real device via USB tunnel)"],
                "androidSerial": ["type": "string", "description": "Android emulator serial (e.g. emulator-5554). When set, routes screenshot/tap/swipe through ADB."],
            ]),
            tool("session_show_defaults", "Show current session defaults", [:]),
            tool("tap", "Tap on screen by coordinates or accessibility label", [
                "x": ["type": "number", "description": "X coordinate"],
                "y": ["type": "number", "description": "Y coordinate"],
                "label": ["type": "string", "description": "Tap element by accessibility label (alternative to x,y)"],
                "postDelay": ["type": "number", "description": "Delay after tap in seconds"],
            ]),
            tool("swipe", "Swipe gesture from one point to another", [
                "x1": ["type": "number", "description": "Start X"],
                "y1": ["type": "number", "description": "Start Y"],
                "x2": ["type": "number", "description": "End X"],
                "y2": ["type": "number", "description": "End Y"],
                "duration": ["type": "number", "description": "Swipe duration in seconds"],
            ]),
            tool("type_text", "Type text into the focused field", [
                "text": ["type": "string", "description": "Text to type"],
            ]),
            tool("touch", "Precise touch down/up events for toggles and long press", [
                "x": ["type": "number", "description": "X coordinate"],
                "y": ["type": "number", "description": "Y coordinate"],
                "down": ["type": "boolean", "description": "Perform touch down"],
                "up": ["type": "boolean", "description": "Perform touch up"],
                "delay": ["type": "number", "description": "Delay between down and up (for long press)"],
            ]),
            tool("screenshot", "Take a simulator screenshot", [:]),
            tool("launch_app_sim", "Launch an app on the simulator. Set inject_probe=true for apps WITHOUT Noober SDK to enable network logs and UI inspection.", [
                "bundleId": ["type": "string", "description": "Bundle identifier (uses default if not set)"],
                "simulatorId": ["type": "string", "description": "Simulator UDID (uses default if not set)"],
                "inject_probe": ["type": "boolean", "description": "Inject NooberProbe for deep inspection (network, UI, logs) without SDK integration"],
            ]),
            tool("stop_app_sim", "Stop a running app", [
                "bundleId": ["type": "string", "description": "Bundle identifier"],
            ]),
            tool("list_sims", "List available simulators", [:]),
            tool("boot_sim", "Boot a simulator", [
                "simulatorId": ["type": "string", "description": "Simulator UDID to boot"],
            ]),
            tool("open_sim", "Open the Simulator.app window", [:]),
            tool("snapshot_ui", "Get accessibility tree of the simulator screen", [:]),
            tool("button", "Press a hardware button (home, lock, siri)", [
                "buttonType": ["type": "string", "description": "Button: home, lock, siri, side-button, apple-pay"],
                "duration": ["type": "number", "description": "Hold duration in seconds"],
            ]),
        ]
    }

    // MARK: - Simulator Tool Handler

    private func handleSimulatorTool(_ name: String, args: [String: Any]) -> String {
        let isInputTool = name == "tap" || name == "swipe" || name == "type_text"
        if !sim.isAvailable && !(isInputTool && client.isConnected) {
            return "Simulator tools not available — AXe binary not found"
        }

        switch name {
        case "session_set_defaults":
            // Handle USB connection mode for real device
            if let mode = args["connectMode"] as? String, mode == "usb" {
                client.forceDisconnect()
                client.connectDirectTCP()
                let status = client.isConnected ? "Connected via USB tunnel" : "USB tunnel connection failed — ensure app is running and iproxy is active"
                let defaults = sim.setDefaults(args: args)
                return "\(defaults)\n\(status)"
            }
            return sim.setDefaults(args: args)
        case "session_show_defaults":
            return sim.showDefaults()
        case "tap":
            // If label provided and Noober SDK connected, resolve label → coordinates first
            var resolvedArgs = args
            if let label = args["label"] as? String, args["x"] == nil, client.isConnected {
                let findResult = client.requestFindElement(text: label, exact: false)
                if let centerRange = findResult.range(of: "center=("),
                   let closeRange = findResult[centerRange.upperBound...].range(of: ")") {
                    let coordStr = findResult[centerRange.upperBound..<closeRange.lowerBound]
                    let parts = coordStr.split(separator: ",")
                    if parts.count == 2, let cx = Int(parts[0]), let cy = Int(parts[1]) {
                        resolvedArgs["x"] = cx
                        resolvedArgs["y"] = cy
                    }
                }
                if resolvedArgs["x"] == nil { return "Element not found: \(label)" }
            }
            // Always use AXe/simctl for the actual tap (in-process synthesis is fragile on iOS 26+)
            guard sim.isAvailable else { return "No tap target — provide x,y coordinates or label" }
            return sim.tap(
                x: resolvedArgs["x"] as? Int,
                y: resolvedArgs["y"] as? Int,
                label: resolvedArgs["x"] != nil ? nil : args["label"] as? String,
                id: args["id"] as? String,
                postDelay: args["postDelay"] as? Double
            )
        case "swipe":
            // Always use AXe/simctl for swipes
            guard sim.isAvailable else { return "Swipe not available" }
            return sim.swipe(
                startX: args["x1"] as? Int ?? 0, startY: args["y1"] as? Int ?? 0,
                endX: args["x2"] as? Int ?? 0, endY: args["y2"] as? Int ?? 0,
                duration: args["duration"] as? Double
            )
        case "type_text":
            if client.isConnected {
                return client.requestTypeText(args["text"] as? String ?? "")
            }
            guard sim.isAvailable else { return "Type not available — Noober SDK not connected" }
            return sim.typeText(args["text"] as? String ?? "")
        case "touch":
            return sim.touch(
                x: args["x"] as? Int ?? 0,
                y: args["y"] as? Int ?? 0,
                down: args["down"] as? Bool ?? true,
                up: args["up"] as? Bool ?? true,
                delay: args["delay"] as? Double
            )
        case "screenshot":
            let result = sim.screenshot()
            return result.text // base64 handled separately if needed
        case "launch_app_sim":
            // Force disconnect from old probe (may be dead after crash/stop)
            client.forceDisconnect()

            // Always inject probe — it auto-skips if real Noober SDK is present
            let result = sim.launchApp(
                bundleId: args["bundleId"] as? String,
                udid: args["simulatorId"] as? String,
                injectProbe: true
            )
            // Wait for new probe Bonjour to advertise
            Thread.sleep(forTimeInterval: 2)
            client.waitForConnection(timeout: 8)
            return result
        case "stop_app_sim":
            // Force disconnect — the probe in the old process is dead
            client.forceDisconnect()
            return sim.stopApp(bundleId: args["bundleId"] as? String)
        case "list_sims":
            return sim.listSimulators()
        case "boot_sim":
            return sim.bootSimulator(udid: args["simulatorId"] as? String)
        case "open_sim":
            return sim.openSimulator()
        case "snapshot_ui":
            return sim.snapshotUI()
        case "button":
            return sim.button(
                args["buttonType"] as? String ?? "home",
                duration: args["duration"] as? Double
            )
        default:
            return "Unknown tool: \(name)"
        }
    }

    // MARK: - JSON-RPC Helpers

    private func jsonRPC(id: Any?, result: [String: Any]) -> [String: Any] {
        var resp: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { resp["id"] = id }
        return resp
    }

    private func jsonRPCError(id: Any?, code: Int, message: String) -> [String: Any] {
        var resp: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        if let id { resp["id"] = id }
        return resp
    }

    private func sendResponse(_ response: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: response),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line) // stdout
        fflush(stdout)
    }
}
