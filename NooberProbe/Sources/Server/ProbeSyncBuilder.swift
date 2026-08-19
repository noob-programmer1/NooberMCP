// ProbeSyncBuilder.swift
// NooberProbe — Builds the FullSyncPayload for NooberMCP

import Foundation
import UIKit

/// Builds a FullSyncPayload that matches the exact Codable structure
/// NooberClient.handleFullSync expects on the MCP side.
///
/// The probe uses ProbeState for captured HTTP requests/logs (from the
/// NetworkInterceptor) and gathers UserDefaults directly.
@MainActor
enum ProbeSyncBuilder {

    static func buildFullSync() -> FullSyncPayload {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Unknown"

        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let appVersion = "\(shortVersion) (\(buildNumber))"

        // Install screen tracker on first sync (safe to call multiple times)
        ProbeScreenTracker.install()

        // Refresh UserDefaults in ProbeState
        ProbeState.shared.refreshUserDefaults()

        return FullSyncPayload(
            httpRequests: ProbeState.shared.httpRequests,
            wsConnections: [],
            logEntries: ProbeState.shared.logEntries,
            environmentState: TransferableEnvironmentState(
                environments: [],
                activeEnvironmentId: nil
            ),
            rulesState: TransferableRulesState(
                rewriteRules: [],
                mockRules: [],
                interceptRules: []
            ),
            qaState: TransferableQAState(
                results: [],
                buildNumber: buildNumber
            ),
            userDefaultsEntries: ProbeState.shared.userDefaults,
            keychainEntries: [],
            currentScreen: ProbeScreenTracker.currentScreen,
            deviceName: UIDevice.current.name,
            appName: appName,
            appVersion: appVersion,
            recordedFlows: nil
        )
    }
}
