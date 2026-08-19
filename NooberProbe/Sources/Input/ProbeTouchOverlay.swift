// ProbeTouchOverlay.swift
// NooberProbe — Visual feedback for ALL AI-driven interactions.
// Tap ripples, swipe trails, scan lines, camera flash, data pulses, and a
// persistent Siri-like glowing orb that activates when any AI tool runs.

import UIKit

// MARK: - Tool Activity Category

enum ProbeToolCategory {
    case input       // tap, swipe, type — blue
    case scan        // screen_html, screen_text, find_element — cyan
    case capture     // screenshot — white flash
    case data        // network_logs, app_logs, user_defaults, cookies, websocket — purple
    case verify      // assert_request, check_event, get_value — green/red
    case environment // switch_env, get_env — orange

    var color: UIColor {
        switch self {
        case .input:       return .systemBlue
        case .scan:        return .systemCyan
        case .capture:     return .white
        case .data:        return UIColor(red: 0.6, green: 0.4, blue: 1.0, alpha: 1.0) // purple
        case .verify:      return .systemGreen
        case .environment: return .systemOrange
        }
    }

    var label: String {
        switch self {
        case .input:       return "INPUT"
        case .scan:        return "SCANNING"
        case .capture:     return "CAPTURE"
        case .data:        return "READING"
        case .verify:      return "VERIFYING"
        case .environment: return "ENV"
        }
    }

    var icon: String {
        switch self {
        case .input:       return "\u{25C9}"  // ◉
        case .scan:        return "\u{29D6}"  // ⧖
        case .capture:     return "\u{25CE}"  // ◎
        case .data:        return "\u{2261}"  // ≡
        case .verify:      return "\u{2713}"  // ✓
        case .environment: return "\u{21C4}"  // ⇄
        }
    }
}

// MARK: - Main Overlay Controller

@MainActor
enum ProbeTouchOverlay {

    // MARK: - Overlay Window (lazy, passthrough, strong ref)

    private static var _overlayWindow: UIWindow?

    private static var overlayWindow: UIWindow? {
        if let existing = _overlayWindow, existing.windowScene != nil { return existing }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
              ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else {
            fputs("[NooberProbe] TouchOverlay: no window scene found\n", stderr)
            return nil
        }

        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = .alert + 100
        window.backgroundColor = .clear
        window.isHidden = false
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        vc.view.isUserInteractionEnabled = false
        window.rootViewController = vc
        _overlayWindow = window
        fputs("[NooberProbe] TouchOverlay: overlay window created\n", stderr)
        return window
    }

    private static var container: UIView? {
        overlayWindow?.rootViewController?.view
    }

    // MARK: - Orb (persistent AI activity indicator)

    private static var orbView: ProbeOrbView?
    private static var orbHideTimer: Timer?

    /// Show/update the orb. Each call resets the auto-hide timer to 3s.
    /// During active tool chains (tools every few seconds), the orb stays
    /// visible continuously with the shimmer animation running.
    private static func showOrb(category: ProbeToolCategory, detail: String? = nil) {
        guard let container else { return }

        if orbView == nil {
            let orb = ProbeOrbView()
            let safeBottom = container.safeAreaInsets.bottom
            let y = container.bounds.height - 60 - safeBottom
            orb.frame = CGRect(x: (container.bounds.width - 140) / 2, y: y, width: 140, height: 36)
            orb.alpha = 0
            orb.transform = CGAffineTransform(scaleX: 0.8, y: 0.8).concatenating(
                CGAffineTransform(translationX: 0, y: 10)
            )
            container.addSubview(orb)
            orbView = orb
        }

        orbView?.configure(category: category, detail: detail)

        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0, options: []) {
            orbView?.alpha = 1
            orbView?.transform = .identity
        }

        // Reset auto-hide: 3s after the last tool call
        orbHideTimer?.invalidate()
        orbHideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            Task { @MainActor in
                UIView.animate(withDuration: 0.4) {
                    orbView?.alpha = 0
                    orbView?.transform = CGAffineTransform(scaleX: 0.8, y: 0.8).concatenating(
                        CGAffineTransform(translationX: 0, y: 10)
                    )
                }
            }
        }
    }

    /// Explicitly dismiss the orb (e.g., from MCP hideOverlay command).
    static func hideOrb() {
        orbHideTimer?.invalidate()
        orbHideTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            Task { @MainActor in
                UIView.animate(withDuration: 0.3) {
                    orbView?.alpha = 0
                    orbView?.transform = CGAffineTransform(scaleX: 0.8, y: 0.8).concatenating(
                        CGAffineTransform(translationX: 0, y: 10)
                    )
                }
            }
        }
    }

    // MARK: - Tap Ripple

    static func showTap(at point: CGPoint) {
        fputs("[NooberProbe] TouchOverlay: showTap at \(Int(point.x)),\(Int(point.y))\n", stderr)
        showOrb(category: .input, detail: "tap \(Int(point.x)),\(Int(point.y))")
        guard let container else { return }

        let size: CGFloat = 44
        let ripple = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        ripple.center = point
        ripple.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.35)
        ripple.layer.cornerRadius = size / 2
        ripple.layer.borderWidth = 2
        ripple.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.7).cgColor
        ripple.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        container.addSubview(ripple)

        let dot = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
        dot.center = CGPoint(x: size / 2, y: size / 2)
        dot.backgroundColor = .white
        dot.layer.cornerRadius = 4
        ripple.addSubview(dot)

        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0, options: []) {
            ripple.transform = .identity
        } completion: { _ in
            UIView.animate(withDuration: 0.3, delay: 0.1) {
                ripple.alpha = 0
                ripple.transform = CGAffineTransform(scaleX: 1.5, y: 1.5)
            } completion: { _ in
                ripple.removeFromSuperview()
            }
        }
    }

    // MARK: - Swipe Trail

    static func showSwipe(from start: CGPoint, to end: CGPoint) {
        fputs("[NooberProbe] TouchOverlay: showSwipe \(Int(start.x)),\(Int(start.y)) -> \(Int(end.x)),\(Int(end.y))\n", stderr)
        showOrb(category: .input, detail: "swipe")
        guard let container else { return }

        let trailLayer = CAShapeLayer()
        let path = UIBezierPath()
        path.move(to: start)
        path.addLine(to: end)
        trailLayer.path = path.cgPath
        trailLayer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.6).cgColor
        trailLayer.lineWidth = 3
        trailLayer.lineCap = .round
        trailLayer.fillColor = nil
        trailLayer.lineDashPattern = [6, 4]
        container.layer.addSublayer(trailLayer)

        let startDot = makeDot(at: start, color: .systemBlue, size: 10)
        container.addSubview(startDot)

        let head = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
        head.center = start
        head.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.5)
        head.layer.cornerRadius = 8
        head.layer.borderWidth = 2
        head.layer.borderColor = UIColor.systemBlue.cgColor
        container.addSubview(head)

        let arrow = makeArrow(at: end, from: start)
        container.layer.addSublayer(arrow)

        let drawAnim = CABasicAnimation(keyPath: "strokeEnd")
        drawAnim.fromValue = 0
        drawAnim.toValue = 1
        drawAnim.duration = 0.35
        trailLayer.add(drawAnim, forKey: "draw")

        UIView.animate(withDuration: 0.35, delay: 0, options: .curveEaseInOut) {
            head.center = end
        } completion: { _ in
            UIView.animate(withDuration: 0.3, delay: 0.15) {
                head.alpha = 0
                startDot.alpha = 0
            } completion: { _ in
                trailLayer.removeFromSuperlayer()
                arrow.removeFromSuperlayer()
                head.removeFromSuperview()
                startDot.removeFromSuperview()
            }
            let fadeAnim = CABasicAnimation(keyPath: "opacity")
            fadeAnim.fromValue = 1
            fadeAnim.toValue = 0
            fadeAnim.beginTime = CACurrentMediaTime() + 0.15
            fadeAnim.duration = 0.3
            fadeAnim.fillMode = .forwards
            fadeAnim.isRemovedOnCompletion = false
            trailLayer.add(fadeAnim, forKey: "fade")
            arrow.add(fadeAnim, forKey: "fade")
        }
    }

    // MARK: - Type Text Indicator

    static func showTypeText(near point: CGPoint?) {
        showOrb(category: .input, detail: "typing")
        guard let container else { return }

        let label = UILabel()
        label.text = "  abc  "
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.8)
        label.layer.cornerRadius = 10
        label.layer.masksToBounds = true
        label.textAlignment = .center
        label.sizeToFit()
        label.frame.size.height = 20

        if let point {
            label.center = CGPoint(x: point.x, y: point.y - 30)
        } else {
            label.center = CGPoint(x: container.bounds.midX, y: container.bounds.maxY - 80)
        }

        label.alpha = 0
        label.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        container.addSubview(label)

        UIView.animate(withDuration: 0.15) {
            label.alpha = 1
            label.transform = .identity
        } completion: { _ in
            UIView.animate(withDuration: 0.25, delay: 0.4) {
                label.alpha = 0
            } completion: { _ in
                label.removeFromSuperview()
            }
        }
    }

    // MARK: - Scan Line (screen_html, screen_text, find_element)

    static func showScan() {
        fputs("[NooberProbe] TouchOverlay: showScan\n", stderr)
        showOrb(category: .scan, detail: "screen")
        guard let container else { return }

        let scanLine = UIView(frame: CGRect(x: 0, y: 0, width: container.bounds.width, height: 2))
        scanLine.backgroundColor = UIColor.systemCyan.withAlphaComponent(0.8)

        // Glow effect
        scanLine.layer.shadowColor = UIColor.systemCyan.cgColor
        scanLine.layer.shadowOffset = .zero
        scanLine.layer.shadowRadius = 8
        scanLine.layer.shadowOpacity = 0.9

        container.addSubview(scanLine)

        // Edge highlight bars
        let leftBar = UIView(frame: CGRect(x: 0, y: 0, width: 3, height: container.bounds.height))
        leftBar.backgroundColor = UIColor.systemCyan.withAlphaComponent(0.15)
        let rightBar = UIView(frame: CGRect(x: container.bounds.width - 3, y: 0, width: 3, height: container.bounds.height))
        rightBar.backgroundColor = UIColor.systemCyan.withAlphaComponent(0.15)
        container.addSubview(leftBar)
        container.addSubview(rightBar)
        leftBar.alpha = 0
        rightBar.alpha = 0

        UIView.animate(withDuration: 0.1) {
            leftBar.alpha = 1
            rightBar.alpha = 1
        }

        UIView.animate(withDuration: 0.6, delay: 0, options: .curveEaseInOut) {
            scanLine.frame.origin.y = container.bounds.height
        } completion: { _ in
            UIView.animate(withDuration: 0.2) {
                scanLine.alpha = 0
                leftBar.alpha = 0
                rightBar.alpha = 0
            } completion: { _ in
                scanLine.removeFromSuperview()
                leftBar.removeFromSuperview()
                rightBar.removeFromSuperview()
            }
        }
    }

    // MARK: - Screenshot Flash

    static func showCaptureFlash() {
        fputs("[NooberProbe] TouchOverlay: showCaptureFlash\n", stderr)
        showOrb(category: .capture, detail: "screenshot")
        guard let container else { return }

        let flash = UIView(frame: container.bounds)
        flash.backgroundColor = .white
        flash.alpha = 0
        container.addSubview(flash)

        UIView.animate(withDuration: 0.08) {
            flash.alpha = 0.7
        } completion: { _ in
            UIView.animate(withDuration: 0.25) {
                flash.alpha = 0
            } completion: { _ in
                flash.removeFromSuperview()
            }
        }
    }

    // MARK: - Data Pulse (network, logs, defaults)

    static func showDataPulse(detail: String) {
        fputs("[NooberProbe] TouchOverlay: showDataPulse — \(detail)\n", stderr)
        showOrb(category: .data, detail: detail)
        guard let container else { return }

        // Corner pulse rings (top-right) indicating data flowing
        let pulseSize: CGFloat = 24
        let pulseCenter = CGPoint(x: container.bounds.width - 30, y: 50)

        for i in 0..<3 {
            let ring = UIView(frame: CGRect(x: 0, y: 0, width: pulseSize, height: pulseSize))
            ring.center = pulseCenter
            ring.backgroundColor = .clear
            ring.layer.cornerRadius = pulseSize / 2
            ring.layer.borderWidth = 1.5
            ring.layer.borderColor = UIColor(red: 0.6, green: 0.4, blue: 1.0, alpha: 0.7).cgColor
            ring.alpha = 0
            ring.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
            container.addSubview(ring)

            let delay = Double(i) * 0.15
            UIView.animate(withDuration: 0.4, delay: delay, options: .curveEaseOut) {
                ring.alpha = 1
                ring.transform = .identity
            } completion: { _ in
                UIView.animate(withDuration: 0.3) {
                    ring.alpha = 0
                    ring.transform = CGAffineTransform(scaleX: 2.0, y: 2.0)
                } completion: { _ in
                    ring.removeFromSuperview()
                }
            }
        }
    }

    // MARK: - Verify Result (assert, check)

    static func showVerifyResult(passed: Bool, detail: String) {
        fputs("[NooberProbe] TouchOverlay: showVerify — \(passed ? "PASS" : "FAIL") \(detail)\n", stderr)
        showOrb(category: .verify, detail: passed ? "PASS" : "FAIL")
        guard let container else { return }

        let badge = UIView(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
        badge.center = CGPoint(x: container.bounds.midX, y: container.bounds.midY - 40)
        badge.backgroundColor = (passed ? UIColor.systemGreen : UIColor.systemRed).withAlphaComponent(0.9)
        badge.layer.cornerRadius = 24

        let symbol = UILabel(frame: badge.bounds)
        symbol.text = passed ? "\u{2713}" : "\u{2717}"  // ✓ or ✗
        symbol.font = .systemFont(ofSize: 26, weight: .bold)
        symbol.textColor = .white
        symbol.textAlignment = .center
        badge.addSubview(symbol)

        badge.alpha = 0
        badge.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
        container.addSubview(badge)

        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0, options: []) {
            badge.alpha = 1
            badge.transform = .identity
        } completion: { _ in
            UIView.animate(withDuration: 0.25, delay: 0.6) {
                badge.alpha = 0
                badge.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
            } completion: { _ in
                badge.removeFromSuperview()
            }
        }
    }

    // MARK: - Environment Switch

    static func showEnvironmentSwitch(name: String) {
        fputs("[NooberProbe] TouchOverlay: showEnvSwitch — \(name)\n", stderr)
        showOrb(category: .environment, detail: name)
    }

    // MARK: - Generic Tool Activity (for tools without a specific animation)

    static func showToolActivity(category: ProbeToolCategory, detail: String) {
        showOrb(category: category, detail: detail)
    }

    // MARK: - Helpers

    private static func makeDot(at point: CGPoint, color: UIColor, size: CGFloat) -> UIView {
        let dot = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        dot.center = point
        dot.backgroundColor = color.withAlphaComponent(0.8)
        dot.layer.cornerRadius = size / 2
        return dot
    }

    private static func makeArrow(at tip: CGPoint, from origin: CGPoint) -> CAShapeLayer {
        let angle = atan2(tip.y - origin.y, tip.x - origin.x)
        let arrowLength: CGFloat = 10
        let arrowAngle: CGFloat = .pi / 6

        let path = UIBezierPath()
        path.move(to: tip)
        path.addLine(to: CGPoint(
            x: tip.x - arrowLength * cos(angle - arrowAngle),
            y: tip.y - arrowLength * sin(angle - arrowAngle)
        ))
        path.move(to: tip)
        path.addLine(to: CGPoint(
            x: tip.x - arrowLength * cos(angle + arrowAngle),
            y: tip.y - arrowLength * sin(angle + arrowAngle)
        ))

        let layer = CAShapeLayer()
        layer.path = path.cgPath
        layer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.8).cgColor
        layer.lineWidth = 2.5
        layer.lineCap = .round
        layer.fillColor = nil
        return layer
    }
}

// MARK: - Siri-like Orb View

private class ProbeOrbView: UIView {

    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let iconLabel = UILabel()
    private let textLabel = UILabel()
    private let glowLayer = CAGradientLayer()
    private var pulseAnimation: CAAnimation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        layer.cornerRadius = 18
        clipsToBounds = true

        // Blur background
        blurView.frame = bounds
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(blurView)

        // Glow border
        layer.borderWidth = 1.5
        layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.6).cgColor

        // Animated gradient glow behind content
        glowLayer.frame = CGRect(x: 0, y: 0, width: bounds.width * 2, height: bounds.height)
        glowLayer.startPoint = CGPoint(x: 0, y: 0.5)
        glowLayer.endPoint = CGPoint(x: 1, y: 0.5)
        glowLayer.cornerRadius = 18
        blurView.contentView.layer.addSublayer(glowLayer)

        // Icon
        iconLabel.font = .systemFont(ofSize: 13)
        iconLabel.textAlignment = .center
        iconLabel.frame = CGRect(x: 6, y: 0, width: 24, height: 36)
        addSubview(iconLabel)

        // Label
        textLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        textLabel.frame = CGRect(x: 30, y: 0, width: bounds.width - 36, height: 36)
        addSubview(textLabel)
    }

    func configure(category: ProbeToolCategory, detail: String?) {
        let color = category.color
        iconLabel.text = category.icon
        iconLabel.textColor = color

        let displayText = detail ?? category.label
        textLabel.text = displayText.uppercased()
        textLabel.textColor = color

        layer.borderColor = color.withAlphaComponent(0.5).cgColor

        // Update gradient glow colors
        glowLayer.colors = [
            color.withAlphaComponent(0.0).cgColor,
            color.withAlphaComponent(0.15).cgColor,
            color.withAlphaComponent(0.0).cgColor
        ]
        glowLayer.locations = [0, 0.5, 1]

        // Shimmer animation
        glowLayer.removeAnimation(forKey: "shimmer")
        let shimmer = CABasicAnimation(keyPath: "position.x")
        shimmer.fromValue = -bounds.width
        shimmer.toValue = bounds.width * 2
        shimmer.duration = 1.2
        shimmer.repeatCount = .infinity
        glowLayer.add(shimmer, forKey: "shimmer")
    }
}

// MARK: - Passthrough Window

private class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil  // All touches pass through
    }
}
