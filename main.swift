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
        TabSwitchHUD.shared.show(next: next)
    }
}

// MARK: - Tab Switch HUD

class TabSwitchHUD {
    static let shared = TabSwitchHUD()
    
    private var hudWindow: NSPanel?
    private var dismissTimer: Timer?
    private var arrowLabel: NSTextField?
    private var textLabel: NSTextField?
    
    private func createWindow() {
        let hudWidth: CGFloat = 180
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
        text.frame = NSRect(x: 0, y: 10, width: hudWidth, height: 18)
        
        visualEffect.addSubview(arrow)
        visualEffect.addSubview(text)
        panel.contentView = visualEffect
        
        self.hudWindow = panel
        self.arrowLabel = arrow
        self.textLabel = text
    }
    
    func show(next: Bool) {
        guard UserDefaults.standard.bool(forKey: "showHUD") else { return }
        
        DispatchQueue.main.async {
            if self.hudWindow == nil {
                self.createWindow()
            }
            
            // Update content
            self.arrowLabel?.stringValue = next ? "▶" : "◀"
            self.textLabel?.stringValue = next ? "Next Tab" : "Previous Tab"
            
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
    
    // Safely unwrap phases if needed

    
    // Only act when a supported browser is frontmost
    guard let activeApp = NSWorkspace.shared.frontmostApplication,
          let bundleId = activeApp.bundleIdentifier,
          BrowserRegistry.shared.isActiveBrowser(bundleId) else {
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
        menu.addItem(NSMenuItem(title: "SlideTabSafari v3", action: nil, keyEquivalent: ""))
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
        
        // Add HUD toggle
        let isHUDEnabled = UserDefaults.standard.bool(forKey: "showHUD")
        hudToggleItem = NSMenuItem(title: "Show Tab Switch HUD", action: #selector(toggleHUD(_:)), keyEquivalent: "")
        hudToggleItem.state = isHUDEnabled ? .on : .off
        menu.addItem(hudToggleItem)
        
        // Add Browsers submenu
        let browsersItem = NSMenuItem(title: "Browsers", action: nil, keyEquivalent: "")
        let browsersMenu = NSMenu()
        for browser in BrowserRegistry.shared.supportedBrowsers {
            let item = NSMenuItem(title: browser.name, action: #selector(toggleBrowser(_:)), keyEquivalent: "")
            item.representedObject = browser.bundleId
            item.state = BrowserRegistry.shared.isEnabled(browser.bundleId) ? .on : .off
            browsersMenu.addItem(item)
        }
        browsersItem.submenu = browsersMenu
        menu.addItem(browsersItem)
        
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
    
    @objc func toggleBrowser(_ sender: NSMenuItem) {
        guard let bundleId = sender.representedObject as? String else { return }
        let newValue = BrowserRegistry.shared.toggle(bundleId)
        sender.state = newValue ? .on : .off
    }
    
    @objc func toggleHUD(_ sender: NSMenuItem) {
        let current = UserDefaults.standard.bool(forKey: "showHUD")
        let newValue = !current
        UserDefaults.standard.set(newValue, forKey: "showHUD")
        sender.state = newValue ? .on : .off
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
