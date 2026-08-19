import Foundation

/// Proxies XcodeBuildMCP as a child process — spawns it via npx,
/// communicates over MCP stdio protocol, and forwards tool calls.
final class XcodeBuildProxy {
    private var process: Process?
    private var stdin: Pipe?
    private var stdout: Pipe?
    private var pendingResponses: [Int: (String) -> Void] = [:]
    private var nextId = 1000
    private let lock = NSLock()
    private var buffer = Data()
    private(set) var isReady = false
    private(set) var tools: [[String: Any]] = []

    /// Discover npx path and spawn XcodeBuildMCP
    func start() {
        guard process == nil else { return }

        // Find npx — check common locations
        let npxPath = findExecutable("npx")
        guard let npx = npxPath else {
            log("[xcode-proxy] npx not found — XcodeBuildMCP proxy disabled")
            return
        }
        log("[xcode-proxy] Found npx at: \(npx)")

        let process = Process()
        self.process = process
        process.executableURL = URL(fileURLWithPath: npx)
        process.arguments = ["-y", "xcodebuildmcp@latest", "mcp"]

        // Inherit environment + add workflows
        var env = ProcessInfo.processInfo.environment
        env["XCODEBUILDMCP_ENABLED_WORKFLOWS"] = "simulator,ui-automation,device,macos,debugging,logging,simulator-management,swift-package,project-discovery,project-scaffolding,coverage,utilities,xcode-ide"
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        self.stdin = stdinPipe
        self.stdout = stdoutPipe

        // Read stdout asynchronously
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.handleStdoutData(data)
        }

        do {
            try process.run()
            log("[xcode-proxy] XcodeBuildMCP started (pid: \(process.processIdentifier))")

            // Initialize MCP handshake
            sendMCP(id: 1, method: "initialize", params: [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "NooberMCP-Proxy", "version": "1.0.0"]
            ])

            // Wait briefly for init response, then request tool list
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.sendMCP(id: 0, method: "notifications/initialized", params: [:])
                self?.sendMCP(id: 2, method: "tools/list", params: [:])
            }
        } catch {
            log("[xcode-proxy] Failed to start: \(error)")
        }
    }

    /// Stop the proxy
    func stop() {
        process?.terminate()
        process = nil
        stdin = nil
        stdout = nil
        isReady = false
        tools = []
    }

    /// Call a tool on XcodeBuildMCP and wait for result (blocking, with timeout)
    func callTool(name: String, args: [String: Any], timeout: TimeInterval = 30) -> String {
        guard isReady else { return "XcodeBuildMCP proxy not ready" }

        let semaphore = DispatchSemaphore(value: 0)
        var result = "XcodeBuildMCP call timed out"

        lock.lock()
        let id = nextId
        nextId += 1
        pendingResponses[id] = { response in
            result = response
            semaphore.signal()
        }
        lock.unlock()

        sendMCP(id: id, method: "tools/call", params: [
            "name": name,
            "arguments": args
        ])

        _ = semaphore.wait(timeout: .now() + timeout)

        lock.lock()
        pendingResponses.removeValue(forKey: id)
        lock.unlock()

        return result
    }

    // MARK: - Private

    private func sendMCP(id: Int, method: String, params: [String: Any]) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if method != "notifications/initialized" {
            msg["id"] = id
        } else {
            msg.removeValue(forKey: "id")
        }

        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        stdin?.fileHandleForWriting.write(Data(line.utf8))
    }

    private func handleStdoutData(_ data: Data) {
        buffer.append(data)

        // Process complete lines
        while let newlineRange = buffer.range(of: Data("\n".utf8)) {
            let lineData = buffer[buffer.startIndex..<newlineRange.lowerBound]
            buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

            guard let line = String(data: lineData, encoding: .utf8),
                  !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }

            handleMCPResponse(json)
        }
    }

    private func handleMCPResponse(_ json: [String: Any]) {
        let id = json["id"] as? Int

        // Handle initialize response
        if id == 1 {
            log("[xcode-proxy] Initialized")
            return
        }

        // Handle tools/list response
        if id == 2, let result = json["result"] as? [String: Any],
           let toolList = result["tools"] as? [[String: Any]] {
            self.tools = toolList
            self.isReady = true
            log("[xcode-proxy] Ready — \(toolList.count) tools available")
            return
        }

        // Handle tool call response
        if let id, let callback = (lock.withLock { pendingResponses[id] }) {
            if let result = json["result"] as? [String: Any],
               let content = result["content"] as? [[String: Any]] {
                // Extract text content
                let texts = content.compactMap { item -> String? in
                    if item["type"] as? String == "text" { return item["text"] as? String }
                    return nil
                }
                callback(texts.joined(separator: "\n"))
            } else if let error = json["error"] as? [String: Any] {
                callback("Error: \(error["message"] as? String ?? "unknown")")
            } else {
                callback("Unknown response")
            }
        }
    }

    private func findExecutable(_ name: String) -> String? {
        // Check common paths
        let paths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(ProcessInfo.processInfo.environment["HOME"] ?? "")/. local/bin/\(name)",
        ]

        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Try `which`
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [name]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let output, !output.isEmpty, FileManager.default.isExecutableFile(atPath: output) {
            return output
        }

        // Check fnm multishells (common with Node version managers)
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let fnmDir = "\(home)/.local/state/fnm_multishells"
        if let shells = try? FileManager.default.contentsOfDirectory(atPath: fnmDir) {
            for shell in shells.sorted().reversed() {
                let candidate = "\(fnmDir)/\(shell)/bin/\(name)"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        return nil
    }
}

private func log(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}
