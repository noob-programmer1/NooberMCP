import Foundation
import AppKit
import ObjectiveC

/// Reads the simulator's accessibility tree in-process via AccessibilityPlatformTranslation's
/// `AXPTranslator`, bridged to `SimDevice.sendAccessibilityRequestAsync` — the same channel
/// Accessibility Inspector uses. Works for any app (and SpringBoard / system alerts), with no
/// SDK and no probe. Approach after meta/idb (MIT) and EvanBacon/serve-sim (Apache-2.0).
final class SimAccessibility: NSObject {
    static let shared = SimAccessibility()

    struct Element {
        var role: String
        var label: String?
        var value: String?
        var identifier: String?
        var frame: CGRect
        var enabled: Bool
        var children: [Element]

        var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
        var isInteresting: Bool {
            label != nil || value != nil || identifier != nil ||
            ["Button", "TextField", "SecureTextField", "Switch", "Slider", "Link", "Cell", "SearchField", "TextView", "Tab", "Image"].contains(role)
        }
    }

    private let queue = DispatchQueue(label: "noober.ax", qos: .userInitiated)
    private let lock = NSLock()
    private var tokenToDevice: [String: NSObject] = [:]
    private var translator: NSObject?
    private static let maxElements = 800

    private func ensureTranslator() throws -> NSObject {
        lock.lock(); defer { lock.unlock() }
        if let translator { return translator }
        guard CoreSim.loaded, let cls = NSClassFromString("AXPTranslator") as? NSObject.Type,
              let t = cls.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject else {
            throw SimHIDError("AXPTranslator unavailable")
        }
        t.setValue(self, forKey: "bridgeTokenDelegate")
        t.setValue(true, forKey: "supportsDelegateTokens")
        if t.responds(to: NSSelectorFromString("setAccessibilityEnabled:")) { t.setValue(true, forKey: "accessibilityEnabled") }
        translator = t
        return t
    }

    /// Full tree of the frontmost application.
    func tree(device: SimDeviceRef) throws -> Element {
        let translator = try ensureTranslator()
        let token = UUID().uuidString
        lock.withLock { tokenToDevice[token] = device.raw }
        defer { lock.withLock { _ = tokenToDevice.removeValue(forKey: token) } }

        typealias FrontFn = @convention(c) (AnyObject, Selector, UInt32, NSString) -> AnyObject?
        typealias MacFn = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
        let frontSel = NSSelectorFromString("frontmostApplicationWithDisplayId:bridgeDelegateToken:")
        let macSel = NSSelectorFromString("macPlatformElementFromTranslation:")
        guard let fImp = translator.method(for: frontSel), let mImp = translator.method(for: macSel) else {
            throw SimHIDError("AXPTranslator API changed")
        }
        guard let translation = unsafeBitCast(fImp, to: FrontFn.self)(translator, frontSel, 0, token as NSString) as? NSObject else {
            throw SimHIDError("no frontmost application (is the simulator booted and unlocked?)")
        }
        translation.setValue(token, forKey: "bridgeDelegateToken")
        guard let root = unsafeBitCast(mImp, to: MacFn.self)(translator, macSel, translation) as? NSObject else {
            throw SimHIDError("could not translate frontmost application")
        }
        var budget = Self.maxElements
        var visited = Set<ObjectIdentifier>()
        guard var el = serialize(root, token: token, budget: &budget, visited: &visited, depth: 0) else {
            throw SimHIDError("empty accessibility tree")
        }
        // The frontmost-app tree misses SpringBoard alerts, remote views and some SwiftUI content.
        // Probe a point grid for anything not already covered (after serve-sim's discovery pass).
        if gridProbe {
            let screen = device.screenPoints
            let extra = probeGrid(translator: translator, token: token, screen: screen, known: el, budget: &budget, visited: &visited)
            if !extra.isEmpty { el.children.append(contentsOf: extra) }
        }
        return el
    }

    /// Set NOOBER_AX_GRID=0 to disable grid discovery.
    private let gridProbe = ProcessInfo.processInfo.environment["NOOBER_AX_GRID"] != "0"

    private func probeGrid(translator: NSObject, token: String, screen: CGSize, known: Element,
                           budget: inout Int, visited: inout Set<ObjectIdentifier>) -> [Element] {
        typealias PointFn = @convention(c) (AnyObject, Selector, CGPoint, UInt32, NSString) -> AnyObject?
        typealias MacFn = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
        let pointSel = NSSelectorFromString("objectAtPoint:displayId:bridgeDelegateToken:")
        let macSel = NSSelectorFromString("macPlatformElementFromTranslation:")
        guard let pImp = translator.method(for: pointSel), let mImp = translator.method(for: macSel) else { return [] }
        let objectAt = unsafeBitCast(pImp, to: PointFn.self), toMac = unsafeBitCast(mImp, to: MacFn.self)

        // Leaf frames already described: a point inside one of them adds nothing.
        var covered: [CGRect] = []
        // Childless containers (a tab bar that exposes no tabs, remote views) are opaque to the
        // tree: probe inside them even where content scrolled underneath claims the area.
        var forced: [CGRect] = []
        func collect(_ e: Element) {
            let container = ["Group", "GenericElement", "ScrollArea", "Window", "Application", "List", "Table",
                             "Outline", "Collection", "Unknown", "Element", "Other", "TabGroup", "Toolbar"].contains(e.role)
            if e.children.isEmpty, !container, e.frame.width > 0, e.frame.width < screen.width * 0.9 || e.frame.height < screen.height * 0.5 {
                covered.append(e.frame)
            } else if e.children.isEmpty, container, e.frame.width * e.frame.height < screen.width * screen.height * 0.4 {
                forced.append(e.frame)
            }
            e.children.forEach(collect)
        }
        collect(known)
        var seen = Set<String>()
        var found: [Element] = []
        let t0 = Date(); var probes = 0
        defer { if ProcessInfo.processInfo.environment["NOOBER_AX_DEBUG"] != nil { nlog("[ax] grid: \(probes) probes, \(found.count) found, \(Int(Date().timeIntervalSince(t0) * 1000))ms") } }
        let step: CGFloat = 36
        var y = step / 2
        while y < screen.height, budget > 0 {
            var x = step / 2
            while x < screen.width, budget > 0 {
                let p = CGPoint(x: x, y: y)
                x += step
                if !forced.contains(where: { $0.contains(p) }), covered.contains(where: { $0.contains(p) }) { continue }
                probes += 1
                guard let t = objectAt(translator, pointSel, p, 0, token as NSString) as? NSObject else { continue }
                t.setValue(token, forKey: "bridgeDelegateToken")
                guard let mac = toMac(translator, macSel, t) as? NSObject,
                      let e = serialize(mac, token: token, budget: &budget, visited: &visited, depth: 1) else { continue }
                // Whole-screen containers carry nothing new; remember them and move on.
                if e.frame.width >= screen.width - 1, e.frame.height >= screen.height - 1, e.children.isEmpty { continue }
                let key = "\(Int(e.frame.minX)),\(Int(e.frame.minY)),\(Int(e.frame.width)),\(Int(e.frame.height))|\(e.label ?? "")"
                covered.append(e.frame)
                if seen.insert(key).inserted { found.append(e) }
            }
            y += step
        }
        return found
    }

    private func serialize(_ obj: NSObject, token: String, budget: inout Int, visited: inout Set<ObjectIdentifier>, depth: Int) -> Element? {
        guard budget > 0, depth < 80, visited.insert(ObjectIdentifier(obj)).inserted else { return nil }
        budget -= 1
        (obj.value(forKey: "translation") as? NSObject)?.setValue(token, forKey: "bridgeDelegateToken")
        let frame: CGRect = (obj as? NSAccessibilityElement)?.accessibilityFrame()
            ?? (obj.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
        var role = str(obj, "accessibilityRole") ?? ""
        if role.hasPrefix("AX") { role.removeFirst(2) }
        let subrole = str(obj, "accessibilitySubrole")
        if role == "Group" || role.isEmpty, let roleDesc = str(obj, "accessibilityRoleDescription"), !roleDesc.isEmpty {
            // iOS traits surface through roleDescription ("button", "tab", "heading" …)
            role = role.isEmpty ? roleDesc.capitalized : role
        }
        if let subrole, subrole.hasPrefix("AX"), role == "Button" || role == "Group" {
            let s = String(subrole.dropFirst(2))
            if ["Toggle", "Switch", "Tab", "SearchField"].contains(s) { role = s }
        }
        var children: [Element] = []
        let kids = (obj as? NSAccessibilityElement)?.accessibilityChildren() ?? (obj.value(forKey: "accessibilityChildren") as? [Any])
        for k in kids ?? [] {
            guard budget > 0 else { break }
            if let k = k as? NSObject, let c = serialize(k, token: token, budget: &budget, visited: &visited, depth: depth + 1) {
                children.append(c)
            }
        }
        let enabled = (obj.value(forKey: "accessibilityEnabled") as? NSNumber)?.boolValue ?? true
        return Element(role: role, label: str(obj, "accessibilityLabel"), value: str(obj, "accessibilityValue"),
                       identifier: str(obj, "accessibilityIdentifier"), frame: frame, enabled: enabled, children: children)
    }

    private func str(_ obj: NSObject, _ key: String) -> String? {
        guard obj.responds(to: NSSelectorFromString(key)) else { return nil }
        let v = obj.value(forKey: key)
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let a = v as? NSAttributedString { return a.string.isEmpty ? nil : a.string }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    // MARK: - AXPTranslationTokenDelegateHelper

    @objc(accessibilityTranslationDelegateBridgeCallbackWithToken:)
    func bridgeCallback(token: String) -> AnyObject {
        let block: @convention(block) (AnyObject?) -> AnyObject? = { [weak self] request in
            guard let self, let request, let device = self.lock.withLock({ self.tokenToDevice[token] }) else {
                return Self.emptyResponse()
            }
            return self.forward(request, to: device)
        }
        return block as AnyObject
    }

    @objc(accessibilityTranslationConvertPlatformFrameToSystem:withToken:)
    func convertFrame(_ rect: NSRect, withToken token: String) -> NSRect { rect }

    @objc(accessibilityTranslationRootParentWithToken:)
    func rootParent(withToken token: String) -> AnyObject? { nil }

    private func forward(_ request: AnyObject, to device: NSObject) -> AnyObject? {
        let sel = NSSelectorFromString("sendAccessibilityRequestAsync:completionQueue:completionHandler:")
        guard let imp = device.method(for: sel) else { return Self.emptyResponse() }
        typealias SendFn = @convention(c) (AnyObject, Selector, AnyObject, DispatchQueue, AnyObject) -> Void
        let sem = DispatchSemaphore(value: 0)
        final class Box { var value: AnyObject? }
        let box = Box()
        let done: @convention(block) (AnyObject?) -> Void = { resp in box.value = resp; sem.signal() }
        unsafeBitCast(imp, to: SendFn.self)(device, sel, request, queue, done as AnyObject)
        if sem.wait(timeout: .now() + 5) == .timedOut { return Self.emptyResponse() }
        return box.value ?? Self.emptyResponse()
    }

    private static func emptyResponse() -> AnyObject? {
        (NSClassFromString("AXPTranslatorResponse") as? NSObject.Type)?
            .perform(NSSelectorFromString("emptyResponse"))?.takeUnretainedValue()
    }
}

// MARK: - Compact rendering with element refs

/// Turns a tree into a token-cheap outline. Every actionable element gets a short ref
/// (`e12`) that `tap(ref:)` resolves to its centre — no coordinate guessing.
struct UIOutline {
    struct Ref { let center: CGPoint; let frame: CGRect; let summary: String }

    private(set) var refs: [String: Ref] = [:]
    private(set) var text = ""
    private var counter = 0

    init(root: SimAccessibility.Element, screen: CGSize) {
        render(root, depth: 0, screen: screen)
        if text.isEmpty { text = "(no accessible elements on screen)" }
    }

    private mutating func render(_ el: SimAccessibility.Element, depth: Int, screen: CGSize) {
        let onScreen = el.frame.width > 0 && el.frame.height > 0 &&
            el.frame.maxX > 0 && el.frame.maxY > 0 && el.frame.minX < screen.width && el.frame.minY < screen.height
        let show = el.isInteresting && onScreen && depth > 0
        var nextDepth = depth
        if show {
            counter += 1
            let ref = "e\(counter)"
            var line = String(repeating: "  ", count: max(0, depth - 1)) + "[\(ref)] \(el.role.isEmpty ? "Element" : el.role)"
            if let l = el.label { line += " \"\(Self.clip(l))\"" }
            if let v = el.value, v != el.label {
                if ["RadioButton", "Switch", "Toggle", "CheckBox", "Tab"].contains(el.role), v == "0" || v == "1" {
                    if v == "1" { line += " (selected)" }
                } else {
                    line += " = \"\(Self.clip(v))\""
                }
            }
            if let id = el.identifier { line += " #\(id)" }
            if !el.enabled { line += " (disabled)" }
            line += " @\(Int(el.center.x.rounded())),\(Int(el.center.y.rounded()))"
            text += line + "\n"
            refs[ref] = Ref(center: el.center, frame: el.frame, summary: line.trimmingCharacters(in: .whitespaces))
            nextDepth = depth + 1
        } else if depth == 0 {
            nextDepth = 1
        }
        for c in el.children { render(c, depth: nextDepth, screen: screen) }
    }

    private static func clip(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > 80 ? String(one.prefix(77)) + "…" : one
    }

    /// All visible strings, for cheap text assertions.
    static func texts(_ el: SimAccessibility.Element) -> [String] {
        var out: [String] = []
        func walk(_ e: SimAccessibility.Element) {
            // Skip the status bar (clock, signal, battery) — it changes on its own and is noise in diffs.
            let statusBar = e.frame.height > 0 && e.frame.height < 40 && e.frame.maxY <= 56
            if !statusBar {
                if let l = e.label { out.append(l) }
                if let v = e.value, v != e.label { out.append(v) }
            }
            e.children.forEach(walk)
        }
        walk(el)
        return out
    }

    /// Best match for a text query: exact label > prefix > contains; prefers actionable roles.
    static func find(_ query: String, in root: SimAccessibility.Element) -> SimAccessibility.Element? {
        let q = query.lowercased()
        var best: (score: Int, el: SimAccessibility.Element)?
        func consider(_ e: SimAccessibility.Element) {
            for candidate in [e.label, e.identifier, e.value].compactMap({ $0?.lowercased() }) {
                var score = 0
                if candidate == q { score = 100 } else if candidate.hasPrefix(q) { score = 60 } else if candidate.contains(q) { score = 30 }
                if score > 0 {
                    if ["Button", "Cell", "Link", "Tab", "Switch", "TextField", "SearchField"].contains(e.role) { score += 10 }
                    if e.frame.width > 0, e.frame.height > 0, best == nil || score > best!.score { best = (score, e) }
                }
            }
            e.children.forEach(consider)
        }
        consider(root)
        return best?.el
    }
}
