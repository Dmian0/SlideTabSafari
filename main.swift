import Cocoa
import CoreGraphics

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
    // Increase this value if the gesture triggers too easily.
    let horizontalThreshold: CGFloat = 50.0
    
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
    
    var statusItem: NSStatusItem!
    var eventTapPort: CFMachPort?
    var directionMenuItem: NSMenuItem!
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Register default preference (true = natural direction)
        UserDefaults.standard.register(defaults: ["naturalSwipeDirection": true])
        
        // Setup menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
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
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        
        checkAccessibility()
    }
    
    @objc func toggleSwipeDirection(_ sender: NSMenuItem) {
        let current = UserDefaults.standard.bool(forKey: "naturalSwipeDirection")
        let newValue = !current
        UserDefaults.standard.set(newValue, forKey: "naturalSwipeDirection")
        sender.state = newValue ? .on : .off
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
