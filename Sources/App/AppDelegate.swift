import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var analysisWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var currentViewModel: AnalysisViewModel?
    private var luluWindowMonitorTimer: Timer?
    private var initialLuLuWindowSize: CGSize?  // Track initial alert window size
    
    private let monitor = AccessibilityMonitor.shared
    private let claudeClient = ClaudeAPIClient.shared
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupStatusBar()
        setupNotifications()
        
        // Check if first launch or needs setup
        if !UserDefaults.standard.bool(forKey: "hasCompletedSetup") || !claudeClient.hasAPIKey {
            showWelcomeWindow()
        } else {
            // Auto-start monitoring if accessibility is enabled
            if monitor.checkAccessibilityPermission() {
                monitor.startMonitoring()
            }
        }
    }
    
    // MARK: - Menu Bar
    
    private func setupMenuBar() {
        let mainMenu = NSMenu()
        
        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About LuLu AI Companion", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit LuLu AI Companion", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        
        // Edit menu (for Copy/Paste shortcuts)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        
        NSApp.mainMenu = mainMenu
    }
    
    // MARK: - Welcome Window
    
    private func showWelcomeWindow() {
        let welcomeView = WelcomeView(onComplete: { [weak self] in
            self?.welcomeWindow?.close()
            self?.welcomeWindow = nil
            
            // Start monitoring after setup
            if self?.monitor.checkAccessibilityPermission() == true {
                self?.monitor.startMonitoring()
            }
        })
        
        welcomeWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 580),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        welcomeWindow?.title = "Welcome"
        welcomeWindow?.contentView = NSHostingView(rootView: welcomeView)
        welcomeWindow?.center()
        welcomeWindow?.makeKeyAndOrderFront(nil)
        
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - Status Bar
    
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "shield.checkered", accessibilityDescription: "LuLu AI")
            button.action = #selector(togglePopover)
        }
        
        // Create popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 400)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: StatusBarView(
            onShowWelcome: { [weak self] in
                self?.popover.performClose(nil)
                self?.showWelcomeWindow()
            }
        ))
    }
    
    @objc private func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
    
    // MARK: - Alert Notifications
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLuLuAlert(_:)),
            name: .luluAlertDetected,
            object: nil
        )
    }
    
    @objc private func handleLuLuAlert(_ notification: Notification) {
        guard let alert = notification.userInfo?["alert"] as? ConnectionAlert else { return }
        
        // Create view model and show window IMMEDIATELY on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let viewModel = AnalysisViewModel(alert: alert)
            self.currentViewModel = viewModel
            self.showAnalysisWindow(viewModel: viewModel)
            
            // Then do enrichment and analysis in background
            Task { [weak self, weak viewModel] in
                guard let self = self, let viewModel = viewModel else { return }
                
                // Step 1: Enrich with WHOIS/geo data
                let enrichedAlert = await EnrichmentService.shared.enrichAlert(alert)
                await MainActor.run { [weak viewModel] in
                    viewModel?.updateEnrichment(enrichedAlert)
                }
                
                // Step 2: Analyze with Claude
                if self.claudeClient.hasAPIKey {
                    do {
                        let analysis = try await self.claudeClient.analyzeConnection(enrichedAlert)
                        await MainActor.run { [weak viewModel] in
                            viewModel?.updateAnalysis(analysis)
                        }
                        
                        // Step 3: Send to OpenClaw for remote management (if enabled)
                        OpenClawIntegration.shared.sendAlert(enrichedAlert, analysis: analysis)
                        
                    } catch let error as ClaudeAPIClient.APIError {
                        print("Analysis error: \(error)")
                        
                        // Check if it's an authentication error (all keys invalid)
                        if case .httpError(let code, _) = error, code == 401 {
                            await MainActor.run { [weak viewModel] in
                                viewModel?.setError("API key invalid (401). Add a valid key below:")
                            }
                        } else {
                            await MainActor.run { [weak viewModel] in
                                viewModel?.setError(error.localizedDescription)
                            }
                        }
                    } catch {
                        print("Analysis error: \(error)")
                        await MainActor.run { [weak viewModel] in
                            viewModel?.setError(error.localizedDescription)
                        }
                    }
                } else {
                    await MainActor.run { [weak viewModel] in
                        viewModel?.setError("No API key configured. Add one below:")
                    }
                }
            }
        }
    }
    
    // MARK: - Analysis Window
    
    private func showAnalysisWindow(viewModel: AnalysisViewModel) {
        // Close existing window if any
        if let existingWindow = analysisWindow {
            existingWindow.close()
            analysisWindow = nil
        }
        
        // Stop any existing timer
        luluWindowMonitorTimer?.invalidate()
        luluWindowMonitorTimer = nil
        
        let contentView = AnalysisView(viewModel: viewModel)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "🤖 AI Analysis"
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.level = .floating
        window.isReleasedWhenClosed = false  // Prevent crash on close
        window.makeKeyAndOrderFront(nil)
        
        self.analysisWindow = window
        
        NSApp.activate(ignoringOtherApps: true)
        
        // Start monitoring LuLu window - close our window if LuLu alert is dismissed
        startLuLuWindowMonitor()
    }
    
    // MARK: - LuLu Window Monitor
    
    private func startLuLuWindowMonitor() {
        // Reset initial window size
        initialLuLuWindowSize = nil
        
        // Wait 3 seconds before starting to monitor
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            
            print("[DEBUG] Starting LuLu window monitor after 3s delay")
            
            // Check every 1.5 seconds
            self.luluWindowMonitorTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                
                let currentSize = self.getLuLuAlertWindowSize()
                let analysisComplete = !(self.currentViewModel?.isLoadingAnalysis ?? true)
                
                // Store initial size on first detection
                if self.initialLuLuWindowSize == nil, let size = currentSize {
                    self.initialLuLuWindowSize = size
                    print("[DEBUG] Initial LuLu window size: \(size.width)x\(size.height)")
                }
                
                // Consider alert dismissed if:
                // 1. No large LuLu window found, OR
                // 2. Window size changed significantly (decreased by >100px in either dimension)
                var alertDismissed = (currentSize == nil)
                
                if let initial = self.initialLuLuWindowSize, let current = currentSize {
                    let widthDiff = initial.width - current.width
                    let heightDiff = initial.height - current.height
                    if widthDiff > 100 || heightDiff > 100 {
                        alertDismissed = true
                        print("[DEBUG] Window size changed significantly: \(initial.width)x\(initial.height) -> \(current.width)x\(current.height)")
                    }
                }
                
                print("[DEBUG] Monitor: size=\(currentSize?.width ?? 0)x\(currentSize?.height ?? 0), dismissed=\(alertDismissed), complete=\(analysisComplete)")
                
                if alertDismissed && analysisComplete {
                    DispatchQueue.main.async {
                        self.luluWindowMonitorTimer?.invalidate()
                        self.luluWindowMonitorTimer = nil
                        self.initialLuLuWindowSize = nil
                        
                        if let window = self.analysisWindow {
                            window.close()
                            self.analysisWindow = nil
                            self.currentViewModel = nil
                            print("[DEBUG] Auto-closed analysis window")
                        }
                    }
                }
            }
        }
    }
    
    private func getLuLuAlertWindowSize() -> CGSize? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        
        for window in windows {
            if let ownerName = window[kCGWindowOwnerName as String] as? String,
               ownerName.lowercased().contains("lulu") {
                let bounds = window[kCGWindowBounds as String] as? [String: Any]
                let height = bounds?["Height"] as? CGFloat ?? 0
                let width = bounds?["Width"] as? CGFloat ?? 0
                
                // Only consider windows larger than 100x100 as alert windows
                if width > 100 && height > 100 {
                    return CGSize(width: width, height: height)
                }
            }
        }
        
        return nil
    }
    
    private func isLuLuAlertWindowVisible() -> Bool {
        return getLuLuAlertWindowSize() != nil
    }
}
