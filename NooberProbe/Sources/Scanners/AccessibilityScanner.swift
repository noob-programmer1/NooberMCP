// AccessibilityScanner.swift
// NooberProbe — Scans the UIKit accessibility tree for screen content
//
// Provides fast in-process accessibility scanning identical to the Noober SDK's
// AccessibilityScanner. Generates element lists, visible text, semantic HTML,
// snapshots, and screenshots — all callable from the ProbeServer command handler.
//
// All public methods MUST be called on the main thread (@MainActor).

import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
enum ProbeAccessibilityScanner {

    // MARK: - Element Type

    struct Element {
        let label: String
        let type: String            // "Button", "StaticText", "Image", etc.
        let frame: CGRect           // screen coordinates
        let value: String?
        let traits: UIAccessibilityTraits
        let isButton: Bool
        let isTextField: Bool
    }

    // MARK: - Find Element

    /// Search for elements whose label contains (or exactly matches) the given text.
    /// Returns raw Element array sorted by Y position.
    static func find(text: String, exact: Bool = false) -> [Element] {
        let all = scanAll()
        let query = text.lowercased()
        return all.filter { el in
            let label = el.label.lowercased()
            return exact ? label == query : label.contains(query)
        }
    }

    /// Find the first tappable element matching the text.
    static func findTappable(text: String) -> Element? {
        find(text: text).first { $0.isButton || $0.traits.contains(.button) }
            ?? find(text: text).first
    }

    // MARK: - All Visible Text

    /// Returns all visible text strings on the current screen.
    static func allVisibleText() -> [String] {
        scanAll()
            .filter { !$0.label.isEmpty }
            .map { el in
                if let value = el.value, !value.isEmpty, value != el.label {
                    return "\(el.label): \(value)"
                }
                return el.label
            }
    }

    // MARK: - Screen HTML

    /// Generates compact semantic HTML with tap coordinates.
    /// Designed for LLM comprehension — each element has an id and center coordinates.
    ///
    /// Example output:
    /// ```
    /// <html><title>Home</title>
    /// <button id=1 c="160,300">Login</button>
    /// <p id=2 c="160,400">Welcome to the app</p>
    /// </html>
    /// ```
    static func screenHTML() -> (html: String, elementCount: Int) {
        let screen = ProbeState.shared.currentScreen
        let elements = scanAll()

        var html = "<html><title>\(escapeHTML(screen))</title>\n"
        var id = 1

        for el in elements {
            guard !el.label.isEmpty else { continue }

            let cx = Int(el.frame.midX)
            let cy = Int(el.frame.midY)
            let tag = htmlTag(for: el)
            let content = escapeHTML(el.label)

            if let value = el.value, !value.isEmpty, value != el.label {
                html += "<\(tag) id=\(id) c=\"\(cx),\(cy)\">\(content): \(escapeHTML(value))</\(tag)>\n"
            } else {
                html += "<\(tag) id=\(id) c=\"\(cx),\(cy)\">\(content)</\(tag)>\n"
            }
            id += 1
        }

        html += "</html>"
        return (html, id - 1)
    }

    // MARK: - Snapshot (element descriptors)

    /// Returns a full list of accessibility elements with frames and interactivity info.
    static func snapshot() -> [SnapshotElement] {
        scanAll().map { el in
            SnapshotElement(
                label: el.label.isEmpty ? nil : el.label,
                identifier: nil,
                type: el.type,
                x: Int(el.frame.minX),
                y: Int(el.frame.minY),
                width: Int(el.frame.width),
                height: Int(el.frame.height),
                interactive: el.isButton || el.isTextField
            )
        }
    }

    // MARK: - Screenshot

    /// Renders the key window to a PNG image and returns base64-encoded data.
    static func screenshot() -> String? {
        guard let window = appWindow else { return nil }

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { ctx in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }

        guard let pngData = image.pngData() else { return nil }
        return pngData.base64EncodedString()
    }

    // MARK: - Full Scan

    /// Scan all accessibility elements on screen.
    /// Returns deduplicated elements sorted by Y position.
    static func scanAll() -> [Element] {
        guard let window = appWindow else { return [] }

        var elements: [Element] = []
        scanAccessibilityTree(window, into: &elements)

        // Deduplicate by label + frame
        var seen = Set<String>()
        elements = elements.filter { el in
            let key = "\(el.label)|\(Int(el.frame.minX)),\(Int(el.frame.minY))"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }

        return elements.sorted { $0.frame.minY < $1.frame.minY }
    }

    // MARK: - Private: Tree Traversal

    private static func scanAccessibilityTree(_ element: Any, into results: inout [Element]) {
        if let ax = element as? NSObject {
            let isElement = ax.isAccessibilityElement
            let label = ax.accessibilityLabel ?? ""
            let frame = ax.accessibilityFrame
            let traits = ax.accessibilityTraits
            let value = ax.accessibilityValue

            if isElement && !label.isEmpty && frame.width > 0 && frame.height > 0 {
                // Skip NooberProbe's own elements (shouldn't have any, but guard)
                if let view = element as? UIView,
                   String(describing: type(of: view)).contains("Noober") ||
                   String(describing: type(of: view)).contains("Probe") {
                    // skip
                } else {
                    let typeName = traitToType(traits)
                    results.append(Element(
                        label: label,
                        type: typeName,
                        frame: frame,
                        value: value,
                        traits: traits,
                        isButton: traits.contains(.button),
                        isTextField: traits.contains(.searchField) || element is UITextField
                    ))
                }
            }
        }

        // Method 1: accessibilityElements (SwiftUI populates this)
        if let container = element as? NSObject,
           let children = container.accessibilityElements {
            for child in children {
                scanAccessibilityTree(child, into: &results)
            }
        }

        // Method 2: UIView subviews (catches UIKit views)
        if let view = element as? UIView {
            if view.isHidden || view.alpha < 0.01 { return }

            // Skip system/probe windows
            let viewTypeName = String(describing: type(of: view))
            if viewTypeName.contains("Noober") || viewTypeName.contains("Probe") { return }

            for subview in view.subviews {
                scanAccessibilityTree(subview, into: &results)
            }
        }

        // Method 3: accessibilityElementCount (older API)
        if let container = element as? NSObject {
            let count = container.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                for i in 0..<count {
                    if let child = container.accessibilityElement(at: i) {
                        scanAccessibilityTree(child, into: &results)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private static func traitToType(_ traits: UIAccessibilityTraits) -> String {
        if traits.contains(.button) { return "Button" }
        if traits.contains(.link) { return "Link" }
        if traits.contains(.image) { return "Image" }
        if traits.contains(.searchField) { return "SearchField" }
        if traits.contains(.header) { return "Header" }
        if traits.contains(.staticText) { return "StaticText" }
        if traits.contains(.adjustable) { return "Slider" }
        if traits.contains(.tabBar) { return "TabBar" }
        return "Other"
    }

    private static func htmlTag(for element: Element) -> String {
        switch element.type {
        case "Button": return "button"
        case "Link": return "a"
        case "Image": return "img"
        case "SearchField": return "input"
        case "Header": return "h2"
        case "Slider": return "input"
        case "TabBar": return "nav"
        case "StaticText": return "p"
        default: return "span"
        }
    }

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
            .first { window in
                // Skip non-key windows and any window that looks like a system overlay
                let typeName = String(describing: type(of: window))
                if typeName.contains("Noober") || typeName.contains("Probe") { return false }
                return window.isKeyWindow
            }
    }
}
