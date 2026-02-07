import Foundation

/// Client for Claude API with multi-key failover support
class ClaudeAPIClient: ObservableObject {
    @Published var isAnalyzing = false
    @Published var lastError: String?
    @Published var apiKeysConfigured: Int = 0
    
    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let model = "claude-sonnet-4-20250514"
    
    static let shared = ClaudeAPIClient()
    
    private init() {
        refreshKeyCount()
    }
    
    // MARK: - Multi-Key Management
    
    /// All configured API keys (environment + app keychain only)
    var apiKeys: [String] {
        var keys: [String] = []
        
        // 1. Environment variable
        if let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !envKey.isEmpty {
            keys.append(envKey)
        }
        
        // 2. Our own app's keychain entries
        if let key = KeychainHelper.get(key: "claude_api_key"), !key.isEmpty {
            if !keys.contains(key) { keys.append(key) }
        }
        
        // 3. Additional backup keys (users can add multiple)
        for i in 1...5 {
            if let key = KeychainHelper.get(key: "claude_api_key_\(i)"), !key.isEmpty {
                if !keys.contains(key) { keys.append(key) }
            }
        }
        
        return keys
    }
    
    var hasAPIKey: Bool {
        !apiKeys.isEmpty
    }
    
    func refreshKeyCount() {
        apiKeysConfigured = apiKeys.count
    }
    
    // MARK: - Key Management (for CLI and UI)
    
    /// Add a new API key (auto-cleans whitespace)
    func addAPIKey(_ key: String, slot: Int = 0) {
        // Clean the key - remove all whitespace and newlines
        let cleanedKey = key.components(separatedBy: .whitespacesAndNewlines).joined()
        
        guard !cleanedKey.isEmpty else {
            print("Error: Empty key after cleaning")
            return
        }
        
        let keyName = slot == 0 ? "claude_api_key" : "claude_api_key_\(slot)"
        KeychainHelper.save(key: keyName, value: cleanedKey)
        refreshKeyCount()
        print("Saved key to slot \(slot): \(String(cleanedKey.prefix(15)))...")
    }
    
    /// Remove an API key
    func removeAPIKey(slot: Int = 0) {
        let keyName = slot == 0 ? "claude_api_key" : "claude_api_key_\(slot)"
        KeychainHelper.delete(key: keyName)
        refreshKeyCount()
    }
    
    /// Get next available slot for a new key
    func nextAvailableSlot() -> Int {
        if KeychainHelper.get(key: "claude_api_key") == nil { return 0 }
        for i in 1...5 {
            if KeychainHelper.get(key: "claude_api_key_\(i)") == nil { return i }
        }
        return 0 // Overwrite primary if all full
    }
    
    /// List all key slots and their status (for CLI)
    func listKeys() -> [(slot: Int, hasKey: Bool, prefix: String?)] {
        var result: [(slot: Int, hasKey: Bool, prefix: String?)] = []
        
        if let key = KeychainHelper.get(key: "claude_api_key") {
            result.append((0, true, String(key.prefix(12)) + "..."))
        } else {
            result.append((0, false, nil))
        }
        
        for i in 1...5 {
            if let key = KeychainHelper.get(key: "claude_api_key_\(i)") {
                result.append((i, true, String(key.prefix(12)) + "..."))
            }
        }
        
        return result
    }
    
    // MARK: - Analysis with Failover
    
    func analyzeConnection(_ alert: ConnectionAlert) async throws -> AIAnalysis {
        let keys = apiKeys
        guard !keys.isEmpty else {
            throw APIError.noAPIKey
        }
        
        await MainActor.run { isAnalyzing = true }
        defer { Task { @MainActor in isAnalyzing = false } }
        
        var lastError: Error?
        
        // Try each key until one works
        for (index, key) in keys.enumerated() {
            do {
                let prompt = buildPrompt(for: alert)
                let response = try await sendRequest(prompt: prompt, apiKey: key)
                let analysis = parseResponse(response, for: alert)
                
                // Success! If this wasn't the first key, log it
                if index > 0 {
                    print("API key \(index + 1) succeeded after \(index) failures")
                }
                
                return analysis
            } catch let error as APIError {
                lastError = error
                
                // Only retry on rate limit or server errors
                switch error {
                case .httpError(let code, _) where code == 429 || code >= 500:
                    print("Key \(index + 1) failed with \(code), trying next...")
                    continue
                case .httpError(let code, _) where code == 401:
                    print("Key \(index + 1) is invalid (401), trying next...")
                    continue
                default:
                    throw error // Don't retry on other errors
                }
            } catch {
                lastError = error
                print("Key \(index + 1) failed: \(error), trying next...")
            }
        }
        
        // All keys failed
        throw lastError ?? APIError.noAPIKey
    }
    
    // MARK: - Prompt Building
    
    private func buildPrompt(for alert: ConnectionAlert) -> String {
        """
        You are a macOS firewall security advisor. Analyze this outgoing network connection and provide a security recommendation.
        
        \(alert.promptDescription)
        
        Based on this information:
        1. Identify what service/application is likely making this connection
        2. Assess the security risk (is this expected behavior?)
        3. Recommend: ALLOW, BLOCK, or CAUTION
        4. Explain your reasoning briefly
        
        Respond in this exact JSON format:
        {
            "recommendation": "ALLOW" | "BLOCK" | "CAUTION",
            "confidence": 0.0-1.0,
            "known_service": "Name of known service if identified, or null",
            "summary": "One-line summary",
            "details": "2-3 sentence explanation",
            "risks": ["risk1", "risk2"]
        }
        
        Common safe connections:
        - Apple services (*.apple.com, *.icloud.com)
        - Google (*.google.com, *.googleapis.com, *.1e100.net)
        - Microsoft (*.microsoft.com)
        - CDNs (*.cloudflare.com, *.akamai.com, *.fastly.net)
        
        Be cautious about:
        - Unknown IPs without reverse DNS
        - Connections to unusual ports
        - Processes connecting to unexpected destinations
        - Newly installed or unsigned applications
        """
    }
    
    // MARK: - API Request
    
    private func sendRequest(prompt: String, apiKey: String) async throws -> String {
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        
        // Detect OAuth token vs API key and use appropriate header
        if apiKey.hasPrefix("sk-ant-oat") {
            // OAuth token - use Authorization Bearer header
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            print("Using OAuth token auth")
        } else {
            // Regular API key - use x-api-key header
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            print("Using API key auth")
        }
        
        request.timeoutInterval = 30
        
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: errorBody)
        }
        
        // Parse Claude response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstContent = content.first,
              let text = firstContent["text"] as? String else {
            throw APIError.parseError
        }
        
        return text
    }
    
    // MARK: - Response Parsing
    
    private func parseResponse(_ response: String, for alert: ConnectionAlert) -> AIAnalysis {
        var analysis = AIAnalysis(alert: alert)
        
        // Find JSON in response
        if let jsonStart = response.firstIndex(of: "{"),
           let jsonEnd = response.lastIndex(of: "}") {
            let jsonString = String(response[jsonStart...jsonEnd])
            
            if let data = jsonString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                
                if let rec = json["recommendation"] as? String {
                    switch rec.uppercased() {
                    case "ALLOW": analysis.recommendation = .allow
                    case "BLOCK": analysis.recommendation = .block
                    case "CAUTION": analysis.recommendation = .caution
                    default: analysis.recommendation = .unknown
                    }
                }
                
                analysis.confidence = json["confidence"] as? Double ?? 0.5
                analysis.summary = json["summary"] as? String ?? ""
                analysis.details = json["details"] as? String ?? ""
                analysis.risks = json["risks"] as? [String] ?? []
                analysis.knownService = json["known_service"] as? String
            }
        }
        
        if analysis.summary.isEmpty {
            analysis.summary = "See details"
            analysis.details = response
        }
        
        return analysis
    }
    
    // MARK: - Errors
    
    enum APIError: LocalizedError {
        case noAPIKey
        case invalidResponse
        case httpError(statusCode: Int, message: String)
        case parseError
        
        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "No API key configured. Please add your Claude API key."
            case .invalidResponse:
                return "Invalid response from server"
            case .httpError(let code, let message):
                return "HTTP \(code): \(message)"
            case .parseError:
                return "Failed to parse API response"
            }
        }
    }
}
