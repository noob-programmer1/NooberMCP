import Foundation

/// Physical iOS devices through Xcode's CoreDevice CLI (`devicectl`). No idb, no
/// libimobiledevice, no iproxy: the device's CoreDevice tunnel gives us an IPv6 address that
/// reaches the Noober SDK's TCP listener directly.
enum DeviceBridge {
    struct Device {
        let identifier: String      // CoreDevice UUID (accepted by every devicectl command)
        let udid: String
        let name: String
        let model: String
        let osVersion: String
        let isPhysical: Bool
        let state: String           // booted / shutdown / unavailable …
        let tunnelIP: String?
        let tunnelState: String?
        let transport: String?      // wired / localNetwork / sameMachine

        var oneLine: String {
            var s = "\(name) — \(model), iOS \(osVersion), \(isPhysical ? "physical" : "simulator"), \(state)"
            if isPhysical { s += ", \(transport ?? "?")/tunnel \(tunnelState ?? "?")" }
            return s + "  [\(udid)]"
        }
    }

    /// All devices devicectl knows (physical + simulators on Xcode 27).
    static func list(timeout: TimeInterval = 20) -> [Device] {
        let path = NSTemporaryDirectory() + "noober-devices-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let r = Exec.xcrun(["devicectl", "list", "devices", "-j", path, "-q"], timeout: timeout), r.ok,
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]] else { return [] }
        return devices.compactMap { d in
            let conn = d["connectionProperties"] as? [String: Any] ?? [:]
            let props = d["deviceProperties"] as? [String: Any] ?? [:]
            let hw = d["hardwareProperties"] as? [String: Any] ?? [:]
            guard let id = d["identifier"] as? String else { return nil }
            let reality = hw["reality"] as? String
            let isPhysical = reality == "physical" || (reality == nil && (props["provider"] as? String) == nil)
            let tunnelState = conn["tunnelState"] as? String
            var state = props["bootState"] as? String ?? "unknown"
            if isPhysical, tunnelState != "connected" { state = "unavailable" }
            return Device(
                identifier: id,
                udid: hw["udid"] as? String ?? id,
                name: (props["name"] as? String ?? "?").trimmingCharacters(in: .whitespaces),
                model: hw["marketingName"] as? String ?? hw["productType"] as? String ?? "?",
                osVersion: props["osVersionNumber"] as? String ?? "?",
                isPhysical: isPhysical,
                state: state,
                tunnelIP: conn["tunnelIPAddress"] as? String,
                tunnelState: tunnelState,
                transport: conn["transportType"] as? String)
        }
    }

    static func physical() -> [Device] { list().filter(\.isPhysical) }

    static func find(_ idOrName: String) -> Device? {
        let all = physical()
        return all.first { $0.udid == idOrName || $0.identifier == idOrName }
            ?? all.first { $0.name.localizedCaseInsensitiveContains(idOrName) }
    }

    static func launch(device: String, bundleId: String, terminateExisting: Bool = true,
                       env: [String: String] = [:], args: [String] = []) -> String {
        var a = ["devicectl", "device", "process", "launch", "--device", device]
        if terminateExisting { a.append("--terminate-existing") }
        if !env.isEmpty, let data = try? JSONSerialization.data(withJSONObject: env),
           let s = String(data: data, encoding: .utf8) {
            a += ["--environment-variables", s]
        }
        a.append(bundleId)
        a += args
        return Exec.xcrun(a, timeout: 60)?.message ?? "devicectl launch timed out"
    }

    static func terminate(device: String, bundleId: String) -> String {
        // devicectl terminates by pid; resolve it from the running-process list.
        let path = NSTemporaryDirectory() + "noober-procs-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let r = Exec.xcrun(["devicectl", "device", "info", "processes", "--device", device, "-j", path, "-q"], timeout: 30), r.ok,
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let procs = (json["result"] as? [String: Any])?["runningProcesses"] as? [[String: Any]] else {
            return "Could not list processes on device"
        }
        let appPathHint = "/\(bundleId)"
        let match = procs.first { p in
            (p["bundleIdentifier"] as? String) == bundleId ||
            ((p["executable"] as? String)?.contains(appPathHint) ?? false)
        }
        guard let pid = match?["processIdentifier"] as? Int else { return "\(bundleId) is not running" }
        return Exec.xcrun(["devicectl", "device", "process", "terminate", "--device", device, "--pid", "\(pid)"], timeout: 30)?.message ?? "timed out"
    }

    static func install(device: String, appPath: String) -> String {
        Exec.xcrun(["devicectl", "device", "install", "app", "--device", device, appPath], timeout: 300)?.message ?? "install timed out"
    }

    static func openURL(device: String, url: String) -> String {
        Exec.xcrun(["devicectl", "device", "process", "openURL", "--device", device, url], timeout: 30)?.message ?? "timed out"
    }

    static func orientation(device: String, value: String) -> String {
        Exec.xcrun(["devicectl", "device", "orientation", "set", "--device", device, value], timeout: 30)?.message ?? "timed out"
    }

    static func appearance(device: String, style: String) -> String {
        Exec.xcrun(["devicectl", "device", "settings", "appearance", "--device", device, "--mode", style], timeout: 30)?.message ?? "timed out"
    }

    static func location(device: String, lat: Double, lon: Double) -> String {
        Exec.xcrun(["devicectl", "device", "simulate", "location", "coordinate", "--device", device,
                    "--latitude", "\(lat)", "--longitude", "\(lon)"], timeout: 30)?.message ?? "timed out"
    }
}
