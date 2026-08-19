// CrashHandler.swift
// NooberProbe — Catches NSExceptions and POSIX signals, writes crash report to /tmp

import Foundation

// Global C-compatible handlers (can't be closures — C function pointers required)
private func probeExceptionHandler(_ exception: NSException) {
    ProbeCrashHandler.writeCrash(
        type: "NSException",
        name: exception.name.rawValue,
        reason: exception.reason ?? "Unknown",
        stack: exception.callStackSymbols
    )
}

private func probeSignalHandler(_ sig: Int32) {
    let name: String
    switch sig {
    case SIGABRT: name = "SIGABRT"
    case SIGSEGV: name = "SIGSEGV"
    case SIGBUS:  name = "SIGBUS"
    case SIGFPE:  name = "SIGFPE"
    case SIGILL:  name = "SIGILL"
    default:      name = "SIG\(sig)"
    }
    ProbeCrashHandler.handleSignal(name)
}

enum ProbeCrashHandler {

    private static var installed = false
    private static let crashDir = "/tmp"

    static func install(bundleId: String) {
        guard !installed else { return }
        installed = true

        // Save bundle ID for crash file naming
        _bundleId = bundleId

        // ObjC exception handler
        NSSetUncaughtExceptionHandler(probeExceptionHandler)

        // POSIX signal handlers — must be plain C functions (no closures)
        signal(SIGABRT, probeSignalHandler)
        signal(SIGSEGV, probeSignalHandler)
        signal(SIGBUS, probeSignalHandler)
        signal(SIGFPE, probeSignalHandler)
        signal(SIGILL, probeSignalHandler)

        fputs("[NooberProbe] Crash handler installed for \(bundleId)\n", stderr)
    }

    private static var _bundleId = "unknown"

    static func handleSignal(_ name: String) {
        let stack = Thread.callStackSymbols
        writeCrash(type: "Signal", name: name, reason: "Process received \(name)", stack: stack)
    }

    static func writeCrash(type: String, name: String, reason: String, stack: [String]) {
        let screen = ProbeState.shared.currentScreen

        // Get last network request for context
        let lastRequest: String
        let state = ProbeState.shared
        if let last = state.recentRequests().last {
            lastRequest = "\(last.method) \(last.url) → \(last.statusCode ?? 0)"
        } else {
            lastRequest = "none"
        }

        let crash: [String: Any] = [
            "type": type,
            "name": name,
            "reason": reason,
            "stack": stack,
            "screen": screen,
            "lastRequest": lastRequest,
            "bundleId": _bundleId,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        // Write synchronously — we may be dying
        let path = "\(crashDir)/noober_crash_\(_bundleId.replacingOccurrences(of: ".", with: "_")).json"
        if let data = try? JSONSerialization.data(withJSONObject: crash, options: .prettyPrinted) {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    /// Read the last crash log (called from MCP side, not from inside the crashed process)
    static func readCrashLog(bundleId: String) -> String? {
        let path = "\(crashDir)/noober_crash_\(bundleId.replacingOccurrences(of: ".", with: "_")).json"
        guard let data = FileManager.default.contents(atPath: path),
              let crash = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

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
}
