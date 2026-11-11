import Foundation
import CoreGraphics

/// MCP server over stdio (JSON-RPC 2.0, newline-delimited) and HTTP.
final class MCPServer {
    static let version = "2.0.0"
    static let supportedProtocols = ["2025-06-18", "2025-03-26", "2024-11-05"]

    let client = NooberClient()
    let toolHandler = ToolHandler()
    let sim = SimulatorBridge()

    func run() {
        client.start()
        // Warm the HID connection and the accessibility translator (~3s cold) off the request path.
        DispatchQueue.global(qos: .utility).async { [self] in
            guard CoreSim.firstBooted() != nil || sim.simulatorId != nil else { return }
            _ = try? sim.simInput().ensureTransport()
            _ = try? sim.uiTree()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            client.waitForConnection(timeout: 8)
        }
        DispatchQueue.global().async { [self] in
            while let line = readLine(strippingNewline: true) {
                guard !line.isEmpty, let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let response = dispatch(json) { sendResponse(response) }
            }
            exit(0) // stdin closed → client went away
        }
    }

    /// Handle a JSON-RPC MCP request from HTTP. Same logic as stdio.
    func handleHTTPMCP(body: [String: Any]) -> [String: Any] {
        dispatch(body) ?? jsonRPC(id: body["id"], result: [:])
    }

    private func dispatch(_ json: [String: Any]) -> [String: Any]? {
        let id = json["id"]
        let method = json["method"] as? String ?? ""
        let params = json["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize": return handleInitialize(id: id, params: params)
        case "tools/list": return jsonRPC(id: id, result: ["tools": allToolDefinitions()])
        case "tools/call": return handleToolCall(id: id, params: params)
        case "ping": return jsonRPC(id: id, result: [:])
        default:
            if method.hasPrefix("notifications/") || id == nil { return nil }
            return jsonRPCError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func handleInitialize(id: Any?, params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String ?? ""
        let version = Self.supportedProtocols.contains(requested) ? requested : Self.supportedProtocols[0]
        return jsonRPC(id: id, result: [
            "protocolVersion": version,
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": "NooberMCP", "version": Self.version],
            "instructions": Self.instructions,
        ])
    }

    static let instructions = """
    NooberMCP drives iOS simulators, physical iPhones and Android emulators, and sees inside the running app (network, logs, storage) when the Noober SDK or probe is present.
    Fast loop: snapshot_ui (refs + coordinates, no image) → tap(ref:"e4") → the tap result already reports what changed (screen, API calls, errors). Use screenshot only for visual checks. Use wait_for instead of sleeping.
    Coordinates are always iOS points (same space as snapshot_ui and screenshot).
    """

    func allToolDefinitions() -> [[String: Any]] {
        nooberToolDefinitions() + deviceToolDefinitions()
    }

    // MARK: - Tool calls

    private func handleToolCall(id: Any?, params: [String: Any]) -> [String: Any] {
        let toolName = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        let content = callTool(toolName, args: args)
        return jsonRPC(id: id, result: ["content": content])
    }

    /// Returns MCP content items.
    func callTool(_ toolName: String, args: [String: Any]) -> [[String: Any]] {
        if toolName.hasPrefix("noober_") {
            // Android: noober_* go through the Frida bridge, no companion socket.
            if sim.isAndroidMode {
                return text(toolHandler.call(tool: toolName, args: args, client: client, bundleId: sim.bundleId, sim: sim))
            }
            let offlineTools: Set<String> = ["noober_get_crash_log", "noober_rebuild_app"]
            if !offlineTools.contains(toolName) { client.waitForConnection(timeout: 8) }
            if toolName == "noober_screenshot" {
                let r = client.requestScreenshot()
                var c = text(r.text)
                if let b = r.imageBase64 { c.append(["type": "image", "data": b, "mimeType": "image/png"]) }
                return c
            }
            return text(toolHandler.call(tool: toolName, args: args, client: client, bundleId: sim.bundleId, sim: sim))
        }
        return handleDeviceTool(toolName, args: args)
    }

    private func text(_ s: String) -> [[String: Any]] { [["type": "text", "text": s]] }

    // MARK: - Device tools

    private func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private func bool(_ v: Any?, default d: Bool) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return ["true", "1", "yes"].contains(s.lowercased()) }
        return d
    }

    private func handleDeviceTool(_ name: String, args: [String: Any]) -> [[String: Any]] {
        switch name {
        case "session_set_defaults":
            if args["simulatorId"] != nil || args["androidSerial"] != nil {
                client.directHost = nil   // leaving physical-device mode
                sim.clearPhysical()
            }
            var out = sim.setDefaults(args: args)
            if let mode = args["connectMode"] as? String, mode == "usb" {
                client.connectDirectTCP()
                out += client.isConnected ? "\nConnected via USB tunnel (127.0.0.1:54321)" : "\nUSB connect failed — is iproxy running?"
            }
            if let dev = args["deviceId"] as? String, !dev.isEmpty {
                out += "\n" + connectPhysical(dev)
            }
            return text(out)

        case "session_show_defaults":
            return text(sim.showDefaults() + "\n  Noober in-app: \(client.isConnected ? "connected" : "not connected")")

        case "list_devices", "list_sims":
            return text(sim.listDevices(includeShutdown: bool(args["all"], default: name == "list_sims")))

        case "boot_sim":
            return text(sim.bootSimulator(udid: args["simulatorId"] as? String))

        case "open_sim":
            return text(sim.openSimulator())

        case "launch_app_sim", "launch_app":
            client.forceDisconnect()
            var env: [String: String] = [:]
            (args["env"] as? [String: Any])?.forEach { env[$0.key] = "\($0.value)" }
            let launchArgs = (args["args"] as? [Any])?.map { "\($0)" } ?? []
            let inject = bool(args["inject_probe"], default: true) && !sim.isPhysicalMode
            if let s = args["simulatorId"] as? String { _ = sim.setDefaults(args: ["simulatorId": s]) }
            let result = sim.launchApp(bundleId: args["bundleId"] as? String, injectProbe: inject, env: env, args: launchArgs)
            if sim.isPhysicalMode, let dev = sim.deviceId {
                return text(result + "\n" + connectPhysical(dev, quiet: true))
            }
            // Probe: wait for its ready file then Bonjour. No probe: only an SDK can answer — short browse.
            client.waitForConnection(timeout: inject ? 6 : 3, waitForProbeReadyFile: inject)
            return text(result + (client.isConnected ? "\nNoober attached — network, logs and in-app tools are live." : "\nApp launched (Noober not attached — device tools still work)."))

        case "stop_app_sim", "stop_app":
            client.forceDisconnect()
            return text(sim.stopApp(bundleId: args["bundleId"] as? String))

        case "install_app":
            guard let path = args["path"] as? String else { return text("Error: path is required") }
            return text(sim.installApp(path: path))

        case "open_url":
            guard let url = args["url"] as? String else { return text("Error: url is required") }
            return observed(args) { sim.openURL(url) }

        case "set_appearance":
            return text(sim.setAppearance(args["style"] as? String ?? "dark"))

        case "set_location":
            guard let lat = num(args["latitude"]), let lon = num(args["longitude"]) else { return text("Error: latitude and longitude required") }
            return text(sim.setLocation(lat: lat, lon: lon))

        case "tap":
            return observed(args) { performTap(args) }

        case "swipe":
            return observed(args) {
                if let dir = args["direction"] as? String {
                    if sim.isPhysicalMode { return physicalOnly("swipe(direction)") }
                    return sim.swipe(direction: dir, distance: num(args["distance"]) ?? 0.5)
                }
                let x1 = Int(num(args["x1"]) ?? 0), y1 = Int(num(args["y1"]) ?? 0)
                let x2 = Int(num(args["x2"]) ?? 0), y2 = Int(num(args["y2"]) ?? 0)
                if sim.isPhysicalMode {
                    guard client.isConnected else { return physicalOnly("swipe") }
                    return client.requestSwipe(x1: x1, y1: y1, x2: x2, y2: y2, duration: num(args["duration"]))
                }
                return sim.swipe(startX: x1, startY: y1, endX: x2, endY: y2, duration: num(args["duration"]))
            }

        case "type_text":
            let textValue = args["text"] as? String ?? ""
            let submit = bool(args["submit"], default: false)
            return observed(args) {
                var out: String
                // In-process insertion handles any Unicode and needs no keyboard focus quirks.
                if client.isConnected, !sim.isAndroidMode {
                    out = client.requestTypeText(textValue)
                } else if sim.isPhysicalMode {
                    return physicalOnly("type_text")
                } else {
                    out = sim.typeText(textValue)
                }
                if submit, !sim.isPhysicalMode { out += "; " + sim.pressKey("return") }
                return out
            }

        case "press_key":
            return observed(args) {
                sim.pressKey(args["key"] as? String ?? "return", modifiers: (args["modifiers"] as? [String]) ?? [])
            }

        case "touch":
            return text(sim.touch(x: Int(num(args["x"]) ?? 0), y: Int(num(args["y"]) ?? 0),
                                  down: bool(args["down"], default: true), up: bool(args["up"], default: true),
                                  delay: num(args["delay"])))

        case "button":
            return observed(args) { sim.button(args["buttonType"] as? String ?? "home", duration: num(args["duration"])) }

        case "screenshot":
            let q: Screenshot.Quality = (args["quality"] as? String) == "full" ? .full : .fast
            let r = sim.screenshot(quality: q)
            var c = text(r.text)
            if let b = r.base64 { c.append(["type": "image", "data": b, "mimeType": r.mime]) }
            return c

        case "snapshot_ui":
            if sim.isPhysicalMode {
                return text(client.isConnected ? client.requestScreenHTML()
                            : "On physical devices the UI tree comes from the Noober SDK (not connected) or Xcode's DeviceInteraction tools — see xcode_tools.")
            }
            return text(sim.snapshotUI())

        case "wait_for":
            return text(waitFor(args))

        case "doctor":
            return text(doctor())

        case "xcode_tools":
            do {
                let tools = try XcodeMCPBridge.shared.ensureStarted()
                let lines = tools.map { t -> String in
                    let n = t["name"] as? String ?? "?"
                    let d = (t["description"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
                    let props = ((t["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?.keys.sorted().joined(separator: ", ") ?? ""
                    return "• \(n)(\(props)) — \(d.prefix(140))"
                }
                return text("Xcode MCP tools (call with xcode_call):\n" + lines.joined(separator: "\n"))
            } catch { return text("Xcode MCP unavailable: \(error)") }

        case "xcode_call":
            guard let tool = args["tool"] as? String else { return text("Error: tool is required (see xcode_tools)") }
            var toolArgs = args["arguments"] as? [String: Any] ?? [:]
            if toolArgs.isEmpty, let s = args["arguments"] as? String, let d = s.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { toolArgs = parsed }
            do { return try XcodeMCPBridge.shared.call(tool, arguments: toolArgs, timeout: num(args["timeout"]) ?? 600) }
            catch { return text("Xcode MCP call failed: \(error)") }

        default:
            return text("Unknown tool: \(name)")
        }
    }

    private func physicalOnly(_ what: String) -> String {
        "\(what) on a physical device needs the Noober SDK in the app (connected over the CoreDevice tunnel automatically), or Xcode 27's DeviceInteraction tools via xcode_call."
    }

    /// Connect to the Noober SDK on a physical device over its CoreDevice tunnel — no iproxy.
    private func connectPhysical(_ idOrName: String, quiet: Bool = false) -> String {
        guard let dev = DeviceBridge.find(idOrName) else {
            return "Device \(idOrName) not found among paired devices (see list_devices)."
        }
        _ = sim.setDefaults(args: ["deviceId": dev.identifier])
        guard let ip = dev.tunnelIP, dev.tunnelState == "connected" else {
            return "\(dev.name): CoreDevice tunnel is \(dev.tunnelState ?? "down") — unlock the phone / reconnect the cable. devicectl tools (screenshot, launch) will retry."
        }
        client.directHost = ip
        client.connectDirectTCP(host: ip, port: 54321, timeout: quiet ? 6 : 4)
        if client.isConnected { return "\(dev.name): Noober SDK connected over CoreDevice tunnel [\(ip)]:54321." }
        return "\(dev.name): selected (screenshot/launch/terminate via devicectl). Noober SDK not reachable at [\(ip)]:54321 — launch a DEBUG build that calls Noober.shared.start() for taps, network and logs."
    }

    private func performTap(_ args: [String: Any]) -> String {
        let hold = num(args["hold"]) ?? 0.05
        let double = bool(args["double"], default: false)
        if sim.isPhysicalMode {
            guard client.isConnected else { return physicalOnly("tap") }
            if let x = num(args["x"]), let y = num(args["y"]) { return client.requestTap(x: Int(x), y: Int(y)) }
            if let label = args["label"] as? String { return tapViaNoober(label) }
            return "Error: provide x+y or label"
        }
        if let x = num(args["x"]), let y = num(args["y"]) {
            if sim.isAndroidMode { return sim.tap(x: Int(x), y: Int(y)) }
            return sim.tapPoint(CGPoint(x: x, y: y), hold: hold, double: double)
        }
        guard let q = (args["ref"] as? String) ?? (args["label"] as? String) ?? (args["id"] as? String) else {
            return "Error: provide x+y, ref (from snapshot_ui) or label"
        }
        switch sim.locate(q) {
        case .success(let el):
            let r = sim.tapPoint(el.center, hold: hold, double: double)
            return r.hasPrefix("Error") ? r : r + " — \(el.role) \"\(el.label ?? el.identifier ?? q)\""
        case .failure(let e):
            // Fall back to the in-app finder when the AX tree can't see it (e.g. custom-drawn views).
            if client.isConnected, args["ref"] == nil { return tapViaNoober(q) }
            return "Error: \(e)"
        }
    }

    private func tapViaNoober(_ label: String) -> String {
        let find = client.requestFindElement(text: label, exact: false)
        guard let r = find.range(of: "center=("), let close = find[r.upperBound...].range(of: ")") else {
            return "Element not found: \(label)"
        }
        let parts = find[r.upperBound..<close.lowerBound].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return "Element not found: \(label)" }
        if sim.isPhysicalMode { return client.requestTap(x: parts[0], y: parts[1]) }
        return sim.tapPoint(CGPoint(x: parts[0], y: parts[1]))
    }

    // MARK: - Act → observe

    private struct Before {
        let at: Date
        let requestIds: Set<UUID>
        let logIds: Set<UUID>
        let screen: String
        let texts: [String]?
    }

    /// Runs an action, waits for the UI and network to settle, then reports what changed —
    /// so the agent needs no follow-up screenshot/snapshot round trip for the common case.
    private func observed(_ args: [String: Any], _ action: () -> String) -> [[String: Any]] {
        let observe = bool(args["observe"], default: true)
        guard observe else { return text(action()) }
        let connected = client.isConnected
        let useAX = !connected && !sim.isPhysicalMode && !sim.isAndroidMode
        let before = Before(at: Date(),
                            requestIds: connected ? Set(client.httpRequests.map(\.id)) : [],
                            logIds: connected ? Set(client.logEntries.map(\.id)) : [],
                            screen: client.currentScreen,
                            texts: useAX ? sim.visibleTexts() : nil)
        let result = action()
        if result.hasPrefix("Error") { return text(result) }
        let summary = settleAndDiff(before, connected: connected, useAX: useAX, maxWait: num(args["settle"]) ?? 3)
        return text(summary.isEmpty ? result : result + "\n" + summary)
    }

    private func settleAndDiff(_ before: Before, connected: Bool, useAX: Bool, maxWait: Double) -> String {
        let deadline = Date().addingTimeInterval(max(0.3, maxWait))
        Thread.sleep(forTimeInterval: 0.35)
        if connected {
            // Settle = no new requests/logs for 400ms (network calls kicked off by the tap land in this window).
            var lastSignature = "", quietSince = Date()
            while Date() < deadline {
                // Screen-name events trail the transition, so they count as activity too.
                let signature = "\(client.httpRequests.count)|\(client.logEntries.count)|\(client.currentScreen)"
                if signature != lastSignature { lastSignature = signature; quietSince = Date() }
                if Date().timeIntervalSince(quietSince) >= 0.4 { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        var lines: [String] = []
        if connected {
            if client.currentScreen != before.screen { lines.append("screen: \(before.screen) → \(client.currentScreen)") }
            let newReqs = client.httpRequests.filter { !before.requestIds.contains($0.id) }
            for r in newReqs.prefix(8) {
                let status = r.statusCode.map(String.init) ?? (r.errorDescription.map { "ERR \($0.prefix(60))" } ?? "…")
                lines.append("api: \(r.method) \(r.path) → \(status) (\(Int(r.duration * 1000))ms)\(r.isMocked ? " [mocked]" : "")")
            }
            if newReqs.count > 8 { lines.append("api: +\(newReqs.count - 8) more (noober_get_network_logs)") }
            let newLogs = client.logEntries.filter { !before.logIds.contains($0.id) }
            for l in newLogs where l.level == "ERROR" || l.level == "WARN" {
                lines.append("log \(l.level.lowercased()): \(l.message.prefix(140))")
            }
        } else if useAX, let old = before.texts {
            Thread.sleep(forTimeInterval: 0.25)
            if let now = sim.visibleTexts() {
                let oldSet = Set(old), newSet = Set(now)
                let added = now.filter { !oldSet.contains($0) }.uniqued().prefix(12)
                let removed = old.filter { !newSet.contains($0) }.uniqued().prefix(8)
                if added.isEmpty && removed.isEmpty { lines.append("ui: no visible change") }
                if !added.isEmpty { lines.append("ui+: " + added.map { "\"\($0.prefix(50))\"" }.joined(separator: ", ")) }
                if !removed.isEmpty { lines.append("ui-: " + removed.map { "\"\($0.prefix(50))\"" }.joined(separator: ", ")) }
            }
        }
        return lines.isEmpty ? "" : "Observed:\n  " + lines.joined(separator: "\n  ")
    }

    // MARK: - wait_for

    private func waitFor(_ args: [String: Any]) -> String {
        let timeout = num(args["timeout"]) ?? 10
        let deadline = Date().addingTimeInterval(timeout)
        let started = Date()
        let textQ = args["text"] as? String
        let gone = bool(args["gone"], default: false)
        let request = args["request"] as? String
        let screen = args["screen"] as? String
        guard textQ != nil || request != nil || screen != nil else { return "Error: pass text, request (URL substring) or screen" }
        let baseline = Set(client.httpRequests.map(\.id))
        while Date() < deadline {
            if let request {
                if let r = client.httpRequests.first(where: { !baseline.contains($0.id) && $0.url.contains(request) }) {
                    return "PASS after \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(r.method) \(r.path) → \(r.statusCode.map(String.init) ?? "error")"
                }
            } else if let screen {
                if client.currentScreen.localizedCaseInsensitiveContains(screen) {
                    return "PASS after \(String(format: "%.1f", Date().timeIntervalSince(started)))s: screen is \(client.currentScreen)"
                }
            } else if let textQ {
                let texts: [String]
                if sim.isPhysicalMode || sim.isAndroidMode {
                    texts = [client.requestScreenText(timeout: 2)]
                } else {
                    texts = sim.visibleTexts() ?? []
                }
                let present = texts.contains { $0.localizedCaseInsensitiveContains(textQ) }
                if present != gone {
                    return "PASS after \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \"\(textQ)\" \(gone ? "gone" : "visible")"
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return "FAIL: timed out after \(Int(timeout))s waiting for \(request.map { "request \($0)" } ?? screen.map { "screen \($0)" } ?? "\"\(textQ!)\" to \(gone ? "disappear" : "appear")")"
    }

    // MARK: - doctor

    private func doctor() -> String {
        var l: [String] = ["NooberMCP \(Self.version)"]
        let xv = Exec.run("/usr/bin/xcodebuild", ["-version"], timeout: 15)?.stdoutString.replacingOccurrences(of: "\n", with: " ") ?? "?"
        l.append("Xcode: \(xv.trimmingCharacters(in: .whitespaces)) at \(CoreSim.developerDir)")
        l.append("CoreSimulator loaded: \(CoreSim.loaded ? "yes" : "NO")")
        l.append("SimulatorKit Indigo symbols: \(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IndigoHIDMessageForMouseNSEvent") != nil ? "yes" : "no")")
        l.append("AXPTranslator: \(NSClassFromString("AXPTranslator") != nil ? "yes" : "no")")
        if let udid = sim.resolveUDID(), let dev = CoreSim.device(udid: udid) {
            l.append("Simulator: \(dev.name) (\(dev.runtimeName)) \(dev.stateString), \(Int(dev.screenPoints.width))x\(Int(dev.screenPoints.height))pt")
            if dev.isBooted {
                do {
                    let t0 = Date()
                    let input = try sim.simInput()
                    _ = try input.ensureTransport()
                    l.append("HID transport: \(input.transportName) (\(Int(Date().timeIntervalSince(t0) * 1000))ms)")
                } catch { l.append("HID transport: FAILED — \(error)") }
                let t1 = Date()
                if let tree = try? sim.uiTree() {
                    l.append("Accessibility: ok, \(UIOutline.texts(tree).count) strings (\(Int(Date().timeIntervalSince(t1) * 1000))ms)")
                } else { l.append("Accessibility: FAILED") }
            }
        } else { l.append("Simulator: none booted") }
        l.append("Probe dylib: \(SimulatorBridge.resolveProbePath() ?? "not found")")
        let phys = DeviceBridge.physical()
        l.append("Physical devices: \(phys.isEmpty ? "none" : phys.map(\.oneLine).joined(separator: "; "))")
        l.append("Noober in-app: \(client.isConnected ? "connected (screen: \(client.currentScreen))" : "not connected")")
        l.append("Xcode MCP (mcpbridge): \(XcodeMCPBridge.xcodeIsRunning ? "Xcode running — use xcode_tools" : "Xcode not running")")
        return l.joined(separator: "\n")
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

    private let outLock = NSLock()
    private func sendResponse(_ response: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
        outLock.withLock {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
    }
}

extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
