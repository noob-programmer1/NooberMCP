import Foundation
import CoreGraphics

/// Routes device operations to the right backend:
///  - iOS simulator → native CoreSimulator (in-process HID + accessibility; no AXe, no idb)
///  - physical iPhone → `devicectl` (Xcode 27) + the Noober SDK over the CoreDevice tunnel
///  - Android → adb
final class SimulatorBridge {

    // Session defaults
    private(set) var simulatorId: String?
    private(set) var deviceId: String?        // physical device (CoreDevice identifier or UDID)
    private(set) var bundleId: String?
    private(set) var scheme: String?
    private(set) var projectPath: String?
    private(set) var workspacePath: String?
    private(set) var androidSerial: String?

    var isAndroidMode: Bool { androidSerial != nil }
    var isPhysicalMode: Bool { deviceId != nil && androidSerial == nil }

    /// Native simulator support is always present on macOS with Xcode installed.
    var isAvailable: Bool { CoreSim.loaded }

    private var inputs: [String: SimInput] = [:]
    private let inputsLock = NSLock()
    /// Element refs from the last `snapshot_ui`, resolved by `tap(ref:)`.
    private(set) var lastOutline: UIOutline?

    // MARK: - Session Defaults

    func setDefaults(args: [String: Any]) -> String {
        if let s = args["simulatorId"] as? String, !s.isEmpty { simulatorId = s; deviceId = nil; androidSerial = nil }
        if let d = args["deviceId"] as? String, !d.isEmpty { deviceId = d; androidSerial = nil }
        if let b = args["bundleId"] as? String { bundleId = b }
        if let s = args["scheme"] as? String { scheme = s }
        if let p = args["projectPath"] as? String { projectPath = p }
        if let w = args["workspacePath"] as? String { workspacePath = w }
        if let a = args["androidSerial"] as? String { androidSerial = a.isEmpty ? nil : a }
        return showDefaults()
    }

    func clearPhysical() { deviceId = nil }

    func showDefaults() -> String {
        var lines: [String] = ["Session defaults:"]
        if let a = androidSerial { lines.append("  target: Android \(a)") }
        else if let d = deviceId { lines.append("  target: physical device \(d)") }
        else if let s = simulatorId ?? CoreSim.firstBooted()?.udid {
            let dev = CoreSim.device(udid: s)
            lines.append("  target: simulator \(dev?.name ?? "?") [\(s)]\(simulatorId == nil ? " (auto: first booted)" : "")")
        } else { lines.append("  target: (none — boot a simulator or set deviceId)") }
        if let b = bundleId { lines.append("  bundleId: \(b)") }
        if let s = scheme { lines.append("  scheme: \(s)") }
        if let p = workspacePath ?? projectPath { lines.append("  project: \(p)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Device discovery

    func listSimulators() -> String {
        Exec.xcrun(["simctl", "list", "devices", "available", "-j"], timeout: 20)?.stdoutString ?? "Failed to list simulators"
    }

    /// Compact, token-cheap list of simulators + physical devices.
    func listDevices(includeShutdown: Bool) -> String {
        var lines: [String] = []
        let sims = CoreSim.allDevices().filter { $0.hasTouchscreen && (includeShutdown || $0.isBooted) }
            .sorted { ($0.isBooted ? 0 : 1, $0.name) < ($1.isBooted ? 0 : 1, $1.name) }
        lines.append("Simulators\(includeShutdown ? "" : " (booted — pass all:true for every simulator)"):")
        if sims.isEmpty { lines.append("  (none)") }
        for s in sims { lines.append("  \(s.name) — \(s.runtimeName), \(s.stateString)  [\(s.udid)]") }
        let phys = DeviceBridge.physical()
        lines.append("Physical devices:")
        if phys.isEmpty { lines.append("  (none paired)") }
        for d in phys { lines.append("  " + d.oneLine) }
        return lines.joined(separator: "\n")
    }

    func bootSimulator(udid: String? = nil) -> String {
        guard let id = udid ?? simulatorId else { return "Error: pass simulatorId" }
        let r = Exec.xcrun(["simctl", "boot", id], timeout: 120)
        if let r, !r.ok, !r.message.contains("current state: Booted") { return "Boot failed: \(r.message)" }
        _ = Exec.xcrun(["simctl", "bootstatus", id], timeout: 180)
        if simulatorId == nil { simulatorId = id }
        return "Booted \(CoreSim.device(udid: id)?.name ?? id)"
    }

    /// Opens Device Hub (Xcode 27) or Simulator.app (older).
    func openSimulator() -> String {
        let dev = CoreSim.developerDir
        for app in ["\(dev)/../Applications/DeviceHub.app", "\(dev)/Applications/Simulator.app"]
        where FileManager.default.fileExists(atPath: app) {
            _ = Exec.run("/usr/bin/open", [app], timeout: 10)
            return "Opened \(URL(fileURLWithPath: app).deletingPathExtension().lastPathComponent)"
        }
        return "Neither Device Hub nor Simulator.app found under \(dev)"
    }

    // MARK: - App lifecycle

    func launchApp(bundleId bid: String? = nil, udid: String? = nil, injectProbe: Bool = false,
                   env: [String: String] = [:], args: [String] = []) -> String {
        let bundle = bid ?? bundleId ?? ""
        guard !bundle.isEmpty else { return "Error: no bundleId set. Call session_set_defaults first." }
        if isPhysicalMode, udid == nil, let dev = deviceId {
            return DeviceBridge.launch(device: dev, bundleId: bundle, env: env, args: args)
        }
        guard let id = udid ?? resolveUDID() else { return "Error: no booted simulator" }
        var childEnv: [String: String] = [:]
        for (k, v) in env { childEnv["SIMCTL_CHILD_\(k)"] = v }
        if injectProbe, let probe = Self.resolveProbePath() {
            childEnv["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = probe
        }
        let r = Exec.xcrun(["simctl", "launch", "--terminate-running-process", id, bundle] + args, timeout: 60, env: childEnv)
        return r?.message ?? "Launch timed out"
    }

    /// Copies the probe to /tmp and re-signs it ad hoc. iOS 26+ simulators reject
    /// DYLD_INSERT_LIBRARIES from user directories and anything but an ad-hoc signature.
    static func resolveProbePath() -> String? {
        let tmpPath = "/tmp/NooberProbe.dylib"
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let execDir = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent().path
        var candidates = [
            execDir + "/../Resources/Bundled/NooberProbe.dylib",   // .app bundle
            execDir + "/Bundled/NooberProbe.dylib",                // release archive
            execDir + "/../Bundled/NooberProbe.dylib",
            home + "/.noobqa/bin/NooberProbe.dylib",
        ]
        // Development: walk up from .build/… (layout differs across SwiftPM versions) to the repo's Bundled/.
        var dir = URL(fileURLWithPath: execDir)
        for _ in 0..<6 {
            dir.deleteLastPathComponent()
            candidates.append(dir.appendingPathComponent("Bundled/NooberProbe.dylib").path)
        }
        if let override = ProcessInfo.processInfo.environment["NOOBER_PROBE_PATH"] { candidates.insert(override, at: 0) }
        guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return FileManager.default.fileExists(atPath: tmpPath) ? tmpPath : nil
        }
        // Skip the copy + codesign when the staged copy is already current.
        let fm = FileManager.default
        if let a = try? fm.attributesOfItem(atPath: source), let b = try? fm.attributesOfItem(atPath: tmpPath),
           (a[.size] as? Int) == (b[.size] as? Int),
           let ma = a[.modificationDate] as? Date, let mb = b[.modificationDate] as? Date, mb >= ma {
            return tmpPath
        }
        try? fm.removeItem(atPath: tmpPath)
        guard (try? fm.copyItem(atPath: source, toPath: tmpPath)) != nil else {
            return fm.fileExists(atPath: tmpPath) ? tmpPath : nil
        }
        Exec.run("/usr/bin/codesign", ["--force", "--sign", "-", tmpPath], timeout: 30)
        return tmpPath
    }

    func stopApp(bundleId bid: String? = nil, udid: String? = nil) -> String {
        let bundle = bid ?? bundleId ?? ""
        guard !bundle.isEmpty else { return "Error: no bundleId" }
        if isPhysicalMode, udid == nil, let dev = deviceId { return DeviceBridge.terminate(device: dev, bundleId: bundle) }
        guard let id = udid ?? resolveUDID() else { return "Error: no booted simulator" }
        return Exec.xcrun(["simctl", "terminate", id, bundle], timeout: 30)?.message ?? "Failed"
    }

    func installApp(path: String) -> String {
        if isPhysicalMode, let dev = deviceId { return DeviceBridge.install(device: dev, appPath: path) }
        guard let id = resolveUDID() else { return "Error: no booted simulator" }
        return Exec.xcrun(["simctl", "install", id, path], timeout: 300)?.message ?? "Install timed out"
    }

    func openURL(_ url: String) -> String {
        if isPhysicalMode, let dev = deviceId { return DeviceBridge.openURL(device: dev, url: url) }
        guard let id = resolveUDID() else { return "Error: no booted simulator" }
        return Exec.xcrun(["simctl", "openurl", id, url], timeout: 30)?.message ?? "Failed"
    }

    func setAppearance(_ style: String) -> String {
        if isPhysicalMode, let dev = deviceId { return DeviceBridge.appearance(device: dev, style: style) }
        guard let id = resolveUDID() else { return "Error: no booted simulator" }
        return Exec.xcrun(["simctl", "ui", id, "appearance", style], timeout: 30)?.message ?? "Failed"
    }

    func setLocation(lat: Double, lon: Double) -> String {
        if isPhysicalMode, let dev = deviceId { return DeviceBridge.location(device: dev, lat: lat, lon: lon) }
        guard let id = resolveUDID() else { return "Error: no booted simulator" }
        return Exec.xcrun(["simctl", "location", id, "set", "\(lat),\(lon)"], timeout: 30)?.message ?? "Failed"
    }

    // MARK: - Input (simulator: native HID)

    /// The SimInput for the current simulator, reusing its warm HID connection.
    func simInput() throws -> SimInput {
        guard let udid = resolveUDID(), let dev = CoreSim.device(udid: udid) else {
            throw SimHIDError("no booted simulator — boot one or call session_set_defaults(simulatorId:)")
        }
        guard dev.isBooted else { throw SimHIDError("simulator \(dev.name) is \(dev.stateString)") }
        return inputsLock.withLock {
            if let i = inputs[udid] { return i }
            let i = SimInput(device: dev)
            inputs[udid] = i
            return i
        }
    }

    var screenSizePoints: CGSize? {
        guard let udid = resolveUDID() else { return nil }
        return CoreSim.device(udid: udid)?.screenPoints
    }

    private func attempt(_ what: String, _ body: (SimInput) throws -> String) -> String {
        do { return try body(try simInput()) } catch { return "Error: \(what) failed — \(error)" }
    }

    func tap(x: Int? = nil, y: Int? = nil, label: String? = nil, id: String? = nil,
             postDelay: Double? = nil) -> String {
        if isAndroidMode { return adbTap(x: x, y: y) }
        var point: CGPoint?
        var described = ""
        if let x, let y {
            point = CGPoint(x: x, y: y)
        } else if let q = label ?? id {
            switch locate(q) {
            case .success(let el):
                point = el.center
                described = " \(el.role) \"\(el.label ?? el.identifier ?? q)\""
            case .failure(let e): return "Error: \(e)"
            }
        }
        guard let p = point else { return "Error: provide x+y, label or ref" }
        let result = attempt("tap") { input in
            try input.tap(x: p.x, y: p.y)
            return "Tapped\(described) at (\(Int(p.x)), \(Int(p.y)))"
        }
        if let d = postDelay, d > 0 { Thread.sleep(forTimeInterval: d) }
        return result
    }

    func tapPoint(_ p: CGPoint, hold: Double = 0.05, double: Bool = false) -> String {
        attempt("tap") { input in
            if double { try input.doubleTap(x: p.x, y: p.y) } else { try input.tap(x: p.x, y: p.y, hold: hold) }
            return "\(double ? "Double-tapped" : hold > 0.3 ? "Long-pressed" : "Tapped") at (\(Int(p.x)), \(Int(p.y)))"
        }
    }

    enum LocateError: Error, CustomStringConvertible {
        case notFound(String), failed(String)
        var description: String {
            switch self {
            case .notFound(let q): return "no element matching \"\(q)\" on screen (try snapshot_ui)"
            case .failed(let m): return m
            }
        }
    }

    /// Resolve `e12` refs (from the last snapshot) or free text via the accessibility tree.
    func locate(_ query: String) -> Result<SimAccessibility.Element, LocateError> {
        if query.range(of: #"^@?e\d+$"#, options: .regularExpression) != nil {
            let key = query.hasPrefix("@") ? String(query.dropFirst()) : query
            guard let r = lastOutline?.refs[key] else { return .failure(.failed("unknown ref \(query) — call snapshot_ui first")) }
            return .success(.init(role: "ref", label: query, value: nil, identifier: nil, frame: r.frame, enabled: true, children: []))
        }
        do {
            let tree = try uiTree()
            guard let el = UIOutline.find(query, in: tree) else { return .failure(.notFound(query)) }
            return .success(el)
        } catch { return .failure(.failed("\(error)")) }
    }

    func swipe(startX: Int, startY: Int, endX: Int, endY: Int, duration: Double? = nil) -> String {
        if isAndroidMode { return adbSwipe(x1: startX, y1: startY, x2: endX, y2: endY, duration: duration) }
        return attempt("swipe") { input in
            try input.swipe(from: CGPoint(x: startX, y: startY), to: CGPoint(x: endX, y: endY), duration: duration ?? 0.3)
            return "Swiped (\(startX),\(startY)) → (\(endX),\(endY))"
        }
    }

    /// Direction swipe ("scroll up" = finger moves up, content moves up to reveal what's below).
    func swipe(direction: String, distance: Double = 0.5) -> String {
        guard let s = screenSizePoints else { return "Error: no booted simulator" }
        let cx = s.width / 2, cy = s.height / 2
        let dx = s.width * distance / 2, dy = s.height * distance / 2
        let (a, b): (CGPoint, CGPoint)
        switch direction.lowercased() {
        case "up": (a, b) = (CGPoint(x: cx, y: cy + dy), CGPoint(x: cx, y: cy - dy))
        case "down": (a, b) = (CGPoint(x: cx, y: cy - dy), CGPoint(x: cx, y: cy + dy))
        case "left": (a, b) = (CGPoint(x: cx + dx, y: cy), CGPoint(x: cx - dx, y: cy))
        case "right": (a, b) = (CGPoint(x: cx - dx, y: cy), CGPoint(x: cx + dx, y: cy))
        default: return "Error: direction must be up/down/left/right"
        }
        return swipe(startX: Int(a.x), startY: Int(a.y), endX: Int(b.x), endY: Int(b.y), duration: 0.3)
    }

    func typeText(_ text: String) -> String {
        if isAndroidMode { return adbType(text) }
        return attempt("type") { input in
            let unmapped = try input.type(text)
            return unmapped.isEmpty ? "Typed \(text.count) characters"
                : "Typed text; \(unmapped.count) non-ASCII characters skipped (\(unmapped.prefix(20))) — inject the Noober probe/SDK for full Unicode typing"
        }
    }

    func pressKey(_ name: String, modifiers: [String] = []) -> String {
        guard let usage = HIDKeymap.named[name.lowercased()] ?? (name.count == 1 ? HIDKeymap.usage(for: Character(name)).map { $0.0 } : nil) else {
            return "Error: unknown key \(name). Known: \(HIDKeymap.named.keys.sorted().joined(separator: ", "))"
        }
        let mods: [UInt32] = modifiers.compactMap {
            switch $0.lowercased() { case "cmd", "command": return HIDKeymap.leftGUI; case "shift": return HIDKeymap.leftShift
            case "ctrl", "control": return 0xE0; case "alt", "option": return 0xE2; default: return nil }
        }
        return attempt("key") { input in try input.key(usage: usage, modifiers: mods); return "Pressed \(name)" }
    }

    func touch(x: Int, y: Int, down: Bool = true, up: Bool = true, delay: Double? = nil) -> String {
        tapPoint(CGPoint(x: x, y: y), hold: down && up ? (delay ?? 0.05) : 0.05)
    }

    func button(_ buttonType: String, duration: Double? = nil) -> String {
        if isAndroidMode { return adbButton(buttonType) }
        guard let b = SimButton(loose: buttonType) else {
            return "Error: unknown button \(buttonType). Use: \(SimButton.allCases.map(\.rawValue).joined(separator: ", "))"
        }
        return attempt("button") { input in try input.press(b, duration: duration ?? 0.1); return "Pressed \(b.rawValue)" }
    }

    // MARK: - Screenshot

    /// Returns caption, base64 payload and MIME type.
    func screenshot(quality: Screenshot.Quality = .fast) -> (text: String, base64: String?, mime: String) {
        if isAndroidMode { let r = adbScreenshot(); return (r.text, r.base64, "image/png") }
        if isPhysicalMode, let dev = deviceId {
            let (img, msg) = Screenshot.device(id: dev, quality: quality)
            return (msg, img?.base64, img?.mimeType ?? "image/png")
        }
        guard let udid = resolveUDID() else { return ("Error: no booted simulator", nil, "image/png") }
        let (img, msg) = Screenshot.simulator(udid: udid, pointSize: CoreSim.device(udid: udid)?.screenPoints, quality: quality)
        return (msg, img?.base64, img?.mimeType ?? "image/png")
    }

    // MARK: - Accessibility

    func uiTree() throws -> SimAccessibility.Element {
        guard let udid = resolveUDID(), let dev = CoreSim.device(udid: udid) else { throw SimHIDError("no booted simulator") }
        return try SimAccessibility.shared.tree(device: dev)
    }

    func snapshotUI() -> String {
        do {
            let tree = try uiTree()
            let outline = UIOutline(root: tree, screen: screenSizePoints ?? CGSize(width: 10000, height: 10000))
            lastOutline = outline
            return outline.text + "\nTap with tap(ref:\"e3\") or tap(label:\"…\"). Coordinates are points."
        } catch {
            return "Error: accessibility snapshot failed — \(error)"
        }
    }

    func visibleTexts() -> [String]? {
        guard let t = try? uiTree() else { return nil }
        return UIOutline.texts(t)
    }

    // MARK: - Helpers

    func resolveUDID() -> String? {
        if let id = simulatorId { return id }
        return CoreSim.firstBooted()?.udid
    }

    /// Kept for ToolHandler.rebuildApp; runs through zsh.
    func shell(_ command: String, timeout: TimeInterval = 30) -> String? {
        Exec.run("/bin/zsh", ["-c", command], timeout: timeout).map {
            ($0.stdoutString + $0.stderrString).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Android (adb)

    private var adbPath: String {
        if let sdk = ProcessInfo.processInfo.environment["ANDROID_HOME"] { return "\(sdk)/platform-tools/adb" }
        return "\(ProcessInfo.processInfo.environment["HOME"] ?? "")/Library/Android/sdk/platform-tools/adb"
    }

    private func adb(_ args: [String], timeout: TimeInterval = 20) -> Exec.Result? {
        guard let serial = androidSerial else { return nil }
        return Exec.run(adbPath, ["-s", serial] + args, timeout: timeout)
    }

    private func adbScreenshot() -> (text: String, base64: String?) {
        guard let r = adb(["exec-out", "screencap", "-p"]), r.stdout.count > 100 else { return ("Android screenshot failed", nil) }
        return ("Screenshot captured (\(r.stdout.count) bytes)", r.stdout.base64EncodedString())
    }

    private func adbTap(x: Int?, y: Int?) -> String {
        guard let x, let y else { return "Error: Android tap requires x,y coordinates" }
        _ = adb(["shell", "input", "tap", "\(x)", "\(y)"])
        AndroidCapture.invalidateScreenCache()
        return "Tapped (\(x), \(y))"
    }

    private func adbSwipe(x1: Int, y1: Int, x2: Int, y2: Int, duration: Double?) -> String {
        _ = adb(["shell", "input", "swipe", "\(x1)", "\(y1)", "\(x2)", "\(y2)", "\(Int((duration ?? 0.3) * 1000))"])
        AndroidCapture.invalidateScreenCache()
        return "Swiped (\(x1),\(y1)) → (\(x2),\(y2))"
    }

    private func adbType(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: " ", with: "%s")
        _ = adb(["shell", "input", "text", escaped])
        return "Typed: \(text)"
    }

    private func adbButton(_ buttonType: String) -> String {
        let keycode: String
        switch buttonType.lowercased() {
        case "home": keycode = "3"
        case "back": keycode = "4"
        case "menu": keycode = "82"
        case "enter", "return": keycode = "66"
        case "volume_up": keycode = "24"
        case "volume_down": keycode = "25"
        case "power", "lock": keycode = "26"
        default: keycode = buttonType
        }
        _ = adb(["shell", "input", "keyevent", keycode])
        return "Pressed: \(buttonType)"
    }
}
