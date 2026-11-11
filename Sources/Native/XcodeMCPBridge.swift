import Foundation

/// MCP client for Xcode's own MCP server (`xcrun mcpbridge`, Xcode 26.3+).
///
/// Gives the agent Xcode's native tools — BuildProject, GetBuildLog, RunSomeTests,
/// RenderPreview, DocumentationSearch, XcodeListNavigatorIssues and, on Xcode 27, the
/// DeviceInteraction* tools (XCTest-backed taps + UI hierarchy on simulators **and physical
/// devices**). Started lazily on first use; needs Xcode running with
/// Settings › Intelligence › "Allow external agents to use Xcode tools" enabled.
final class XcodeMCPBridge {
    static let shared = XcodeMCPBridge()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private let lock = NSLock()
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var nextId = 1
    private(set) var tools: [[String: Any]] = []
    private let ioQueue = DispatchQueue(label: "noober.xcode-mcp")

    var isRunning: Bool { lock.withLock { process?.isRunning ?? false } }

    struct BridgeError: Error, CustomStringConvertible { let description: String }

    static var xcodeIsRunning: Bool {
        !(Exec.run("/usr/bin/pgrep", ["-x", "Xcode"], timeout: 5)?.stdoutString.isEmpty ?? true)
    }

    /// Starts mcpbridge (if needed) and returns its tool list.
    func ensureStarted(timeout: TimeInterval = 20) throws -> [[String: Any]] {
        if isRunning, !tools.isEmpty { return tools }
        guard Self.xcodeIsRunning else {
            throw BridgeError(description: "Xcode is not running. Open your project in Xcode 26.3+ and enable Settings › Intelligence › \"Allow external agents to use Xcode tools\".")
        }
        stop()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["mcpbridge"]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            self?.ioQueue.async { self?.consume(d) }
        }
        p.terminationHandler = { [weak self] _ in self?.failAll("mcpbridge exited") }
        try p.run()
        lock.withLock { process = p; stdinHandle = inPipe.fileHandleForWriting }

        _ = try request("initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "NooberMCP", "version": MCPServer.version],
        ], timeout: timeout)
        notify("notifications/initialized")
        let list = try request("tools/list", [:], timeout: timeout)
        tools = list["tools"] as? [[String: Any]] ?? []
        nlog("[xcode-mcp] connected — \(tools.count) Xcode tools")
        return tools
    }

    func stop() {
        lock.withLock {
            process?.terminate()
            process = nil
            stdinHandle = nil
        }
        tools = []
    }

    func toolNames() -> [String] { tools.compactMap { $0["name"] as? String } }

    /// Finds a tool by exact name, else by case-insensitive suffix/contains (names vary by Xcode build).
    func resolve(_ name: String) -> String? {
        let names = toolNames()
        if names.contains(name) { return name }
        let l = name.lowercased()
        return names.first { $0.lowercased() == l } ?? names.first { $0.lowercased().contains(l) }
    }

    /// Calls a tool and returns MCP `content` items (text + images) untouched.
    func call(_ name: String, arguments: [String: Any], timeout: TimeInterval = 300) throws -> [[String: Any]] {
        _ = try ensureStarted()
        guard let resolved = resolve(name) else {
            throw BridgeError(description: "Xcode has no tool named \(name). Available: \(toolNames().joined(separator: ", "))")
        }
        let result = try request("tools/call", ["name": resolved, "arguments": arguments], timeout: timeout)
        var content = result["content"] as? [[String: Any]] ?? []
        if let structured = result["structuredContent"], content.isEmpty,
           let d = try? JSONSerialization.data(withJSONObject: structured, options: [.prettyPrinted]) {
            content = [["type": "text", "text": String(decoding: d, as: UTF8.self)]]
        }
        if (result["isError"] as? Bool) == true {
            content.insert(["type": "text", "text": "Xcode reported an error for \(resolved):"], at: 0)
        }
        return content
    }

    // MARK: JSON-RPC plumbing

    private func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        let sem = DispatchSemaphore(value: 0)
        var outcome: Result<[String: Any], Error> = .failure(BridgeError(description: "\(method) timed out after \(Int(timeout))s"))
        let id: Int = lock.withLock {
            let i = nextId; nextId += 1
            pending[i] = { r in outcome = r; sem.signal() }
            return i
        }
        try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            _ = lock.withLock { pending.removeValue(forKey: id) }
        }
        return try outcome.get()
    }

    private func notify(_ method: String) {
        try? write(["jsonrpc": "2.0", "method": method])
    }

    private func write(_ obj: [String: Any]) throws {
        guard let h = lock.withLock({ stdinHandle }) else { throw BridgeError(description: "mcpbridge not running") }
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(0x0A)
        try h.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = (json["id"] as? Int) ?? (json["id"] as? NSNumber)?.intValue,
                  let cb = lock.withLock({ pending.removeValue(forKey: id) }) else { continue }
            if let err = json["error"] as? [String: Any] {
                cb(.failure(BridgeError(description: err["message"] as? String ?? "Xcode MCP error")))
            } else {
                cb(.success(json["result"] as? [String: Any] ?? [:]))
            }
        }
    }

    private func failAll(_ why: String) {
        let cbs = lock.withLock { () -> [(Result<[String: Any], Error>) -> Void] in
            let c = Array(pending.values); pending.removeAll(); process = nil; stdinHandle = nil; return c
        }
        cbs.forEach { $0(.failure(BridgeError(description: why))) }
    }
}
