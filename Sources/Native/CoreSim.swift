import Foundation
import ObjectiveC
import CoreGraphics

/// In-process access to CoreSimulator — no `simctl` subprocess, no AXe, no idb.
///
/// The private frameworks are dlopen'd from the active Xcode rather than linked, so one
/// binary works across Xcode versions. Xcode 27 moved SimulatorKit from
/// `Developer/Library/PrivateFrameworks` to `Contents/SharedFrameworks`, which is the
/// change that broke AXe/idb; both locations are tried here.
enum CoreSim {

    /// Active developer dir: `DEVELOPER_DIR`, else `xcode-select -p`, else the default Xcode.
    static let developerDir: String = {
        if let env = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !env.isEmpty { return env }
        if let out = Exec.run("/usr/bin/xcode-select", ["-p"], timeout: 5)?.stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty {
            return out
        }
        return "/Applications/Xcode.app/Contents/Developer"
    }()

    /// Loads CoreSimulator + SimulatorKit + AccessibilityPlatformTranslation once.
    static let loaded: Bool = {
        let dev = developerDir
        let core = [
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
            "\(dev)/Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
        ]
        let kit = [
            "\(dev)/../SharedFrameworks/SimulatorKit.framework/SimulatorKit",        // Xcode 27+
            "\(dev)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",  // Xcode 26 and older
        ]
        let coreOK = core.contains { dlopen($0, RTLD_NOW) != nil }
        let kitOK = kit.contains { dlopen($0, RTLD_NOW) != nil }
        _ = dlopen("/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation", RTLD_NOW)
        if !coreOK { nlog("[coresim] CoreSimulator.framework not loadable") }
        if !kitOK { nlog("[coresim] SimulatorKit.framework not loadable — legacy HID path unavailable") }
        return coreOK
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedSet: NSObject?

    /// The default device set (`~/Library/Developer/CoreSimulator/Devices`).
    static func deviceSet() -> NSObject? {
        lock.lock(); defer { lock.unlock() }
        if let cachedSet { return cachedSet }
        guard loaded, let ctxClass = NSClassFromString("SimServiceContext") else { return nil }
        typealias CtxFn = @convention(c) (AnyClass, Selector, NSString, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        typealias SetFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        var error: NSError?
        let ctxSel = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard let ctxImp = method_getImplementation(class_getClassMethod(ctxClass, ctxSel)!) as IMP?,
              let ctx = unsafeBitCast(ctxImp, to: CtxFn.self)(ctxClass, ctxSel, developerDir as NSString, &error) else {
            nlog("[coresim] no service context: \(error?.localizedDescription ?? "?")")
            return nil
        }
        let setSel = NSSelectorFromString("defaultDeviceSetWithError:")
        guard let set = unsafeBitCast(class_getMethodImplementation(object_getClass(ctx), setSel), to: SetFn.self)(ctx, setSel, &error) as? NSObject else {
            nlog("[coresim] no device set: \(error?.localizedDescription ?? "?")")
            return nil
        }
        cachedSet = set
        return set
    }

    static func device(udid: String) -> SimDeviceRef? {
        guard let set = deviceSet(),
              let byUDID = set.value(forKey: "devicesByUDID") as? [AnyHashable: AnyObject] else { return nil }
        for (key, value) in byUDID where "\(key)".caseInsensitiveCompare(udid) == .orderedSame {
            if let obj = value as? NSObject { return SimDeviceRef(obj) }
        }
        return nil
    }

    static func allDevices() -> [SimDeviceRef] {
        guard let set = deviceSet(), let devices = set.value(forKey: "devices") as? [NSObject] else { return [] }
        return devices.map(SimDeviceRef.init)
    }

    /// First booted iOS-family device, preferring the most recently booted.
    static func firstBooted() -> SimDeviceRef? {
        allDevices().first { $0.isBooted && $0.hasTouchscreen }
    }
}

/// A thin, typed wrapper over a `SimDevice` instance.
struct SimDeviceRef {
    let raw: NSObject
    init(_ raw: NSObject) { self.raw = raw }

    var udid: String { (raw.value(forKey: "UDID") as? NSUUID)?.uuidString ?? "\(raw.value(forKey: "UDID") ?? "")" }
    var name: String { raw.value(forKey: "name") as? String ?? "?" }
    var stateString: String { raw.value(forKey: "stateString") as? String ?? "?" }
    /// SimDeviceState: 0 creating, 1 shutdown, 2 booting, 3 booted, 4 shutting down.
    var state: Int { (raw.value(forKey: "state") as? NSNumber)?.intValue ?? 0 }
    var isBooted: Bool { state == 3 }

    private var deviceType: NSObject? { raw.value(forKey: "deviceType") as? NSObject }

    var runtimeName: String {
        ((raw.value(forKey: "runtime") as? NSObject)?.value(forKey: "name") as? String) ?? "?"
    }

    var deviceTypeIdentifier: String { raw.value(forKey: "deviceTypeIdentifier") as? String ?? "" }

    var hasTouchscreen: Bool {
        let id = deviceTypeIdentifier
        return id.contains("iPhone") || id.contains("iPad") || id.contains("iPod")
    }

    /// Main screen size in **pixels** and its scale, from the device type.
    var screenPixels: CGSize {
        if let v = deviceType?.value(forKey: "mainScreenSize") as? NSValue { return v.sizeValue }
        return CGSize(width: 1170, height: 2532)
    }

    var screenScale: CGFloat {
        if let n = deviceType?.value(forKey: "mainScreenScale") as? NSNumber, n.doubleValue > 0 { return CGFloat(n.doubleValue) }
        return 3
    }

    /// Main screen size in **points** — the coordinate space every tool speaks.
    var screenPoints: CGSize {
        let px = screenPixels, s = screenScale
        return CGSize(width: px.width / s, height: px.height / s)
    }

    /// Look up a launchd service inside the guest. Returns MACH_PORT_NULL on failure.
    func lookup(_ service: String) -> (port: mach_port_t, error: NSError?) {
        typealias Fn = @convention(c) (AnyObject, Selector, NSString, UnsafeMutablePointer<NSError?>?) -> mach_port_t
        let sel = NSSelectorFromString("lookup:error:")
        guard raw.responds(to: sel) else { return (mach_port_t(MACH_PORT_NULL), nil) }
        var error: NSError?
        let port = unsafeBitCast(class_getMethodImplementation(object_getClass(raw), sel), to: Fn.self)(raw, sel, service as NSString, &error)
        return (port, error)
    }
}

func nlog(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}
