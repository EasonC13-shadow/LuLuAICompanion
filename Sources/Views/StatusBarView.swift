import SwiftUI

struct StatusBarView: View {
    @ObservedObject private var monitor = AccessibilityMonitor.shared
    @ObservedObject private var claudeClient = ClaudeAPIClient.shared
    @State private var showingSettings = false
    @State private var showingAccessibilityHelp = false
    
    var onShowWelcome: (() -> Void)?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "shield.checkered")
                    .font(.title2)
                    .foregroundColor(.blue)
                Text("LuLu AI Companion")
                    .font(.headline)
                Spacer()
            }
            .padding(.bottom, 4)
            
            Divider()
            
            // Status Section
            VStack(alignment: .leading, spacing: 8) {
                StatusRow(
                    title: "Accessibility",
                    status: monitor.accessibilityEnabled ? "Enabled" : "Not Enabled",
                    isOK: monitor.accessibilityEnabled,
                    action: monitor.accessibilityEnabled ? nil : {
                        showingAccessibilityHelp = true
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                )
                
                StatusRow(
                    title: "Monitoring",
                    status: monitor.isMonitoring ? "Active" : "Inactive",
                    isOK: monitor.isMonitoring,
                    action: {
                        if monitor.isMonitoring {
                            monitor.stopMonitoring()
                        } else {
                            monitor.startMonitoring()
                        }
                    }
                )
                
                StatusRow(
                    title: "API Keys",
                    status: claudeClient.apiKeysConfigured > 0 ? "\(claudeClient.apiKeysConfigured) configured" : "Not Set",
                    isOK: claudeClient.hasAPIKey,
                    action: { showingSettings = true }
                )
                
                if claudeClient.apiKeysConfigured > 1 {
                    Text("  ↳ Failover enabled")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.leading, 16)
                }
            }
            
            Divider()
            
            // Last Alert
            if let alert = monitor.lastAlert {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last Alert")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Image(systemName: "arrow.right.circle")
                        VStack(alignment: .leading) {
                            Text(alert.processName.isEmpty ? "Unknown" : alert.processName)
                                .font(.system(.body, design: .monospaced))
                            Text("\(alert.ipAddress):\(alert.port)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                Text("No alerts detected yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            // Actions
            HStack {
                Button("Settings") {
                    showingSettings = true
                }
                
                Button("Setup") {
                    onShowWelcome?()
                }
                .buttonStyle(.borderless)
                
                Spacer()
                
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding()
        .frame(width: 300)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .frame(width: 450, height: 450)
        }
        .alert("Accessibility Permission", isPresented: $showingAccessibilityHelp) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("If you reinstalled the app:\n\n1. Find \"LuLuAICompanion\" in the Privacy list\n2. Remove it with the \"-\" button\n3. Re-add the app with \"+\"\n4. Toggle the switch ON")
        }
    }
}

struct StatusRow: View {
    let title: String
    let status: String
    let isOK: Bool
    var action: (() -> Void)?
    
    var body: some View {
        HStack {
            Circle()
                .fill(isOK ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            
            Text(title)
                .frame(width: 100, alignment: .leading)
            
            Text(status)
                .foregroundColor(.secondary)
                .font(.caption)
            
            Spacer()
            
            if let action = action {
                Button(action: action) {
                    Image(systemName: isOK ? "arrow.clockwise" : "gear")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

#Preview {
    StatusBarView()
}
