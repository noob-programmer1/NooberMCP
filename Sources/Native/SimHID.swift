import Foundation
import XPC
import ObjectiveC
import CoreGraphics

/// Native simulator input — replaces AXe.
///
/// Two transports, chosen per device:
///  - **dtuhid** (Xcode 27+): plain-XPC messages to the guest `dtuhidd` daemon
///    (`com.apple.coredevice.feature.remote.hid.digitizer`). Device Hub routes all input
///    through it, and while it is active backboardd *drops* legacy Indigo events silently —
///    the reason AXe/idb taps stopped working on Xcode 27.
///  - **indigo** (Xcode 26 and older): `IndigoHIDMessageFor*` + `SimDeviceLegacyHIDClient`.
///
/// Wire formats follow meta/idb (MIT) `FBSimulatorControl/HID` and EvanBacon/serve-sim.
/// Connections are kept warm per device, so an input event costs well under a millisecond.
protocol SimHIDTransport: AnyObject {
    var name: String { get }
    /// phase: 0 = start, 1 = move, 2 = end. x/y normalized 0...1.
    func touch(phase: Int, x: Double, y: Double, x2: Double?, y2: Double?) throws
    /// USB HID keyboard usage (page 0x07).
    func key(usage: UInt32, down: Bool) throws
    func button(_ button: SimButton, down: Bool) throws
    /// Wait until previously sent events have reached the guest.
    func flush()
    var isValid: Bool { get }
}

enum SimButton: String, CaseIterable {
    case home, lock, side, siri, volumeUp = "volume_up", volumeDown = "volume_down", playPause = "play_pause"

    /// HID Consumer page usage (dtuhid).
    var consumerUsage: (page: UInt64, code: UInt64) {
        switch self {
        case .home: return (0x0C, 0x40)
        case .lock, .side: return (0x0C, 0x30)
        case .siri: return (0x0C, 0xCF)
        case .volumeUp: return (0x0C, 0xE9)
        case .volumeDown: return (0x0C, 0xEA)
        case .playPause: return (0x0C, 0xCD)
        }
    }

    /// Legacy Indigo `ButtonEventSource`, where one exists.
    var indigoSource: Int32? {
        switch self {
        case .home: return 0x0
        case .lock: return 0x1
        case .side: return 0xbb8
        case .siri: return 0x400002
        default: return nil
        }
    }

    init?(loose: String) {
        let k = loose.lowercased().replacingOccurrences(of: "-", with: "_")
        switch k {
        case "home": self = .home
        case "lock", "power": self = .lock
        case "side", "side_button": self = .side
        case "siri": self = .siri
        case "volume_up", "volumeup": self = .volumeUp
        case "volume_down", "volumedown": self = .volumeDown
        case "play_pause", "playpause": self = .playPause
        default: return nil
        }
    }
}

struct SimHIDError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - dtuhid (Xcode 27+)

final class DTUHIDTransport: SimHIDTransport {
    static let serviceName = "com.apple.coredevice.feature.remote.hid.digitizer"
    let name = "dtuhid"
    private let connection: xpc_connection_t
    private let queue = DispatchQueue(label: "noober.dtuhid", qos: .userInteractive)
    private let stateLock = NSLock()
    private var invalidated = false
    private var pendingSends = 0

    var isValid: Bool { stateLock.withLock { !invalidated } }

    private init(connection: xpc_connection_t) {
        self.connection = connection
    }

    /// Connects and proves a live daemon answers (a send to a dead one succeeds silently).
    static func connect(device: SimDeviceRef, attempts: Int = 3) throws -> DTUHIDTransport {
        var lastError = "unknown"
        for attempt in 1...attempts {
            do {
                let t = try connectOnce(device: device)
                if try t.ping(timeout: 4) { return t }
                lastError = "dtuhidd did not answer"
            } catch {
                lastError = "\(error)"
                if lastError.contains("not supported") { throw error }
            }
            if attempt < attempts { Thread.sleep(forTimeInterval: 1.5) }
        }
        throw SimHIDError("dtuhid unavailable: \(lastError)")
    }

    private typealias EndpointFromPort = @convention(c) (mach_port_t, UInt64, UInt64) -> Unmanaged<AnyObject>?
    private typealias ConnFromEndpoint = @convention(c) (xpc_object_t) -> Unmanaged<AnyObject>?
    private typealias EnableSim2Host = @convention(c) (xpc_connection_t) -> Void

    private static func connectOnce(device: SimDeviceRef) throws -> DTUHIDTransport {
        guard device.isBooted else { throw SimHIDError("simulator \(device.udid) is not booted (\(device.stateString))") }
        let looked = device.lookup(serviceName)
        guard looked.port != MACH_PORT_NULL else {
            if let e = looked.error, e.domain == "com.apple.CoreSimulator.SimError", e.code == 405 {
                throw SimHIDError("dtuhid service not supported by this runtime")
            }
            throw SimHIDError("lookup \(serviceName) failed: \(looked.error?.localizedDescription ?? "no port")")
        }
        let h = dlopen(nil, RTLD_NOW)
        guard let a = dlsym(h, "xpc_endpoint_create_mach_port_4sim"),
              let b = dlsym(h, "xpc_connection_create_from_endpoint"),
              let c = dlsym(h, "xpc_connection_enable_sim2host_4sim") else {
            throw SimHIDError("sim XPC symbols unavailable")
        }
        guard let endpoint = unsafeBitCast(a, to: EndpointFromPort.self)(looked.port, 0, 0)?.takeRetainedValue() as? xpc_object_t,
              let conn = unsafeBitCast(b, to: ConnFromEndpoint.self)(endpoint)?.takeRetainedValue() as? xpc_connection_t else {
            throw SimHIDError("could not create XPC connection to dtuhidd")
        }
        unsafeBitCast(c, to: EnableSim2Host.self)(conn)
        let t = DTUHIDTransport(connection: conn)
        xpc_connection_set_target_queue(conn, t.queue)
        xpc_connection_set_event_handler(conn) { [weak t] event in
            if xpc_get_type(event) == XPC_TYPE_ERROR, xpc_equal(event, XPC_ERROR_CONNECTION_INVALID) {
                t?.stateLock.withLock { t?.invalidated = true }
            }
        }
        xpc_connection_activate(conn)
        return t
    }

    /// Barrier round-trip using keyboard usage 0 ("no event"), invisible to the guest.
    func ping(timeout: TimeInterval) throws -> Bool {
        let msg = envelope("IndigoKeyboardButtonEvent", payload: keyPayload(usage: 0, down: false), barrier: true)
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        xpc_connection_send_message_with_reply(connection, msg, queue) { reply in
            ok = xpc_get_type(reply) == XPC_TYPE_DICTIONARY
            sem.signal()
        }
        guard sem.wait(timeout: .now() + timeout) == .success else { return false }
        return ok
    }

    func touch(phase: Int, x: Double, y: Double, x2: Double?, y2: Double?) throws {
        let p = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(p, "pointOne", point(x, y))
        if let x2, let y2 { xpc_dictionary_set_value(p, "pointTwo", point(x2, y2)) }
        xpc_dictionary_set_uint64(p, "eventType", UInt64(phase))
        xpc_dictionary_set_uint64(p, "edge", 0)
        xpc_dictionary_set_uint64(p, "target", 0)
        try send(envelope("IndigoDigitizerEvent", payload: p))
    }

    func key(usage: UInt32, down: Bool) throws {
        try send(envelope("IndigoKeyboardButtonEvent", payload: keyPayload(usage: UInt64(usage), down: down)))
    }

    func button(_ button: SimButton, down: Bool) throws {
        let u = button.consumerUsage
        let p = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(p, "usagePage", u.page)
        xpc_dictionary_set_uint64(p, "usageCode", u.code)
        xpc_dictionary_set_uint64(p, "state", down ? 1 : 2)
        try send(envelope("IndigoButtonEvent", payload: p))
    }

    func flush() {
        let sem = DispatchSemaphore(value: 0)
        xpc_connection_send_barrier(connection) { sem.signal() }
        _ = sem.wait(timeout: .now() + 2)
        // Barrier = handed to the kernel; give the daemon a beat to dispatch into the guest.
        let had = stateLock.withLock { () -> Bool in let h = pendingSends > 0; pendingSends = 0; return h }
        if had { Thread.sleep(forTimeInterval: 0.03) }
    }

    // MARK: helpers

    private func send(_ msg: xpc_object_t) throws {
        guard isValid else { throw SimHIDError("dtuhid connection invalidated") }
        xpc_connection_send_message(connection, msg)
        stateLock.withLock { pendingSends += 1 }
    }

    private func envelope(_ type: String, payload: xpc_object_t, barrier: Bool = false) -> xpc_object_t {
        let m = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(m, "messageType", type)
        xpc_dictionary_set_bool(m, "isBarrier", barrier)
        xpc_dictionary_set_string(m, "featureIdentifier", Self.serviceName)
        xpc_dictionary_set_value(m, "payload", payload)
        return m
    }

    private func keyPayload(usage: UInt64, down: Bool) -> xpc_object_t {
        let p = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(p, "usageCode", usage)
        xpc_dictionary_set_uint64(p, "state", down ? 1 : 2)
        return p
    }

    private func point(_ x: Double, _ y: Double) -> xpc_object_t {
        let pt = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_double(pt, "x", x)
        xpc_dictionary_set_double(pt, "y", y)
        return pt
    }

    deinit { xpc_connection_cancel(connection) }
}

// MARK: - Indigo (Xcode 26 and older)

final class IndigoTransport: SimHIDTransport {
    let name = "indigo"
    private let client: NSObject
    private let sendSel = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
    private let queue = DispatchQueue(label: "noober.indigo", qos: .userInteractive)

    // IndigoHIDMessageForMouseNSEvent(CGPoint*, CGPoint*, target, NSEventType, NSSize, edge)
    private typealias MouseFn = @convention(c) (UnsafePointer<CGPoint>, UnsafePointer<CGPoint>?, UInt32, Int32, CGFloat, CGFloat, UInt32) -> UnsafeMutableRawPointer?
    private typealias ButtonFn = @convention(c) (Int32, Int32, Int32) -> UnsafeMutableRawPointer?
    private typealias KeyFn = @convention(c) (UInt32, UInt32) -> UnsafeMutableRawPointer?
    private typealias SendFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, ObjCBool, AnyObject?, AnyObject?) -> Void
    private let mouse: MouseFn
    private let buttonFn: ButtonFn?
    private let keyFn: KeyFn?

    var isValid: Bool { true }

    init(device: SimDeviceRef) throws {
        let h = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let m = dlsym(h, "IndigoHIDMessageForMouseNSEvent") else { throw SimHIDError("SimulatorKit Indigo symbols not loaded") }
        mouse = unsafeBitCast(m, to: MouseFn.self)
        buttonFn = dlsym(h, "IndigoHIDMessageForButton").map { unsafeBitCast($0, to: ButtonFn.self) }
        keyFn = dlsym(h, "IndigoHIDMessageForKeyboardArbitrary").map { unsafeBitCast($0, to: KeyFn.self) }
        guard let cls = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") ?? NSClassFromString("SimDeviceLegacyHIDClient") else {
            throw SimHIDError("SimDeviceLegacyHIDClient not found")
        }
        typealias InitFn = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        let sel = NSSelectorFromString("initWithDevice:error:")
        var error: NSError?
        let alloc = (cls as AnyObject).perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
        guard let c = unsafeBitCast(class_getMethodImplementation(cls, sel), to: InitFn.self)(alloc, sel, device.raw, &error) as? NSObject else {
            throw SimHIDError("legacy HID client: \(error?.localizedDescription ?? "init failed")")
        }
        client = c
    }

    private func send(_ msg: UnsafeMutableRawPointer?) throws {
        guard let msg else { throw SimHIDError("Indigo message builder returned nil") }
        unsafeBitCast(class_getMethodImplementation(object_getClass(client), sendSel), to: SendFn.self)(client, sendSel, msg, true, nil, nil)
    }

    func touch(phase: Int, x: Double, y: Double, x2: Double?, y2: Double?) throws {
        var p1 = CGPoint(x: x, y: y)
        // NSEventType: 1 = down (also used for moves — the builder rejects dragged), 2 = up.
        let type: Int32 = phase == 2 ? 2 : 1
        if let x2, let y2 {
            var p2 = CGPoint(x: x2, y: y2)
            try send(mouse(&p1, &p2, 0x32, type, 1, 1, 0))
        } else {
            try send(mouse(&p1, nil, 0x32, type, 1, 1, 0))
        }
    }

    func key(usage: UInt32, down: Bool) throws {
        guard let keyFn else { throw SimHIDError("keyboard injection unavailable") }
        try send(keyFn(usage, down ? 1 : 2))
    }

    func button(_ button: SimButton, down: Bool) throws {
        guard let buttonFn, let source = button.indigoSource else {
            throw SimHIDError("button \(button.rawValue) not supported on the legacy transport")
        }
        try send(buttonFn(source, down ? 1 : 2, 0x33))
    }

    func flush() { Thread.sleep(forTimeInterval: 0.02) }
}

// MARK: - High-level input

/// Gesture vocabulary on top of a transport. Coordinates are in **points**.
final class SimInput {
    let device: SimDeviceRef
    private var transport: SimHIDTransport?
    private let lock = NSLock()

    init(device: SimDeviceRef) { self.device = device }

    /// Selection: `NOOBER_HID_TRANSPORT=indigo|dtuhid` forces one; otherwise dtuhid with Indigo fallback.
    func ensureTransport() throws -> SimHIDTransport {
        lock.lock(); defer { lock.unlock() }
        if let t = transport, t.isValid { return t }
        let forced = ProcessInfo.processInfo.environment["NOOBER_HID_TRANSPORT"]?.lowercased()
        if forced == "indigo" {
            transport = try IndigoTransport(device: device)
            return transport!
        }
        do {
            let t = try DTUHIDTransport.connect(device: device)
            transport = t
            nlog("[hid] \(device.name): dtuhid transport ready")
            return t
        } catch {
            if forced == "dtuhid" { throw error }
            nlog("[hid] dtuhid unavailable (\(error)) — falling back to Indigo")
            let t = try IndigoTransport(device: device)
            transport = t
            return t
        }
    }

    var transportName: String { lock.withLock { transport?.name ?? "not connected" } }

    func reset() { lock.withLock { transport = nil } }

    private func norm(_ x: Double, _ y: Double) -> (Double, Double) {
        let s = device.screenPoints
        return (min(max(x / Double(s.width), 0), 1), min(max(y / Double(s.height), 0), 1))
    }

    /// Runs `body`, reconnecting once if the transport died underneath us (sim reboot, daemon restart).
    private func withTransport(_ body: (SimHIDTransport) throws -> Void) throws {
        do {
            try body(try ensureTransport())
        } catch let e as SimHIDError where e.description.contains("invalidated") {
            reset()
            try body(try ensureTransport())
        }
    }

    func tap(x: Double, y: Double, hold: Double = 0.05) throws {
        let (nx, ny) = norm(x, y)
        try withTransport { t in
            try t.touch(phase: 0, x: nx, y: ny, x2: nil, y2: nil)
            Thread.sleep(forTimeInterval: max(hold, 0.03))
            try t.touch(phase: 2, x: nx, y: ny, x2: nil, y2: nil)
            t.flush()
        }
    }

    func doubleTap(x: Double, y: Double) throws {
        try tap(x: x, y: y, hold: 0.03)
        Thread.sleep(forTimeInterval: 0.08)
        try tap(x: x, y: y, hold: 0.03)
    }

    /// Straight-line drag with ~60Hz intermediate samples.
    func swipe(from: CGPoint, to: CGPoint, duration: Double = 0.3, holdFirst: Double = 0) throws {
        let steps = max(4, Int(duration * 60))
        let dt = duration / Double(steps)
        try withTransport { t in
            let (sx, sy) = norm(from.x, from.y)
            try t.touch(phase: 0, x: sx, y: sy, x2: nil, y2: nil)
            if holdFirst > 0 { Thread.sleep(forTimeInterval: holdFirst) }
            for i in 1...steps {
                let f = Double(i) / Double(steps)
                // ease-out so scroll views see a natural deceleration
                let e = 1 - pow(1 - f, 2)
                let (x, y) = norm(from.x + (to.x - from.x) * e, from.y + (to.y - from.y) * e)
                try t.touch(phase: 1, x: x, y: y, x2: nil, y2: nil)
                Thread.sleep(forTimeInterval: dt)
            }
            let (ex, ey) = norm(to.x, to.y)
            try t.touch(phase: 2, x: ex, y: ey, x2: nil, y2: nil)
            t.flush()
        }
    }

    /// Two-finger pinch around a centre. scale > 1 zooms in.
    func pinch(center: CGPoint, scale: Double, duration: Double = 0.4) throws {
        let start = 60.0, end = start * scale
        let steps = max(6, Int(duration * 60))
        try withTransport { t in
            func pts(_ r: Double) -> (Double, Double, Double, Double) {
                let a = norm(center.x - r, center.y), b = norm(center.x + r, center.y)
                return (a.0, a.1, b.0, b.1)
            }
            var p = pts(start)
            try t.touch(phase: 0, x: p.0, y: p.1, x2: p.2, y2: p.3)
            for i in 1...steps {
                p = pts(start + (end - start) * Double(i) / Double(steps))
                try t.touch(phase: 1, x: p.0, y: p.1, x2: p.2, y2: p.3)
                Thread.sleep(forTimeInterval: duration / Double(steps))
            }
            try t.touch(phase: 2, x: p.0, y: p.1, x2: p.2, y2: p.3)
            t.flush()
        }
    }

    func press(_ button: SimButton, duration: Double = 0.1) throws {
        try withTransport { t in
            try t.button(button, down: true)
            Thread.sleep(forTimeInterval: duration)
            try t.button(button, down: false)
            t.flush()
        }
    }

    /// Types via HID keyboard events (US layout). Returns characters that have no key mapping.
    @discardableResult
    func type(_ text: String) throws -> String {
        var unmapped = ""
        try withTransport { t in
            for ch in text {
                guard let (usage, shift) = HIDKeymap.usage(for: ch) else { unmapped.append(ch); continue }
                if shift { try t.key(usage: HIDKeymap.leftShift, down: true) }
                try t.key(usage: usage, down: true)
                try t.key(usage: usage, down: false)
                if shift { try t.key(usage: HIDKeymap.leftShift, down: false) }
            }
            t.flush()
        }
        return unmapped
    }

    func key(usage: UInt32, modifiers: [UInt32] = []) throws {
        try withTransport { t in
            for m in modifiers { try t.key(usage: m, down: true) }
            try t.key(usage: usage, down: true)
            try t.key(usage: usage, down: false)
            for m in modifiers.reversed() { try t.key(usage: m, down: false) }
            t.flush()
        }
    }
}

/// US-layout ASCII → USB HID usage (page 0x07).
enum HIDKeymap {
    static let leftShift: UInt32 = 0xE1
    static let leftGUI: UInt32 = 0xE3
    static let named: [String: UInt32] = [
        "return": 0x28, "enter": 0x28, "escape": 0x29, "esc": 0x29, "backspace": 0x2A, "delete": 0x2A,
        "tab": 0x2B, "space": 0x2C, "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52,
        "forward_delete": 0x4C, "home": 0x4A, "end": 0x4D, "page_up": 0x4B, "page_down": 0x4E,
    ]

    static func usage(for ch: Character) -> (UInt32, Bool)? {
        guard let a = ch.asciiValue else { return nil }
        switch a {
        case 0x61...0x7A: return (UInt32(a - 0x61) + 0x04, false)          // a-z
        case 0x41...0x5A: return (UInt32(a - 0x41) + 0x04, true)           // A-Z
        case 0x31...0x39: return (UInt32(a - 0x31) + 0x1E, false)          // 1-9
        case 0x30: return (0x27, false)                                     // 0
        case 0x0A, 0x0D: return (0x28, false)
        case 0x09: return (0x2B, false)
        case 0x20: return (0x2C, false)
        default: break
        }
        let table: [Character: (UInt32, Bool)] = [
            "-": (0x2D, false), "_": (0x2D, true), "=": (0x2E, false), "+": (0x2E, true),
            "[": (0x2F, false), "{": (0x2F, true), "]": (0x30, false), "}": (0x30, true),
            "\\": (0x31, false), "|": (0x31, true), ";": (0x33, false), ":": (0x33, true),
            "'": (0x34, false), "\"": (0x34, true), "`": (0x35, false), "~": (0x35, true),
            ",": (0x36, false), "<": (0x36, true), ".": (0x37, false), ">": (0x37, true),
            "/": (0x38, false), "?": (0x38, true), "!": (0x1E, true), "@": (0x1F, true),
            "#": (0x20, true), "$": (0x21, true), "%": (0x22, true), "^": (0x23, true),
            "&": (0x24, true), "*": (0x25, true), "(": (0x26, true), ")": (0x27, true),
        ]
        return table[ch]
    }
}
