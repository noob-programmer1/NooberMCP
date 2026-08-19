import Foundation

/// Native bridge to iOS Simulator — calls AXe binary + simctl directly.
/// Replaces the entire XcodeBuildMCP Node.js stack.
final class SimulatorBridge {

    // Session defaults
    private(set) var simulatorId: String?
    private(set) var bundleId: String?
    private(set) var scheme: String?
    private(set) var projectPath: String?
    private(set) var workspacePath: String?
    private(set) var androidSerial: String?  // set when testing Android

    var isAndroidMode: Bool { androidSerial != nil }

    private let axePath: String
    private let frameworksPath: String

    init() {
        // Find AXe binary — check bundled location first, then XcodeBuildMCP cache
        let bundleDir = ProcessInfo.processInfo.arguments.first
            .flatMap { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
            ?? "."
        let candidates = [
            "\(bundleDir)/Bundled/axe",
            "\(bundleDir)/../Bundled/axe",
            // Running straight out of .build/<config>/ during development
            "\(bundleDir)/../../../Bundled/axe",
        ]
        // Explicit override wins — useful when AXe lives outside the release layout
        let override = ProcessInfo.processInfo.environment["NOOBER_AXE_PATH"].map { [$0] } ?? []

        let allCandidates = override + candidates
        axePath = allCandidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "axe"
        frameworksPath = URL(fileURLWithPath: axePath).deletingLastPathComponent()
            .appendingPathComponent("Frameworks").path

        if FileManager.default.isExecutableFile(atPath: axePath) {
            log("[sim-bridge] AXe found at: \(axePath)")
        } else {
            log("[sim-bridge] WARNING: AXe not found — simulator tools will be unavailable")
        }
    }

    var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: axePath)
    }

    // MARK: - Session Defaults

    func setDefaults(args: [String: Any]) -> String {
        if let s = args["simulatorId"] as? String { simulatorId = s }
        if let b = args["bundleId"] as? String { bundleId = b }
        if let s = args["scheme"] as? String { scheme = s }
        if let p = args["projectPath"] as? String { projectPath = p }
        if let w = args["workspacePath"] as? String { workspacePath = w }
        if let a = args["androidSerial"] as? String { androidSerial = a }

        var result: [String: String] = [:]
        if let s = simulatorId { result["simulatorId"] = s }
        if let b = bundleId { result["bundleId"] = b }
        if let s = scheme { result["scheme"] = s }
        if let a = androidSerial { result["androidSerial"] = a; result["mode"] = "android" }
        return "Defaults updated: \(result)"
    }

    func showDefaults() -> String {
        var lines: [String] = ["Session defaults:"]
        if let s = simulatorId { lines.append("  simulatorId: \(s)") }
        if let b = bundleId { lines.append("  bundleId: \(b)") }
        if let s = scheme { lines.append("  scheme: \(s)") }
        if lines.count == 1 { lines.append("  (none set)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Simulator Management

    func listSimulators() -> String {
        return shell("xcrun simctl list devices available -j") ?? "Failed to list simulators"
    }

    func bootSimulator(udid: String? = nil) -> String {
        let id = udid ?? simulatorId ?? "booted"
        let result = shell("xcrun simctl boot \(id) 2>&1")
        return result ?? "Failed to boot simulator"
    }

    func openSimulator() -> String {
        _ = shell("open -a Simulator")
        return "Simulator.app opened"
    }

    // MARK: - App Lifecycle

    func launchApp(bundleId bid: String? = nil, udid: String? = nil, injectProbe: Bool = false) -> String {
        let id = udid ?? simulatorId ?? "booted"
        let bundle = bid ?? bundleId ?? ""
        guard !bundle.isEmpty else { return "Error: no bundleId set. Call session_set_defaults first." }

        var command = "xcrun simctl launch \(id) \(bundle) 2>&1"
        if injectProbe, let probePath = resolveProbePath() {
            // Inject NooberProbe dylib for network/UI inspection without SDK
            command = "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=\(probePath) \(command)"
        }
        let result = shell(command)
        return result ?? "Failed to launch app"
    }

    /// Resolve path to NooberProbe.dylib (bundled next to axe)
    private func resolveProbePath() -> String? {
        Self.resolveProbePath()
    }

    /// Static probe path resolution.
    ///
    /// Always returns `/tmp/NooberProbe.dylib` after copying from the bundled
    /// source and re-signing adhoc. iOS 26+ simulator's `DYLD_INSERT_LIBRARIES`
    /// rejects user-directory paths and dylibs carrying anything other than an
    /// adhoc signature — the `/tmp/` + adhoc combo is the only reliable mode.
    ///
    /// Search order:
    /// 1. Inside the shipped .app bundle (`Contents/Resources/Bundled/`).
    /// 2. Same dir as the NooberMCP binary (`Contents/MacOS/Bundled/`) — old layout.
    /// 3. Up one (`Contents/Bundled/`) — older layout.
    /// 4. `~/Documents/cityflo/NooberMCP/Bundled/...` — DEV ONLY, kept last so
    ///    shipped builds prefer the bundled copy.
    static func resolveProbePath() -> String? {
        let tmpPath = "/tmp/NooberProbe.dylib"
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let execDir = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .deletingLastPathComponent().path
        let candidates = [
            execDir + "/../Resources/Bundled/NooberProbe.dylib",   // shipped: Contents/Resources/Bundled
            execDir + "/Bundled/NooberProbe.dylib",                // old: Contents/MacOS/Bundled
            execDir + "/../Bundled/NooberProbe.dylib",             // old: Contents/Bundled
            home + "/.noobqa/bin/NooberProbe.dylib",               // user override
            home + "/Documents/cityflo/NooberMCP/Bundled/NooberProbe.dylib", // dev only
        ]
        guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            // Last-resort fallback: use existing /tmp leftover if present
            return FileManager.default.fileExists(atPath: tmpPath) ? tmpPath : nil
        }

        // Copy + re-sign adhoc on every resolution. Stripping any inherited
        // signature (Developer ID + hardened runtime from build pipeline) is
        // mandatory — iOS 26+ silently drops dylibs with stricter sigs.
        try? FileManager.default.removeItem(atPath: tmpPath)
        do {
            try FileManager.default.copyItem(atPath: source, toPath: tmpPath)
        } catch {
            return FileManager.default.fileExists(atPath: tmpPath) ? tmpPath : nil
        }
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", tmpPath]
        codesign.standardOutput = Pipe()
        codesign.standardError = Pipe()
        try? codesign.run()
        codesign.waitUntilExit()
        return tmpPath
    }

    func stopApp(bundleId bid: String? = nil, udid: String? = nil) -> String {
        let id = udid ?? simulatorId ?? "booted"
        let bundle = bid ?? bundleId ?? ""
        guard !bundle.isEmpty else { return "Error: no bundleId" }
        return shell("xcrun simctl terminate \(id) \(bundle) 2>&1") ?? "Failed"
    }

    // MARK: - UI Interaction (via AXe or ADB for Android)

    func tap(x: Int? = nil, y: Int? = nil, label: String? = nil, id: String? = nil,
             postDelay: Double? = nil) -> String {
        log("[sim-bridge] tap called. isAndroidMode=\(isAndroidMode), androidSerial=\(androidSerial ?? "nil")")
        if isAndroidMode { return adbTap(x: x, y: y, label: label) }
        guard let udid = resolveUDID() else { return "Error: no simulator configured" }

        var args = ["tap", "--udid", udid]
        if let x, let y {
            args += ["-x", "\(x)", "-y", "\(y)"]
        } else if let label {
            args += ["--label", label]
        } else if let id {
            args += ["--id", id]
        } else {
            return "Error: provide x+y coordinates or label or id"
        }
        if let d = postDelay { args += ["--post-delay", String(format: "%.1f", d)] }

        return runAxe(args)
    }

    func swipe(startX: Int, startY: Int, endX: Int, endY: Int, duration: Double? = nil) -> String {
        if isAndroidMode { return adbSwipe(x1: startX, y1: startY, x2: endX, y2: endY, duration: duration) }
        guard let udid = resolveUDID() else { return "Error: no simulator configured" }

        var args = ["swipe", "--udid", udid,
                    "--start-x", "\(startX)", "--start-y", "\(startY)",
                    "--end-x", "\(endX)", "--end-y", "\(endY)"]
        if let d = duration { args += ["--duration", String(format: "%.1f", d)] }

        return runAxe(args)
    }

    func typeText(_ text: String) -> String {
        if isAndroidMode { return adbType(text) }
        guard let udid = resolveUDID() else { return "Error: no simulator configured" }
        return runAxe(["type", text, "--udid", udid])
    }

    func touch(x: Int, y: Int, down: Bool = true, up: Bool = true, delay: Double? = nil) -> String {
        guard let udid = resolveUDID() else { return "Error: no simulator configured" }

        var args = ["touch", "-x", "\(x)", "-y", "\(y)", "--udid", udid]
        if down { args.append("--down") }
        if up { args.append("--up") }
        if let d = delay { args += ["--delay", String(format: "%.1f", d)] }

        return runAxe(args)
    }

    func button(_ buttonType: String, duration: Double? = nil) -> String {
        if isAndroidMode { return adbButton(buttonType) }
        guard let udid = resolveUDID() else { return "Error: no simulator configured" }
        var args = ["button", buttonType, "--udid", udid]
        if let d = duration { args += ["--duration", String(format: "%.1f", d)] }
        return runAxe(args)
    }

    // MARK: - Screenshot

    func screenshot() -> (text: String, base64: String?) {
        if isAndroidMode { return adbScreenshot() }
        guard let udid = resolveUDID() else { return ("Error: no simulator configured", nil) }

        let tmpFile = "/tmp/noober_screenshot_\(UUID().uuidString).png"
        let result = shell("xcrun simctl io \(udid) screenshot \(tmpFile) 2>&1")

        guard let _ = result,
              let data = FileManager.default.contents(atPath: tmpFile) else {
            return ("Screenshot failed", nil)
        }

        let base64 = data.base64EncodedString()
        try? FileManager.default.removeItem(atPath: tmpFile)
        return ("Screenshot captured (\(data.count) bytes)", base64)
    }

    // MARK: - Android ADB Commands

    private var adbPath: String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        return "\(home)/Library/Android/sdk/platform-tools/adb"
    }

    private func adbScreenshot() -> (text: String, base64: String?) {
        guard let serial = androidSerial else { return ("Error: no Android device", nil) }
        let tmpFile = "/tmp/noober_android_screenshot_\(UUID().uuidString).png"
        _ = shell("'\(adbPath)' -s \(serial) exec-out screencap -p > '\(tmpFile)' 2>/dev/null")
        guard let data = FileManager.default.contents(atPath: tmpFile), data.count > 100 else {
            return ("Android screenshot failed", nil)
        }
        let base64 = data.base64EncodedString()
        try? FileManager.default.removeItem(atPath: tmpFile)
        return ("Screenshot captured (\(data.count) bytes)", base64)
    }

    private func adbTap(x: Int?, y: Int?, label: String?) -> String {
        guard let serial = androidSerial else { return "Error: no Android device" }
        guard let x, let y else { return "Error: Android tap requires x,y coordinates" }
        _ = shell("'\(adbPath)' -s \(serial) shell input tap \(x) \(y) 2>&1")
        AndroidCapture.invalidateScreenCache()
        return "Tapped (\(x), \(y))"
    }

    private func adbSwipe(x1: Int, y1: Int, x2: Int, y2: Int, duration: Double?) -> String {
        guard let serial = androidSerial else { return "Error: no Android device" }
        let durationMs = Int((duration ?? 0.3) * 1000)
        _ = shell("'\(adbPath)' -s \(serial) shell input swipe \(x1) \(y1) \(x2) \(y2) \(durationMs) 2>&1")
        AndroidCapture.invalidateScreenCache() // screen changed after swipe
        return "Swiped (\(x1),\(y1)) → (\(x2),\(y2))"
    }

    private func adbType(_ text: String) -> String {
        guard let serial = androidSerial else { return "Error: no Android device" }
        let escaped = text.replacingOccurrences(of: " ", with: "%s")
            .replacingOccurrences(of: "'", with: "\\'")
        _ = shell("'\(adbPath)' -s \(serial) shell input text '\(escaped)' 2>&1")
        return "Typed: \(text)"
    }

    private func adbButton(_ buttonType: String) -> String {
        guard let serial = androidSerial else { return "Error: no Android device" }
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
        _ = shell("'\(adbPath)' -s \(serial) shell input keyevent \(keycode) 2>&1")
        return "Pressed: \(buttonType)"
    }

    // MARK: - Accessibility Snapshot

    func snapshotUI() -> String {
        guard let udid = resolveUDID() else { return "Error: no simulator configured" }
        return runAxe(["describe-ui", "--udid", udid])
    }

    // MARK: - Helpers

    private func resolveUDID() -> String? {
        if let id = simulatorId { return id }
        // Try to find a booted simulator
        if let json = shell("xcrun simctl list devices booted -j"),
           let data = json.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let devices = parsed["devices"] as? [String: [[String: Any]]] {
            for (_, devList) in devices {
                if let first = devList.first, let udid = first["udid"] as? String {
                    simulatorId = udid
                    return udid
                }
            }
        }
        return nil
    }

    private func runAxe(_ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: axePath)
        process.arguments = args

        // Set DYLD_FRAMEWORK_PATH so AXe can find its bundled frameworks
        var env = ProcessInfo.processInfo.environment
        let existingPath = env["DYLD_FRAMEWORK_PATH"] ?? ""
        env["DYLD_FRAMEWORK_PATH"] = frameworksPath + (existingPath.isEmpty ? "" : ":\(existingPath)")
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let outStr = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if process.terminationStatus != 0 {
                return "Error: \(errStr.isEmpty ? outStr : errStr)"
            }
            return outStr.isEmpty ? "OK" : outStr
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    func shell(_ command: String, timeout: TimeInterval = 30) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()

        // Timeout support for long-running commands (e.g., xcodebuild)
        if timeout > 0 {
            let deadline = DispatchTime.now() + timeout
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                process.waitUntilExit()
                semaphore.signal()
            }
            if semaphore.wait(timeout: deadline) == .timedOut {
                process.terminate()
                return nil
            }
        } else {
            process.waitUntilExit()
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func log(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}
