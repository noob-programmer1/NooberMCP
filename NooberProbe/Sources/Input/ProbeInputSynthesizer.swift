// ProbeInputSynthesizer.swift
// NooberProbe — In-process touch synthesis for tap, swipe, and text input.
// Uses UIKit hit-testing and accessibility activation instead of external AXe binary.

import Foundation
import UIKit

@MainActor
enum ProbeInputSynthesizer {

    struct InputResult: Codable {
        let success: Bool
        let message: String
    }

    // MARK: - Tap

    /// Tap at screen coordinates by finding the view at that point and activating it.
    static func tap(x: Int, y: Int) -> InputResult {
        let point = CGPoint(x: x, y: y)

        guard let window = appWindow else {
            return InputResult(success: false, message: "No key window found")
        }

        // Find the view at this point
        guard let hitView = window.hitTest(point, with: nil) else {
            return InputResult(success: false, message: "No view at (\(x),\(y))")
        }

        // Try accessibility activation first (works for buttons, controls)
        if hitView.accessibilityActivate() {
            return InputResult(success: true, message: "Tapped via accessibility: \(hitView.accessibilityLabel ?? type(of: hitView).description())")
        }

        // Fallback: walk up to find a UIControl and send actions
        var view: UIView? = hitView
        while let current = view {
            if let control = current as? UIControl {
                control.sendActions(for: .touchUpInside)
                return InputResult(success: true, message: "Tapped control: \(control.accessibilityLabel ?? type(of: control).description())")
            }
            // Check for tap gesture recognizers
            if let gestures = current.gestureRecognizers {
                for gesture in gestures where gesture is UITapGestureRecognizer {
                    gesture.state = .ended
                    return InputResult(success: true, message: "Triggered tap gesture on: \(current.accessibilityLabel ?? type(of: current).description())")
                }
            }
            view = current.superview
        }

        return InputResult(success: false, message: "No tappable element at (\(x),\(y))")
    }

    // MARK: - Swipe

    /// Swipe from one point to another by programmatically scrolling the nearest scroll view.
    static func swipe(x1: Int, y1: Int, x2: Int, y2: Int, duration: Double = 0.5) -> InputResult {
        guard let window = appWindow else {
            return InputResult(success: false, message: "No key window found")
        }

        let startPoint = CGPoint(x: x1, y: y1)
        var view: UIView? = window.hitTest(startPoint, with: nil)

        while let current = view {
            if let scrollView = current as? UIScrollView {
                let dx = CGFloat(x1 - x2)
                let dy = CGFloat(y1 - y2)
                let newOffset = CGPoint(
                    x: scrollView.contentOffset.x + dx,
                    y: scrollView.contentOffset.y + dy
                )
                scrollView.setContentOffset(newOffset, animated: true)
                return InputResult(success: true, message: "Scrolled by (\(Int(dx)),\(Int(dy)))")
            }
            view = current.superview
        }

        return InputResult(success: false, message: "No scrollable view found at (\(x1),\(y1))")
    }

    // MARK: - Type Text

    /// Type text into the current first responder.
    static func typeText(_ text: String) -> InputResult {
        guard let window = appWindow else {
            return InputResult(success: false, message: "No key window found")
        }

        guard let responder = window.findFirstResponder() else {
            return InputResult(success: false, message: "No text field is focused")
        }

        if let textInput = responder as? UITextInput {
            textInput.insertText(text)
            return InputResult(success: true, message: "Typed \(text.count) characters")
        }

        if let keyInput = responder as? UIKeyInput {
            for char in text {
                keyInput.insertText(String(char))
            }
            return InputResult(success: true, message: "Typed \(text.count) characters via UIKeyInput")
        }

        return InputResult(success: false, message: "First responder doesn't accept text input")
    }

    // MARK: - Helpers

    private static var appWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}

// MARK: - UIView First Responder Search

extension UIView {
    func findFirstResponder() -> UIResponder? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let responder = subview.findFirstResponder() { return responder }
        }
        return nil
    }
}
