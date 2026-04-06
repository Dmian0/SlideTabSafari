import Cocoa
import CoreGraphics
import ServiceManagement
import os
import SwiftUI

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
    func processScrollEvent(_ event: CGEvent, bundleId: String) -> Bool {
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
                
                sendTabSwitch(next: goNext, bundleId: bundleId)
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
    
    private func sendTabSwitch(next: Bool, bundleId: String) {
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
        
        TabSwitchHUD.shared.show(next: next, bundleId: bundleId)
    }
}

// MARK: - Tab Switch HUD

class TabSwitchHUD {
    static let shared = TabSwitchHUD()
    
    private var hudWindow: NSPanel?
    private var dismissTimer: Timer?
    private var arrowLabel: NSTextField?
    private var textLabel: NSTextField?
    
    // Counter to avoid race conditions with multiple rapid swipes
    private var tabSwitchCount: Int = 0
    
    private func createWindow() {
        let hudWidth: CGFloat = 300 // Increased from 180 to fit long tab titles
        let hudHeight: CGFloat = 90
        
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - hudWidth / 2
        let y = screenFrame.midY - hudHeight / 2 + 80
        
        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: hudWidth, height: hudHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        
        // Vibrancy background (native macOS HUD style)
        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: hudWidth, height: hudHeight))
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 16
        visualEffect.layer?.masksToBounds = true
        
        // Arrow indicator
        let arrow = NSTextField(labelWithString: "▶")
        arrow.font = NSFont.systemFont(ofSize: 34, weight: .ultraLight)
        arrow.textColor = .white
        arrow.alignment = .center
        arrow.frame = NSRect(x: 0, y: 32, width: hudWidth, height: 42)
        
        // Direction text
        let text = NSTextField(labelWithString: "Next Tab")
        text.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        text.textColor = NSColor.white.withAlphaComponent(0.75)
        text.alignment = .center
        text.lineBreakMode = .byTruncatingTail
        text.frame = NSRect(x: 10, y: 10, width: hudWidth - 20, height: 18)
        
        visualEffect.addSubview(arrow)
        visualEffect.addSubview(text)
        panel.contentView = visualEffect
        
        self.hudWindow = panel
        self.arrowLabel = arrow
        self.textLabel = text
    }
    
    func show(next: Bool, bundleId: String) {
        guard UserDefaults.standard.bool(forKey: "showHUD") else { return }
        
        DispatchQueue.main.async {
            if self.hudWindow == nil {
                self.createWindow()
            }
            
            // Update content
            self.arrowLabel?.stringValue = next ? "▶" : "◀"
            self.textLabel?.stringValue = next ? "Next Tab" : "Previous Tab"
            
            self.tabSwitchCount += 1
            let currentCount = self.tabSwitchCount
            
            // Fetch tab title asynchronously
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) {
                self.fetchTabTitle(bundleId: bundleId, switchCount: currentCount)
            }
            
            // Reset dismiss timer
            self.dismissTimer?.invalidate()
            
            // Fade in
            self.hudWindow?.alphaValue = 0
            self.hudWindow?.orderFrontRegardless()
            
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                self.hudWindow?.animator().alphaValue = 1.0
            }
            
            // Auto-dismiss after 0.6s
            self.dismissTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.3
                    self.hudWindow?.animator().alphaValue = 0.0
                }) {
                    self.hudWindow?.orderOut(nil)
                }
            }
        }
    }
    
    private func fetchTabTitle(bundleId: String, switchCount: Int) {
        let scriptString: String?
        
        let chromiumBrowsers = [
            "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser",
            "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "company.thebrowser.Browser",
            "com.operasoftware.Opera"
        ]
        
        let safariBrowsers = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
        
        if chromiumBrowsers.contains(bundleId) {
            scriptString = "tell application id \"\(bundleId)\" to return title of active tab of front window"
        } else if safariBrowsers.contains(bundleId) {
            scriptString = "tell application id \"\(bundleId)\" to return name of current tab of front window"
        } else {
            scriptString = nil
        }
        
        guard let source = scriptString else { return }
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: source) {
            let output = scriptObject.executeAndReturnError(&error)
            if error == nil, let title = output.stringValue, !title.isEmpty {
                DispatchQueue.main.async {
                    // Update only if this is still the result of the same swipe
                    if self.tabSwitchCount == switchCount {
                        self.textLabel?.stringValue = title
                    }
                }
            }
        }
    }
}

// MARK: - Onboarding Window

class OnboardingWindowController: NSObject {
    
    private var window: NSWindow?
    
    func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "hasSeenOnboarding") else { return }
        showWindow()
    }
    
    func showWindow() {
        let windowWidth: CGFloat = 520
        let windowHeight: CGFloat = 480
        
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - windowWidth / 2
        let y = screenFrame.midY - windowHeight / 2
        
        let win = NSWindow(
            contentRect: NSRect(x: x, y: y, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Welcome to SlideTabSafari"
        win.isReleasedWhenClosed = false
        win.center()
        
        // Background with vibrancy
        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        visualEffect.material = .windowBackground
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        win.contentView = visualEffect
        
        // --- Title ---
        let titleLabel = NSTextField(labelWithString: "SlideTabSafari")
        titleLabel.font = NSFont.systemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 0, y: windowHeight - 65, width: windowWidth, height: 36)
        visualEffect.addSubview(titleLabel)
        
        let subtitleLabel = NSTextField(labelWithString: "Switch Safari tabs with trackpad gestures")
        subtitleLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.frame = NSRect(x: 0, y: windowHeight - 90, width: windowWidth, height: 20)
        visualEffect.addSubview(subtitleLabel)
        
        // --- Step Cards ---
        let cardWidth: CGFloat = windowWidth - 60
        let cardHeight: CGFloat = 80
        let cardX: CGFloat = 30
        var cardY: CGFloat = windowHeight - 190
        
        // Step 1: Gesture
        let step1 = createStepCard(
            frame: NSRect(x: cardX, y: cardY, width: cardWidth, height: cardHeight),
            icon: "\u{1F91A}",  // 🤚
            title: "Swipe to Switch Tabs",
            detail: "Perform a two-finger horizontal swipe on your trackpad\nto move between Safari tabs instantly."
        )
        visualEffect.addSubview(step1)
        
        // Step 2: Multi-browser
        cardY -= (cardHeight + 16)
        let step2 = createStepCard(
            frame: NSRect(x: cardX, y: cardY, width: cardWidth, height: cardHeight),
            icon: "\u{1F310}",  // 🌐
            title: "Works with All Major Browsers",
            detail: "Safari, Chrome, Brave, Arc, Firefox, Edge and more.\nSwipe to switch tabs in any supported browser."
        )
        visualEffect.addSubview(step2)
        
        // Step 3: Permissions
        cardY -= (cardHeight + 16)
        let step3 = createStepCard(
            frame: NSRect(x: cardX, y: cardY, width: cardWidth, height: cardHeight),
            icon: "\u{1F512}",  // 🔒
            title: "Grant Accessibility Permission",
            detail: "Go to System Settings → Privacy & Security → Accessibility\nand enable SlideTabSafari. The app will wait automatically."
        )
        visualEffect.addSubview(step3)
        
        // --- Get Started Button ---
        let button = NSButton(title: "Get Started", target: self, action: #selector(onGetStarted(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        button.frame = NSRect(x: (windowWidth - 160) / 2, y: 24, width: 160, height: 40)
        button.keyEquivalent = "\r"
        visualEffect.addSubview(button)
        
        // --- Footer ---
        let footerLabel = NSTextField(labelWithString: "Runs silently in your menu bar  \u{21E5}")
        footerLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.alignment = .center
        footerLabel.frame = NSRect(x: 0, y: 72, width: windowWidth, height: 16)
        visualEffect.addSubview(footerLabel)
        
        self.window = win
        
        // Temporarily show in Dock so the window is reachable
        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    private func createStepCard(frame: NSRect, icon: String, title: String, detail: String) -> NSView {
        let card = NSView(frame: frame)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        
        let iconLabel = NSTextField(labelWithString: icon)
        iconLabel.font = NSFont.systemFont(ofSize: 28)
        iconLabel.frame = NSRect(x: 16, y: (frame.height - 34) / 2, width: 40, height: 34)
        card.addSubview(iconLabel)
        
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 64, y: frame.height - 30, width: frame.width - 80, height: 20)
        card.addSubview(titleLabel)
        
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.frame = NSRect(x: 64, y: 8, width: frame.width - 80, height: 36)
        card.addSubview(detailLabel)
        
        return card
    }
    
    @objc private func onGetStarted(_ sender: NSButton) {
        UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            self.window?.animator().alphaValue = 0.0
        }) {
            self.window?.orderOut(nil)
            self.window = nil
            // Return to accessory mode (no Dock icon)
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Browser Registry

struct BrowserInfo {
    let bundleId: String
    let name: String
}

class BrowserRegistry {
    static let shared = BrowserRegistry()
    
    let supportedBrowsers: [BrowserInfo] = [
        BrowserInfo(bundleId: "com.apple.Safari", name: "Safari"),
        BrowserInfo(bundleId: "com.apple.SafariTechnologyPreview", name: "Safari Technology Preview"),
        BrowserInfo(bundleId: "com.google.Chrome", name: "Google Chrome"),
        BrowserInfo(bundleId: "com.google.Chrome.canary", name: "Chrome Canary"),
        BrowserInfo(bundleId: "com.brave.Browser", name: "Brave"),
        BrowserInfo(bundleId: "company.thebrowser.Browser", name: "Arc"),
        BrowserInfo(bundleId: "org.mozilla.firefox", name: "Firefox"),
        BrowserInfo(bundleId: "com.microsoft.edgemac", name: "Microsoft Edge"),
        BrowserInfo(bundleId: "com.operasoftware.Opera", name: "Opera"),
        BrowserInfo(bundleId: "com.vivaldi.Vivaldi", name: "Vivaldi"),
    ]
    
    /// Returns the UserDefaults key for a given browser bundle ID.
    private func key(for bundleId: String) -> String {
        return "browser_\(bundleId)"
    }
    
    /// Check if a browser is enabled. Defaults to true for all browsers.
    func isEnabled(_ bundleId: String) -> Bool {
        let k = key(for: bundleId)
        // If the key has never been set, default to true
        if UserDefaults.standard.object(forKey: k) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: k)
    }
    
    /// Check if a bundle ID belongs to a supported browser AND is enabled.
    func isActiveBrowser(_ bundleId: String) -> Bool {
        let isSupported = supportedBrowsers.contains { $0.bundleId == bundleId }
        return isSupported && isEnabled(bundleId)
    }
    
    /// Toggle a browser on/off.
    func toggle(_ bundleId: String) -> Bool {
        let newValue = !isEnabled(bundleId)
        UserDefaults.standard.set(newValue, forKey: key(for: bundleId))
        return newValue
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
    
    // Only act when a supported browser is frontmost
    guard let activeApp = NSWorkspace.shared.frontmostApplication,
          let bundleId = activeApp.bundleIdentifier,
          BrowserRegistry.shared.isActiveBrowser(bundleId) else {
        return Unmanaged.passUnretained(event)
    }
    
    // Process through our gesture tracker
    let shouldConsume = GestureTracker.shared.processScrollEvent(event, bundleId: bundleId)
    
    if shouldConsume {
        return nil // CONSUME: Safari never sees this event
    }
    
    return Unmanaged.passUnretained(event) // pass through
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    
    var statusItem: NSStatusItem?
    var eventTapPort: CFMachPort?
    var hudToggleItem: NSMenuItem!
    var onboardingController: OnboardingWindowController?
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Register default preference
        UserDefaults.standard.register(defaults: [
            "naturalSwipeDirection": true,
            "sensitivityLevel": 1,
            "hideMenuIcon": false,
            "showHUD": true,
            "hasSeenOnboarding": false
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
        
        // Show onboarding on first launch
        onboardingController = OnboardingWindowController()
        onboardingController?.showIfNeeded()
        
        checkAccessibility()
        
        // Listen to preference changes (e.g., from SwiftUI view)
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
    }
    
    @objc func defaultsChanged() {
        if UserDefaults.standard.bool(forKey: "hideMenuIcon") {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        } else {
            setupMenuBarIcon()
        }
        // Sync the fast toggle in the menu
        hudToggleItem?.state = UserDefaults.standard.bool(forKey: "showHUD") ? .on : .off
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
        menu.addItem(NSMenuItem(title: "SlideTabSafari v4", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ",")
        menu.addItem(prefsItem)
        
        let isHUDEnabled = UserDefaults.standard.bool(forKey: "showHUD")
        hudToggleItem = NSMenuItem(title: "Show Tab Switch HUD", action: #selector(toggleHUD(_:)), keyEquivalent: "")
        hudToggleItem.state = isHUDEnabled ? .on : .off
        menu.addItem(hudToggleItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }
    
    @objc func openPreferences() {
        PreferencesWindowController.shared.show()
    }
    
    @objc func toggleHUD(_ sender: NSMenuItem) {
        let current = UserDefaults.standard.bool(forKey: "showHUD")
        let newValue = !current
        UserDefaults.standard.set(newValue, forKey: "showHUD")
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

// MARK: - SwiftUI Preferences Window

struct PreferencesView: View {
    @AppStorage("naturalSwipeDirection") var naturalSwipeDirection = true
    @AppStorage("sensitivityLevel") var sensitivityLevel = 1
    @AppStorage("hideMenuIcon") var hideMenuIcon = false
    @AppStorage("showHUD") var showHUD = true
    
    var autostartBinding: Binding<Bool> {
        Binding(
            get: {
                if #available(macOS 13.0, *) {
                    return SMAppService.mainApp.status == .enabled
                }
                return false
            },
            set: { newValue in
                if #available(macOS 13.0, *) {
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        print("Failed to update autostart: \(error)")
                    }
                }
            }
        )
    }
    
    var body: some View {
        TabView {
            // General Tab
            Form {
                Section {
                    Picker("Swipe Direction:", selection: $naturalSwipeDirection) {
                        Text("Natural").tag(true)
                        Text("Standard").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    
                    Picker("Sensitivity:", selection: $sensitivityLevel) {
                        Text("Low (requires long swipe)").tag(0)
                        Text("Medium (default)").tag(1)
                        Text("High (quick swipe)").tag(2)
                    }
                } header: {
                    Text("Gestures")
                        .font(.headline)
                }
                .padding(.bottom, 10)
                
                Section {
                    Toggle("Show Tab Switch HUD", isOn: $showHUD)
                    Toggle("Hide Menu Bar Icon", isOn: Binding(
                        get: { hideMenuIcon },
                        set: {
                            if $0 {
                                // Add confirmation alert when attempting to hide from Prefs
                                let alert = NSAlert()
                                alert.messageText = "Hide Menu Bar Icon?"
                                alert.informativeText = "If you hide the icon, the app will continue to run in the background. To show the icon again, simply reopen the app from your Applications folder."
                                alert.addButton(withTitle: "Hide")
                                alert.addButton(withTitle: "Cancel")
                                if alert.runModal() == .alertFirstButtonReturn {
                                    hideMenuIcon = true
                                }
                            } else {
                                hideMenuIcon = false
                            }
                        }
                    ))
                    if #available(macOS 13.0, *) {
                        Toggle("Launch at Login", isOn: autostartBinding)
                    }
                } header: {
                    Text("Appearance & System")
                        .font(.headline)
                }
            }
            .padding(20)
            .tabItem {
                Label("General", systemImage: "gear")
            }
            
            // Browsers Tab
            Form {
                Text("Select which browsers to enable gesture support for:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 10)
                
                ForEach(BrowserRegistry.shared.supportedBrowsers, id: \.bundleId) { browser in
                    ToggleBrowserRow(browser: browser)
                }
            }
            .padding(20)
            .tabItem {
                Label("Browsers", systemImage: "safari")
            }
        }
        .frame(width: 480, height: 350)
    }
}

struct ToggleBrowserRow: View {
    let browser: BrowserInfo
    @AppStorage var isEnabled: Bool
    
    init(browser: BrowserInfo) {
        self.browser = browser
        self._isEnabled = AppStorage(wrappedValue: true, "browser_\(browser.bundleId)")
    }
    
    var body: some View {
        Toggle(browser.name, isOn: $isEnabled)
    }
}

class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()
    
    init() {
        let hostingController = NSHostingController(rootView: PreferencesView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 350),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "SlideTabSafari Preferences"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // no dock icon
app.run()
