import Foundation

/// Tool schemas for the in-app (SDK / probe) tools. Unchanged from 1.x.
extension MCPServer {
    func nooberToolDefinitions() -> [[String: Any]] {
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

    func tool(_ name: String, _ desc: String, _ props: [String: [String: String]]) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": props]
        if props.isEmpty { schema["properties"] = [:] as [String: Any] }
        return ["name": name, "description": desc, "inputSchema": schema]
    }
}
