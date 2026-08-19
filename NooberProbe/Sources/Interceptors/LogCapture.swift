// LogCapture.swift
// NooberProbe — Captures stderr output (print() statements and os_log on Simulator)
//
// Redirects stderr via dup2 into a pipe. Reads the pipe in a background thread,
// creates TransferableLogEntry for each line, and sends it via ProbeServer.

import Foundation

enum ProbeLogCapture {

    private static var hasInstalled = false
    private static var originalStderr: Int32 = -1

    /// Installs the stderr redirect. Call once at probe startup.
    static func install() {
        guard !hasInstalled else { return }
        hasInstalled = true

        let pipe = Pipe()
        let readHandle = pipe.fileHandleForReading

        // Save original stderr so we can still write to it (for our own logs)
        originalStderr = dup(STDERR_FILENO)

        // Redirect stderr to our pipe
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        // Close our copy of the write end — stderr IS the write end now
        // (pipe.fileHandleForWriting is retained by the Pipe object)

        // Read in background
        DispatchQueue.global(qos: .utility).async {
            readLoop(handle: readHandle)
        }

        // Use the original stderr fd for our own logging from now on
        probelogfd = originalStderr

        probelog("Log capture installed")
    }

    /// Writes directly to the original stderr, bypassing the capture.
    /// Used by probelog() so our debug messages don't create infinite loops.
    static var probelogfd: Int32 = STDERR_FILENO

    private static func readLoop(handle: FileHandle) {
        var lineBuffer = Data()

        while true {
            let data = handle.availableData
            if data.isEmpty {
                // EOF — stderr was closed
                break
            }

            // Also write to original stderr so the console still works
            if originalStderr >= 0 {
                data.withUnsafeBytes { bytes in
                    if let baseAddress = bytes.baseAddress {
                        write(originalStderr, baseAddress, bytes.count)
                    }
                }
            }

            // Buffer and split by newlines
            lineBuffer.append(data)

            while let newlineRange = lineBuffer.range(of: Data([0x0A])) { // '\n'
                let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<newlineRange.lowerBound)
                lineBuffer.removeSubrange(lineBuffer.startIndex...newlineRange.lowerBound)

                guard let line = String(data: lineData, encoding: .utf8),
                      !line.isEmpty else { continue }

                // Skip our own log lines to avoid feedback loops
                if line.contains("[NooberProbe]") { continue }

                // Parse the line into a log entry
                let (level, category, message) = parseLine(line)

                let entry = TransferableLogEntry(
                    id: UUID(),
                    timestamp: Date(),
                    level: level,
                    category: category,
                    message: message,
                    file: "",
                    line: 0,
                    screenName: ProbeState.shared.currentScreen
                )

                ProbeState.shared.addLog(entry)

                // Stream to macOS
                if let msg = try? CompanionMessage(type: .eventLog, payload: entry) {
                    DispatchQueue.main.async {
                        ProbeServer.shared.send(msg)
                    }
                }
            }

            // Guard against unbounded buffer growth (lines without newlines)
            if lineBuffer.count > 64 * 1024 {
                lineBuffer.removeAll()
            }
        }
    }

    /// Best-effort parse of a log line to extract level and category.
    ///
    /// Common patterns:
    ///   "[ERROR] NetworkManager: request failed" → ("ERROR", "NetworkManager", "request failed")
    ///   "2024-01-01 12:00:00 [info] something" → ("INFO", "app", "something")
    ///   "plain print statement" → ("DEBUG", "app", "plain print statement")
    private static func parseLine(_ line: String) -> (level: String, category: String, message: String) {
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)

        // Pattern: [LEVEL] Category: message
        if let regex = try? NSRegularExpression(pattern: #"\[(\w+)\]\s*([\w.]+):\s*(.*)"#),
           let match = regex.firstMatch(in: line, range: range), match.numberOfRanges >= 4 {
            let rawLevel = nsLine.substring(with: match.range(at: 1)).uppercased()
            return (normalizeLevel(rawLevel), nsLine.substring(with: match.range(at: 2)), nsLine.substring(with: match.range(at: 3)))
        }

        // Pattern: [LEVEL] message (no category)
        if let regex = try? NSRegularExpression(pattern: #"\[(\w+)\]\s*(.*)"#),
           let match = regex.firstMatch(in: line, range: range), match.numberOfRanges >= 3 {
            let rawLevel = nsLine.substring(with: match.range(at: 1)).uppercased()
            return (normalizeLevel(rawLevel), "app", nsLine.substring(with: match.range(at: 2)))
        }

        return ("DEBUG", "app", line)
    }

    private static func normalizeLevel(_ raw: String) -> String {
        switch raw {
        case "DEBUG", "TRACE", "VERBOSE": return "DEBUG"
        case "INFO", "NOTICE": return "INFO"
        case "WARN", "WARNING": return "WARN"
        case "ERROR", "ERR", "CRITICAL", "FAULT": return "ERROR"
        default: return "DEBUG"
        }
    }
}

// MARK: - Override probelog to use original stderr

/// Replaces the default probelog from NetworkInterceptor.swift when LogCapture
/// is active. Writes to the original stderr fd so our messages still appear
/// in the console but don't get captured as app logs.
///
/// NOTE: This is a separate function that shadows the one in NetworkInterceptor.
/// In practice both files are compiled together, so we rely on the linker
/// picking up the version from whichever file defines it. To avoid duplicate
/// symbol issues, probelog() is defined ONLY in NetworkInterceptor.swift and
/// this file uses it directly.
