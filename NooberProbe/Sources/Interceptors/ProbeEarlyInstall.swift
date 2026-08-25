// ProbeEarlyInstall.swift
// NooberProbe — interceptors that must be live before the app's own code runs.

import Foundation

/// Apps fire their session, config, and feature-flag requests during launch.
/// The probe used to install every interceptor inside `ProbeServer.start()`,
/// which is deferred half a second to wait for a UIWindow — so those launch
/// requests were never captured and the network log looked empty.
///
/// Everything here is pure registration and swizzling with no UIKit dependency,
/// so it runs synchronously from the dylib's `+load`, before `main()`.
enum ProbeEarlyInstall {

    nonisolated(unsafe) private static var installed = false

    static func run() {
        guard !installed else { return }
        installed = true

        ProbeNetworkInterceptor.install()
        ProbeLogCapture.install()
        ProbeWebViewConsoleCapture.install()
        ProbeCrashHandler.install(bundleId: Bundle.main.bundleIdentifier ?? "unknown")

        fputs("[NooberProbe] Early interceptors installed (pre-main)\n", stderr)
    }
}
