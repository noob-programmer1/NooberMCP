import Foundation

/// Lightweight HTTP API server on localhost for non-MCP clients.
/// Any tool (Cursor, Codex, Python scripts, curl) can call these endpoints.
/// Runs alongside the MCP stdio server on port 8686 (configurable via NOOBER_PORT).
final class HTTPServer {
    private let mcpServer: MCPServer
    private var serverSocket: Int32 = -1
    private let port: UInt16
    private var running = false

    init(mcpServer: MCPServer, port: UInt16 = 8686) {
        self.mcpServer = mcpServer
        self.port = UInt16(ProcessInfo.processInfo.environment["NOOBER_PORT"].flatMap { Int($0) } ?? Int(port))
    }

    func start() {
        DispatchQueue.global(qos: .default).async { [self] in
            startListening()
        }
    }

    private func startListening() {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else { log("[http] Failed to create socket"); return }

        var yes: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult >= 0 else { log("[http] Failed to bind port \(port)"); return }

        listen(serverSocket, 10)
        running = true
        log("[http] Listening on http://localhost:\(port)")

        while running {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(serverSocket, sockPtr, &clientLen)
                }
            }
            guard clientSocket >= 0 else { continue }
            DispatchQueue.global().async { [self] in
                handleClient(clientSocket)
            }
        }
    }

    private func handleClient(_ socket: Int32) {
        defer { close(socket) }

        // Read HTTP request
        var buffer = [UInt8](repeating: 0, count: 65536)
        let bytesRead = recv(socket, &buffer, buffer.count, 0)
        guard bytesRead > 0 else { return }

        let requestData = Data(buffer[0..<bytesRead])
        guard let requestStr = String(data: requestData, encoding: .utf8) else { return }

        // Parse HTTP request line
        let lines = requestStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return }

        let method = String(parts[0])
        let path = String(parts[1])

        // Parse body (for POST)
        var body: [String: Any] = [:]
        if let bodyStart = requestStr.range(of: "\r\n\r\n") {
            let bodyStr = String(requestStr[bodyStart.upperBound...])
            if let data = bodyStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                body = json
            }
        }

        // CORS headers for browser access
        let corsHeaders = "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization\r\n"

        // Handle OPTIONS preflight
        if method == "OPTIONS" {
            let response = "HTTP/1.1 204 No Content\r\n\(corsHeaders)\r\n"
            sendHTTP(socket, response)
            return
        }

        // MCP-over-HTTP endpoint — speaks JSON-RPC like stdin MCP
        if path == "/mcp" && method == "POST" {
            let mcpResponse = mcpServer.handleHTTPMCP(body: body)
            let jsonData = (try? JSONSerialization.data(withJSONObject: mcpResponse, options: [])) ?? Data("{}".utf8)
            let jsonStr = String(data: jsonData, encoding: .utf8) ?? "{}"
            let httpResponse = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\(corsHeaders)Content-Length: \(jsonData.count)\r\n\r\n\(jsonStr)"
            sendHTTP(socket, httpResponse)
            return
        }

        // Route request (REST API)
        let result = routeRequest(method: method, path: path, body: body)
        let jsonData = (try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted)) ?? Data("{}".utf8)
        let jsonStr = String(data: jsonData, encoding: .utf8) ?? "{}"

        let httpResponse = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\(corsHeaders)Content-Length: \(jsonData.count)\r\n\r\n\(jsonStr)"
        sendHTTP(socket, httpResponse)
    }

    private func sendHTTP(_ socket: Int32, _ response: String) {
        let data = Array(response.utf8)
        _ = send(socket, data, data.count, 0)
    }

    // MARK: - Routing

    private func routeRequest(method: String, path: String, body: [String: Any]) -> [String: Any] {
        let cleanPath = path.split(separator: "?").first.map(String.init) ?? path

        switch (method, cleanPath) {
        // Status
        case ("GET", "/status"):
            return ["ok": true, "server": "NooberMCP", "port": port,
                    "android": mcpServer.sim.isAndroidMode,
                    "simulatorId": mcpServer.sim.simulatorId ?? "",
                    "bundleId": mcpServer.sim.bundleId ?? "",
                    "nooberConnected": mcpServer.client.isConnected]

        // Devices
        case ("GET", "/devices"):
            let simList = mcpServer.sim.listSimulators()
            return ["simulators": simList]

        case ("POST", "/devices/defaults"):
            let result = mcpServer.sim.setDefaults(args: body)
            return ["result": result]

        // Screenshot
        case ("GET", "/screenshot"):
            let result = mcpServer.sim.screenshot()
            var response: [String: Any] = ["text": result.text]
            if let base64 = result.base64 { response["image"] = base64 }
            return response

        // Input
        case ("POST", "/tap"):
            let result = callTool("tap", args: body)
            return ["result": result]

        case ("POST", "/swipe"):
            let result = callTool("swipe", args: body)
            return ["result": result]

        case ("POST", "/type"):
            let result = callTool("type_text", args: body)
            return ["result": result]

        case ("POST", "/button"):
            let result = callTool("button", args: body)
            return ["result": result]

        // Noober tools
        case ("GET", "/noober/status"):
            return ["result": callTool("noober_status", args: [:])]

        case ("GET", "/noober/network-logs"):
            let limit = (path.contains("limit=") ? Int(path.components(separatedBy: "limit=").last?.prefix(5) ?? "") : nil) ?? 20
            return ["result": callTool("noober_get_network_logs", args: ["limit": limit])]

        case ("GET", let p) where p.hasPrefix("/noober/request/"):
            let id = String(p.dropFirst("/noober/request/".count))
            return ["result": callTool("noober_get_request_detail", args: ["request_id": id])]

        case ("GET", "/noober/app-logs"):
            let limit = (path.contains("limit=") ? Int(path.components(separatedBy: "limit=").last?.prefix(5) ?? "") : nil) ?? 20
            return ["result": callTool("noober_get_app_logs", args: ["limit": limit])]

        case ("GET", "/noober/screen-html"):
            return ["result": callTool("noober_screen_html", args: [:])]

        case ("GET", "/noober/screen-text"):
            return ["result": callTool("noober_screen_text", args: [:])]

        case ("POST", "/noober/find-element"):
            return ["result": callTool("noober_find_element", args: body)]

        case ("POST", "/noober/assert-request"):
            return ["result": callTool("noober_assert_request", args: body)]

        case ("GET", "/noober/user-defaults"):
            return ["result": callTool("noober_get_user_defaults", args: [:])]

        case ("POST", "/noober/mock-rule"):
            return ["result": callTool("noober_add_mock_rule", args: body)]

        case ("DELETE", let p) where p.hasPrefix("/noober/mock-rule/"):
            let id = String(p.dropFirst("/noober/mock-rule/".count))
            return ["result": callTool("noober_remove_mock_rule", args: ["rule_id": id])]

        case ("GET", "/noober/rules"):
            return ["result": callTool("noober_get_rules", args: [:])]

        default:
            return ["error": "Not found", "path": cleanPath, "method": method,
                    "hint": "GET /status for server info, GET /screenshot for screen capture"]
        }
    }

    /// Call a tool through the same MCPServer dispatch (reuses all existing logic)
    private func callTool(_ name: String, args: [String: Any]) -> String {
        // For Android mode, use the Android path directly
        if mcpServer.sim.isAndroidMode {
            // Android: route through ToolHandler which checks AndroidCapture
            if name.hasPrefix("noober_") {
                return mcpServer.toolHandler.call(
                    tool: name, args: args,
                    client: mcpServer.client,
                    bundleId: mcpServer.sim.bundleId,
                    sim: mcpServer.sim
                )
            }
            // Input tools
            switch name {
            case "tap": return mcpServer.sim.tap(x: args["x"] as? Int, y: args["y"] as? Int, label: args["label"] as? String)
            case "swipe": return mcpServer.sim.swipe(startX: args["x1"] as? Int ?? 0, startY: args["y1"] as? Int ?? 0, endX: args["x2"] as? Int ?? 0, endY: args["y2"] as? Int ?? 0, duration: args["duration"] as? Double)
            case "type_text": return mcpServer.sim.typeText(args["text"] as? String ?? "")
            case "button": return mcpServer.sim.button(args["buttonType"] as? String ?? args["type"] as? String ?? "home")
            default: return "Unknown tool: \(name)"
            }
        }

        // iOS: route through ToolHandler
        return mcpServer.toolHandler.call(
            tool: name, args: args,
            client: mcpServer.client,
            bundleId: mcpServer.sim.bundleId,
            sim: mcpServer.sim
        )
    }

    func stop() {
        running = false
        if serverSocket >= 0 { close(serverSocket) }
    }
}

private func log(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}
