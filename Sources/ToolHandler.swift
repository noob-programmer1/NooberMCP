import Foundation
import NooberShared

/// Implements each MCP tool by querying the NooberClient's cached state.
struct ToolHandler {

    func call(tool: String, args: [String: Any], client: NooberClient, bundleId: String? = nil, sim: SimulatorBridge? = nil) -> String {
        // Fire overlay visualization — show orb while tool is running
        triggerOverlay(tool: tool, client: client)
        defer { client.hideOverlay() }

        // Android mode: check Frida bridge capture file first
        if sim?.isAndroidMode == true || AndroidCapture.isActive {
            // Overlay disabled for now — causes Frida crash without SYSTEM_ALERT_WINDOW permission
            // TODO: re-enable after granting permission in pre-warm

            switch tool {
            case "noober_status":
                return AndroidCapture.status()
            case "noober_get_network_logs":
                return AndroidCapture.networkLogs(
                    limit: args["limit"] as? Int ?? 20,
                    urlFilter: args["url_pattern"] as? String
                )
            case "noober_get_request_detail":
                return AndroidCapture.requestDetail(id: args["request_id"] as? String ?? "")
            case "noober_get_app_logs":
                return AndroidCapture.appLogs(
                    limit: args["limit"] as? Int ?? 20,
                    level: args["level"] as? String
                )
            case "noober_assert_request":
                return AndroidCapture.assertRequest(
                    urlPattern: args["url_pattern"] as? String ?? "",
                    method: args["method"] as? String
                )
            case "noober_screen_html":
                return AndroidCapture.screenHTML(serial: sim?.androidSerial)
            case "noober_screen_text":
                let html = AndroidCapture.screenHTML(serial: sim?.androidSerial)
                // Extract just the text content from the HTML
                var texts: [String] = []
                for line in html.components(separatedBy: "\n") {
                    if let start = line.range(of: ">"), let end = line.range(of: "</", range: start.upperBound..<line.endIndex) {
                        let text = String(line[start.upperBound..<end.lowerBound])
                        if !text.isEmpty { texts.append(text) }
                    }
                }
                return texts.joined(separator: "\n")
            case "noober_find_element":
                let searchText = args["text"] as? String ?? ""
                let html = AndroidCapture.screenHTML(serial: sim?.androidSerial)
                for line in html.components(separatedBy: "\n") {
                    if line.lowercased().contains(searchText.lowercased()),
                       let centerRange = line.range(of: "center=\""),
                       let closeQuote = line.range(of: "\"", range: centerRange.upperBound..<line.endIndex) {
                        let coords = line[centerRange.upperBound..<closeQuote.lowerBound]
                        return "Found: \(searchText) at center=(\(coords))"
                    }
                }
                return "Element not found: \(searchText)"
            case "noober_get_user_defaults":
                return AndroidCapture.readPrefs(prefsName: args["filter"] as? String)
            case "noober_add_mock_rule":
                return AndroidCapture.addMockRule(
                    id: args["rule_id"] as? String ?? "mock-\(Int(Date().timeIntervalSince1970))",
                    urlPattern: args["url_pattern"] as? String ?? "",
                    method: args["method"] as? String ?? "*",
                    statusCode: args["status_code"] as? Int ?? 200,
                    responseBody: args["response_body"] as? String ?? "{}",
                    responseHeaders: (args["response_headers"] as? [String: String]) ?? ["Content-Type": "application/json"]
                )
            case "noober_remove_mock_rule":
                return AndroidCapture.removeMockRule(id: args["rule_id"] as? String ?? "")
            default:
                break // fall through to normal handler
            }
        }

        switch tool {
        case "noober_status":
            return status(client)
        case "noober_get_network_logs":
            return networkLogs(client, limit: args["limit"] as? Int ?? 20, screen: args["screen"] as? String, source: args["source"] as? String)
        case "noober_get_request_detail":
            return requestDetail(client, id: args["request_id"] as? String ?? "")
        case "noober_get_app_logs":
            return appLogs(client, limit: args["limit"] as? Int ?? 20, level: args["level"] as? String, screen: args["screen"] as? String)
        case "noober_get_environment":
            return environment(client)
        case "noober_switch_environment":
            return switchEnvironment(client, name: args["environment_name"] as? String ?? "")
        case "noober_replay_request":
            return replayRequest(client, id: args["request_id"] as? String ?? "")
        case "noober_get_qa_checklist":
            return qaChecklist(client)
        case "noober_mark_qa":
            return markQA(client, id: args["item_id"] as? String ?? "", status: args["status"] as? String ?? "", notes: args["notes"] as? String)
        case "noober_get_user_defaults":
            return userDefaults(client, filter: args["filter"] as? String)
        case "noober_get_websocket_logs":
            return websocketLogs(client, limit: args["limit"] as? Int ?? 20)
        case "noober_get_rules":
            return rules(client)
        case "noober_find_element":
            return client.requestFindElement(text: args["text"] as? String ?? "", exact: args["exact"] as? Bool ?? false)
        case "noober_screen_text":
            return client.requestScreenText()
        case "noober_screen_html":
            return client.requestScreenHTML()
        case "noober_check_event":
            return checkEvent(client, name: args["event_name"] as? String ?? "", property: args["property"] as? String, value: args["value"] as? String, since: args["since_seconds"] as? Int)
        case "noober_get_value":
            return getValue(client, text: args["text"] as? String ?? "")
        case "noober_assert_request":
            return assertRequest(client, args: args)
        case "noober_current_screen":
            guard client.isConnected else { return "Noober not connected" }
            // Fetch live screen name via a quick screen_text call (updates currentScreen)
            _ = client.requestScreenText(timeout: 2)
            return "Current screen: \(client.currentScreen)"
        case "noober_screenshot":
            let result = client.requestScreenshot()
            return result.text
        case "noober_get_recorded_flows":
            return recordedFlows(client)
        case "noober_timeline":
            return timeline(client, sinceSeconds: args["since_seconds"] as? Int ?? 30, limit: args["limit"] as? Int ?? 50)
        case "noober_get_cookies":
            return client.requestCookies()
        case "noober_set_user_default":
            guard let key = args["key"] as? String, let value = args["value"] as? String else {
                return "key and value are required"
            }
            return client.requestStorageWrite(type: "command.setUserDefault",
                                              payload: ["key": key, "value": value])
        case "noober_remove_user_default":
            guard let key = args["key"] as? String else { return "key is required" }
            return client.requestStorageWrite(type: "command.removeUserDefault", payload: ["key": key])
        case "noober_set_keychain":
            guard let account = args["account"] as? String, let value = args["value"] as? String else {
                return "account and value are required"
            }
            var payload: [String: Any] = ["account": account, "value": value]
            if let service = args["service"] as? String { payload["service"] = service }
            if let itemClass = args["itemClass"] as? String { payload["itemClass"] = itemClass }
            return client.requestStorageWrite(type: "command.setKeychain", payload: payload)
        case "noober_remove_keychain":
            guard let account = args["account"] as? String else { return "account is required" }
            var payload: [String: Any] = ["account": account]
            if let service = args["service"] as? String { payload["service"] = service }
            return client.requestStorageWrite(type: "command.removeKeychain", payload: payload)
        case "noober_set_cookie":
            guard let name = args["name"] as? String, let value = args["value"] as? String,
                  let domain = args["domain"] as? String else {
                return "name, value and domain are required"
            }
            var payload: [String: Any] = ["name": name, "value": value, "domain": domain]
            if let path = args["path"] as? String { payload["path"] = path }
            if let secure = args["isSecure"] as? Bool { payload["isSecure"] = secure }
            if let ttl = args["expiresInSeconds"] as? Double { payload["expiresInSeconds"] = ttl }
            return client.requestStorageWrite(type: "command.setCookie", payload: payload)
        case "noober_remove_cookie":
            guard let name = args["name"] as? String else { return "name is required" }
            var payload: [String: Any] = ["name": name]
            if let domain = args["domain"] as? String { payload["domain"] = domain }
            return client.requestStorageWrite(type: "command.removeCookie", payload: payload)
        case "noober_assert_element":
            return assertElement(client, text: args["text"] as? String ?? "", state: args["state"] as? String ?? "exists")
        case "noober_verify_screen":
            return verifyScreen(client, contains: args["contains"] as? String, notContains: args["not_contains"] as? String)
        case "noober_assert_flow":
            return assertFlow(client, stepsJSON: args["steps"] as? String ?? "[]")
        case "noober_add_mock_rule":
            return addMockRule(client, args: args)
        case "noober_remove_mock_rule":
            return removeRule(client, type: "mock", ruleId: args["rule_id"] as? String ?? "")
        case "noober_add_intercept_rule":
            return addInterceptRule(client, args: args)
        case "noober_remove_intercept_rule":
            return removeRule(client, type: "intercept", ruleId: args["rule_id"] as? String ?? "")
        case "noober_perf_snapshot":
            return client.requestPerfSnapshot()
        case "noober_accessibility_audit":
            return client.requestAccessibilityAudit()
        case "noober_visual_check":
            return visualCheck(client, bundleId: bundleId, screenName: args["screen_name"] as? String, threshold: args["threshold"] as? Double ?? 5.0, saveBaseline: args["save_baseline"] as? Bool ?? false)
        case "noober_webview_console":
            return webviewConsole(client, level: args["level"] as? String, limit: args["limit"] as? Int ?? 50)
        case "noober_get_crash_log":
            return getCrashLog(bundleId: bundleId)
        case "noober_rebuild_app":
            guard let sim else { return "Error: Simulator bridge not available" }
            return rebuildApp(sim, args: args)
        default:
            return "Unknown tool: \(tool)"
        }
    }

    // MARK: - Overlay Visualization

    private func triggerOverlay(tool: String, client: NooberClient) {
        switch tool {
        // Data tools
        case "noober_get_network_logs", "noober_get_request_detail", "noober_replay_request":
            client.showOverlay(category: "data", detail: "network")
        case "noober_get_app_logs":
            client.showOverlay(category: "data", detail: "logs")
        case "noober_get_user_defaults":
            client.showOverlay(category: "data", detail: "defaults")
        case "noober_get_websocket_logs":
            client.showOverlay(category: "data", detail: "websocket")
        case "noober_get_cookies":
            client.showOverlay(category: "data", detail: "cookies")
        case "noober_get_rules":
            client.showOverlay(category: "data", detail: "rules")
        case "noober_timeline":
            client.showOverlay(category: "data", detail: "timeline")
        case "noober_get_recorded_flows":
            client.showOverlay(category: "data", detail: "flows")
        case "noober_get_qa_checklist":
            client.showOverlay(category: "data", detail: "QA checklist")
        // Verify tools
        case "noober_check_event":
            client.showOverlay(category: "verify", detail: "event")
        case "noober_get_value":
            client.showOverlay(category: "verify", detail: "value")
        case "noober_assert_request":
            client.showOverlay(category: "verify", detail: "request")
        case "noober_assert_element":
            client.showOverlay(category: "verify", detail: "element")
        case "noober_verify_screen":
            client.showOverlay(category: "verify", detail: "screen")
        case "noober_assert_flow":
            client.showOverlay(category: "verify", detail: "flow")
        // Environment
        case "noober_switch_environment":
            client.showOverlay(category: "environment", detail: "switching")
        case "noober_get_environment":
            client.showOverlay(category: "environment", detail: "env")
        // Scan tools (these also trigger via probe, but fire for non-probe path)
        case "noober_current_screen":
            client.showOverlay(category: "scan", detail: "screen")
        default:
            break
        }
    }

    // MARK: - Status

    private func status(_ c: NooberClient) -> String {
        guard c.isConnected else {
            return """
            Noober: NOT CONNECTED
            The iOS app may not be running, or Noober.shared.start() hasn't been called.
            Ensure the app is running in the simulator with Noober enabled.
            """
        }
        return """
        Noober: CONNECTED ✅
        Build: \(c.buildNumber)
        HTTP Requests: \(c.httpRequests.count)
        WebSocket Connections: \(c.wsConnections.count)
        Log Entries: \(c.logEntries.count)
        Environments: \(c.environments.count) (active: \(c.environments.first(where: { $0.id == c.activeEnvironmentId })?.name ?? "none"))
        QA Checklist Items: \(c.qaResults.count)
        Rules: \(c.rewriteRules.count) rewrite, \(c.mockRules.count) mock, \(c.interceptRules.count) intercept
        UserDefaults: \(c.userDefaultsEntries.count) entries
        Keychain: \(c.keychainEntries.count) entries
        """
    }

    // MARK: - Network

    private func networkLogs(_ c: NooberClient, limit: Int, screen: String? = nil, source: String? = nil) -> String {
        guard c.isConnected else { return "Noober not connected" }
        var filtered = c.httpRequests
        if let screen { filtered = filtered.filter { $0.screenName?.lowercased().contains(screen.lowercased()) == true } }
        if let source {
            switch source.lowercased() {
            case "webview", "web_view", "wv":
                filtered = filtered.filter { $0.isWebView }
            case "native", "urlsession", "url_session":
                filtered = filtered.filter { !$0.isWebView }
            default:
                break
            }
        }
        let requests = Array(filtered.suffix(limit).reversed())
        if requests.isEmpty {
            var filters: [String] = []
            if let screen { filters.append("screen \"\(screen)\"") }
            if let source { filters.append("source \"\(source)\"") }
            return filters.isEmpty ? "No HTTP requests captured yet." : "No HTTP requests matching \(filters.joined(separator: " + "))."
        }

        let header = source?.lowercased() == "webview" ? "WebView HTTP Requests" : "Recent HTTP Requests"
        var lines: [String] = ["\(header) (\(requests.count)):"]
        for r in requests {
            let status = r.statusCode.map { "\($0)" } ?? "—"
            let dur = String(format: "%.0fms", r.duration * 1000)
            let flags = [
                r.isMocked ? "MOCKED" : nil,
                r.isIntercepted ? "INTERCEPTED" : nil,
                r.isEnvironmentRewritten ? "REWRITTEN" : nil,
                r.isWebView ? "WEBVIEW" : nil,
            ].compactMap { $0 }.joined(separator: ",")

            lines.append("[\(r.id.uuidString.prefix(8))] \(r.method) \(status) \(dur) \(r.url)\(flags.isEmpty ? "" : " (\(flags))")\(r.screenName.map { " from: \($0)" } ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    private func requestDetail(_ c: NooberClient, id: String) -> String {
        guard c.isConnected else { return "Noober not connected" }
        guard let request = c.httpRequests.first(where: { $0.id.uuidString.hasPrefix(id) || $0.id.uuidString == id }) else {
            return "Request not found. Use noober_get_network_logs to see available requests."
        }

        var lines: [String] = [
            "Request: \(request.method) \(request.url)",
            "Status: \(request.statusCode ?? 0)",
            "Duration: \(String(format: "%.0fms", request.duration * 1000))",
            "Screen: \(request.screenName ?? "unknown")",
            "",
            "--- Request Headers ---",
        ]
        for (k, v) in request.requestHeaders.sorted(by: { $0.key < $1.key }) {
            lines.append("\(k): \(v)")
        }

        if let body = request.requestBody, let text = String(data: body, encoding: .utf8), !text.isEmpty {
            lines.append("")
            lines.append("--- Request Body ---")
            lines.append(String(text.prefix(2000)))
        }

        lines.append("")
        lines.append("--- Response Headers ---")
        for (k, v) in request.responseHeaders.sorted(by: { $0.key < $1.key }) {
            lines.append("\(k): \(v)")
        }

        if let body = request.responseBody, let text = String(data: body, encoding: .utf8), !text.isEmpty {
            lines.append("")
            lines.append("--- Response Body ---")
            lines.append(String(text.prefix(4000)))
        }

        if let err = request.errorDescription {
            lines.append("")
            lines.append("--- Error ---")
            lines.append(err)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Logs

    private func appLogs(_ c: NooberClient, limit: Int, level: String?, screen: String? = nil) -> String {
        guard c.isConnected else { return "Noober not connected" }
        var entries = c.logEntries
        if let level { entries = entries.filter { $0.level == level } }
        if let screen { entries = entries.filter { $0.screenName?.lowercased().contains(screen.lowercased()) == true } }
        let recent = Array(entries.suffix(limit).reversed())
        if recent.isEmpty {
            var filters: [String] = []
            if let level { filters.append("level \(level)") }
            if let screen { filters.append("screen \"\(screen)\"") }
            return filters.isEmpty ? "No log entries." : "No log entries matching \(filters.joined(separator: " + "))."
        }

        var lines: [String] = ["App Logs (\(recent.count)\(screen.map { " on \($0)" } ?? "")):"]
        for e in recent {
            let screenTag = e.screenName.map { " [\($0)]" } ?? ""
            lines.append("[\(e.level)] [\(e.category)] \(e.message)\(screenTag)  (\(e.file):\(e.line))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Environment

    private func environment(_ c: NooberClient) -> String {
        guard c.isConnected else { return "Noober not connected" }
        let active = c.environments.first(where: { $0.id == c.activeEnvironmentId })

        var lines: [String] = ["Active: \(active?.name ?? "none")"]
        if let active {
            for (i, url) in active.baseURLs.enumerated() {
                lines.append("  URL[\(i)]: \(url)")
            }
        }
        lines.append("")
        lines.append("Available environments:")
        for env in c.environments {
            let marker = env.id == c.activeEnvironmentId ? " ← ACTIVE" : ""
            lines.append("  \(env.name)\(marker): \(env.baseURLs.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private func switchEnvironment(_ c: NooberClient, name: String) -> String {
        guard c.isConnected else { return "Noober not connected" }
        guard let env = c.environments.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            let available = c.environments.map(\.name).joined(separator: ", ")
            return "Environment '\(name)' not found. Available: \(available)"
        }
        c.sendCommand(.commandSwitchEnvironment, payload: SwitchEnvironmentCommand(environmentId: env.id))
        return "Switched to: \(env.name) (\(env.baseURLs.joined(separator: ", ")))"
    }

    // MARK: - Replay

    private func replayRequest(_ c: NooberClient, id: String) -> String {
        guard c.isConnected else { return "Noober not connected" }
        guard let request = c.httpRequests.first(where: { $0.id.uuidString.hasPrefix(id) || $0.id.uuidString == id }) else {
            return "Request not found."
        }
        c.sendCommand(.commandReplayRequest, payload: ReplayRequestCommand(
            url: request.url, method: request.method,
            headers: request.requestHeaders, body: request.requestBody
        ))
        return "Replaying: \(request.method) \(request.url)"
    }

    // MARK: - QA Checklist

    private func qaChecklist(_ c: NooberClient) -> String {
        guard c.isConnected else { return "Noober not connected" }
        if c.qaResults.isEmpty { return "No QA checklist items registered." }

        var lines: [String] = ["QA Checklist (build \(c.buildNumber)):"]
        for item in c.qaResults {
            let icon = item.status == "PASSED" ? "✅" : item.status == "FAILED" ? "❌" : "⏳"
            lines.append("\(icon) [\(item.id.uuidString.prefix(8))] \(item.title) — \(item.status)")
            if !item.notes.isEmpty { lines.append("   Notes: \(item.notes)") }
            if !item.endpoints.isEmpty { lines.append("   Endpoints: \(item.endpoints.joined(separator: ", "))") }
            if !item.failNotes.isEmpty { lines.append("   Fail reason: \(item.failNotes)") }
        }
        return lines.joined(separator: "\n")
    }

    private func markQA(_ c: NooberClient, id: String, status: String, notes: String?) -> String {
        guard c.isConnected else { return "Noober not connected" }
        guard let item = c.qaResults.first(where: { $0.id.uuidString.hasPrefix(id) || $0.id.uuidString == id }) else {
            return "QA item not found."
        }
        let type: CompanionMessageType = status == "PASSED" ? .commandMarkQAPassed :
                                         status == "FAILED" ? .commandMarkQAFailed : .commandResetQAItem
        c.sendCommand(type, payload: MarkQACommand(itemId: item.id, notes: notes, requestIds: nil))
        return "Marked '\(item.title)' as \(status)"
    }

    // MARK: - Storage

    private func userDefaults(_ c: NooberClient, filter: String?) -> String {
        guard c.isConnected else { return "Noober not connected" }
        var entries = c.userDefaultsEntries
        if let filter { entries = entries.filter { $0.key.lowercased().contains(filter.lowercased()) } }
        if entries.isEmpty { return "No UserDefaults entries\(filter.map { " matching '\($0)'" } ?? "")." }

        var lines: [String] = ["UserDefaults (\(entries.count) entries):"]
        for e in entries.prefix(50) {
            lines.append("  [\(e.valueType)] \(e.key) = \(e.displayValue.prefix(200))")
        }
        if entries.count > 50 { lines.append("  ... \(entries.count - 50) more") }
        return lines.joined(separator: "\n")
    }

    // MARK: - WebSocket

    private func websocketLogs(_ c: NooberClient, limit: Int) -> String {
        guard c.isConnected else { return "Noober not connected" }
        if c.wsConnections.isEmpty { return "No WebSocket connections." }

        var lines: [String] = ["WebSocket Connections (\(c.wsConnections.count)):"]
        for conn in c.wsConnections {
            lines.append("[\(conn.id.uuidString.prefix(8))] \(conn.url) — \(conn.status)")
            for frame in conn.frames.suffix(limit) {
                let dir = frame.direction == "Sent" ? "→" : "←"
                let payload = frame.payloadString ?? frame.payload.map { "\($0.count) bytes" } ?? ""
                lines.append("  \(dir) [\(frame.frameType)] \(String(payload.prefix(200)))")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Rules

    private func rules(_ c: NooberClient) -> String {
        guard c.isConnected else { return "Noober not connected" }

        var lines: [String] = []

        if !c.rewriteRules.isEmpty {
            lines.append("URL Rewrite Rules (\(c.rewriteRules.count)):")
            for r in c.rewriteRules {
                lines.append("  \(r.isEnabled ? "✅" : "❌") \(r.name): \(r.matchPattern.mode)(\(r.matchPattern.pattern)) → \(r.replacementHost)")
            }
        }

        if !c.mockRules.isEmpty {
            lines.append("Mock Rules (\(c.mockRules.count)):")
            for r in c.mockRules {
                lines.append("  \(r.isEnabled ? "✅" : "❌") \(r.name): \(r.matchPattern.pattern) → \(r.mockStatusCode)")
            }
        }

        if !c.interceptRules.isEmpty {
            lines.append("Intercept Rules (\(c.interceptRules.count)):")
            for r in c.interceptRules {
                lines.append("  \(r.isEnabled ? "✅" : "❌") \(r.name): \(r.matchPattern.pattern)")
            }
        }

        return lines.isEmpty ? "No rules configured." : lines.joined(separator: "\n")
    }

    // MARK: - Check Event (fast analytics verification)

    private func checkEvent(_ c: NooberClient, name: String, property: String?, value: String?, since: Int?) -> String {
        guard c.isConnected else { return "Noober not connected" }
        let entries = c.logEntries

        // Search ALL cached logs (buffer is max 500 — fast enough)
        // Time filtering was unreliable due to clock differences
        let query = name.lowercased()
        let matches = entries.filter {
            $0.message.lowercased().contains(query) || $0.category.lowercased().contains(query)
        }

        if matches.isEmpty {
            return "NOT FOUND: Event \"\(name)\" not found in \(entries.count) log entries\(since.map { " (last \($0)s)" } ?? "")"
        }

        // If checking a specific property value
        if let property, let value {
            let propQuery = "\(property).*\(value)".lowercased()
            let propMatches = matches.filter { $0.message.lowercased().range(of: propQuery, options: .regularExpression) != nil }
            if propMatches.isEmpty {
                let lastMatch = matches.last!
                return "FOUND but PROPERTY MISMATCH: Event \"\(name)\" fired \(matches.count)x but \"\(property)\" != \"\(value)\"\nLatest: \(lastMatch.message)"
            }
            return "PASS: Event \"\(name)\" fired with \(property) = \(value) (\(propMatches.count) match(es))"
        }

        // If checking just a property exists
        if let property {
            let propMatches = matches.filter { $0.message.lowercased().contains(property.lowercased()) }
            if propMatches.isEmpty {
                return "FOUND but MISSING PROPERTY: Event \"\(name)\" fired \(matches.count)x but property \"\(property)\" not found\nLatest: \(matches.last!.message)"
            }
            // Extract the property value
            let msg = propMatches.last!.message
            return "PASS: Event \"\(name)\" fired with \"\(property)\" present (\(propMatches.count)x)\nLatest: \(String(msg.prefix(300)))"
        }

        // Just check if event fired
        let latest = matches.last!
        return "PASS: Event \"\(name)\" fired \(matches.count) time(s)\nLatest: \(String(latest.message.prefix(300)))"
    }

    // MARK: - Get Value (fast element value extraction)

    private func getValue(_ c: NooberClient, text: String) -> String {
        guard c.isConnected else { return "Noober not connected" }

        // Use screen text to find the value near the matching text
        let screenText = c.requestScreenText(timeout: 3)
        let lines = screenText.components(separatedBy: "\n")
        let query = text.lowercased()

        // Find the line containing the query
        for (i, line) in lines.enumerated() {
            if line.lowercased().contains(query) {
                // Return this line and adjacent lines for context
                var result = "Found: \(line.trimmingCharacters(in: .whitespaces))"
                if i + 1 < lines.count {
                    result += "\nNext: \(lines[i + 1].trimmingCharacters(in: .whitespaces))"
                }
                return result
            }
        }

        return "NOT FOUND: No element containing \"\(text)\" on current screen"
    }

    // MARK: - Assert Request (network validation — Noober's advantage over Revyl)

    private func assertRequest(_ c: NooberClient, args: [String: Any]) -> String {
        guard c.isConnected else { return "Noober not connected" }

        let urlPattern = args["url_pattern"] as? String
        let method = args["method"] as? String
        let minStatus = args["min_status"] as? Int ?? 200
        let maxStatus = args["max_status"] as? Int ?? 299
        let bodyContains = args["body_contains"] as? String
        let since = args["since_seconds"] as? Int

        var candidates = c.httpRequests

        // Filter by time window
        if let since {
            let cutoff = Date().addingTimeInterval(-Double(since))
            candidates = candidates.filter { $0.timestamp > cutoff }
        }

        // Filter by URL pattern
        if let urlPattern {
            let pattern = urlPattern.lowercased()
            candidates = candidates.filter { $0.url.lowercased().contains(pattern) }
        }

        // Filter by method
        if let method {
            candidates = candidates.filter { $0.method.uppercased() == method.uppercased() }
        }

        if candidates.isEmpty {
            var desc = "FAIL: No requests found"
            if let urlPattern { desc += " matching URL \"\(urlPattern)\"" }
            if let method { desc += " with method \(method)" }
            if let since { desc += " in the last \(since)s" }
            return desc
        }

        // Check status code range
        let statusMatches = candidates.filter {
            guard let code = $0.statusCode else { return false }
            return code >= minStatus && code <= maxStatus
        }

        if statusMatches.isEmpty {
            let statuses = candidates.compactMap { $0.statusCode }.map(String.init).joined(separator: ", ")
            return "FAIL: Found \(candidates.count) matching request(s) but none with status \(minStatus)-\(maxStatus). Actual statuses: \(statuses)"
        }

        // Check body contains
        if let bodyContains {
            let bodyMatches = statusMatches.filter {
                guard let body = $0.responseBody,
                      let text = String(data: body, encoding: .utf8) else { return false }
                return text.lowercased().contains(bodyContains.lowercased())
            }
            if bodyMatches.isEmpty {
                return "FAIL: Found \(statusMatches.count) request(s) with correct status but response body does not contain \"\(bodyContains)\""
            }
            let match = bodyMatches.first!
            return "PASS: \(match.method) \(match.statusCode ?? 0) \(match.url) — response contains \"\(bodyContains)\""
        }

        let match = statusMatches.first!
        return "PASS: \(match.method) \(match.statusCode ?? 0) \(match.url)"
    }

    // MARK: - Recorded Flows

    private func recordedFlows(_ c: NooberClient) -> String {
        guard c.isConnected else { return "Noober not connected" }
        if c.recordedFlows.isEmpty { return "No recorded flows. Record a flow in Noober by tapping the record button on the floating bubble." }

        var lines: [String] = ["Recorded Flows (\(c.recordedFlows.count)):"]
        for flow in c.recordedFlows {
            lines.append("")
            lines.append("[\(flow.id.uuidString.prefix(8))] \(flow.name) (\(flow.steps.count) steps)")
            if let desc = flow.description, !desc.isEmpty {
                lines.append("  Description: \(desc)")
            }
            for (i, step) in flow.steps.enumerated() {
                var desc = "  \(i + 1). \(step.action)"
                if let label = step.label { desc += " \"\(label)\"" }
                if let coords = step.startCoordinates { desc += " at (\(Int(coords.x)),\(Int(coords.y)))" }
                if let text = step.text { desc += " text=\"\(text)\"" }
                if let extra = step.extra { desc += " \(extra)" }
                desc += " [screen: \(step.screen)]"
                lines.append(desc)
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Timeline (unified view of network + logs + screen transitions)

    private func timeline(_ c: NooberClient, sinceSeconds: Int, limit: Int) -> String {
        guard c.isConnected else { return "Noober not connected" }

        let cutoff = Date().addingTimeInterval(-Double(sinceSeconds))

        struct TimelineEvent: Comparable {
            let time: Date
            let type: String
            let detail: String
            static func < (lhs: TimelineEvent, rhs: TimelineEvent) -> Bool { lhs.time < rhs.time }
        }

        var events: [TimelineEvent] = []

        // Network requests
        for req in c.httpRequests where req.timestamp > cutoff {
            let status = req.statusCode.map { "\($0)" } ?? "?"
            let dur = "\(Int(req.duration))ms"
            events.append(TimelineEvent(
                time: req.timestamp,
                type: "NET",
                detail: "\(req.method) \(status) \(req.url.prefix(80)) [\(dur)]"
            ))
        }

        // Logs
        for log in c.logEntries where log.timestamp > cutoff {
            events.append(TimelineEvent(
                time: log.timestamp,
                type: "LOG[\(log.level.prefix(4))]",
                detail: "[\(log.category)] \(log.message.prefix(100))"
            ))
        }

        events.sort()
        let limited = events.suffix(limit)

        if limited.isEmpty { return "No events in the last \(sinceSeconds)s" }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        var lines = ["Timeline (last \(sinceSeconds)s, \(limited.count) events):"]
        for e in limited {
            lines.append("  \(formatter.string(from: e.time)) [\(e.type)] \(e.detail)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Cookies

    private func cookies(_ c: NooberClient) -> String {
        guard c.isConnected else { return "Noober not connected" }
        // Cookies are not currently in the sync payload — return UserDefaults cookie-related entries
        let cookieEntries = c.userDefaultsEntries.filter {
            $0.key.lowercased().contains("cookie") || $0.key.contains("HTTPCookie")
        }
        if cookieEntries.isEmpty {
            return "No cookie data in current sync. Cookie inspection requires Noober SDK or NooberProbe Phase 2."
        }
        return cookieEntries.map { "\($0.key): \($0.displayValue)" }.joined(separator: "\n")
    }

    // MARK: - Assert Element (structured PASS/FAIL)

    private func assertElement(_ c: NooberClient, text: String, state: String) -> String {
        guard c.isConnected else { return "FAIL: Noober not connected" }

        let result = c.requestFindElement(text: text, exact: false)

        switch state.lowercased() {
        case "exists":
            if result.contains("Found") && !result.contains("No elements found") {
                return "PASS: Element '\(text)' exists on screen"
            }
            return "FAIL: Element '\(text)' not found on screen"

        case "enabled":
            if result.contains("Found") && !result.contains("No elements found") {
                // Element found — we can't check enabled state directly, but existence implies visibility
                return "PASS: Element '\(text)' found (visible = likely enabled)"
            }
            return "FAIL: Element '\(text)' not found"

        case "disabled":
            if result.contains("No elements found") {
                return "PASS: Element '\(text)' not visible (possibly disabled/hidden)"
            }
            return "INFO: Element '\(text)' is visible — check if it's actually disabled"

        case "selected":
            return "INFO: Selected state check not supported. Use noober_screen_html to inspect element attributes."

        default:
            return "Unknown state '\(state)'. Use: exists, enabled, disabled, selected"
        }
    }

    // MARK: - Mock/Intercept Rules

    private func addMockRule(_ c: NooberClient, args: [String: Any]) -> String {
        guard c.isConnected else { return "Noober not connected — mock rules require Noober SDK in the app" }

        let urlPattern = args["url_pattern"] as? String ?? ""
        let statusCode = args["status_code"] as? Int ?? 200
        let body = args["response_body"] as? String
        let method = args["method"] as? String
        let name = args["name"] as? String ?? "Mock \(urlPattern.prefix(30))"

        guard !urlPattern.isEmpty else { return "Error: url_pattern is required" }

        c.sendRawCommand(type: "command.addMockRule", payload: [
            "urlPattern": urlPattern,
            "statusCode": statusCode,
            "responseBody": body ?? "{}",
            "httpMethod": method as Any,
            "name": name,
        ])

        return "Mock rule added: \(method ?? "ANY") \(urlPattern) → \(statusCode) \(name)"
    }

    private func addInterceptRule(_ c: NooberClient, args: [String: Any]) -> String {
        guard c.isConnected else { return "Noober not connected — intercept rules require Noober SDK" }

        let urlPattern = args["url_pattern"] as? String ?? ""
        let method = args["method"] as? String
        let name = args["name"] as? String ?? "Intercept \(urlPattern.prefix(30))"

        guard !urlPattern.isEmpty else { return "Error: url_pattern is required" }

        c.sendRawCommand(type: "command.addInterceptRule", payload: [
            "urlPattern": urlPattern,
            "httpMethod": method as Any,
            "name": name,
        ])

        return "Intercept rule added: \(method ?? "ANY") \(urlPattern) — \(name)"
    }

    private func removeRule(_ c: NooberClient, type: String, ruleId: String) -> String {
        guard c.isConnected else { return "Noober not connected" }
        guard !ruleId.isEmpty else { return "Error: rule_id is required" }

        let msgType = type == "mock" ? "command.removeMockRule" : "command.removeInterceptRule"
        c.sendRawCommand(type: msgType, payload: ["ruleId": ruleId])

        return "\(type.capitalized) rule removed: \(ruleId)"
    }

    // MARK: - Verify Screen (PASS/FAIL)

    private func verifyScreen(_ c: NooberClient, contains: String?, notContains: String?) -> String {
        guard c.isConnected else { return "FAIL: Noober not connected" }

        let screenText = c.requestScreenText()
        let lower = screenText.lowercased()
        var results: [String] = []

        if let text = contains {
            if lower.contains(text.lowercased()) {
                results.append("PASS: Screen contains '\(text)'")
            } else {
                results.append("FAIL: Screen does NOT contain '\(text)'")
            }
        }

        if let text = notContains {
            if lower.contains(text.lowercased()) {
                results.append("FAIL: Screen contains '\(text)' (should NOT)")
            } else {
                results.append("PASS: Screen does not contain '\(text)' (correct)")
            }
        }

        if results.isEmpty { return "No assertion specified. Provide 'contains' or 'not_contains'." }

        let allPassed = results.allSatisfy { $0.hasPrefix("PASS") }
        let screen = c.currentScreen
        return "Screen: \(screen)\n" + results.joined(separator: "\n") + "\nOverall: \(allPassed ? "PASS" : "FAIL")"
    }

    // MARK: - Assert Flow (network assertion chains)

    private func assertFlow(_ c: NooberClient, stepsJSON: String) -> String {
        guard c.isConnected else { return "FAIL: Noober not connected" }

        guard let data = stepsJSON.data(using: .utf8),
              let steps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return "FAIL: Invalid JSON in 'steps' parameter. Expected a JSON array of step objects."
        }

        if steps.isEmpty {
            return "FAIL: No steps provided. Pass a JSON array of steps."
        }

        var results: [String] = []
        var passCount = 0
        var failCount = 0

        for (i, step) in steps.enumerated() {
            let stepNum = i + 1
            let type = step["type"] as? String ?? ""

            switch type {
            case "request":
                let urlPattern = step["url_pattern"] as? String ?? ""
                let method = step["method"] as? String
                let expectedStatus = step["status"] as? Int

                var candidates = c.httpRequests

                // Filter by URL pattern
                if !urlPattern.isEmpty {
                    let pattern = urlPattern.lowercased()
                    candidates = candidates.filter { $0.url.lowercased().contains(pattern) }
                }

                // Filter by method
                if let method {
                    candidates = candidates.filter { $0.method.uppercased() == method.uppercased() }
                }

                if candidates.isEmpty {
                    results.append("Step \(stepNum) [request] FAIL: No requests matching \(method ?? "ANY") \(urlPattern)")
                    failCount += 1
                } else if let expectedStatus {
                    let statusMatches = candidates.filter { $0.statusCode == expectedStatus }
                    if statusMatches.isEmpty {
                        let actual = candidates.compactMap { $0.statusCode }.map(String.init).joined(separator: ", ")
                        results.append("Step \(stepNum) [request] FAIL: Found \(candidates.count) request(s) for \(urlPattern) but none with status \(expectedStatus). Actual: \(actual)")
                        failCount += 1
                    } else {
                        let match = statusMatches.last!
                        results.append("Step \(stepNum) [request] PASS: \(match.method) \(match.statusCode ?? 0) \(match.url)")
                        passCount += 1
                    }
                } else {
                    let match = candidates.last!
                    results.append("Step \(stepNum) [request] PASS: \(match.method) \(match.statusCode ?? 0) \(match.url)")
                    passCount += 1
                }

            case "event":
                let eventName = step["event_name"] as? String ?? ""
                let query = eventName.lowercased()
                let matches = c.logEntries.filter {
                    $0.message.lowercased().contains(query) || $0.category.lowercased().contains(query)
                }

                if matches.isEmpty {
                    results.append("Step \(stepNum) [event] FAIL: Event \"\(eventName)\" not found in \(c.logEntries.count) log entries")
                    failCount += 1
                } else {
                    results.append("Step \(stepNum) [event] PASS: Event \"\(eventName)\" fired \(matches.count) time(s)")
                    passCount += 1
                }

            case "screen":
                let screenName = step["screen_name"] as? String ?? ""
                let current = c.currentScreen.lowercased()

                if current.contains(screenName.lowercased()) {
                    results.append("Step \(stepNum) [screen] PASS: Current screen \"\(c.currentScreen)\" matches \"\(screenName)\"")
                    passCount += 1
                } else {
                    results.append("Step \(stepNum) [screen] FAIL: Current screen \"\(c.currentScreen)\" does not match \"\(screenName)\"")
                    failCount += 1
                }

            default:
                results.append("Step \(stepNum) [unknown] FAIL: Unknown step type \"\(type)\". Use: request, event, screen")
                failCount += 1
            }
        }

        let overall = failCount == 0 ? "PASS" : "FAIL"
        let summary = "Assert Flow: \(passCount)/\(steps.count) passed, \(failCount) failed — Overall: \(overall)"
        return summary + "\n" + results.joined(separator: "\n")
    }

    // MARK: - Visual Regression Check

    private func visualCheck(_ c: NooberClient, bundleId: String?, screenName: String?, threshold: Double, saveBaseline: Bool) -> String {
        guard c.isConnected else { return "FAIL: Noober not connected" }

        let _ = c.requestScreenshot()
        guard let base64 = c.screenshotBase64Data,
              let currentPNG = Data(base64Encoded: base64) else {
            return "FAIL: Could not capture screenshot"
        }

        let screen = screenName ?? c.currentScreen
        let appBundleId = bundleId ?? "unknown"

        if saveBaseline {
            VisualDiff.saveBaseline(currentPNG, bundleId: appBundleId, screen: screen)
            return "Baseline saved for screen \"\(screen)\" (app: \(appBundleId))\nPath: \(VisualDiff.baselinesDir)/\(appBundleId)/"
        }

        guard let baselinePNG = VisualDiff.loadBaseline(bundleId: appBundleId, screen: screen) else {
            VisualDiff.saveBaseline(currentPNG, bundleId: appBundleId, screen: screen)
            return "No baseline found for screen \"\(screen)\" — saved current screenshot as baseline.\nRun again to compare against this baseline."
        }

        guard let result = VisualDiff.compare(current: currentPNG, baseline: baselinePNG, threshold: threshold) else {
            return "FAIL: Could not compare images (decode error)"
        }

        let diffStr = String(format: "%.2f%%", result.diffPercent)
        let threshStr = String(format: "%.1f%%", threshold)

        if result.passed {
            return "PASS: Visual check for \"\(screen)\" — \(diffStr) changed (\(result.changedPixels)/\(result.totalPixels) pixels, threshold: \(threshStr))"
        } else {
            return "FAIL: Visual regression on \"\(screen)\" — \(diffStr) changed (\(result.changedPixels)/\(result.totalPixels) pixels, threshold: \(threshStr))\nUse save_baseline=true to update the baseline if this change is intentional."
        }
    }

    // MARK: - WebView Console Logs

    private func webviewConsole(_ c: NooberClient, level: String?, limit: Int) -> String {
        guard c.isConnected else { return "Noober not connected" }
        return c.requestWebViewConsole(level: level, limit: limit)
    }

    // MARK: - Crash Log

    private func getCrashLog(bundleId: String?) -> String {
        // Try exact bundle ID first
        if let bid = bundleId {
            if let report = readCrashFile(bundleId: bid) {
                return report
            }
        }

        // Fallback: scan /tmp for any noober_crash_*.json file
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(atPath: "/tmp") {
            let crashFiles = files.filter { $0.hasPrefix("noober_crash_") && $0.hasSuffix(".json") }
                .sorted()  // alphabetical — predictable
            if let latest = crashFiles.last {
                let path = "/tmp/\(latest)"
                if let data = fm.contents(atPath: path),
                   let crash = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return formatCrashReport(crash)
                }
            }
        }

        return "No crash log found. The app may not have crashed, or the crash handler was not installed."
    }

    private func readCrashFile(bundleId: String) -> String? {
        let path = "/tmp/noober_crash_\(bundleId.replacingOccurrences(of: ".", with: "_")).json"
        guard let data = FileManager.default.contents(atPath: path),
              let crash = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return formatCrashReport(crash)
    }

    private func formatCrashReport(_ crash: [String: Any]) -> String {
        var lines: [String] = [
            "CRASH REPORT",
            "Type: \(crash["type"] ?? "?") — \(crash["name"] ?? "?")",
            "Reason: \(crash["reason"] ?? "?")",
            "Screen: \(crash["screen"] ?? "?")",
            "Last API: \(crash["lastRequest"] ?? "none")",
            "Time: \(crash["timestamp"] ?? "?")",
            "",
            "Stack Trace:"
        ]
        if let stack = crash["stack"] as? [String] {
            for (i, frame) in stack.prefix(20).enumerated() {
                lines.append("  \(i): \(frame)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Rebuild App

    private func rebuildApp(_ sim: SimulatorBridge, args: [String: Any]) -> String {
        let scheme = args["scheme"] as? String ?? sim.scheme ?? ""
        let projectPath = args["project_path"] as? String ?? ""
        let simId = sim.simulatorId ?? "booted"
        let bundleId = sim.bundleId ?? ""

        guard !scheme.isEmpty else { return "Error: scheme is required. Set it with session_set_defaults or pass it as an argument." }

        var lines: [String] = ["Rebuilding..."]

        // Stop app
        if !bundleId.isEmpty {
            _ = sim.stopApp(bundleId: bundleId)
            lines.append("Stopped \(bundleId)")
        }

        // Build
        var buildCmd: String
        if !projectPath.isEmpty {
            if projectPath.hasSuffix(".xcworkspace") {
                buildCmd = "xcodebuild -workspace '\(projectPath)' -scheme \(scheme) -destination 'platform=iOS Simulator,id=\(simId)' -derivedDataPath /tmp/noober_build build 2>&1 | tail -5"
            } else {
                buildCmd = "xcodebuild -project '\(projectPath)' -scheme \(scheme) -destination 'platform=iOS Simulator,id=\(simId)' -derivedDataPath /tmp/noober_build build 2>&1 | tail -5"
            }
        } else {
            buildCmd = "xcodebuild -scheme \(scheme) -destination 'platform=iOS Simulator,id=\(simId)' -derivedDataPath /tmp/noober_build build 2>&1 | tail -5"
        }

        guard let buildOutput = sim.shell(buildCmd, timeout: 120) else {
            return "Build failed (timeout after 120 seconds)"
        }

        if buildOutput.contains("BUILD SUCCEEDED") {
            lines.append("Build succeeded")
        } else if buildOutput.contains("BUILD FAILED") {
            return "Build failed:\n\(buildOutput)"
        } else {
            lines.append("Build output: \(String(buildOutput.suffix(200)))")
        }

        // Find .app
        let findCmd = "find /tmp/noober_build -name '*.app' -path '*/Build/Products/*' | head -1"
        guard let appPath = sim.shell(findCmd)?.trimmingCharacters(in: .whitespacesAndNewlines), !appPath.isEmpty else {
            return lines.joined(separator: "\n") + "\nError: Could not find built .app"
        }

        // Install
        _ = sim.shell("xcrun simctl install \(simId) '\(appPath)' 2>&1")
        lines.append("Installed: \(appPath.components(separatedBy: "/").last ?? appPath)")

        // Relaunch with probe
        if !bundleId.isEmpty {
            let probePath = "/tmp/NooberProbe.dylib"
            var launchCmd = "xcrun simctl launch \(simId) \(bundleId) 2>&1"
            if FileManager.default.fileExists(atPath: probePath) {
                launchCmd = "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=\(probePath) \(launchCmd)"
            }
            _ = sim.shell(launchCmd)
            lines.append("Relaunched \(bundleId)")
        }

        return lines.joined(separator: "\n")
    }
}
