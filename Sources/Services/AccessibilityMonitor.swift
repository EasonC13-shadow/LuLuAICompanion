import Cocoa
import ApplicationServices

/// Monitors for LuLu alert windows using Accessibility API
class AccessibilityMonitor: ObservableObject {
    @Published var isMonitoring = false
    @Published var lastAlert: ConnectionAlert?
    @Published var accessibilityEnabled = false
    
    private var observer: AXObserver?
    private var timer: Timer?
    
    static let shared = AccessibilityMonitor()
    
    private init() {
        checkAccessibilityPermission()
    }
    
    // MARK: - Permission Check
    
    func checkAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        DispatchQueue.main.async {
            self.accessibilityEnabled = trusted
        }
        return trusted
    }
    
    // MARK: - Monitoring
    
    func startMonitoring() {
        guard checkAccessibilityPermission() else {
            print("Accessibility permission not granted")
            return
        }
        
        isMonitoring = true
        
        // Poll for LuLu windows every 500ms
        // (More reliable than AXObserver for cross-app monitoring)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForLuLuAlert()
        }
        
        print("Started monitoring for LuLu alerts")
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
        print("Stopped monitoring")
    }
    
    // MARK: - Window Detection
    
    private func checkForLuLuAlert() {
        // Find LuLu process
        let runningApps = NSWorkspace.shared.runningApplications
        guard let luluApp = runningApps.first(where: { 
            $0.bundleIdentifier == "com.objective-see.lulu.app" ||
            $0.localizedName == "LuLu"
        }) else {
            return
        }
        
        let pid = luluApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        
        // Get windows
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        
        guard result == .success, let windows = windowsValue as? [AXUIElement] else {
            return
        }
        
        // Check each window for "LuLu Alert" title
        for window in windows {
            var titleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
            
            if let title = titleValue as? String, title.contains("LuLu Alert") {
                extractAlertData(from: window)
                return
            }
        }
    }
    
    // MARK: - Data Extraction
    
    private func extractAlertData(from window: AXUIElement) {
        // Get all UI elements recursively
        let elements = getAllElements(from: window)
        
        // Extract all text from the alert - try multiple attributes
        var texts: [String] = []
        var seenTexts = Set<String>()
        
        for element in elements {
            let attributes = [
                kAXValueAttribute,
                kAXTitleAttribute,
                kAXDescriptionAttribute,
                kAXHelpAttribute
            ]
            
            for attr in attributes {
                var textValue: CFTypeRef?
                AXUIElementCopyAttributeValue(element, attr as CFString, &textValue)
                if let text = textValue as? String, !text.isEmpty, !seenTexts.contains(text) {
                    texts.append(text)
                    seenTexts.insert(text)
                }
            }
        }
        
        // Basic parsing for display purposes - Claude will do the real analysis
        var processName = ""
        var processPath = ""
        var processID = ""
        var processArgs = ""
        var ipAddress = ""
        var port = ""
        var proto = "TCP"
        var reverseDNS = ""
        
        for text in texts {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(":") { continue }
            
            // IP address
            if trimmed.matches(pattern: "^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$") && ipAddress.isEmpty {
                ipAddress = trimmed
            }
            // Port/Protocol
            else if trimmed.matches(pattern: "^\\d{1,5} \\((TCP|UDP)\\)$") {
                let parts = trimmed.components(separatedBy: " ")
                port = parts.first ?? ""
                proto = trimmed.contains("TCP") ? "TCP" : "UDP"
            }
            // PID
            else if trimmed.matches(pattern: "^\\d{4,6}$") && processID.isEmpty {
                processID = trimmed
            }
            // Path
            else if trimmed.starts(with: "/") && trimmed.contains("/") {
                processPath = trimmed
                if let name = trimmed.components(separatedBy: "/").last, !name.isEmpty {
                    processName = name
                }
            }
            // URL args
            else if trimmed.starts(with: "http://") || trimmed.starts(with: "https://") {
                processArgs = trimmed
            }
            // Reverse DNS
            else if trimmed.matches(pattern: "^[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}\\.*$") && reverseDNS.isEmpty && !trimmed.starts(with: "/") {
                reverseDNS = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }
        }
        
        // Create alert with RAW TEXTS for Claude to analyze directly
        let alert = ConnectionAlert(
            processName: processName,
            processPath: processPath,
            processID: processID,
            processArgs: processArgs,
            ipAddress: ipAddress,
            port: port,
            proto: proto,
            reverseDNS: reverseDNS,
            rawTexts: texts
        )
        
        // Trigger if we have data (IP or enough raw texts)
        // Only compare key fields, NOT rawTexts (dropdown changes would cause refresh)
        let hasData = !ipAddress.isEmpty || texts.count > 5
        let isDifferent = ipAddress != lastAlert?.ipAddress || 
                          port != lastAlert?.port ||
                          processName != lastAlert?.processName ||
                          processID != lastAlert?.processID
        if hasData && isDifferent {
            print("DEBUG: Extracted \(texts.count) text elements from LuLu alert")
            print("DEBUG: Basic parse - ip:\(ipAddress), port:\(port), process:\(processName)")
            print("Detected LuLu Alert: \(alert.processName) -> \(alert.ipAddress):\(alert.port)")
            DispatchQueue.main.async {
                self.lastAlert = alert
            }
            
            // Post notification for other parts of app
            NotificationCenter.default.post(
                name: .luluAlertDetected,
                object: nil,
                userInfo: ["alert": alert]
            )
        }
    }
    
    private func getAllElements(from element: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = [element]
        
        var childrenValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        
        if let children = childrenValue as? [AXUIElement] {
            for child in children {
                result.append(contentsOf: getAllElements(from: child))
            }
        }
        
        return result
    }
}

// MARK: - Notification Extension

extension Notification.Name {
    static let luluAlertDetected = Notification.Name("luluAlertDetected")
}

// MARK: - String Extension for Regex

extension String {
    func matches(pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(self.startIndex..., in: self)
        return regex.firstMatch(in: self, options: [], range: range) != nil
    }
    
    func matches(pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(self.startIndex..., in: self)
        if let match = regex.firstMatch(in: self, options: [], range: range) {
            return String(self[Range(match.range, in: self)!])
        }
        return nil
    }
}
