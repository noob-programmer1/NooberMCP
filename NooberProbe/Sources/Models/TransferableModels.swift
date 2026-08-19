// TransferableModels.swift
// NooberProbe — Codable model types matching the Noober SDK Companion protocol
//
// These types are standalone copies of the NooberShared transferable models.
// The JSON encoding MUST match what NooberClient.swift (macOS side) expects:
//   - JSONEncoder/Decoder with .secondsSince1970 date strategy
//   - Field names identical to NooberShared types
//
// The probe dylib cannot link NooberShared (iOS target vs macOS), so we
// duplicate the minimal set of types here.

import Foundation

// MARK: - Network

struct TransferableNetworkRequest: Codable, Sendable {
    let id: UUID
    let timestamp: Date
    let url: String
    let host: String
    let path: String
    let method: String
    let requestHeaders: [String: String]
    let requestBody: Data?
    let statusCode: Int?
    let responseHeaders: [String: String]
    let responseBody: Data?
    let duration: TimeInterval          // seconds (matches Noober SDK)
    let errorDescription: String?
    let mimeType: String?
    let isMocked: Bool
    let isIntercepted: Bool
    let isEnvironmentRewritten: Bool
    let originalURL: String?
    let screenName: String?
    let source: String?                 // "URLSession" or "WebView"
}

// MARK: - Logs

struct TransferableLogEntry: Codable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: String                   // "DEBUG", "INFO", "WARN", "ERROR"
    let category: String
    let message: String
    let file: String
    let line: UInt
    let screenName: String?
}

// MARK: - User Defaults

struct TransferableUserDefaultsEntry: Codable, Sendable {
    let id: String
    let key: String
    let displayValue: String
    let valueType: String               // "String", "Int", "Double", "Bool", "Data", "Date", "Array", "Dict", "?"
}

// MARK: - WebSocket

struct TransferableWSConnection: Codable, Sendable {
    let id: UUID
    let url: String
    let host: String
    let startTime: Date
    let status: String                  // "Connecting", "Connected", "Disconnected", "Error"
    let frames: [TransferableWSFrame]
    let closeCode: Int?
    let closeReason: String?
}

struct TransferableWSFrame: Codable, Sendable {
    let id: UUID
    let connectionId: UUID
    let timestamp: Date
    let direction: String               // "Sent" or "Received"
    let frameType: String               // "TEXT", "BIN", "PING", "PONG", "CLOSE"
    let payload: Data?
    let payloadString: String?
}

// MARK: - Environment

struct TransferableEnvironment: Codable, Sendable {
    let id: UUID
    let name: String
    let baseURLs: [String]
    let notes: String
}

struct TransferableEnvironmentState: Codable, Sendable {
    let environments: [TransferableEnvironment]
    let activeEnvironmentId: UUID?
}

// MARK: - Rules (stub types — probe has no rule engine)

struct TransferableURLMatchPattern: Codable, Sendable {
    let mode: String
    let pattern: String
}

struct TransferableRewriteRule: Codable, Sendable {
    let id: UUID
    let name: String
    let matchPattern: TransferableURLMatchPattern
    let replacementHost: String
    let isEnabled: Bool
    let createdAt: Date
}

struct TransferableMockRule: Codable, Sendable {
    let id: UUID
    let name: String
    let matchPattern: TransferableURLMatchPattern
    let httpMethod: String?
    let mockStatusCode: Int
    let mockResponseHeaders: [String: String]
    let mockResponseBody: Data?
    let isEnabled: Bool
    let createdAt: Date
}

struct TransferableInterceptRule: Codable, Sendable {
    let id: UUID
    let name: String
    let matchPattern: TransferableURLMatchPattern
    let httpMethod: String?
    let isEnabled: Bool
    let createdAt: Date
}

struct TransferableRulesState: Codable, Sendable {
    let rewriteRules: [TransferableRewriteRule]
    let mockRules: [TransferableMockRule]
    let interceptRules: [TransferableInterceptRule]
}

// MARK: - QA Checklist (stub — probe has no QA engine)

struct TransferableQAResult: Codable, Sendable {
    let id: UUID
    let title: String
    let notes: String
    let priority: String
    let endpoints: [String]
    let status: String
    let failNotes: String
    let attachedRequestIds: [UUID]
}

struct TransferableQAState: Codable, Sendable {
    let results: [TransferableQAResult]
    let buildNumber: String
}

// MARK: - Keychain

struct TransferableKeychainEntry: Codable, Sendable {
    let id: String
    let itemClass: String               // "Generic" or "Internet"
    let service: String
    let account: String
    let accessGroup: String?
    let createdAt: Date?
    let modifiedAt: Date?
    let label: String?
}

// MARK: - Full Sync Payload
//
// Matches the Noober SDK's CompanionServer.sendFullSync() layout.
// NooberClient uses a "LenientSyncPayload" with optional fields and
// nested `environmentState` / `rulesState` / `qaState` sub-objects.

struct FullSyncPayload: Codable, Sendable {
    let httpRequests: [TransferableNetworkRequest]
    let wsConnections: [TransferableWSConnection]
    let logEntries: [TransferableLogEntry]
    let environmentState: TransferableEnvironmentState
    let rulesState: TransferableRulesState
    let qaState: TransferableQAState
    let userDefaultsEntries: [TransferableUserDefaultsEntry]
    let keychainEntries: [TransferableKeychainEntry]
    let currentScreen: String
    let deviceName: String
    let appName: String
    let appVersion: String
    let recordedFlows: [NooberFlow]?
}

// MARK: - Recorded Flows (matches SDK's NooberFlow)

struct NooberFlow: Codable, Sendable {
    let id: UUID
    let name: String
    let description: String
    let steps: [NooberFlowStep]
    let recordedAt: Date
    let device: DeviceInfo?

    struct DeviceInfo: Codable, Sendable {
        let name: String
        let screenWidth: Int
        let screenHeight: Int
        let scale: Int
    }
}

struct NooberFlowStep: Codable, Sendable {
    enum Action: String, Codable, Sendable {
        case tap
        case swipe
        case typeText = "type_text"
        case longPress = "long_press"
    }

    struct Coordinates: Codable, Sendable {
        let x: Double
        let y: Double
    }

    let action: Action
    let screen: String
    let label: String?
    let text: String?
    let startCoordinates: Coordinates?
    let endCoordinates: Coordinates?
    let extra: [String: String]?
}

// MARK: - Accessibility / Screen Responses

struct FindElementResult: Codable, Sendable {
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

struct FindElementResponse: Codable, Sendable {
    let screen: String
    let query: String
    let results: [FindElementResult]
}

struct ScreenTextResponse: Codable, Sendable {
    let screen: String
    let lines: [String]
}

struct SnapshotElement: Codable, Sendable {
    let label: String?
    let identifier: String?
    let type: String
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let interactive: Bool
}

struct SnapshotResponse: Codable, Sendable {
    let screen: String
    let elements: [SnapshotElement]
}

struct ScreenshotResponse: Codable, Sendable {
    let screen: String
    let base64PNG: String
}

struct ScreenHTMLResponse: Codable, Sendable {
    let screen: String
    let html: String
    let elementCount: Int
}
