import SwiftUI

struct WelcomeView: View {
    @ObservedObject private var claudeClient = ClaudeAPIClient.shared
    @ObservedObject private var monitor = AccessibilityMonitor.shared
    
    @State private var apiKey: String = ""
    @State private var showKey = false
    @State private var currentStep = 0
    @State private var isChecking = false
    @State private var errorMessage: String?
    @State private var foundExistingKeys = false
    
    @Environment(\.dismiss) private var dismiss
    var onComplete: (() -> Void)?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "shield.checkered")
                    .font(.system(size: 64))
                    .foregroundColor(.blue)
                
                Text("Welcome to LuLu AI Companion")
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("AI-powered firewall analysis")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 30)
            .padding(.bottom, 20)
            
            Divider()
            
            // Content based on step
            VStack(spacing: 20) {
                switch currentStep {
                case 0:
                    checkingExistingKeysView
                case 1:
                    apiKeySetupView
                case 2:
                    accessibilitySetupView
                case 3:
                    completionView
                default:
                    EmptyView()
                }
            }
            .padding(30)
            .frame(maxHeight: .infinity)
            
            Divider()
            
            // Footer with navigation
            HStack {
                if currentStep > 0 && currentStep < 3 {
                    Button("Back") {
                        withAnimation { currentStep -= 1 }
                    }
                }
                
                Spacer()
                
                // Step indicators
                HStack(spacing: 8) {
                    ForEach(0..<4) { step in
                        Circle()
                            .fill(step <= currentStep ? Color.blue : Color.gray.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }
                
                Spacer()
                
                if currentStep < 3 {
                    Button(currentStep == 0 ? "Continue" : "Next") {
                        advanceStep()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdvance)
                } else {
                    Button("Get Started") {
                        complete()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: 500, height: 580)
        .onAppear {
            checkForExistingKeys()
        }
    }
    
    // MARK: - Step Views
    
    private var checkingExistingKeysView: some View {
        VStack(spacing: 20) {
            if isChecking {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Checking for existing API keys...")
                    .foregroundColor(.secondary)
            } else if foundExistingKeys {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.green)
                
                Text("Found \(claudeClient.apiKeysConfigured) API key(s)!")
                    .font(.headline)
                
                Text("We detected existing Claude API keys from OpenClaw or environment variables. You're all set!")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                
                if claudeClient.apiKeysConfigured > 1 {
                    Text("Multiple keys will be used for automatic failover.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Image(systemName: "key.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.orange)
                
                Text("No API Key Found")
                    .font(.headline)
                
                Text("To use AI-powered analysis, you'll need a Claude API key from Anthropic.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var apiKeySetupView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enter your Claude API Key")
                .font(.headline)
            
            HStack {
                if showKey {
                    TextField("sk-xxxxxxxx", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                } else {
                    SecureField("sk-xxxxxxxx", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }
                
                Button(action: { showKey.toggle() }) {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }
            
            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            
            HStack {
                Link(destination: URL(string: "https://console.anthropic.com/")!) {
                    HStack {
                        Image(systemName: "arrow.up.right.square")
                        Text("Get API Key from Anthropic")
                    }
                }
                .font(.caption)
                
                Spacer()
                
                if !apiKey.isEmpty {
                    Button("Verify Key") {
                        verifyKey()
                    }
                    .disabled(isChecking)
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Options:")
                    .font(.caption)
                    .fontWeight(.medium)
                
                Text("• Paste your API key above, or")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("• Run `claude setup-token` in Terminal to configure locally")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Divider()
                    .padding(.vertical, 4)
                
                Text("• Your key is stored securely in macOS Keychain")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("• You can manage keys later in Settings or via CLI")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var accessibilitySetupView: some View {
        VStack(spacing: 16) {
            Image(systemName: monitor.accessibilityEnabled ? "checkmark.circle.fill" : "hand.raised.fill")
                .font(.system(size: 48))
                .foregroundColor(monitor.accessibilityEnabled ? .green : .orange)
            
            Text("Accessibility Permission")
                .font(.headline)
            
            if monitor.accessibilityEnabled {
                Text("Accessibility access is enabled! The app can now detect LuLu alert windows.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            } else {
                Text("This app needs Accessibility permission to detect when LuLu shows a firewall alert.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                .buttonStyle(.borderedProminent)
                
                Button("Check Again") {
                    _ = monitor.checkAccessibilityPermission()
                }
                .buttonStyle(.bordered)
                
                Divider()
                    .padding(.vertical, 8)
                
                // Important note for users who updated the app
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Updated the app?")
                            .fontWeight(.medium)
                    }
                    .font(.caption)
                    
                    Text("If you previously granted permission to an older version, you need to:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Find \"LuLuAICompanion\" in the list")
                        Text("2. Select it and click the \"-\" button to remove")
                        Text("3. Click \"+\" and re-add the app from /Applications")
                        Text("4. Toggle the switch ON")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 16)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }
    
    private var completionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)
            
            Text("You're All Set!")
                .font(.title2)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: claudeClient.hasAPIKey ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(claudeClient.hasAPIKey ? .green : .red)
                    Text("API Key: \(claudeClient.apiKeysConfigured) configured")
                }
                
                HStack {
                    Image(systemName: monitor.accessibilityEnabled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundColor(monitor.accessibilityEnabled ? .green : .orange)
                    Text("Accessibility: \(monitor.accessibilityEnabled ? "Enabled" : "Not enabled (optional)")")
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            
            Text("The app will run in your menu bar and automatically analyze connections when LuLu shows an alert.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .font(.caption)
        }
    }
    
    // MARK: - Logic
    
    private var canAdvance: Bool {
        switch currentStep {
        case 0:
            return !isChecking
        case 1:
            return foundExistingKeys || !apiKey.isEmpty
        case 2:
            return true // Accessibility is optional
        default:
            return true
        }
    }
    
    private func checkForExistingKeys() {
        isChecking = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            claudeClient.refreshKeyCount()
            foundExistingKeys = claudeClient.hasAPIKey
            isChecking = false
            
            // If keys found, skip to step 2
            if foundExistingKeys {
                currentStep = 0 // Show the "found keys" message first
            }
        }
    }
    
    private func advanceStep() {
        withAnimation {
            if currentStep == 0 && foundExistingKeys {
                // Skip API key entry if we already have keys
                currentStep = 2
            } else if currentStep == 1 && !apiKey.isEmpty {
                // Save the key
                claudeClient.addAPIKey(apiKey)
                foundExistingKeys = true
                currentStep = 2
            } else {
                currentStep += 1
            }
        }
    }
    
    private func verifyKey() {
        guard apiKey.hasPrefix("sk-ant-") || apiKey.hasPrefix("sk-3mate-apikey") else {
            errorMessage = "Invalid key format. Key should start with 'sk-ant-' or 'sk-3mate-apikey'"
            return
        }
        
        isChecking = true
        errorMessage = nil
        
        // Simple validation - just check format for now
        // Full validation would require an API call
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isChecking = false
            if apiKey.count > 20 {
                claudeClient.addAPIKey(apiKey)
                currentStep = 2
            } else {
                errorMessage = "Key appears too short"
            }
        }
    }
    
    private func complete() {
        // Mark setup as complete
        UserDefaults.standard.set(true, forKey: "hasCompletedSetup")
        
        // onComplete handles window closing and starting monitoring
        onComplete?()
    }
}

#Preview {
    WelcomeView()
}
