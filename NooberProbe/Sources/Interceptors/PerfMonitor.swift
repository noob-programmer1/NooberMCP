// PerfMonitor.swift
// NooberProbe — FPS + memory profiling for performance snapshots

import Foundation
import UIKit
import QuartzCore

@MainActor
enum ProbePerfMonitor {
    nonisolated(unsafe) fileprivate static var displayLink: CADisplayLink?
    nonisolated(unsafe) fileprivate static var lastTimestamp: CFTimeInterval = 0
    nonisolated(unsafe) fileprivate static var frameCount: Int = 0
    nonisolated(unsafe) fileprivate static var currentFPS: Double = 0
    private static var samples: [(fps: Double, memoryMB: Double, timestamp: Date)] = []
    private static let maxSamples = 60
    private static var timer: Timer?

    static func install() {
        let link = CADisplayLink(target: DisplayLinkTarget.shared, selector: #selector(DisplayLinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                let fps = currentFPS
                let mem = memoryUsageMB()
                samples.append((fps: fps, memoryMB: mem, timestamp: Date()))
                if samples.count > maxSamples { samples.removeFirst() }
            }
        }
    }

    static func snapshot() -> (fps: Double, memoryMB: Double, avgFPS: Double, peakMemoryMB: Double) {
        let avgFPS = samples.isEmpty ? 0 : samples.map(\.fps).reduce(0, +) / Double(samples.count)
        let peakMem = samples.map(\.memoryMB).max() ?? 0
        return (fps: currentFPS, memoryMB: memoryUsageMB(), avgFPS: avgFPS, peakMemoryMB: peakMem)
    }

    nonisolated static func memoryUsageMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576.0 : 0
    }
}

private class DisplayLinkTarget: NSObject {
    static let shared = DisplayLinkTarget()

    @objc func tick(_ link: CADisplayLink) {
        if ProbePerfMonitor.lastTimestamp > 0 {
            ProbePerfMonitor.frameCount += 1
            let elapsed = link.timestamp - ProbePerfMonitor.lastTimestamp
            if elapsed >= 1.0 {
                ProbePerfMonitor.currentFPS = Double(ProbePerfMonitor.frameCount) / elapsed
                ProbePerfMonitor.frameCount = 0
                ProbePerfMonitor.lastTimestamp = link.timestamp
            }
        } else {
            ProbePerfMonitor.lastTimestamp = link.timestamp
        }
    }
}
