// ProbeBootstrap.swift
// NooberProbe — Swift bootstrap called from C constructor

import Foundation

/// Called from the C constructor in NooberProbeEntry.c.
/// This is the very first Swift code that runs when the dylib is loaded.
@_cdecl("NooberProbeBootstrap")
public func NooberProbeBootstrap() {
    // First-line trace — confirms Swift is reachable from ObjC +load.
    fputs("[NooberProbe] Swift entry reached\n", stderr)
    NSLog("[NooberProbe] Swift entry reached")

    // If the real Noober SDK is already loaded, its CompanionServer is handling
    // communication. Don't start a second server — just bail out.
    if NSClassFromString("Noober.CompanionServer") != nil {
        fputs("[NooberProbe] Real Noober SDK detected — skipping probe.\n", stderr)
        return
    }

    let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
    fputs("[NooberProbe] Injected into \(bundleId)\n", stderr)
    NSLog("[NooberProbe] Injected into %@", bundleId)

    // Delay startup slightly so the app has time to create its UIWindow and
    // populate the view hierarchy. 0.5s is enough for most apps; the probe
    // will still discover windows lazily if something appears later.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        ProbeServer.shared.start()
        fputs("[NooberProbe] Server started for \(bundleId)\n", stderr)
        NSLog("[NooberProbe] Server started for %@", bundleId)
    }
}
