import Foundation

/// AI provider types
enum AIProvider: String {
    case anthropic = "Anthropic"
    case openai = "OpenAI"
    case gemini = "Gemini"
    case threeMate = "3mate"
    
    var icon: String {
        switch self {
        case .anthropic: return "brain.head.profile"
        case .openai: return "sparkles"
        case .gemini: return "diamond"
        case .threeMate: return "star.circle"
        }
    }
    
    var model: String {
        switch self {
        case .anthropic: return "claude-haiku-4-5"
        case .openai: return "gpt-5-nano-2025-08-07"
        case .gemini: return "gemini-3-flash-preview"
        case .threeMate: return "claude-haiku-4-5"
        }
    }
    
    static func detect(from apiKey: String) -> AIProvider {
        if apiKey.hasPrefix("sk-3mate") {
            return .threeMate
        } else if apiKey.hasPrefix("sk-ant-") {
            return .anthropic
        } else if apiKey.hasPrefix("AIza") {
            return .gemini
        } else if apiKey.hasPrefix("sk-") {
            return .openai
        } else {
            return .anthropic // fallback
        }
    }
    
    /// Validate key format
    static func isValidKey(_ key: String) -> Bool {
        return key.hasPrefix("sk-ant-") ||
               key.hasPrefix("sk-3mate") ||
               key.hasPrefix("AIza") ||
               (key.hasPrefix("sk-") && key.count > 20)
    }
}

// Keep typealias for backward compatibility
typealias ClaudeAPIClient = AIClient

/// Client for AI API with multi-key failover support (Anthropic, OpenAI, Gemini, 3mate)
class AIClient: ObservableObject {
    @Published var isAnalyzing = false
    @Published var lastError: String?
    @Published var apiKeysConfigured: Int = 0
    var lastUsedModel: String?
    
    // API endpoints
    private let anthropicURL = "https://api.anthropic.com/v1/messages"
    private let threeMateURL = "https://platform.3mate.io/v1/messages"
    private let openaiURL = "https://api.openai.com/v1/chat/completions"
    private let geminiBaseURL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent"
    
    static let shared = AIClient()
    
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
        let cleanedKey = key.components(separatedBy: .whitespacesAndNewlines).joined()
        
        guard !cleanedKey.isEmpty else {
            print("Error: Empty key after cleaning")
            return
        }
        
        let keyName = slot == 0 ? "claude_api_key" : "claude_api_key_\(slot)"
        KeychainHelper.save(key: keyName, value: cleanedKey)
        refreshKeyCount()
        let provider = AIProvider.detect(from: cleanedKey)
        print("Saved \(provider.rawValue) key to slot \(slot): \(String(cleanedKey.prefix(15)))...")
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
        return 0
    }
    
    /// List all key slots and their status (for CLI)
    func listKeys() -> [(slot: Int, hasKey: Bool, prefix: String?, provider: AIProvider?)] {
        var result: [(slot: Int, hasKey: Bool, prefix: String?, provider: AIProvider?)] = []
        
        if let key = KeychainHelper.get(key: "claude_api_key") {
            result.append((0, true, String(key.prefix(12)) + "...", AIProvider.detect(from: key)))
        } else {
            result.append((0, false, nil, nil))
        }
        
        for i in 1...5 {
            if let key = KeychainHelper.get(key: "claude_api_key_\(i)") {
                result.append((i, true, String(key.prefix(12)) + "...", AIProvider.detect(from: key)))
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
        
        print("\n>>> Starting analysis with \(keys.count) key(s)")
        for (index, key) in keys.enumerated() {
            let provider = AIProvider.detect(from: key)
            print("\n>>> Trying key \(index + 1)/\(keys.count) [\(provider.rawValue)]: \(String(key.prefix(20)))...")
            do {
                let prompt = buildPrompt(for: alert)
                let response = try await sendRequest(prompt: prompt, apiKey: key)
                let analysis = parseResponse(response, for: alert)
                
                lastUsedModel = provider.model
                if index > 0 {
                    print("Key \(index + 1) [\(provider.rawValue)] succeeded after \(index) failures")
                }
                
                return analysis
            } catch let error as APIError {
                lastError = error
                
                switch error {
                case .httpError(let code, _) where code == 429 || code >= 500:
                    print("Key \(index + 1) failed with \(code), trying next...")
                    continue
                case .httpError(let code, _) where code == 401 || code == 403:
                    print("Key \(index + 1) is invalid (\(code)), trying next...")
                    continue
                default:
                    throw error
                }
            } catch {
                lastError = error
                print("Key \(index + 1) failed: \(error), trying next...")
            }
        }
        
        throw lastError ?? APIError.noAPIKey
    }
    
    // MARK: - Prompt Building
    
    private func buildPrompt(for alert: ConnectionAlert) -> String {
        """
        You are a macOS firewall security advisor. Analyze this LuLu Firewall alert.
        
        \(alert.promptDescription)
        
        The raw UI elements above are extracted from a LuLu firewall alert popup. Parse them to identify:
        - Process name, PID, path, and arguments (the process making the connection)
        - Destination IP address, port, protocol
        - Reverse DNS if available
        
        LuLu alert format typically has labels like "pid:", "args:", "path:", "ip address:", "port/protocol:", "(reverse) dns:" followed by their values.
        
        Based on ALL available information:
        1. Identify what application/service is making this connection and why
        2. Assess the security risk
        3. Recommend: ALLOW, BLOCK, or CAUTION
        
        Respond in JSON:
        {
            "recommendation": "ALLOW" | "BLOCK" | "CAUTION",
            "confidence": 0.0-1.0,
            "known_service": "Name of service or null",
            "summary": "One-line summary including process name and destination",
            "details": "2-3 sentence explanation with context about the process and connection",
            "risks": ["risk1", "risk2"]
        }
        
        Common safe patterns:
        - Apple services (*.apple.com, *.icloud.com)
        - GitHub (*.github.com, github CDN IPs)
        - Google (*.google.com, *.googleapis.com)
        - CDNs (*.cloudflare.com, *.akamai.com, *.fastly.net, *.awsglobalaccelerator.com)
        - Development tools (curl, git, npm, pip accessing known repos)
        """
    }
    
    // MARK: - API Request
    
    private let claudeCodeVersion = "2.1.2"
    
    private func sendRequest(prompt: String, apiKey: String) async throws -> String {
        let provider = AIProvider.detect(from: apiKey)
        
        switch provider {
        case .anthropic:
            return try await sendAnthropicRequest(prompt: prompt, apiKey: apiKey, isOAuth: apiKey.hasPrefix("sk-ant-oat"))
        case .threeMate:
            return try await sendAnthropicRequest(prompt: prompt, apiKey: apiKey, isOAuth: false, baseURL: threeMateURL)
        case .openai:
            return try await sendOpenAIRequest(prompt: prompt, apiKey: apiKey)
        case .gemini:
            return try await sendGeminiRequest(prompt: prompt, apiKey: apiKey)
        }
    }
    
    // MARK: - Anthropic / 3mate Request
    
    private func sendAnthropicRequest(prompt: String, apiKey: String, isOAuth: Bool, baseURL: String? = nil) async throws -> String {
        let url = baseURL ?? anthropicURL
        
        print("=== API Request Debug ===")
        print("Provider: \(baseURL != nil ? "3mate" : "Anthropic")")
        print("Using endpoint: \(url)")
        
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        
        if baseURL == threeMateURL {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        } else if isOAuth {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("claude-code-20250219,oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("claude-cli/\(claudeCodeVersion) (external, cli)", forHTTPHeaderField: "User-Agent")
            request.setValue("cli", forHTTPHeaderField: "x-app")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        } else {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        
        request.timeoutInterval = 30
        
        let model = AIProvider.detect(from: apiKey).model
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        
        if isOAuth {
            body["system"] = [
                ["type": "text", "text": "You are Claude Code, Anthropic's official CLI for Claude."],
                ["type": "text", "text": "You are also a macOS firewall security advisor. Analyze connections and respond in JSON."]
            ]
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        print("[DEBUG] Response status: \(httpResponse.statusCode)")
        
        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("[DEBUG] Error response: \(errorBody)")
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: errorBody)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstContent = content.first,
              let text = firstContent["text"] as? String else {
            throw APIError.parseError
        }
        
        return text
    }
    
    // MARK: - OpenAI Request
    
    private func sendOpenAIRequest(prompt: String, apiKey: String) async throws -> String {
        print("=== API Request Debug ===")
        print("Provider: OpenAI")
        print("Using endpoint: \(openaiURL)")
        
        var request = URLRequest(url: URL(string: openaiURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        
        let body: [String: Any] = [
            "model": AIProvider.openai.model,
            "max_tokens": 1024,
            "messages": [
                ["role": "system", "content": "You are a macOS firewall security advisor. Analyze connections and respond in JSON."],
                ["role": "user", "content": prompt]
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        print("[DEBUG] Response status: \(httpResponse.statusCode)")
        
        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("[DEBUG] Error response: \(errorBody)")
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: errorBody)
        }
        
        // OpenAI response format: { choices: [{ message: { content: "..." } }] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw APIError.parseError
        }
        
        return text
    }
    
    // MARK: - Gemini Request
    
    private func sendGeminiRequest(prompt: String, apiKey: String) async throws -> String {
        let urlString = "\(geminiBaseURL)?key=\(apiKey)"
        
        print("=== API Request Debug ===")
        print("Provider: Gemini")
        print("Using endpoint: \(geminiBaseURL)?key=***")
        
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        
        let systemInstruction = "You are a macOS firewall security advisor. Analyze connections and respond in JSON."
        
        let body: [String: Any] = [
            "system_instruction": [
                "parts": [["text": systemInstruction]]
            ],
            "contents": [
                [
                    "parts": [["text": prompt]]
                ]
            ],
            "generationConfig": [
                "maxOutputTokens": 1024
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        print("[DEBUG] Response status: \(httpResponse.statusCode)")
        
        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("[DEBUG] Error response: \(errorBody)")
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: errorBody)
        }
        
        // Gemini response format: { candidates: [{ content: { parts: [{ text: "..." }] } }] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            throw APIError.parseError
        }
        
        return text
    }
    
    // MARK: - Response Parsing
    
    private func parseResponse(_ response: String, for alert: ConnectionAlert) -> AIAnalysis {
        var analysis = AIAnalysis(alert: alert)
        
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
                return "No API key configured. Please add an API key."
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
