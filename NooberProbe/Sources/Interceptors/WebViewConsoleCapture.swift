// WebViewConsoleCapture.swift
// NooberProbe — Captures JavaScript console.log/error/warn/debug from WKWebViews
//
// Uses method swizzling on WKWebView.init(frame:configuration:) to inject a
// user script that overrides console methods and posts messages back via
// WKScriptMessageHandler.

import Foundation
import UIKit
import WebKit
import ObjectiveC

enum ProbeWebViewConsoleCapture {

    struct ConsoleEntry {
        let timestamp: Date
        let level: String // "log", "error", "warn", "debug"
        let message: String
        let url: String?
    }

    private static var entries: [ConsoleEntry] = []
    private static let lock = NSLock()
    private static let maxEntries = 200
    nonisolated(unsafe) private static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        swizzleWebViewInit()
        probelog("WebViewConsoleCapture installed")
    }

    static func allEntries() -> [ConsoleEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    static func addEntry(_ entry: ConsoleEntry) {
        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries { entries.removeFirst() }
        lock.unlock()
    }

    static func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    // MARK: - Swizzle

    /// Swizzle WKWebView.init(frame:configuration:) to inject console capture script
    /// into every WKWebView created by the host app.
    private static func swizzleWebViewInit() {
        let originalSelector = #selector(WKWebView.init(frame:configuration:))
        guard let originalMethod = class_getInstanceMethod(WKWebView.self, originalSelector) else {
            probelog("WebViewConsoleCapture: failed to find WKWebView.init(frame:configuration:)")
            return
        }

        let swizzledSelector = #selector(WKWebView.probe_initWithFrame(_:configuration:))
        guard let swizzledMethod = class_getInstanceMethod(WKWebView.self, swizzledSelector) else {
            probelog("WebViewConsoleCapture: failed to find swizzled method")
            return
        }

        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    /// The JavaScript that overrides console methods and posts messages to native.
    static let consoleOverrideJS: String = """
    (function() {
        if (window.__nooberConsoleInstalled) return;
        window.__nooberConsoleInstalled = true;
        var origLog = console.log, origError = console.error, origWarn = console.warn, origDebug = console.debug;
        function send(level, args) {
            var msg = Array.prototype.slice.call(args).map(function(a) {
                try { return typeof a === 'object' ? JSON.stringify(a) : String(a); }
                catch(e) { return String(a); }
            }).join(' ');
            try {
                window.webkit.messageHandlers.nooberConsole.postMessage({level: level, message: msg, url: window.location.href, timestamp: Date.now() / 1000.0});
            } catch(e) {}
        }
        console.log = function() { send('log', arguments); origLog.apply(console, arguments); };
        console.error = function() { send('error', arguments); origError.apply(console, arguments); };
        console.warn = function() { send('warn', arguments); origWarn.apply(console, arguments); };
        console.debug = function() { send('debug', arguments); origDebug.apply(console, arguments); };
    })();
    """
}

// MARK: - WKWebView Swizzle Extension

extension WKWebView {

    /// Swizzled initializer — injects console capture script, then calls original.
    @objc dynamic func probe_initWithFrame(_ frame: CGRect, configuration: WKWebViewConfiguration) -> WKWebView {
        // Inject console capture user script
        let script = WKUserScript(
            source: ProbeWebViewConsoleCapture.consoleOverrideJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(script)

        // Register message handler (idempotent — WKUserContentController ignores duplicate names)
        configuration.userContentController.add(ProbeConsoleHandler.shared, name: "nooberConsole")

        // Call original (swizzled) — since implementations are swapped, calling
        // probe_initWithFrame actually calls the original init(frame:configuration:)
        return self.probe_initWithFrame(frame, configuration: configuration)
    }
}

// MARK: - Script Message Handler

final class ProbeConsoleHandler: NSObject, WKScriptMessageHandler {
    static let shared = ProbeConsoleHandler()

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let level = body["level"] as? String,
              let msg = body["message"] as? String else { return }

        let url = body["url"] as? String
        let timestamp: Date
        if let ts = body["timestamp"] as? Double {
            timestamp = Date(timeIntervalSince1970: ts)
        } else {
            timestamp = Date()
        }

        let entry = ProbeWebViewConsoleCapture.ConsoleEntry(
            timestamp: timestamp,
            level: level,
            message: msg,
            url: url
        )
        ProbeWebViewConsoleCapture.addEntry(entry)
    }
}
