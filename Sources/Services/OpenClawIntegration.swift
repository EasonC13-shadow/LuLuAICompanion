import Foundation

/// Integration with OpenClaw for remote firewall management
class OpenClawIntegration {
    static let shared = OpenClawIntegration()
    
    /// Whether OpenClaw integration is enabled
    @Published var isEnabled: Bool = false
    
    /// Path to openclaw CLI
    private let openclawPath = "/opt/homebrew/bin/openclaw"
    
    /// Pending alerts waiting for user response
    private var pendingAlerts: [UUID: PendingAlert] = [:]
    
    struct PendingAlert {
        let alert: ConnectionAlert
        let analysis: AIAnalysis
        let timestamp: Date
        let windowInfo: LuLuWindowInfo?
    }
    
    struct LuLuWindowInfo {
        let processName: String
        let ipAddress: String
    }
    
    private init() {
        // Check if openclaw is available
        isEnabled = FileManager.default.fileExists(atPath: openclawPath)
        if isEnabled {
            print("[OpenClaw] Integration enabled - found CLI at \(openclawPath)")
        } else {
            print("[OpenClaw] Integration disabled - CLI not found")
        }
    }
    
    // MARK: - Send Alert to OpenClaw
    
    /// Send a firewall alert to OpenClaw for remote decision
    func sendAlert(_ alert: ConnectionAlert, analysis: AIAnalysis) {
        guard isEnabled else { return }
        
        // Store pending alert
        let pendingAlert = PendingAlert(
            alert: alert,
            analysis: analysis,
            timestamp: Date(),
            windowInfo: LuLuWindowInfo(
                processName: alert.processName,
                ipAddress: alert.ipAddress
            )
        )
        pendingAlerts[alert.id] = pendingAlert
        
        // Build message for OpenClaw
        let message = buildAlertMessage(alert: alert, analysis: analysis)
        
        // Send via openclaw wake command
        Task {
            await sendToOpenClaw(message: message, alertId: alert.id)
        }
    }
    
    private func buildAlertMessage(alert: ConnectionAlert, analysis: AIAnalysis) -> String {
        let emoji = switch analysis.recommendation {
        case .allow: "✅"
        case .block: "🚫"
        case .caution: "⚠️"
        case .unknown: "❓"
        }
        
        var msg = """
        🔥 **LuLu Firewall Alert**
        
        \(emoji) AI Recommendation: **\(analysis.recommendation.rawValue)** (\(Int(analysis.confidence * 100))%)
        
        **Connection:**
        """
        
        if !alert.processName.isEmpty {
            msg += "\n• Process: `\(alert.processName)`"
        }
        if !alert.processPath.isEmpty {
            msg += "\n• Path: `\(alert.processPath)`"
        }
        if !alert.processArgs.isEmpty {
            msg += "\n• Args: `\(alert.processArgs)`"
        }
        msg += "\n• Destination: `\(alert.ipAddress):\(alert.port)` (\(alert.proto))"
        if !alert.reverseDNS.isEmpty {
            msg += "\n• DNS: `\(alert.reverseDNS)`"
        }
        if let geo = alert.geoLocation {
            msg += "\n• Location: \(geo)"
        }
        
        msg += "\n\n**Analysis:** \(analysis.summary)"
        
        if !analysis.risks.isEmpty {
            msg += "\n**Risks:** \(analysis.risks.joined(separator: ", "))"
        }
        
        msg += """
        
        
        **Reply with:**
        • `allow always` - Allow permanently
        • `allow process` - Allow for this process lifetime
        • `block` - Block this connection
        • `ignore` - Let me decide locally
        
        (Alert ID: \(alert.id.uuidString.prefix(8)))
        """
        
        return msg
    }
    
    private func sendToOpenClaw(message: String, alertId: UUID) async {
        // Use openclaw cron wake to send a message
        let process = Process()
        process.executableURL = URL(fileURLWithPath: openclawPath)
        process.arguments = ["cron", "wake", "--text", message, "--mode", "now"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            if process.terminationStatus == 0 {
                print("[OpenClaw] Alert sent successfully")
            } else {
                print("[OpenClaw] Failed to send alert: \(output)")
            }
        } catch {
            print("[OpenClaw] Error sending alert: \(error)")
        }
    }
    
    // MARK: - Handle Response
    
    /// Process a response from OpenClaw (called via CLI or webhook)
    func handleResponse(alertIdPrefix: String, action: String, duration: String?) -> Bool {
        // Find the pending alert by ID prefix
        guard let (id, pending) = pendingAlerts.first(where: { 
            $0.key.uuidString.lowercased().hasPrefix(alertIdPrefix.lowercased()) 
        }) else {
            print("[OpenClaw] No pending alert found for ID: \(alertIdPrefix)")
            return false
        }
        
        // Execute the action on LuLu
        let success = executeLuLuAction(
            action: action,
            duration: duration,
            windowInfo: pending.windowInfo
        )
        
        if success {
            pendingAlerts.removeValue(forKey: id)
        }
        
        return success
    }
    
    // MARK: - LuLu Control
    
    /// Execute an action on the LuLu alert window
    private func executeLuLuAction(action: String, duration: String?, windowInfo: LuLuWindowInfo?) -> Bool {
        let normalizedAction = action.lowercased().trimmingCharacters(in: .whitespaces)
        
        // Determine which button to click
        let buttonName: String
        switch normalizedAction {
        case "allow", "allow always", "allow process":
            buttonName = "Allow"
        case "block":
            buttonName = "Block"
        case "ignore":
            print("[OpenClaw] Ignoring alert - user will decide locally")
            return true
        default:
            print("[OpenClaw] Unknown action: \(action)")
            return false
        }
        
        // Determine duration
        let ruleDuration: String?
        if normalizedAction.contains("always") {
            ruleDuration = "Always"
        } else if normalizedAction.contains("process") {
            ruleDuration = "Process lifetime"
        } else {
            ruleDuration = duration
        }
        
        // Use peekaboo or AppleScript to click
        return clickLuLuButton(buttonName: buttonName, duration: ruleDuration)
    }
    
    private func clickLuLuButton(buttonName: String, duration: String?) -> Bool {
        // First, set duration if specified
        if let duration = duration {
            let durationScript = """
            tell application "System Events"
                tell process "LuLu"
                    set frontmost to true
                    delay 0.2
                    -- Find and click the duration radio button
                    try
                        click radio button "\(duration)" of window 1
                    on error
                        -- Try finding in a group
                        click radio button "\(duration)" of group 1 of window 1
                    end try
                end tell
            end tell
            """
            
            let durationProcess = Process()
            durationProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            durationProcess.arguments = ["-e", durationScript]
            
            do {
                try durationProcess.run()
                durationProcess.waitUntilExit()
            } catch {
                print("[OpenClaw] Error setting duration: \(error)")
            }
        }
        
        // Click the Allow/Block button
        let clickScript = """
        tell application "System Events"
            tell process "LuLu"
                set frontmost to true
                delay 0.2
                click button "\(buttonName)" of window 1
            end tell
        end tell
        return "ok"
        """
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", clickScript]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            
            if process.terminationStatus == 0 {
                print("[OpenClaw] Clicked \(buttonName) button successfully")
                return true
            } else {
                print("[OpenClaw] Failed to click button: \(output)")
                return false
            }
        } catch {
            print("[OpenClaw] Error clicking button: \(error)")
            return false
        }
    }
    
    // MARK: - Cleanup
    
    /// Remove stale pending alerts (older than 5 minutes)
    func cleanupStaleAlerts() {
        let staleThreshold = Date().addingTimeInterval(-300) // 5 minutes
        pendingAlerts = pendingAlerts.filter { $0.value.timestamp > staleThreshold }
    }
}
