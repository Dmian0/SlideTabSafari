import Cocoa
import CoreGraphics
import ServiceManagement

// Log class removed for final version.

// MARK: - Gesture State Machine
// Tracks horizontal scroll gesture phases and accumulates delta
// to distinguish intentional swipes from normal scrolling.

class GestureTracker {
    static let shared = GestureTracker()
    
    private var accumulatedDeltaX: CGFloat = 0.0
    private var isTracking = false
    private var hasFired = false
    
    // Threshold: how much horizontal delta before we trigger a tab switch.
    var horizontalThreshold: CGFloat {
        let level = UserDefaults.standard.integer(forKey: "sensitivityLevel")
        switch level {
        case 2: return 30.0 // High (quick)
        case 0: return 80.0 // Low (needs strong swipe)
        default: return 50.0 // Medium (default)
        }
    }
    
    // Maximum vertical delta allowed during a horizontal swipe.
    // If the user scrolls more vertically than this, it's a normal page scroll.
    let verticalTolerance: CGFloat = 10.0
    private var accumulatedDeltaY: CGFloat = 0.0
    
    private var isNaturalDirection: Bool {
        return UserDefaults.standard.bool(forKey: "naturalSwipeDirection")
    }

    /// Process a scroll wheel CGEvent.
    /// Returns `true` if the event should be CONSUMED (blocked from reaching Safari).
    func processScrollEvent(_ event: CGEvent) -> Bool {
        // Get scroll phases from the event
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        
        // Get deltas
        let deltaX = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) // horizontal
        let deltaY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) // vertical
        
        // Phase values: 1=began, 2=changed, 4=ended, 8=cancelled, 128=mayBegin
        
        // If there's momentum (inertial scrolling after finger lift), consume it
        // only if we already fired a tab switch during this gesture.
        if momentumPhase != 0 {
            if hasFired {
                return true // consume momentum events to prevent Safari back/forward
            }
            return false
        }
        
        switch phase {
        case 1: // Began
            accumulatedDeltaX = 0
            accumulatedDeltaY = 0
            isTracking = true
            hasFired = false
            return false // let the first event through (no visible effect yet)
            
        case 2: // Changed
            guard isTracking else { return false }
            
            accumulatedDeltaX += CGFloat(deltaX)
            accumulatedDeltaY += CGFloat(deltaY)
            
            // If vertical movement exceeds tolerance, this is a normal scroll, bail out
            if abs(accumulatedDeltaY) > verticalTolerance && abs(accumulatedDeltaY) > abs(accumulatedDeltaX) {
                isTracking = false
                return false
            }
            
            // Check if horizontal delta exceeds threshold
            if !hasFired && abs(accumulatedDeltaX) > horizontalThreshold {
                let isRightSwipe = accumulatedDeltaX > 0
                
                // Natural Direction: Right Swipe -> Previous Tab (goNext = false)
                // Standard Direction: Right Swipe -> Next Tab (goNext = true)
                let goNext = isNaturalDirection ? !isRightSwipe : isRightSwipe
                
                sendTabSwitch(next: goNext)
                hasFired = true
            }
            
            // If we're tracking a horizontal gesture, consume the event
            if abs(accumulatedDeltaX) > 5 && abs(accumulatedDeltaX) > abs(accumulatedDeltaY) {
                return true // BLOCK Safari from seeing this horizontal scroll
            }
            return false
            
        case 4, 8: // Ended or Cancelled
            let wasTracking = hasFired
            isTracking = false
            hasFired = false
            accumulatedDeltaX = 0
            accumulatedDeltaY = 0
            return wasTracking // consume end event if we fired during this gesture
            
        default:
            return false
        }
    }
    
    private func sendTabSwitch(next: Bool) {
        // Control+Tab = next tab, Control+Shift+Tab = previous tab in Safari
        let keyCode: CGKeyCode = 48 // 48 = Tab key
        
        let eventSource = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false) else {
            return
        }
        
        let flags: CGEventFlags = next ? [.maskControl] : [.maskControl, .maskShift]
        keyDown.flags = flags
        keyUp.flags = flags
        
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        // print("Tab switched (next: \(next))")
    }
}

// MARK: - CGEvent Tap Callback (C-level function)

func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    
    // If the tap is disabled by the system (timeout), re-enable it
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let refcon = refcon {
            let pointer = refcon.assumingMemoryBound(to: CFMachPort.self)
            CGEvent.tapEnable(tap: pointer.pointee, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }
    
    // Only process scroll wheel events
    guard type == .scrollWheel else {
        return Unmanaged.passUnretained(event)
    }
    
    // Safely unwrap phases if needed

    
    // Only act when Safari is frontmost
    guard let activeApp = NSWorkspace.shared.frontmostApplication,
          activeApp.bundleIdentifier == "com.apple.Safari" else {
        return Unmanaged.passUnretained(event)
    }
    
    // Process through our gesture tracker
    let shouldConsume = GestureTracker.shared.processScrollEvent(event)
    
    if shouldConsume {
        return nil // CONSUME: Safari never sees this event
    }
    
    return Unmanaged.passUnretained(event) // pass through
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    
    var statusItem: NSStatusItem?
    var eventTapPort: CFMachPort?
    var directionMenuItem: NSMenuItem!
    var autostartMenuItem: NSMenuItem!
    var lowSensitivityItem: NSMenuItem!
    var medSensitivityItem: NSMenuItem!
    var highSensitivityItem: NSMenuItem!
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Register default preference
        UserDefaults.standard.register(defaults: [
            "naturalSwipeDirection": true,
            "sensitivityLevel": 1,
            "hideMenuIcon": false
        ])
        
        // Auto-enable Launch at Login on first run
        if #available(macOS 13.0, *) {
            if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
                UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
                if SMAppService.mainApp.status != .enabled {
                    try? SMAppService.mainApp.register()
                }
            }
        }
        
        if !UserDefaults.standard.bool(forKey: "hideMenuIcon") {
            setupMenuBarIcon()
        }
        
        checkAccessibility()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // When user opens the app again from Finder, show the menu icon again
        UserDefaults.standard.set(false, forKey: "hideMenuIcon")
        if statusItem == nil {
            setupMenuBarIcon()
        }
        return true
    }
    
    func setupMenuBarIcon() {
        if statusItem != nil { return }
        
        // Setup menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = "⇥"
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "SlideTabSafari v2", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        // Add Swipe Direction toggle
        let isNatural = UserDefaults.standard.bool(forKey: "naturalSwipeDirection")
        directionMenuItem = NSMenuItem(title: "Natural Swipe Direction", action: #selector(toggleSwipeDirection(_:)), keyEquivalent: "")
        directionMenuItem.state = isNatural ? .on : .off
        menu.addItem(directionMenuItem)
        
        // Add Sensitivity Submenu
        let sensitivityItem = NSMenuItem(title: "Sensitivity", action: nil, keyEquivalent: "")
        let sensitivityMenu = NSMenu()
        
        lowSensitivityItem = NSMenuItem(title: "Low (Requires long swipe)", action: #selector(changeSensitivity(_:)), keyEquivalent: "")
        lowSensitivityItem.tag = 0
        medSensitivityItem = NSMenuItem(title: "Medium (Default)", action: #selector(changeSensitivity(_:)), keyEquivalent: "")
        medSensitivityItem.tag = 1
        highSensitivityItem = NSMenuItem(title: "High (Quick swipe)", action: #selector(changeSensitivity(_:)), keyEquivalent: "")
        highSensitivityItem.tag = 2
        
        updateSensitivityCheckmarks()
        
        sensitivityMenu.addItem(lowSensitivityItem)
        sensitivityMenu.addItem(medSensitivityItem)
        sensitivityMenu.addItem(highSensitivityItem)
        sensitivityItem.submenu = sensitivityMenu
        menu.addItem(sensitivityItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Add Launch at Login toggle
        if #available(macOS 13.0, *) {
            autostartMenuItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleAutostart(_:)), keyEquivalent: "")
            autostartMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(autostartMenuItem)
        }
        
        let hideIconItem = NSMenuItem(title: "Hide Menu Bar Icon...", action: #selector(hideMenuIcon(_:)), keyEquivalent: "")
        menu.addItem(hideIconItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }
    
    @objc func toggleSwipeDirection(_ sender: NSMenuItem) {
        let current = UserDefaults.standard.bool(forKey: "naturalSwipeDirection")
        let newValue = !current
        UserDefaults.standard.set(newValue, forKey: "naturalSwipeDirection")
        sender.state = newValue ? .on : .off
    }
    
    @available(macOS 13.0, *)
    @objc func toggleAutostart(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            print("Failed to toggle autostart: \(error)")
        }
    }
    
    @objc func changeSensitivity(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "sensitivityLevel")
        updateSensitivityCheckmarks()
    }
    
    func updateSensitivityCheckmarks() {
        let level = UserDefaults.standard.integer(forKey: "sensitivityLevel")
        lowSensitivityItem?.state = (level == 0) ? .on : .off
        medSensitivityItem?.state = (level == 1) ? .on : .off
        highSensitivityItem?.state = (level == 2) ? .on : .off
    }
    
    @objc func hideMenuIcon(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Hide Menu Bar Icon"
        alert.informativeText = "The menu bar icon will be hidden.\n\nTo show it again and access settings, simply open 'SlideTabSafari.app' from your Applications folder or Finder again."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Hide Icon")
        alert.addButton(withTitle: "Cancel")
        
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            UserDefaults.standard.set(true, forKey: "hideMenuIcon")
            statusItem = nil
        }
    }
    
    var hasPromptedAccessibility = false
    
    func checkAccessibility() {
        if !hasPromptedAccessibility {
            // Prompt ONCE to open System Settings
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            hasPromptedAccessibility = true
            
            if trusted {
                // print("✅ Accessibility granted. Setting up CGEventTap...")
                setupEventTap()
                return
            }
            // print("⚠️ Accessibility not granted yet. Polling...")
        }
        
        // Silent poll (no prompt)
        if AXIsProcessTrusted() {
            // print("✅ Accessibility granted! Setting up CGEventTap...")
            setupEventTap()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                self.checkAccessibility()
            }
        }
    }
    
    func setupEventTap() {
        // Create a global event tap for scroll wheel events
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,  // active tap: can modify/consume events
            eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
            callback: eventTapCallback,
            userInfo: nil
        ) else {
            // print("❌ Failed to create CGEventTap. Check Accessibility permissions.")
            return
        }
        
        eventTapPort = tap
        
        // Add the tap to the current run loop
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // no dock icon
app.run()
