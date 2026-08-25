// ProbeServer.swift
// NooberProbe — Bonjour + TCP server (mirrors CompanionServer from the Noober SDK)

import Foundation
import Network
import UIKit

@MainActor
final class ProbeServer {

    static let shared = ProbeServer()

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private let queue = DispatchQueue(label: "com.nooberprobe.server", qos: .userInitiated)

    private var heartbeatTimer: Timer?
    private var pendingSendCount: Int = 0
    private let maxPendingSends = 64

    private(set) var isConnected = false

    private init() {}

    // MARK: - Start / Stop

    func start() {
        guard listener == nil else { return }

        do {
            let parameters = NWParameters.companionTCP
            let listener = try NWListener(using: parameters)

            // Bonjour service name = device name (same as real SDK)
            let serviceName = UIDevice.current.name
            listener.service = NWListener.Service(name: serviceName, type: "_noober._tcp")

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleListenerState(state)
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleNewConnection(connection)
                }
            }

            self.listener = listener
            listener.start(queue: queue)

            // Network, logs, WebView console and crash handling are already live from
            // the pre-main path; this is a no-op if the dylib bootstrapped normally.
            ProbeEarlyInstall.run()

            // These need a window / runloop, so they wait for start().
            ProbeScreenTracker.install()
            ProbePerfMonitor.install()

            fputs("[NooberProbe] Bonjour listener started as \"\(serviceName)\" on _noober._tcp\n", stderr)

            // Write ready file so NooberMCP knows the probe is up
            let readyPath = "/tmp/noobprobe_ready"
            FileManager.default.createFile(atPath: readyPath, contents: Data("ready".utf8))
        } catch {
            fputs("[NooberProbe] Failed to create listener: \(error)\n", stderr)
        }
    }

    func stop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        activeConnection?.cancel()
        activeConnection = nil

        listener?.cancel()
        listener = nil

        isConnected = false
        pendingSendCount = 0
    }

    // MARK: - Send

    func send(_ message: CompanionMessage) {
        guard let connection = activeConnection, isConnected else { return }

        // Back-pressure: skip non-critical messages if too many are in flight
        if pendingSendCount >= maxPendingSends {
            if message.type != .heartbeat && message.type != .syncFull {
                return
            }
        }

        pendingSendCount += 1
        connection.sendCompanionMessage(message, on: queue) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.pendingSendCount = max(0, self.pendingSendCount - 1)
                if error != nil {
                    self.handleConnectionLost()
                }
            }
        }
    }

    // MARK: - Listener State

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            fputs("[NooberProbe] Listener ready\n", stderr)
        case .failed:
            fputs("[NooberProbe] Listener failed — restarting in 2s\n", stderr)
            listener?.cancel()
            listener = nil
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.start()
            }
        case .cancelled:
            break
        default:
            break
        }
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        fputs("[NooberProbe] New connection received\n", stderr)

        // If we already have an active connection, cancel it
        if let existing = activeConnection {
            existing.cancel()
        }

        activeConnection = connection
        pendingSendCount = 0

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state)
            }
        }

        connection.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            fputs("[NooberProbe] Connection ready — sending full sync\n", stderr)
            isConnected = true
            sendFullSync()
            startHeartbeat()
        case .failed, .cancelled:
            handleConnectionLost()
        case .waiting:
            break
        default:
            break
        }
    }

    private func handleConnectionLost() {
        guard isConnected || activeConnection != nil else { return }

        fputs("[NooberProbe] Connection lost\n", stderr)

        isConnected = false
        pendingSendCount = 0

        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        activeConnection?.cancel()
        activeConnection = nil
    }

    // MARK: - Receive

    private func receiveNextMessage() {
        guard let connection = activeConnection else { return }

        connection.receiveCompanionMessage(on: queue) { [weak self] message, error in
            Task { @MainActor in
                guard let self else { return }

                if let error = error as? NWError {
                    _ = error // suppress warning
                    self.handleConnectionLost()
                    return
                }

                if let error {
                    if error is DecodingError {
                        // Unknown message type — skip and keep connection alive
                    } else {
                        self.handleConnectionLost()
                        return
                    }
                }

                if let message {
                    if message.type == .heartbeat {
                        // Heartbeat acknowledged — connection alive
                    } else {
                        ProbeCommandHandler.handle(message)
                    }
                }

                // Schedule next receive
                self.receiveNextMessage()
            }
        }
    }

    // MARK: - Full Sync

    private func sendFullSync() {
        let payload = ProbeSyncBuilder.buildFullSync()

        if let message = try? CompanionMessage(type: .syncFull, payload: payload) {
            send(message)
        }

        // Start receiving commands after sync
        receiveNextMessage()
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isConnected else { return }
                let heartbeat = CompanionMessage(type: .heartbeat)
                self.send(heartbeat)
            }
        }
    }
}
