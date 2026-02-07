import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var analysisWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var currentViewModel: AnalysisViewModel?
    
    private let monitor = AccessibilityMonitor.shared
    private let claudeClient = ClaudeAPIClient.shared
    
    func applicationDidFinishLaunching(_ notification: Notification) {
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
    }
}
