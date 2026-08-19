import Foundation

/// Reads captured data from the Frida bridge file (~/.noobqa/android-capture.json).
/// This provides network logs, app logs, etc. for Android apps without the Noober SDK.
enum AndroidCapture {

    private static var capturePath: String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        return "\(home)/.noobqa/android-capture.json"
    }

    /// Check if Android capture is active (bridge is running)
    static var isActive: Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: capturePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let connected = json["connected"] as? Bool else { return false }
        // Check timestamp is recent (within 30 seconds)
        if let ts = json["timestamp"] as? Int {
            let age = (Int(Date().timeIntervalSince1970 * 1000) - ts) / 1000
            return connected && age < 30
        }
        return connected
    }

    /// Read the full capture file
    private static func readCapture() -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: capturePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    /// Get network requests (equivalent to noober_get_network_logs)
    static func networkLogs(limit: Int = 20, urlFilter: String? = nil) -> String {
        guard let capture = readCapture(),
              let requests = capture["httpRequests"] as? [[String: Any]] else {
            return "No Android capture data available. Ensure noober-bridge.py is running."
        }

        var filtered = requests
        if let filter = urlFilter, !filter.isEmpty {
            filtered = filtered.filter { ($0["url"] as? String ?? "").contains(filter) }
        }

        let recent = filtered.suffix(limit)
        if recent.isEmpty { return "No network requests captured." }

        var lines: [String] = ["Android Network Logs (\(recent.count) of \(requests.count) total):"]
        for req in recent {
            let method = req["method"] as? String ?? "?"
            let url = req["url"] as? String ?? "?"
            let status = req["statusCode"] as? Int ?? 0
            let duration = req["duration"] as? Int ?? 0
            let shortUrl = url.count > 70 ? String(url.prefix(70)) + "..." : url
            lines.append("  \(method) \(shortUrl) → \(status) (\(duration)ms)")
        }
        return lines.joined(separator: "\n")
    }

    /// Get request detail (equivalent to noober_get_request_detail)
    static func requestDetail(id: String) -> String {
        guard let capture = readCapture(),
              let requests = capture["httpRequests"] as? [[String: Any]] else {
            return "No capture data."
        }

        guard let req = requests.first(where: { ($0["id"] as? String) == id }) else {
            // Try matching by URL substring
            guard let req = requests.last(where: { ($0["url"] as? String ?? "").contains(id) }) else {
                return "Request not found: \(id)"
            }
            return formatRequestDetail(req)
        }
        return formatRequestDetail(req)
    }

    private static func formatRequestDetail(_ req: [String: Any]) -> String {
        var lines: [String] = []
        lines.append("URL: \(req["url"] as? String ?? "?")")
        lines.append("Method: \(req["method"] as? String ?? "?")")
        lines.append("Status: \(req["statusCode"] as? Int ?? 0)")
        lines.append("Duration: \(req["duration"] as? Int ?? 0)ms")

        if let headers = req["requestHeaders"] as? [String: String], !headers.isEmpty {
            lines.append("\nRequest Headers:")
            for (k, v) in headers.sorted(by: { $0.key < $1.key }) {
                lines.append("  \(k): \(v)")
            }
        }
        if let body = req["requestBody"] as? String, !body.isEmpty {
            lines.append("\nRequest Body:")
            lines.append("  \(body.prefix(2000))")
        }
        if let headers = req["responseHeaders"] as? [String: String], !headers.isEmpty {
            lines.append("\nResponse Headers:")
            for (k, v) in headers.sorted(by: { $0.key < $1.key }) {
                lines.append("  \(k): \(v)")
            }
        }
        if let body = req["responseBody"] as? String, !body.isEmpty {
            lines.append("\nResponse Body:")
            lines.append("  \(body.prefix(3000))")
        }
        return lines.joined(separator: "\n")
    }

    /// Get app logs (equivalent to noober_get_app_logs)
    static func appLogs(limit: Int = 20, level: String? = nil) -> String {
        guard let capture = readCapture(),
              let entries = capture["logEntries"] as? [[String: Any]] else {
            return "No Android capture data available."
        }

        var filtered = entries
        if let level = level, !level.isEmpty {
            filtered = filtered.filter { ($0["level"] as? String ?? "") == level }
        }

        let recent = filtered.suffix(limit)
        if recent.isEmpty { return "No log entries captured." }

        var lines: [String] = ["Android App Logs (\(recent.count) of \(entries.count) total):"]
        for entry in recent {
            let level = entry["level"] as? String ?? "?"
            let tag = entry["tag"] as? String ?? "?"
            let msg = entry["message"] as? String ?? ""
            let shortMsg = msg.count > 100 ? String(msg.prefix(100)) + "..." : msg
            lines.append("  [\(level)] \(tag): \(shortMsg)")
        }
        return lines.joined(separator: "\n")
    }

    /// Assert request (equivalent to noober_assert_request)
    static func assertRequest(urlPattern: String, method: String? = nil) -> String {
        guard let capture = readCapture(),
              let requests = capture["httpRequests"] as? [[String: Any]] else {
            return "FAIL: No capture data."
        }

        let matching = requests.filter { req in
            let url = req["url"] as? String ?? ""
            let reqMethod = req["method"] as? String ?? ""
            let urlMatch = url.contains(urlPattern)
            let methodMatch = method == nil || method == "*" || reqMethod.uppercased() == method!.uppercased()
            return urlMatch && methodMatch
        }

        if matching.isEmpty {
            return "FAIL: No request matching '\(urlPattern)' \(method != nil ? "(\(method!))" : "") found."
        }

        let last = matching.last!
        let status = last["statusCode"] as? Int ?? 0
        return "PASS: Found \(matching.count) request(s) matching '\(urlPattern)'. Last: \(last["method"] as? String ?? "?") → \(status)"
    }

    // MARK: - Commands (write to file, bridge picks up)

    private static var commandsPath: String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        return "\(home)/.noobqa/android-commands.json"
    }

    /// Send a command to the Frida bridge
    static func sendCommand(_ cmd: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: cmd, options: []) else { return }
        try? data.write(to: URL(fileURLWithPath: commandsPath), options: .atomic)
    }

    /// Add a mock rule
    static func addMockRule(id: String, urlPattern: String, method: String, statusCode: Int, responseBody: String, responseHeaders: [String: String]) -> String {
        let rule: [String: Any] = [
            "id": id, "urlPattern": urlPattern, "method": method,
            "statusCode": statusCode, "responseBody": responseBody,
            "responseHeaders": responseHeaders, "enabled": true
        ]
        sendCommand(["action": "add_mock_rule", "rule": rule])
        return "Mock rule added: \(method) *\(urlPattern)* → \(statusCode)"
    }

    /// Remove a mock rule
    static func removeMockRule(id: String) -> String {
        sendCommand(["action": "remove_mock_rule", "ruleId": id])
        return "Mock rule removed: \(id)"
    }

    /// Read SharedPreferences
    static func readPrefs(prefsName: String? = nil) -> String {
        // Trigger a read command
        var cmd: [String: Any] = ["action": "read_prefs"]
        if let name = prefsName { cmd["prefsName"] = name }
        sendCommand(cmd)

        // Wait briefly for the bridge to write the data
        Thread.sleep(forTimeInterval: 1.0)

        // Read from capture file
        guard let capture = readCapture(),
              let entries = capture["prefsEntries"] as? [[String: Any]] else {
            return "No SharedPreferences data. Ensure noober-bridge.py is running."
        }

        if entries.isEmpty { return "No SharedPreferences entries found." }

        var lines: [String] = ["SharedPreferences (\(entries.count) entries):"]
        for entry in entries.prefix(50) {
            let file = entry["prefsFile"] as? String ?? "?"
            let key = entry["key"] as? String ?? "?"
            let value = entry["value"] as? String ?? "?"
            let type = entry["type"] as? String ?? "?"
            lines.append("  [\(file)] \(key) = \(value) (\(type))")
        }
        if entries.count > 50 { lines.append("  ... and \(entries.count - 50) more") }
        return lines.joined(separator: "\n")
    }

    /// Write a SharedPreference value
    static func writePref(prefsName: String, key: String, value: String, valueType: String) -> String {
        sendCommand([
            "action": "write_pref",
            "prefsName": prefsName, "key": key,
            "value": value, "valueType": valueType
        ])
        return "Written: [\(prefsName)] \(key) = \(value) (\(valueType))"
    }

    /// Status check
    static func status() -> String {
        guard let capture = readCapture(),
              let connected = capture["connected"] as? Bool, connected else {
            return "Android bridge: NOT CONNECTED\nRun: python3 noober-bridge.py <package> --serial <serial>"
        }
        let pkg = capture["package"] as? String ?? "?"
        let requests = (capture["httpRequests"] as? [[String: Any]])?.count ?? 0
        let logs = (capture["logEntries"] as? [[String: Any]])?.count ?? 0
        return "Android bridge: CONNECTED\nPackage: \(pkg)\nNetwork requests: \(requests)\nLog entries: \(logs)"
    }

    // Cache uiautomator dump to avoid re-dumping for quick sequential calls
    private static var cachedScreenHTML: String?
    private static var cacheTimestamp: Date?
    private static let cacheTTL: TimeInterval = 3.0 // 3 seconds

    /// Screen HTML via uiautomator dump (converted to simplified format)
    static func screenHTML(serial: String?) -> String {
        // Return cache if fresh
        if let cached = cachedScreenHTML, let ts = cacheTimestamp,
           Date().timeIntervalSince(ts) < cacheTTL {
            return cached
        }

        let adbPath: String = {
            let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
            return "\(home)/Library/Android/sdk/platform-tools/adb"
        }()
        let serialArg = serial.map { "-s \($0)" } ?? ""

        // Dump UI hierarchy
        let _ = shell("'\(adbPath)' \(serialArg) shell uiautomator dump /sdcard/noober_ui.xml 2>&1")
        guard let xml = shell("'\(adbPath)' \(serialArg) shell cat /sdcard/noober_ui.xml 2>/dev/null") else {
            return "Failed to dump UI hierarchy"
        }

        let result = convertUIXMLToHTML(xml)
        cachedScreenHTML = result
        cacheTimestamp = Date()
        return result
    }

    /// Invalidate cache (call after tap/swipe that changes the screen)
    static func invalidateScreenCache() {
        cachedScreenHTML = nil
        cacheTimestamp = nil
    }

    /// Convert Android uiautomator XML to a simplified readable format with coordinates
    private static func convertUIXMLToHTML(_ xml: String) -> String {
        var result: [String] = ["<screen platform=\"android\">"]
        // Simple XML parsing — extract clickable/visible nodes with text or content-desc
        let nodes = xml.components(separatedBy: "<node ")
        for node in nodes.dropFirst() {
            let text = extractAttr(node, "text")
            let contentDesc = extractAttr(node, "content-desc")
            let bounds = extractAttr(node, "bounds")
            let clickable = extractAttr(node, "clickable") == "true"
            let className = extractAttr(node, "class")
            let selected = extractAttr(node, "selected") == "true"

            // Skip empty nodes
            guard !text.isEmpty || !contentDesc.isEmpty else { continue }

            let label = !text.isEmpty ? text : contentDesc
            let shortClass = className.components(separatedBy: ".").last ?? className

            // Parse bounds [left,top][right,bottom] → center coordinates
            var centerX = 0, centerY = 0
            if let leftBracket = bounds.range(of: "["),
               let midBracket = bounds.range(of: "]["),
               let rightBracket = bounds.range(of: "]", range: midBracket.upperBound..<bounds.endIndex) {
                let first = bounds[leftBracket.upperBound..<midBracket.lowerBound]
                let second = bounds[midBracket.upperBound..<rightBracket.lowerBound]
                let p1 = first.split(separator: ",").compactMap { Int($0) }
                let p2 = second.split(separator: ",").compactMap { Int($0) }
                if p1.count == 2 && p2.count == 2 {
                    centerX = (p1[0] + p2[0]) / 2
                    centerY = (p1[1] + p2[1]) / 2
                }
            }

            let clickAttr = clickable ? " clickable" : ""
            let selAttr = selected ? " selected" : ""
            result.append("  <\(shortClass)\(clickAttr)\(selAttr) center=\"\(centerX),\(centerY)\">\(label)</\(shortClass)>")
        }
        result.append("</screen>")
        return result.joined(separator: "\n")
    }

    private static func extractAttr(_ node: String, _ name: String) -> String {
        let pattern = "\(name)=\""
        guard let start = node.range(of: pattern) else { return "" }
        let rest = node[start.upperBound...]
        guard let end = rest.range(of: "\"") else { return "" }
        return String(rest[..<end.lowerBound])
    }

    private static func shell(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? ""
        env["PATH"] = "\(home)/Library/Android/sdk/platform-tools:\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        process.environment = env
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch { return nil }
    }
}
