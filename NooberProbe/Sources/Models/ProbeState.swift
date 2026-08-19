// ProbeState.swift
// NooberProbe — Thread-safe in-memory state store
//
// Stores captured network requests, logs, user defaults, and the current screen.
// All mutations are serialized through NSLock.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

final class ProbeState: @unchecked Sendable {

    static let shared = ProbeState()

    // MARK: - Storage

    private var _httpRequests: [TransferableNetworkRequest] = []
    private var _logEntries: [TransferableLogEntry] = []
    private var _userDefaults: [TransferableUserDefaultsEntry] = []
    private var _currentScreen: String = "Unknown"

    private let lock = NSLock()

    private static let maxRequests = 500
    private static let maxLogs = 500

    private init() {}

    // MARK: - Thread-Safe Accessors

    var httpRequests: [TransferableNetworkRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _httpRequests
    }

    var logEntries: [TransferableLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return _logEntries
    }

    var userDefaults: [TransferableUserDefaultsEntry] {
        lock.lock()
        defer { lock.unlock() }
        return _userDefaults
    }

    var currentScreen: String {
        lock.lock()
        defer { lock.unlock() }
        return _currentScreen
    }

    // MARK: - Mutations

    func addRequest(_ request: TransferableNetworkRequest) {
        lock.lock()
        _httpRequests.append(request)
        if _httpRequests.count > Self.maxRequests {
            _httpRequests.removeFirst(_httpRequests.count - Self.maxRequests)
        }
        lock.unlock()
    }

    func addLog(_ entry: TransferableLogEntry) {
        lock.lock()
        _logEntries.append(entry)
        if _logEntries.count > Self.maxLogs {
            _logEntries.removeFirst(_logEntries.count - Self.maxLogs)
        }
        lock.unlock()
    }

    func setScreen(_ name: String) {
        lock.lock()
        _currentScreen = name
        lock.unlock()
    }

    /// Reads UserDefaults.standard and converts entries to TransferableUserDefaultsEntry.
    /// Filters out Apple/system keys to keep the list relevant to the app.
    func refreshUserDefaults() {
        let dict = UserDefaults.standard.dictionaryRepresentation()

        let systemPrefixes = ["Apple", "NS", "com.apple", "AK", "PK", "INNext", "WebKit"]

        var entries: [TransferableUserDefaultsEntry] = []
        for (key, value) in dict {
            // Filter system keys
            let isSystem = systemPrefixes.contains { key.hasPrefix($0) }
            if isSystem { continue }

            let (displayValue, valueType) = Self.describeValue(value)
            entries.append(TransferableUserDefaultsEntry(
                id: key,
                key: key,
                displayValue: displayValue,
                valueType: valueType
            ))
        }

        // Sort by key for stable ordering
        entries.sort { $0.key < $1.key }

        lock.lock()
        _userDefaults = entries
        lock.unlock()
    }

    /// Returns the last few HTTP requests (for crash context).
    func recentRequests() -> [TransferableNetworkRequest] {
        lock.lock()
        defer { lock.unlock() }
        return Array(_httpRequests.suffix(5))
    }

    func clear() {
        lock.lock()
        _httpRequests.removeAll()
        _logEntries.removeAll()
        _userDefaults.removeAll()
        _currentScreen = "Unknown"
        lock.unlock()
    }

    // MARK: - Value Description

    private static func describeValue(_ value: Any) -> (display: String, type: String) {
        switch value {
        case let s as String:
            let truncated = s.count > 200 ? String(s.prefix(200)) + "..." : s
            return (truncated, "String")
        case let n as NSNumber:
            // Distinguish Bool from Int/Double using ObjC type encoding
            if CFBooleanGetTypeID() == CFGetTypeID(n) {
                return (n.boolValue ? "true" : "false", "Bool")
            } else if n.doubleValue != n.doubleValue.rounded() || String(describing: n).contains(".") {
                return (String(describing: n), "Double")
            } else {
                return (String(describing: n), "Int")
            }
        case let d as Data:
            return ("(\(d.count) bytes)", "Data")
        case let date as Date:
            return (ISO8601DateFormatter().string(from: date), "Date")
        case let arr as [Any]:
            if let jsonData = try? JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed]),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                let truncated = jsonString.count > 200 ? String(jsonString.prefix(200)) + "..." : jsonString
                return (truncated, "Array")
            }
            return ("[\(arr.count) items]", "Array")
        case let dict as [String: Any]:
            if let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: [.fragmentsAllowed]),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                let truncated = jsonString.count > 200 ? String(jsonString.prefix(200)) + "..." : jsonString
                return (truncated, "Dict")
            }
            return ("{\(dict.count) keys}", "Dict")
        default:
            return (String(describing: value), "?")
        }
    }
}
