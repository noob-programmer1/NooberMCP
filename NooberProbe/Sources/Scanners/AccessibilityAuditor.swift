// AccessibilityAuditor.swift
// NooberProbe — Audits the screen for common accessibility issues

import Foundation
import UIKit

@MainActor
enum ProbeAccessibilityAuditor {
    struct AuditIssue: Codable {
        let element: String
        let issue: String
        let severity: String // "error", "warning"
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    static func audit() -> [AuditIssue] {
        let elements = ProbeAccessibilityScanner.scanAll()
        var issues: [AuditIssue] = []

        for el in elements {
            let frame = el.frame

            // Missing label on buttons
            if el.isButton && el.label.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(AuditIssue(
                    element: "Button at (\(Int(frame.midX)),\(Int(frame.midY)))",
                    issue: "Button missing accessibility label",
                    severity: "error",
                    x: Int(frame.origin.x),
                    y: Int(frame.origin.y),
                    width: Int(frame.width),
                    height: Int(frame.height)
                ))
            }

            // Small touch targets
            if (el.isButton || el.type == "Link") && (frame.width < 44 || frame.height < 44) {
                issues.append(AuditIssue(
                    element: "\(el.type) \"\(el.label.prefix(30))\"",
                    issue: "Touch target too small (\(Int(frame.width))x\(Int(frame.height)), minimum 44x44)",
                    severity: "warning",
                    x: Int(frame.origin.x),
                    y: Int(frame.origin.y),
                    width: Int(frame.width),
                    height: Int(frame.height)
                ))
            }

            // Images without alt text
            if el.type == "Image" && el.label.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(AuditIssue(
                    element: "Image at (\(Int(frame.midX)),\(Int(frame.midY)))",
                    issue: "Image missing accessibility description",
                    severity: "warning",
                    x: Int(frame.origin.x),
                    y: Int(frame.origin.y),
                    width: Int(frame.width),
                    height: Int(frame.height)
                ))
            }
        }

        return issues
    }
}
