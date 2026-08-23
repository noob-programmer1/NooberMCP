---
description: Integrate the Noober SDK into an iOS app so the Noober MCP tools can see inside it. Use when noober_status reports "not connected", when someone installs the Noober plugin, or when asked to set up, add, or wire up Noober in an iOS project.
---

# Set up the Noober SDK

The Noober MCP tools read from a socket that the **Noober SDK opens inside the user's
app**. Without the SDK integrated and running, every `noober_*` tool reports "not
connected". This skill wires it up.

## 1. Confirm what you're working with

Find the project root and how dependencies are managed:

- `*.xcodeproj` / `*.xcworkspace` → Xcode-managed dependencies
- `Package.swift` with an iOS app target → SwiftPM
- `Podfile` → CocoaPods project that still resolves SPM packages through Xcode

If there is no iOS project in the working directory, stop and ask where it lives. Do not
guess at a path outside the workspace.

## 2. Add the package dependency

SwiftPM (`Package.swift`):

```swift
.package(url: "https://github.com/noob-programmer1/Noober-iOS.git", from: "1.2.0")
```

Then add `"Noober"` to the app target's `dependencies`.

For an `.xcodeproj`, editing `project.pbxproj` by hand is error-prone. Prefer telling the
user to add it through Xcode (File → Add Package Dependencies → paste the URL), and
continue with step 3 once they confirm.

## 3. Start it — placement matters

```swift
#if DEBUG
import Noober
#endif

// UIKit — AppDelegate
func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    #if DEBUG
    Noober.shared.start()
    #endif
    return true
}

// SwiftUI — root view
WindowGroup {
    ContentView()
        .onAppear {
            #if DEBUG
            Noober.shared.start()
            #endif
        }
}
```

**Do not call `start()` from `App.init()`.** It needs a live `UIWindowScene` to attach the
floating debug bubble to. In `App.init` no scene exists yet, so `start()` silently does
nothing: no bubble, no companion socket, and every MCP tool reports "not connected". This
is the most common integration failure.

Guard with `#if DEBUG` so nothing ships to the App Store.

## 4. Build, run, verify

Build and launch on a simulator, then confirm the loop is closed:

1. `session_set_defaults` with the simulator UDID and the app's bundle identifier
2. `noober_status` — expect `CONNECTED ✅` plus a data summary
3. If it says not connected, check in order: the app is a DEBUG build, `start()` runs after
   the scene exists (step 3), the app is in the foreground, and the debug bubble is visible

## 5. Optional registration

Once connected, these make the debugger more useful and are worth offering:

```swift
Noober.shared.registerEnvironments([
    .init(name: "Production", baseURL: "https://api.example.com"),
    .init(name: "Staging", baseURL: "https://staging.example.com")
])

Noober.shared.registerActions([
    .init("Clear Cache", icon: "trash") { CacheManager.clearAll() }
])

Noober.shared.registerMocks([
    .init("Empty cart", url: "/api/cart", json: #"{"items": []}"#)
])
```

For a custom `URLSession`, traffic is only captured if you inject the configuration:

```swift
Noober.shared.inject(into: myCustomSessionConfig)
```
