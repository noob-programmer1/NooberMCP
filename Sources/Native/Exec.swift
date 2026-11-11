import Foundation

/// Runs a process directly (no shell, so no quoting/injection issues) with a timeout.
enum Exec {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: Data
        var ok: Bool { status == 0 }
        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
        var stderrString: String { String(decoding: stderr, as: UTF8.self) }
        /// stdout, or stderr when stdout is empty — trimmed, for user-facing messages.
        var message: String {
            let out = stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            let err = stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            if ok { return out.isEmpty ? "OK" : out }
            return err.isEmpty ? (out.isEmpty ? "exit \(status)" : out) : err
        }
    }

    /// Returns nil only if the process could not be started or timed out.
    @discardableResult
    static func run(_ executable: String, _ args: [String], timeout: TimeInterval = 60,
                    env: [String: String]? = nil, stdin: Data? = nil) -> Result? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let env {
            p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = stdin.map { _ in Pipe() }
        if let inPipe { p.standardInput = inPipe } else { p.standardInput = FileHandle.nullDevice }

        // Drain both pipes concurrently so large outputs (screenshots) can't deadlock.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
            return nil
        }
        if let inPipe, let stdin {
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = group.wait(timeout: .now() + 2)
            return nil
        }
        group.wait()
        return Result(status: p.terminationStatus, stdout: outData, stderr: errData)
    }

    static func xcrun(_ args: [String], timeout: TimeInterval = 60, env: [String: String]? = nil) -> Result? {
        run("/usr/bin/xcrun", args, timeout: timeout, env: env)
    }
}
