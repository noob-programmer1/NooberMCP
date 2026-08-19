// ScreenTracker.swift
// NooberProbe — Swizzles UIViewController.viewDidAppear(_:) to track current screen
//
// Updates ProbeState with a cleaned-up view controller name whenever a new
// screen appears. Uses imp_implementationWithBlock for the swizzle to avoid
// adding Swift extension methods on UIViewController (which can clash with
// the real Noober SDK if both are loaded).

import Foundation
import ObjectiveC
#if canImport(UIKit)
import UIKit
#endif

/// Lightweight screen tracker via viewDidAppear swizzle.
/// Canonical definition — used by ProbeCommandHandler, ProbeSyncBuilder, etc.
@MainActor
enum ProbeScreenTracker {

    nonisolated(unsafe) private static var _currentScreen: String = "Unknown"
    nonisolated(unsafe) private static var isInstalled = false
    nonisolated(unsafe) private static var originalIMP: IMP?

    /// The human-readable name of the currently visible screen.
    static var currentScreen: String {
        _currentScreen
    }

    /// Install the viewDidAppear swizzle. Safe to call multiple times.
    static func install() {
        guard !isInstalled else { return }
        isInstalled = true

        let originalSelector = #selector(UIViewController.viewDidAppear(_:))
        guard let originalMethod = class_getInstanceMethod(UIViewController.self, originalSelector) else {
            probelog("ScreenTracker: failed to find viewDidAppear")
            return
        }

        originalIMP = method_getImplementation(originalMethod)

        let swizzledBlock: @convention(block) (UIViewController, Bool) -> Void = { vc, animated in
            // Call the original viewDidAppear
            let original = unsafeBitCast(originalIMP!, to: (@convention(c) (UIViewController, Selector, Bool) -> Void).self)
            original(vc, originalSelector, animated)

            // Track the screen
            handleViewDidAppear(vc)
        }

        method_setImplementation(originalMethod, imp_implementationWithBlock(swizzledBlock))
        probelog("ScreenTracker installed")
    }

    // MARK: - Private

    private static func handleViewDidAppear(_ vc: UIViewController) {
        guard shouldTrack(vc) else { return }
        let name = humanReadableName(for: vc)
        _currentScreen = name
        ProbeState.shared.setScreen(name)
    }

    /// View controller types to skip (containers, system UI, etc.)
    private static let ignoredVCTypes: Set<String> = [
        "UINavigationController",
        "UITabBarController",
        "UISplitViewController",
        "UIPageViewController",
        "UIAlertController",
        "UIInputWindowController",
        "UICompatibilityInputViewController",
        "UISystemInputAssistantViewController",
        "UIEditingOverlayViewController",
        "_UIContextMenuActionsOnlyViewController",
    ]

    private static func shouldTrack(_ vc: UIViewController) -> Bool {
        let className = String(describing: type(of: vc))

        // Skip known container / system types
        if ignoredVCTypes.contains(className) { return false }

        // Skip private system classes
        if className.hasPrefix("_UI") { return false }
        if className.hasPrefix("_") { return false }

        // Skip Noober/Probe UI
        if className.contains("Noober") || className.contains("Probe") { return false }

        // UIHostingController: only track if it has a meaningful title
        if className.hasPrefix("UIHostingController") {
            if let title = vc.title, !title.isEmpty, title.count < 60 { return true }
            // Still try to extract the generic type name
            return true
        }

        // Skip system frameworks
        let bundle = Bundle(for: type(of: vc))
        if bundle.bundlePath.contains("/System/") || bundle.bundlePath.contains("/usr/lib/") {
            return false
        }

        return true
    }

    /// Converts a view controller into a human-readable screen name.
    ///
    /// Examples:
    ///   "BookingDetailViewController" -> "Booking Detail"
    ///   "HomeController" -> "Home"
    ///   UIHostingController<HomeView> -> "HomeView" (via title) or generic extraction
    private static func humanReadableName(for vc: UIViewController) -> String {
        let className = String(describing: type(of: vc))

        // SwiftUI hosting controller: prefer title, then try generic extraction
        if className.hasPrefix("UIHostingController") || className.contains("UIHostingController") {
            if let title = vc.title, !title.isEmpty {
                return title
            }
            // Try to extract the generic parameter
            if let extracted = extractHostedViewName(className) {
                return extracted
            }
            return "SwiftUI View"
        }

        // Strip common suffixes
        var name = className
        for suffix in ["ViewController", "Controller", "Screen", "VC"] {
            if name.hasSuffix(suffix) && name.count > suffix.count {
                name = String(name.dropLast(suffix.count))
                break
            }
        }

        // Insert spaces before uppercase letters: "BookingDetail" -> "Booking Detail"
        var result = ""
        for (i, char) in name.enumerated() {
            if i > 0 && char.isUppercase {
                let prev = name[name.index(name.startIndex, offsetBy: i - 1)]
                if prev.isLowercase { result.append(" ") }
            }
            result.append(char)
        }

        return result.isEmpty ? className : result
    }

    /// Extract the view name from UIHostingController<ModuleName.ViewName> or mangled names.
    private static func extractHostedViewName(_ className: String) -> String? {
        // Pattern: "UIHostingController<MyApp.HomeView>"
        if let start = className.firstIndex(of: "<"),
           let end = className.lastIndex(of: ">") {
            let viewName = String(className[className.index(after: start)..<end])
            // Strip module prefix: "MyApp.HomeView" -> "HomeView"
            if let dotIndex = viewName.lastIndex(of: ".") {
                return String(viewName[viewName.index(after: dotIndex)...])
            }
            return viewName
        }

        // Try Swift runtime demangling for mangled names (_Tt...)
        if className.hasPrefix("_Tt") {
            return demangleAndExtract(className)
        }

        return nil
    }

    /// Attempts to demangle a Swift symbol and extract the inner type name.
    private static func demangleAndExtract(_ mangled: String) -> String? {
        guard let cStr = mangled.cString(using: .utf8) else { return nil }
        typealias DemangleFunc = @convention(c) (
            UnsafePointer<CChar>?, Int,
            UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<Int>?,
            UInt32
        ) -> UnsafeMutablePointer<CChar>?

        guard let handle = dlopen(nil, RTLD_NOW),
              let sym = dlsym(handle, "swift_demangle") else {
            return nil
        }

        let demangle = unsafeBitCast(sym, to: DemangleFunc.self)
        guard let result = demangle(cStr, mangled.count, nil, nil, 0) else { return nil }
        let demangled = String(cString: result)
        free(result)

        // Extract inner type: "SwiftUI.UIHostingController<MyApp.HomeView>" -> "HomeView"
        if let start = demangled.lastIndex(of: "<"),
           let end = demangled.lastIndex(of: ">") {
            let inner = String(demangled[demangled.index(after: start)..<end])
            if let dot = inner.lastIndex(of: ".") {
                return String(inner[inner.index(after: dot)...])
            }
            return inner
        }
        return nil
    }
}
