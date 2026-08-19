// ProbeCommandHandler.swift
// NooberProbe — Handles incoming commands from NooberMCP

import Foundation
import UIKit

@MainActor
enum ProbeCommandHandler {

    static func handle(_ message: CompanionMessage) {
        switch message.type {
        case .commandFindElement:
            handleFindElement(message)
        case .commandScreenText:
            handleScreenText()
        case .commandScreenHTML:
            handleScreenHTML()
        case .commandRequestSnapshot:
            handleSnapshot()
        case .commandRequestScreenshot:
            handleScreenshot()
        case .commandFireDeepLink:
            handleFireDeepLink(message)
        case .commandClearStore:
            handleClearStore()
        case .commandAddMockRule:
            handleAddMockRule(message)
        case .commandRemoveMockRule:
            handleRemoveMockRule(message)
        case .commandAddInterceptRule:
            handleAddInterceptRule(message)
        case .commandRemoveInterceptRule:
            handleRemoveInterceptRule(message)
        case .commandPerfSnapshot:
            handlePerfSnapshot()
        case .commandAccessibilityAudit:
            handleAccessibilityAudit()
        case .commandGetWebViewConsole:
            handleGetWebViewConsole(message)
        case .commandTap:
            handleTap(message)
        case .commandSwipe:
            handleSwipe(message)
        case .commandTypeText:
            handleTypeText(message)
        case .commandShowOverlay:
            handleShowOverlay(message)
        case .commandHideOverlay:
            ProbeTouchOverlay.hideOrb()
        // Unsupported without SDK
        case .commandSwitchEnvironment,
             .commandToggleRule,
             .commandReplayRequest,
             .commandMarkQAPassed,
             .commandMarkQAFailed,
             .commandResetQAItem:
            break
        default:
            break
        }
    }

    // MARK: - Find Element

    private static func handleFindElement(_ message: CompanionMessage) {
        ProbeTouchOverlay.showScan()
        struct FindCommand: Decodable {
            let text: String
            let exact: Bool?
        }

        struct FoundElement: Codable {
            let label: String
            let type: String
            let x: Int
            let y: Int
            let width: Int
            let height: Int
            let centerX: Int
            let centerY: Int
            let isButton: Bool
        }

        struct FindResponse: Codable {
            let screen: String
            let query: String
            let results: [FoundElement]
        }

        guard let command = try? message.decode(FindCommand.self) else { return }
        let matches = ProbeAccessibilityScanner.find(text: command.text, exact: command.exact ?? false)
        let screen = ProbeScreenTracker.currentScreen

        let response = FindResponse(
            screen: screen,
            query: command.text,
            results: matches.map {
                FoundElement(
                    label: $0.label,
                    type: $0.type,
                    x: Int($0.frame.origin.x),
                    y: Int($0.frame.origin.y),
                    width: Int($0.frame.width),
                    height: Int($0.frame.height),
                    centerX: Int($0.frame.midX),
                    centerY: Int($0.frame.midY),
                    isButton: $0.isButton
                )
            }
        )

        if let msg = try? CompanionMessage(type: .responseFindElement, payload: response) {
            ProbeServer.shared.send(msg)
        }
    }

    // MARK: - Screen Text

    private static func handleScreenText() {
        ProbeTouchOverlay.showScan()
        struct ScreenTextResponse: Codable {
            let screen: String
            let lines: [String]
        }

        let lines = ProbeAccessibilityScanner.allVisibleText()
        let screen = ProbeScreenTracker.currentScreen

        let response = ScreenTextResponse(screen: screen, lines: lines)
        if let msg = try? CompanionMessage(type: .responseScreenText, payload: response) {
            ProbeServer.shared.send(msg)
        }
    }

    // MARK: - Screen HTML

    private static func handleScreenHTML() {
        ProbeTouchOverlay.showScan()
        struct ScreenHTMLResponse: Codable {
            let screen: String
            let html: String
            let elementCount: Int
        }

        let elements = ProbeAccessibilityScanner.scanAll()
        let screen = ProbeScreenTracker.currentScreen

        // Compact semantic HTML — matches SDK's format exactly
        var html = "<html><title>\(escapeHTML(screen))</title>\n"
        for (i, el) in elements.enumerated() {
            let id = i + 1
            let cx = Int(el.frame.midX)
            let cy = Int(el.frame.midY)
            let rawLabel = el.label
            let label = escapeHTML(rawLabel.count > 60 ? String(rawLabel.prefix(57)) + "..." : rawLabel)
            let val = el.value.map { v in " v=\"\(escapeHTML(String(v.prefix(30))))\"" } ?? ""

            switch el.type {
            case "Button":
                html += "<button id=\(id) c=\"\(cx),\(cy)\"\(val)>\(label)</button>\n"
            case "Link":
                html += "<a id=\(id) c=\"\(cx),\(cy)\">\(label)</a>\n"
            case "Image":
                html += "<img id=\(id) c=\"\(cx),\(cy)\" alt=\"\(label)\">\n"
            case "Header":
                html += "<h2 id=\(id) c=\"\(cx),\(cy)\">\(label)</h2>\n"
            case "SearchField":
                html += "<input id=\(id) c=\"\(cx),\(cy)\"\(val) placeholder=\"\(label)\">\n"
            case "Slider":
                html += "<input type=range id=\(id) c=\"\(cx),\(cy)\"\(val) label=\"\(label)\">\n"
            case "TabBar":
                html += "<nav id=\(id) c=\"\(cx),\(cy)\">\(label)</nav>\n"
            case "StaticText":
                html += "<p id=\(id) c=\"\(cx),\(cy)\">\(label)</p>\n"
            default:
                if el.isTextField {
                    html += "<input id=\(id) c=\"\(cx),\(cy)\"\(val) placeholder=\"\(label)\">\n"
                } else if el.isButton {
                    html += "<button id=\(id) c=\"\(cx),\(cy)\"\(val)>\(label)</button>\n"
                } else {
                    html += "<span id=\(id) c=\"\(cx),\(cy)\">\(label)</span>\n"
                }
            }
        }
        html += "</html>"

        let response = ScreenHTMLResponse(screen: screen, html: html, elementCount: elements.count)
        if let msg = try? CompanionMessage(type: .responseScreenHTML, payload: response) {
            ProbeServer.shared.send(msg)
        }
    }

    // MARK: - Screenshot

    private static func handleScreenshot() {
        ProbeTouchOverlay.showCaptureFlash()
        struct ScreenshotResponse: Codable {
            let screen: String
            let base64PNG: String
        }

        guard let window = appWindow else { return }

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        guard let base64 = image.pngData()?.base64EncodedString() else { return }

        let response = ScreenshotResponse(
            screen: ProbeScreenTracker.currentScreen,
            base64PNG: base64
        )
        if let msg = try? CompanionMessage(type: .responseScreenshot, payload: response) {
            ProbeServer.shared.send(msg)
        }
    }

    // MARK: - Snapshot (view hierarchy)

    private static func handleSnapshot() {
        ProbeTouchOverlay.showScan()
        struct SnapshotElement: Codable {
            let label: String?
            let identifier: String?
            let type: String
            let x: Int
            let y: Int
            let width: Int
            let height: Int
            let interactive: Bool
        }

        struct SnapshotResponse: Codable {
            let screen: String
            let elements: [SnapshotElement]
        }

        let elements = ProbeViewHierarchySnapshot.capture()
        let screen = ProbeScreenTracker.currentScreen

        let response = SnapshotResponse(
            screen: screen,
            elements: elements.map {
                SnapshotElement(
                    label: $0.label,
                    identifier: $0.identifier,
                    type: $0.type,
                    x: Int($0.frame.origin.x),
                    y: Int($0.frame.origin.y),
                    width: Int($0.frame.width),
                    height: Int($0.frame.height),
                    interactive: $0.isInteractive
                )
            }
        )

        if let msg = try? CompanionMessage(type: .responseSnapshot, payload: response) {
            ProbeServer.shared.send(msg)
        }
    }

    // MARK: - Deep Link

    private static func handleFireDeepLink(_ message: CompanionMessage) {
        struct FireDeepLinkCommand: Codable {
            let url: String
        }

        guard let command = try? message.decode(FireDeepLinkCommand.self) else { return }
        guard let url = URL(string: command.url) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    // MARK: - Clear Store (probe-level caches)

    private static func handleClearStore() {
        ProbeState.shared.clear()
    }

    // MARK: - Mock Rules

    private static func handleAddMockRule(_ message: CompanionMessage) {
        struct AddMockCmd: Decodable {
            let urlPattern: String
            let matchMode: String?
            let httpMethod: String?
            let statusCode: Int?
            let responseBody: String?
            let responseHeaders: [String: String]?
            let name: String?
        }
        guard let cmd = try? message.decode(AddMockCmd.self) else { return }
        ProbeMockRules.shared.addRule(ProbeMockRules.MockRule(
            id: UUID(),
            name: cmd.name ?? "Mock \(cmd.urlPattern.prefix(30))",
            urlPattern: cmd.urlPattern,
            matchMode: cmd.matchMode ?? "contains",
            httpMethod: cmd.httpMethod,
            statusCode: cmd.statusCode ?? 200,
            responseBody: cmd.responseBody ?? "{}",
            responseHeaders: cmd.responseHeaders ?? ["Content-Type": "application/json"]
        ))
    }

    private static func handleRemoveMockRule(_ message: CompanionMessage) {
        struct RemoveCmd: Decodable { let ruleId: String }
        guard let cmd = try? message.decode(RemoveCmd.self),
              let uuid = UUID(uuidString: cmd.ruleId) else { return }
        ProbeMockRules.shared.removeRule(id: uuid)
    }

    // MARK: - Intercept Rules

    private static func handleAddInterceptRule(_ message: CompanionMessage) {
        struct AddInterceptCmd: Decodable {
            let urlPattern: String
            let matchMode: String?
            let httpMethod: String?
            let name: String?
        }
        guard let cmd = try? message.decode(AddInterceptCmd.self) else { return }
        ProbeInterceptRules.shared.addRule(ProbeInterceptRules.InterceptRule(
            id: UUID(),
            name: cmd.name ?? "Intercept \(cmd.urlPattern.prefix(30))",
            urlPattern: cmd.urlPattern,
            matchMode: cmd.matchMode ?? "contains",
            httpMethod: cmd.httpMethod
        ))
    }

    private static func handleRemoveInterceptRule(_ message: CompanionMessage) {
        struct RemoveCmd: Decodable { let ruleId: String }
        guard let cmd = try? message.decode(RemoveCmd.self),
              let uuid = UUID(uuidString: cmd.ruleId) else { return }
        ProbeInterceptRules.shared.removeRule(id: uuid)
    }

    // MARK: - Performance Snapshot

    private static func handlePerfSnapshot() {
        ProbeTouchOverlay.showDataPulse(detail: "perf")
        struct PerfSnapshotResponse: Codable {
            let fps: Double
            let memoryMB: Double
            let avgFPS: Double
            let peakMemoryMB: Double
            let screen: String
        }

        let perf = ProbePerfMonitor.snapshot()
        let response = PerfSnapshotResponse(
            fps: perf.fps,
            memoryMB: perf.memoryMB,
            avgFPS: perf.avgFPS,
            peakMemoryMB: perf.peakMemoryMB,
            screen: ProbeScreenTracker.currentScreen
        )
        if let msg = try? CompanionMessage(type: .responsePerfSnapshot, payload: response) {
            ProbeServer.shared.send(msg)
        }
    }

    // MARK: - Accessibility Audit

    private static func handleAccessibilityAudit() {
        ProbeTouchOverlay.showScan()
        struct AccessibilityAuditResponse: Codable {
            let screen: String
            let issues: [ProbeAccessibilityAuditor.AuditIssue]
            let issueCount: Int
        }

        let issues = ProbeAccessibilityAuditor.audit()
        let response = AccessibilityAuditResponse(
            screen: ProbeScreenTracker.currentScreen,
            issues: issues,
            issueCount: issues.count
        )
        if let msg = try? CompanionMessage(type: .responseAccessibilityAudit, payload: response) {
            ProbeServer.shared.send(msg)
        }
    }

    // MARK: - WebView Console

    private static func handleGetWebViewConsole(_ message: CompanionMessage) {
        struct GetConsoleCmd: Decodable {
            let level: String?
            let limit: Int?
        }
        struct ConsoleEntryResponse: Codable {
            let timestamp: Double
            let level: String
            let message: String
            let url: String?
        }
        struct WebViewConsoleResponse: Codable {
            let entries: [ConsoleEntryResponse]
            let totalCount: Int
        }

        ProbeTouchOverlay.showDataPulse(detail: "webview console")
        let cmd = try? message.decode(GetConsoleCmd.self)
        let limit = cmd?.limit ?? 50
        let levelFilter = cmd?.level

        var all = ProbeWebViewConsoleCapture.allEntries()
        let totalCount = all.count

        if let levelFilter {
            all = all.filter { $0.level == levelFilter }
        }

        let limited = Array(all.suffix(limit))
        let entries = limited.map {
            ConsoleEntryResponse(
                timestamp: $0.timestamp.timeIntervalSince1970,
                level: $0.level,
                message: $0.message,
                url: $0.url
            )
        }

        let response = WebViewConsoleResponse(entries: entries, totalCount: totalCount)
        if let msg = try? CompanionMessage(type: .responseWebViewConsole, payload: response) {
            ProbeServer.shared.send(msg)
        }
    }

    // MARK: - Input Synthesis

    private static func handleTap(_ message: CompanionMessage) {
        struct TapCommand: Decodable {
            let x: Int
            let y: Int
        }

        guard let command = try? message.decode(TapCommand.self) else { return }
        ProbeTouchOverlay.showTap(at: CGPoint(x: command.x, y: command.y))
        let result = ProbeInputSynthesizer.tap(x: command.x, y: command.y)
        if let msg = try? CompanionMessage(type: .responseTap, payload: result) {
            ProbeServer.shared.send(msg)
        }
    }

    private static func handleSwipe(_ message: CompanionMessage) {
        struct SwipeCommand: Decodable {
            let x1: Int
            let y1: Int
            let x2: Int
            let y2: Int
            let duration: Double?
        }

        guard let command = try? message.decode(SwipeCommand.self) else { return }
        ProbeTouchOverlay.showSwipe(
            from: CGPoint(x: command.x1, y: command.y1),
            to: CGPoint(x: command.x2, y: command.y2)
        )
        let result = ProbeInputSynthesizer.swipe(
            x1: command.x1, y1: command.y1,
            x2: command.x2, y2: command.y2,
            duration: command.duration ?? 0.5
        )
        if let msg = try? CompanionMessage(type: .responseSwipe, payload: result) {
            ProbeServer.shared.send(msg)
        }
    }

    private static func handleTypeText(_ message: CompanionMessage) {
        struct TypeTextCommand: Decodable {
            let text: String
        }

        guard let command = try? message.decode(TypeTextCommand.self) else { return }

        // Find first responder position for the type indicator
        let responderCenter: CGPoint? = appWindow?.findFirstResponder()
            .flatMap { $0 as? UIView }
            .flatMap { $0.superview?.convert($0.center, to: nil) }
        ProbeTouchOverlay.showTypeText(near: responderCenter)

        let result = ProbeInputSynthesizer.typeText(command.text)
        if let msg = try? CompanionMessage(type: .responseTypeText, payload: result) {
            ProbeServer.shared.send(msg)
        }
    }

    // MARK: - Show Overlay (fire-and-forget from MCP)

    private static func handleShowOverlay(_ message: CompanionMessage) {
        struct OverlayCommand: Decodable {
            let category: String   // scan, data, capture, verify, environment
            let detail: String?
            let passed: Bool?      // for verify category
        }

        guard let cmd = try? message.decode(OverlayCommand.self) else {
            fputs("[NooberProbe] handleShowOverlay: decode failed\n", stderr)
            return
        }
        fputs("[NooberProbe] handleShowOverlay: \(cmd.category) / \(cmd.detail ?? "-")\n", stderr)
        switch cmd.category {
        case "scan":
            ProbeTouchOverlay.showScan()
        case "capture":
            ProbeTouchOverlay.showCaptureFlash()
        case "data":
            ProbeTouchOverlay.showDataPulse(detail: cmd.detail ?? "data")
        case "verify":
            ProbeTouchOverlay.showVerifyResult(passed: cmd.passed ?? true, detail: cmd.detail ?? "")
        case "environment":
            ProbeTouchOverlay.showEnvironmentSwitch(name: cmd.detail ?? "env")
        default:
            if let detail = cmd.detail {
                ProbeTouchOverlay.showToolActivity(
                    category: .data,
                    detail: detail
                )
            }
        }
    }

    // MARK: - Helpers

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static var appWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}

// MARK: - Probe View Hierarchy Snapshot
//
// ProbeAccessibilityScanner is defined in Scanners/AccessibilityScanner.swift
// ProbeScreenTracker is defined in Interceptors/ScreenTracker.swift

/// UIView-based snapshot (complementary to the accessibility scanner).
@MainActor
enum ProbeViewHierarchySnapshot {

    struct Element {
        let label: String?
        let identifier: String?
        let type: String
        let frame: CGRect
        let isInteractive: Bool
    }

    static func capture() -> [Element] {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow }) else {
            return []
        }

        var elements: [Element] = []
        walkView(window, in: window, into: &elements)
        return elements.sorted { $0.frame.minY < $1.frame.minY }
    }

    private static func walkView(_ view: UIView, in window: UIWindow, into elements: inout [Element]) {
        guard !view.isHidden, view.alpha > 0.01 else { return }

        let frame = view.convert(view.bounds, to: window)

        let label = view.accessibilityLabel
        let identifier = view.accessibilityIdentifier

        let typeName: String
        if view is UIButton { typeName = "Button" }
        else if view is UILabel { typeName = "Label" }
        else if view is UITextField { typeName = "TextField" }
        else if view is UITextView { typeName = "TextView" }
        else if view is UISwitch { typeName = "Switch" }
        else if view is UISlider { typeName = "Slider" }
        else if view is UIImageView { typeName = "Image" }
        else if view is UITableViewCell { typeName = "Cell" }
        else if view is UICollectionViewCell { typeName = "Cell" }
        else { typeName = String(describing: type(of: view)).components(separatedBy: ".").last ?? "View" }

        let isInteractive = view.isUserInteractionEnabled && (
            view is UIControl ||
            view.gestureRecognizers?.isEmpty == false ||
            view.isAccessibilityElement
        )

        if label != nil || identifier != nil || (isInteractive && frame.width > 10 && frame.height > 10) {
            let element = Element(
                label: label,
                identifier: identifier,
                type: typeName,
                frame: frame,
                isInteractive: isInteractive
            )
            if !elements.contains(where: { $0.label == element.label && $0.frame == element.frame }) {
                elements.append(element)
            }
        }

        for subview in view.subviews {
            walkView(subview, in: window, into: &elements)
        }
    }
}
