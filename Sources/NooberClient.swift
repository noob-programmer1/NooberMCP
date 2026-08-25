import Foundation
import Network
import NooberShared

/// Connects to Noober's Companion Protocol on the iOS Simulator via Bonjour.
/// Uses CompanionConnection from NooberShared for proper framing.
final class NooberClient: @unchecked Sendable {
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "noober-mcp-client")
    private var connectedSemaphore = DispatchSemaphore(value: 0)

    // Cached state
    private(set) var isConnected = false
    private(set) var httpRequests: [TransferableNetworkRequest] = []
    private(set) var wsConnections: [TransferableWSConnection] = []
    private(set) var logEntries: [TransferableLogEntry] = []
    private(set) var environments: [TransferableEnvironment] = []
    private(set) var activeEnvironmentId: UUID?
    private(set) var rewriteRules: [TransferableRewriteRule] = []
    private(set) var mockRules: [TransferableMockRule] = []
    private(set) var interceptRules: [TransferableInterceptRule] = []
    private(set) var qaResults: [TransferableQAResult] = []
    private(set) var userDefaultsEntries: [TransferableUserDefaultsEntry] = []
    private(set) var keychainEntries: [TransferableKeychainEntry] = []
    private(set) var buildNumber: String = ""
    private(set) var lastSnapshot: String?
    private(set) var currentScreen: String = "Unknown"
    private(set) var lastScreenshot: String?
    private(set) var lastFindResult: String?
    private(set) var lastScreenText: String?
    private(set) var lastScreenHTML: String?
    private(set) var lastStorageWrite: String?
    private(set) var lastCookies: String?
    private(set) var lastPerfSnapshot: String?
    private(set) var lastAccessibilityAudit: String?
    private let snapshotSemaphore = DispatchSemaphore(value: 0)
    private let screenshotSemaphore = DispatchSemaphore(value: 0)
    private let findSemaphore = DispatchSemaphore(value: 0)
    private let findLock = NSLock()
    private let screenTextSemaphore = DispatchSemaphore(value: 0)
    private let screenTextLock = NSLock()
    private let screenHTMLSemaphore = DispatchSemaphore(value: 0)
    private let screenHTMLLock = NSLock()
    private let perfSnapshotSemaphore = DispatchSemaphore(value: 0)
    private let accessibilityAuditSemaphore = DispatchSemaphore(value: 0)
    private(set) var lastWebViewConsole: String?
    private let webViewConsoleSemaphore = DispatchSemaphore(value: 0)
    private(set) var lastInputResult: String?
    private let inputSemaphore = DispatchSemaphore(value: 0)
    private(set) var recordedFlows: [RecordedFlowData] = []

    /// Local type for recorded flows from Noober
    struct RecordedFlowData: Decodable {
        let id: UUID
        let name: String
        let description: String?
        let recordedAt: Date
        let steps: [FlowStepData]

        struct FlowStepData: Decodable {
            let action: String
            let screen: String
            let label: String?
            let text: String?
            let startCoordinates: Coords?
            let endCoordinates: Coords?
            let extra: [String: String]?

            struct Coords: Decodable {
                let x: Double
                let y: Double
            }
        }
    }

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // Noober uses secondsSince1970 for dates in transferable models
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    private var hasSynced = false

    /// Wait for Noober to connect + receive initial sync.
    /// If connection was lost, triggers reconnection and waits again.
    func waitForConnection(timeout: TimeInterval = 5) {
        // Quick check — already connected and healthy
        if hasSynced && isConnected {
            // Verify connection is still alive by checking if the TCP connection is ready
            if connection?.state == .ready { return }
            // Connection died silently — force reconnect
            log("[noober] Connection state: \(String(describing: connection?.state)) — forcing reconnect")
            forceDisconnect()
        }

        // Wait for probe ready file (probe writes /tmp/noobprobe_ready when Bonjour starts)
        let readyPath = "/tmp/noobprobe_ready"
        let deadline = Date().addingTimeInterval(min(timeout, 5))
        while !FileManager.default.fileExists(atPath: readyPath) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }

        // Always re-browse (previous browse result may point to dead process)
        log("[noober] Browsing for Noober...")
        hasSynced = false
        connectedSemaphore = DispatchSemaphore(value: 0)  // reset semaphore
        startBrowsing()

        log("[noober] Waiting for sync (up to \(Int(timeout))s)...")
        _ = connectedSemaphore.wait(timeout: .now() + timeout)
        log("[noober] Wait complete — synced: \(hasSynced), connected: \(isConnected)")
    }

    /// Connect directly to a TCP endpoint (e.g. localhost via USB tunnel).
    /// Bypasses Bonjour discovery entirely.
    func connectDirectTCP(host: String = "127.0.0.1", port: UInt16 = 54321, timeout: TimeInterval = 8) {
        forceDisconnect()
        log("[noober] Direct TCP connect to \(host):\(port)...")
        hasSynced = false
        connectedSemaphore = DispatchSemaphore(value: 0)

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        connectTo(endpoint)

        log("[noober] Waiting for direct TCP sync (up to \(Int(timeout))s)...")
        _ = connectedSemaphore.wait(timeout: .now() + timeout)
        log("[noober] Direct TCP — synced: \(hasSynced), connected: \(isConnected)")
    }

    /// Force disconnect — call before reconnecting to a new app instance
    func forceDisconnect() {
        connection?.cancel()
        connection = nil
        browser?.cancel()
        browser = nil
        isConnected = false
        hasSynced = false
        // Remove stale ready file
        try? FileManager.default.removeItem(atPath: "/tmp/noobprobe_ready")
    }

    // MARK: - Discovery

    func start() {
        startBrowsing()
    }

    private func startBrowsing() {
        // Cancel any existing browser
        browser?.cancel()
        browser = nil

        let browser = NWBrowser(for: .bonjour(type: CompanionConnection.bonjourType, domain: nil), using: .init())
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, let result = results.first else { return }
            self.browser?.cancel()
            self.browser = nil
            self.connectTo(result.endpoint)
        }

        browser.stateUpdateHandler = { state in
            if case .failed(let err) = state { log("[noober] Browse failed: \(err)") }
        }

        browser.start(queue: queue)
        log("[noober] Searching for Noober...")
    }

    /// Reconnect after connection loss — tear down old connection and re-browse.
    private func reconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
        startBrowsing()
    }

    // MARK: - Connection (raw TCP — we parse length-prefix manually)

    private func connectTo(_ endpoint: NWEndpoint) {
        // Cancel any previous connection
        connection?.cancel()

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                log("[noober] Connected!")
                self?.isConnected = true
                self?.receiveLoop()
            case .failed(let err):
                log("[noober] Connection failed: \(err)")
                self?.isConnected = false
            case .cancelled:
                break
            default: break
            }
        }

        conn.start(queue: queue)
    }

    // MARK: - Receive (manual length-prefixed framing over raw TCP)

    private func receiveLoop() {
        readNextFrame()
    }

    private func readNextFrame() {
        guard let connection else { return }

        // Read 4-byte length header
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                log("[noober] Header error: \(error)")
                self.isConnected = false
                return
            }
            if isComplete {
                log("[noober] Connection closed")
                self.isConnected = false
                return
            }

            guard let data, data.count >= 4 else {
                self.readNextFrame()
                return
            }

            let length = Int(data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            if length <= 0 || length > 50_000_000 {
                log("[noober] Bad length: \(length), skipping")
                self.readNextFrame()
                return
            }

            // Read message body
            self.readBody(length: length)
        }
    }

    private func readBody(length: Int) {
        guard let connection else { return }

        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { log("[noober] Body error: \(error)"); return }

            if let data {
                do {
                    let message = try self.decoder.decode(CompanionMessage.self, from: data)
                    self.handleMessage(message)
                } catch {
                    // Unknown message type — extract raw type and base64 payload
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let rawType = json["type"] as? String,
                       let payloadBase64 = json["payload"] as? String,
                       let payloadData = Data(base64Encoded: payloadBase64) {
                        self.handleUnknownMessage(rawType: rawType, payload: payloadData)
                    } else {
                        log("[noober] Decode error (\(data.count) bytes): \(error)")
                    }
                }
            }

            if !isComplete {
                self.readNextFrame()
            }
        }
    }

    private func handleMessage(_ message: CompanionMessage) {
        log("[noober] Received: \(message.type)")

        switch message.type {
        case .syncFull:
            handleFullSync(message.payload)

        case .eventHttpRequest:
            if let r = try? decoder.decode(TransferableNetworkRequest.self, from: message.payload) {
                httpRequests.append(r)
                if httpRequests.count > 500 { httpRequests.removeFirst() }
            }

        case .eventLog:
            if let e = try? decoder.decode(TransferableLogEntry.self, from: message.payload) {
                logEntries.append(e)
                if logEntries.count > 500 { logEntries.removeFirst() }
            }

        case .eventWsConnection:
            if let c = try? decoder.decode(TransferableWSConnection.self, from: message.payload) {
                if let i = wsConnections.firstIndex(where: { $0.id == c.id }) {
                    wsConnections[i] = c
                } else {
                    wsConnections.append(c)
                }
            }

        case .eventEnvironmentChanged:
            // Noober sends a nested state object
            if let state = try? decoder.decode(EnvironmentStatePayload.self, from: message.payload) {
                environments = state.environments
                activeEnvironmentId = state.activeEnvironmentId
            }

        case .eventQAStatusChanged:
            if let results = try? decoder.decode([TransferableQAResult].self, from: message.payload) {
                qaResults = results
            }

        case .heartbeat:
            break

        // Responses to commands (screen HTML, snapshot, screenshot, find, screen text)
        case .responseScreenHTML:
            lastScreenHTML = formatScreenHTMLResponse(message.payload)
            screenHTMLSemaphore.signal()
        case .responseStorageWrite:
            lastStorageWrite = formatStorageWriteResponse(message.payload)
            storageSemaphore.signal()
        case .responseCookies:
            lastCookies = formatCookiesResponse(message.payload)
            cookiesSemaphore.signal()
        case .responseSnapshot:
            lastSnapshot = formatSnapshotResponse(message.payload)
            snapshotSemaphore.signal()
        case .responseScreenshot:
            lastScreenshot = formatScreenshotResponse(message.payload)
            screenshotSemaphore.signal()
        case .responseFindElement:
            lastFindResult = formatFindResponse(message.payload)
            findSemaphore.signal()
        case .responseScreenText:
            lastScreenText = formatScreenTextResponse(message.payload)
            screenTextSemaphore.signal()

        default:
            break
        }
    }

    /// Handle responses with unknown/new message types not yet in NooberShared enum
    func handleUnknownMessage(rawType: String, payload: Data) {
        switch rawType {
        case "response.perfSnapshot":
            lastPerfSnapshot = formatPerfSnapshotResponse(payload)
            perfSnapshotSemaphore.signal()
        case "response.accessibilityAudit":
            lastAccessibilityAudit = formatAccessibilityAuditResponse(payload)
            accessibilityAuditSemaphore.signal()
        case "response.webViewConsole":
            lastWebViewConsole = formatWebViewConsoleResponse(payload)
            webViewConsoleSemaphore.signal()
        case "response.tap", "response.swipe", "response.typeText", "response.input":
            lastInputResult = formatInputResponse(payload)
            inputSemaphore.signal()
        default:
            break
        }
    }

    /// Lenient sync payload — all fields optional so missing keys don't crash the decode
    // Local types matching Noober's nested state objects (not exported from NooberShared)
    private struct EnvironmentStatePayload: Decodable {
        let environments: [TransferableEnvironment]
        let activeEnvironmentId: UUID?
    }

    // Matches Noober's actual FullSyncPayload (nested states)
    private struct LenientSyncPayload: Decodable {
        let httpRequests: [TransferableNetworkRequest]?
        let wsConnections: [TransferableWSConnection]?
        let logEntries: [TransferableLogEntry]?
        let environmentState: EnvironmentStatePayload?
        let rulesState: LenientRulesState?
        let qaState: LenientQAState?
        let userDefaultsEntries: [TransferableUserDefaultsEntry]?
        let keychainEntries: [TransferableKeychainEntry]?
        let currentScreen: String?
        let deviceName: String?
        let appName: String?
        let appVersion: String?
        let recordedFlows: [RecordedFlowData]?
    }

    private struct LenientRulesState: Decodable {
        let rewriteRules: [TransferableRewriteRule]?
        let mockRules: [TransferableMockRule]?
        let interceptRules: [TransferableInterceptRule]?
    }

    private struct LenientQAState: Decodable {
        let results: [TransferableQAResult]?
        let buildNumber: String?
    }

    private func handleFullSync(_ payload: Data) {
        do {
            let sync = try decoder.decode(LenientSyncPayload.self, from: payload)
            httpRequests = sync.httpRequests ?? []
            wsConnections = sync.wsConnections ?? []
            logEntries = sync.logEntries ?? []
            environments = sync.environmentState?.environments ?? []
            activeEnvironmentId = sync.environmentState?.activeEnvironmentId
            rewriteRules = sync.rulesState?.rewriteRules ?? []
            mockRules = sync.rulesState?.mockRules ?? []
            interceptRules = sync.rulesState?.interceptRules ?? []
            qaResults = sync.qaState?.results ?? []
            userDefaultsEntries = sync.userDefaultsEntries ?? []
            keychainEntries = sync.keychainEntries ?? []
            buildNumber = sync.qaState?.buildNumber ?? ""
            currentScreen = sync.currentScreen ?? "Unknown"
            recordedFlows = sync.recordedFlows ?? []

            hasSynced = true
            connectedSemaphore.signal()
            log("[noober] Synced: \(httpRequests.count) reqs, \(logEntries.count) logs, \(environments.count) envs, \(qaResults.count) QA, \(userDefaultsEntries.count) UD")
        } catch {
            log("[noober] Sync decode error: \(error)")
        }
    }

    // MARK: - Find Element (accessibility-based, fast)

    func requestFindElement(text: String, exact: Bool, timeout: TimeInterval = 3) -> String {
        findLock.lock()
        defer { findLock.unlock() }
        guard isConnected else { return "Noober not connected" }
        lastFindResult = nil

        let payload: [String: Any] = ["text": text, "exact": exact]
        sendRawCommand(type: "command.findElement", payload: payload)

        let result = findSemaphore.wait(timeout: .now() + timeout)
        if result == .timedOut { return "Find element timed out" }
        return lastFindResult ?? "No results"
    }

    private func formatFindResponse(_ payload: Data) -> String {
        struct FoundElement: Decodable {
            let label: String
            let type: String
            let x: Int
            let y: Int
            let width: Int
            let height: Int
            let centerX: Int
            let centerY: Int
            let isButton: Bool
        }
        struct FindResponse: Decodable {
            let screen: String
            let query: String
            let results: [FoundElement]
        }
        guard let resp = try? decoder.decode(FindResponse.self, from: payload) else {
            return "Find decode failed"
        }
        currentScreen = resp.screen
        if resp.results.isEmpty {
            return "Screen: \(resp.screen)\nNo elements found matching \"\(resp.query)\""
        }
        var lines = ["Screen: \(resp.screen)", "Found \(resp.results.count) match(es) for \"\(resp.query)\":"]
        for el in resp.results {
            let btn = el.isButton ? " [BUTTON]" : ""
            lines.append("  \(el.type) \"\(el.label)\" at (\(el.x),\(el.y)) \(el.width)x\(el.height) center=(\(el.centerX),\(el.centerY))\(btn)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Screen Text (all visible text, fast)

    func requestScreenText(timeout: TimeInterval = 3) -> String {
        screenTextLock.lock()
        defer { screenTextLock.unlock() }
        guard isConnected else { return "Noober not connected" }
        lastScreenText = nil

        sendRawCommand(type: "command.screenText", payload: [:])

        let result = screenTextSemaphore.wait(timeout: .now() + timeout)
        if result == .timedOut { return "Screen text timed out" }
        return lastScreenText ?? "No text"
    }

    private func formatScreenTextResponse(_ payload: Data) -> String {
        struct ScreenTextResponse: Decodable {
            let screen: String
            let lines: [String]
        }
        guard let resp = try? decoder.decode(ScreenTextResponse.self, from: payload) else {
            return "Screen text decode failed"
        }
        currentScreen = resp.screen
        var result = ["Screen: \(resp.screen)", "Visible text (\(resp.lines.count) items):"]
        for line in resp.lines {
            result.append("  \(line)")
        }
        return result.joined(separator: "\n")
    }

    /// Send a raw command for message types not in NooberShared.
    /// Builds JSON that matches CompanionMessage's Codable format exactly.
    func sendRawCommand(type: String, payload: [String: Any]) {
        guard let connection else { return }

        // CompanionMessage.payload is Data, which Codable encodes as base64.
        // We need to match this exactly.
        let payloadData = payload.isEmpty ? Data() : ((try? JSONSerialization.data(withJSONObject: payload)) ?? Data())

        // Build the message using JSONEncoder to match CompanionMessage's Codable format
        struct RawMessage: Encodable {
            let type: String
            let payload: Data
            let timestamp: Date
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let msgData = try? encoder.encode(RawMessage(type: type, payload: payloadData, timestamp: Date())) else { return }

        var length = UInt32(msgData.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(msgData)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    // MARK: - View Hierarchy Snapshot

    /// Request a live snapshot from Noober (runs in-app, returns in ~100ms)
    func requestSnapshot(timeout: TimeInterval = 5) -> String {
        guard isConnected else { return "Noober not connected" }
        lastSnapshot = nil
        sendRawCommand(type: "command.requestSnapshot", payload: [:])
        let result = snapshotSemaphore.wait(timeout: .now() + timeout)
        if result == .timedOut { return "Snapshot timed out (Noober didn't respond)" }
        return lastSnapshot ?? "No snapshot data"
    }

    private func formatSnapshotResponse(_ payload: Data) -> String {
        struct SnapshotElement: Decodable {
            let label: String?
            let identifier: String?
            let type: String
            let x: Int
            let y: Int
            let width: Int
            let height: Int
            let interactive: Bool
        }

        struct SnapshotResponse: Decodable {
            let screen: String
            let elements: [SnapshotElement]
        }

        guard let snapshot = try? decoder.decode(SnapshotResponse.self, from: payload) else {
            return "Failed to decode snapshot"
        }

        var lines: [String] = ["Screen: \(snapshot.screen)", "Elements (\(snapshot.elements.count)):"]
        for el in snapshot.elements {
            let name = el.label ?? el.identifier ?? ""
            let interactiveTag = el.interactive ? " [tappable]" : ""
            lines.append("  \(el.type) \"\(name)\" at (\(el.x),\(el.y)) \(el.width)x\(el.height)\(interactiveTag)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - In-Process Screenshot

    func requestScreenshot(timeout: TimeInterval = 5) -> (text: String, imageBase64: String?) {
        guard isConnected else { return ("Noober not connected", nil) }
        lastScreenshot = nil
        sendRawCommand(type: "command.requestScreenshot", payload: [:])
        let result = screenshotSemaphore.wait(timeout: .now() + timeout)
        if result == .timedOut { return ("Screenshot timed out", nil) }
        return (lastScreenshot ?? "No screenshot", screenshotBase64)
    }

    private var screenshotBase64: String?

    /// Public accessor for the last captured screenshot base64 string (for visual diff)
    var screenshotBase64Data: String? { screenshotBase64 }

    private func formatScreenshotResponse(_ payload: Data) -> String {
        struct ScreenshotResponse: Decodable {
            let screen: String
            let base64PNG: String
        }
        guard let resp = try? decoder.decode(ScreenshotResponse.self, from: payload) else {
            return "Screenshot decode failed"
        }
        currentScreen = resp.screen
        screenshotBase64 = resp.base64PNG
        return "Screen: \(resp.screen)\nScreenshot captured (\(resp.base64PNG.count) bytes base64)"
    }

    // MARK: - Storage Writes

    private let storageSemaphore = DispatchSemaphore(value: 0)
    private let storageLock = NSLock()
    private let cookiesSemaphore = DispatchSemaphore(value: 0)
    private let cookiesLock = NSLock()

    /// Sends a write command and waits for the app to confirm it.
    func requestStorageWrite(type: String, payload: [String: Any], timeout: TimeInterval = 3) -> String {
        storageLock.lock()
        defer { storageLock.unlock() }
        guard isConnected else { return "Noober not connected" }
        lastStorageWrite = nil
        sendRawCommand(type: type, payload: payload)
        if storageSemaphore.wait(timeout: .now() + timeout) == .timedOut {
            return "Timed out waiting for the app to confirm the write"
        }
        return lastStorageWrite ?? "No response"
    }

    func requestCookies(timeout: TimeInterval = 3) -> String {
        cookiesLock.lock()
        defer { cookiesLock.unlock() }
        guard isConnected else { return "Noober not connected" }
        lastCookies = nil
        sendRawCommand(type: "command.getCookies", payload: [:])
        if cookiesSemaphore.wait(timeout: .now() + timeout) == .timedOut {
            return "Timed out waiting for cookies"
        }
        return lastCookies ?? "No response"
    }

    private func formatStorageWriteResponse(_ payload: Data) -> String {
        struct StorageWriteResponse: Decodable {
            let ok: Bool
            let detail: String
        }
        guard let resp = try? JSONDecoder().decode(StorageWriteResponse.self, from: payload) else {
            return "Malformed write response"
        }
        return (resp.ok ? "OK: " : "FAILED: ") + resp.detail
    }

    private func formatCookiesResponse(_ payload: Data) -> String {
        struct CookieData: Decodable {
            let name: String, value: String, domain: String, path: String
            let isSecure: Bool, isHTTPOnly: Bool
            let expiresAt: Date?
        }
        struct CookiesResponse: Decodable { let cookies: [CookieData] }

        let decoder = JSONDecoder()
        guard let resp = try? decoder.decode(CookiesResponse.self, from: payload) else {
            return "Malformed cookies response"
        }
        guard !resp.cookies.isEmpty else { return "No cookies set" }
        return "Cookies (\(resp.cookies.count)):\n" + resp.cookies.map {
            var flags: [String] = []
            if $0.isSecure { flags.append("Secure") }
            if $0.isHTTPOnly { flags.append("HttpOnly") }
            let suffix = flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]"
            return "  \($0.domain)\($0.path)  \($0.name)=\($0.value)\(suffix)"
        }.joined(separator: "\n")
    }

    // MARK: - Screen HTML (semantic HTML encoding, optimized for LLM comprehension)

    func requestScreenHTML(timeout: TimeInterval = 3) -> String {
        screenHTMLLock.lock()
        defer { screenHTMLLock.unlock() }
        guard isConnected else { return "Noober not connected" }
        lastScreenHTML = nil
        let start = CFAbsoluteTimeGetCurrent()
        sendRawCommand(type: "command.screenHTML", payload: [:])
        let result = screenHTMLSemaphore.wait(timeout: .now() + timeout)
        let elapsed = String(format: "%.0fms", (CFAbsoluteTimeGetCurrent() - start) * 1000)
        if result == .timedOut {
            log("[noober] screen_html timed out after \(elapsed) — falling back to screen_text")
            return requestScreenText(timeout: 3)
        }
        log("[noober] screen_html completed in \(elapsed)")
        return lastScreenHTML ?? "No data"
    }

    private func formatScreenHTMLResponse(_ payload: Data) -> String {
        struct ScreenHTMLResponse: Decodable {
            let screen: String
            let html: String
            let elementCount: Int
        }
        guard let resp = try? decoder.decode(ScreenHTMLResponse.self, from: payload) else {
            return "Screen HTML decode failed"
        }
        currentScreen = resp.screen
        return resp.html
    }

    // MARK: - Performance Snapshot

    func requestPerfSnapshot(timeout: TimeInterval = 3) -> String {
        guard isConnected else { return "Noober not connected" }
        lastPerfSnapshot = nil
        sendRawCommand(type: "command.perfSnapshot", payload: [:])
        let result = perfSnapshotSemaphore.wait(timeout: .now() + timeout)
        if result == .timedOut { return "Perf snapshot timed out" }
        return lastPerfSnapshot ?? "No perf data"
    }

    private func formatPerfSnapshotResponse(_ payload: Data) -> String {
        struct PerfSnapshotResponse: Decodable {
            let fps: Double
            let memoryMB: Double
            let avgFPS: Double
            let peakMemoryMB: Double
            let screen: String
        }
        guard let resp = try? decoder.decode(PerfSnapshotResponse.self, from: payload) else {
            return "Perf snapshot decode failed"
        }
        currentScreen = resp.screen
        return """
        Screen: \(resp.screen)
        Current FPS: \(String(format: "%.1f", resp.fps))
        Average FPS: \(String(format: "%.1f", resp.avgFPS))
        Memory: \(String(format: "%.1f", resp.memoryMB)) MB
        Peak Memory: \(String(format: "%.1f", resp.peakMemoryMB)) MB
        """
    }

    // MARK: - Accessibility Audit

    func requestAccessibilityAudit(timeout: TimeInterval = 3) -> String {
        guard isConnected else { return "Noober not connected" }
        lastAccessibilityAudit = nil
        sendRawCommand(type: "command.accessibilityAudit", payload: [:])
        let result = accessibilityAuditSemaphore.wait(timeout: .now() + timeout)
        if result == .timedOut { return "Accessibility audit timed out" }
        return lastAccessibilityAudit ?? "No audit data"
    }

    private func formatAccessibilityAuditResponse(_ payload: Data) -> String {
        struct AuditIssue: Decodable {
            let element: String
            let issue: String
            let severity: String
            let x: Int
            let y: Int
            let width: Int
            let height: Int
        }
        struct AccessibilityAuditResponse: Decodable {
            let screen: String
            let issues: [AuditIssue]
            let issueCount: Int
        }
        guard let resp = try? decoder.decode(AccessibilityAuditResponse.self, from: payload) else {
            return "Accessibility audit decode failed"
        }
        currentScreen = resp.screen
        if resp.issues.isEmpty {
            return "Screen: \(resp.screen)\nAccessibility Audit: PASS — No issues found"
        }
        let errors = resp.issues.filter { $0.severity == "error" }.count
        let warnings = resp.issues.filter { $0.severity == "warning" }.count
        var lines = [
            "Screen: \(resp.screen)",
            "Accessibility Audit: \(resp.issueCount) issue(s) — \(errors) error(s), \(warnings) warning(s)",
        ]
        for issue in resp.issues {
            let icon = issue.severity == "error" ? "ERROR" : "WARN"
            lines.append("  [\(icon)] \(issue.element): \(issue.issue) at (\(issue.x),\(issue.y)) \(issue.width)x\(issue.height)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - WebView Console Logs

    func requestWebViewConsole(level: String? = nil, limit: Int = 50, timeout: TimeInterval = 3) -> String {
        guard isConnected else { return "Noober not connected" }
        lastWebViewConsole = nil

        var payload: [String: Any] = ["limit": limit]
        if let level { payload["level"] = level }
        sendRawCommand(type: "command.getWebViewConsole", payload: payload)

        let result = webViewConsoleSemaphore.wait(timeout: .now() + timeout)
        if result == .timedOut { return "WebView console request timed out" }
        return lastWebViewConsole ?? "No WebView console data"
    }

    private func formatWebViewConsoleResponse(_ payload: Data) -> String {
        struct ConsoleEntry: Decodable {
            let timestamp: Double
            let level: String
            let message: String
            let url: String?
        }
        struct WebViewConsoleResponse: Decodable {
            let entries: [ConsoleEntry]
            let totalCount: Int
        }
        guard let resp = try? decoder.decode(WebViewConsoleResponse.self, from: payload) else {
            return "WebView console decode failed"
        }
        if resp.entries.isEmpty {
            return "No WebView console entries captured.\nNote: Console capture requires WKWebView instances in the app."
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        var lines = ["WebView Console (\(resp.entries.count) of \(resp.totalCount) entries):"]
        for entry in resp.entries {
            let date = Date(timeIntervalSince1970: entry.timestamp)
            let time = formatter.string(from: date)
            let levelTag = entry.level.uppercased()
            let urlSuffix = entry.url.map { " (\(String($0.suffix(60))))" } ?? ""
            lines.append("  [\(time)] [\(levelTag)] \(String(entry.message.prefix(300)))\(urlSuffix)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Input Synthesis (in-process via probe)

    func requestTap(x: Int, y: Int, timeout: TimeInterval = 3) -> String {
        guard isConnected else { return "Noober not connected" }
        lastInputResult = nil
        sendRawCommand(type: "command.tap", payload: ["x": x, "y": y])
        let result = inputSemaphore.wait(timeout: .now() + timeout)
        if result == .timedOut { return "Probe tap timed out" }
        return lastInputResult ?? "No tap result"
    }

    func requestSwipe(x1: Int, y1: Int, x2: Int, y2: Int, duration: Double? = nil, timeout: TimeInterval = 3) -> String {
        guard isConnected else { return "Noober not connected" }
        lastInputResult = nil
        var payload: [String: Any] = ["x1": x1, "y1": y1, "x2": x2, "y2": y2]
        if let d = duration { payload["duration"] = d }
        sendRawCommand(type: "command.swipe", payload: payload)
        let result = inputSemaphore.wait(timeout: .now() + timeout)
        if result == .timedOut { return "Probe swipe timed out" }
        return lastInputResult ?? "No swipe result"
    }

    func requestTypeText(_ text: String, timeout: TimeInterval = 3) -> String {
        guard isConnected else { return "Noober not connected" }
        lastInputResult = nil
        sendRawCommand(type: "command.typeText", payload: ["text": text])
        let result = inputSemaphore.wait(timeout: .now() + timeout)
        if result == .timedOut { return "Probe type_text timed out" }
        return lastInputResult ?? "No type result"
    }

    /// Fire-and-forget: show a visual overlay in the app (no response expected)
    func showOverlay(category: String, detail: String? = nil, passed: Bool? = nil) {
        guard isConnected else { return }
        var payload: [String: Any] = ["category": category]
        if let detail { payload["detail"] = detail }
        if let passed { payload["passed"] = passed }
        log("[noober] showOverlay: \(category) / \(detail ?? "-")")
        sendRawCommand(type: "command.showOverlay", payload: payload)
    }

    /// Tell the app to dismiss the overlay orb
    func hideOverlay() {
        guard isConnected else { return }
        sendRawCommand(type: "command.hideOverlay", payload: [:])
    }

    private func formatInputResponse(_ payload: Data) -> String {
        struct InputResult: Decodable {
            let success: Bool
            let message: String
        }
        guard let resp = try? decoder.decode(InputResult.self, from: payload) else {
            return "Input response decode failed"
        }
        return resp.success ? "OK: \(resp.message)" : "FAILED: \(resp.message)"
    }

    // MARK: - Send Commands

    func sendCommand(_ type: CompanionMessageType, payload: Encodable) {
        guard let connection, isConnected else { return }
        let payloadData = (try? JSONEncoder().encode(payload)) ?? Data()
        let message = CompanionMessage(type: type, payload: payloadData, timestamp: Date())
        CompanionConnection.send(message, on: connection) { error in
            if let error { log("[noober] Send error: \(error)") }
        }
    }
}

private func log(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}
