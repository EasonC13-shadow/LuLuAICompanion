import SwiftUI

/// Observable model for live updates
class AnalysisViewModel: ObservableObject {
    @Published var alert: ConnectionAlert
    @Published var recommendation: AIAnalysis.Recommendation = .unknown
    @Published var confidence: Double = 0
    @Published var summary: String = ""
    @Published var details: String = ""
    @Published var risks: [String] = []
    @Published var knownService: String?
    
    @Published var isLoadingEnrichment: Bool = true
    @Published var isLoadingAnalysis: Bool = true
    @Published var errorMessage: String?
    
    init(alert: ConnectionAlert) {
        self.alert = alert
    }
    
    func updateEnrichment(_ enrichedAlert: ConnectionAlert) {
        self.alert = enrichedAlert
        self.isLoadingEnrichment = false
    }
    
    func updateAnalysis(_ analysis: AIAnalysis) {
        self.recommendation = analysis.recommendation
        self.confidence = analysis.confidence
        self.summary = analysis.summary
        self.details = analysis.details
        self.risks = analysis.risks
        self.knownService = analysis.knownService
        self.isLoadingAnalysis = false
        self.errorMessage = nil
    }
    
    func setError(_ message: String) {
        self.errorMessage = message
        self.isLoadingAnalysis = false
    }
    
    func retry() {
        // Reset state and re-analyze
        self.isLoadingAnalysis = true
        self.errorMessage = nil
        self.recommendation = .unknown
        self.confidence = 0
        self.summary = ""
        self.details = ""
        self.risks = []
        self.knownService = nil
        
        Task {
            let client = ClaudeAPIClient.shared
            if client.hasAPIKey {
                do {
                    let analysis = try await client.analyzeConnection(self.alert)
                    await MainActor.run {
                        self.updateAnalysis(analysis)
                    }
                } catch {
                    await MainActor.run {
                        self.setError(error.localizedDescription)
                    }
                }
            } else {
                await MainActor.run {
                    self.setError("No API key configured.")
                }
            }
        }
    }
}

struct AnalysisView: View {
    @ObservedObject var viewModel: AnalysisViewModel
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Recommendation Header
                HStack(spacing: 12) {
                    if viewModel.isLoadingAnalysis {
                        ProgressView()
                            .scaleEffect(1.5)
                            .frame(width: 48, height: 48)
                    } else {
                        Text(viewModel.recommendation.emoji)
                            .font(.system(size: 48))
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        if viewModel.isLoadingAnalysis {
                            Text("Analyzing...")
                                .font(.title)
                                .fontWeight(.bold)
                                .foregroundColor(.secondary)
                            Text("Asking Claude for security assessment")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text(viewModel.recommendation.rawValue)
                                .font(.title)
                                .fontWeight(.bold)
                                .foregroundColor(recommendationColor)
                            
                            if let service = viewModel.knownService {
                                Text(service)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            // Confidence bar
                            HStack(spacing: 4) {
                                Text("Confidence:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                ProgressView(value: viewModel.confidence)
                                    .frame(width: 80)
                                
                                Text("\(Int(viewModel.confidence * 100))%")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    Spacer()
                }
                .padding()
                .background(recommendationColor.opacity(0.1))
                .cornerRadius(12)
                
                // Error message with inline key input
                if let error = viewModel.errorMessage {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(error)
                                .foregroundColor(.red)
                            
                            Spacer()
                            
                            Button(action: { viewModel.retry() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.clockwise")
                                    Text("Retry")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        
                        // Show key input if it's an API key error
                        if error.contains("API key") || error.contains("invalid") || error.contains("401") {
                            APIKeyInputSection(claudeClient: ClaudeAPIClient.shared)
                        }
                    }
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                }
                
                // Summary
                if !viewModel.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Summary")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(viewModel.summary)
                            .font(.body)
                    }
                }
                
                // Connection Details
                GroupBox("Connection Details") {
                    VStack(alignment: .leading, spacing: 8) {
                        DetailRow(label: "Process", value: viewModel.alert.processName)
                        DetailRow(label: "Path", value: viewModel.alert.processPath)
                        DetailRow(label: "Destination", value: "\(viewModel.alert.ipAddress):\(viewModel.alert.port)")
                        DetailRow(label: "Protocol", value: viewModel.alert.proto)
                        
                        if viewModel.isLoadingEnrichment {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Loading WHOIS/DNS...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            if !viewModel.alert.reverseDNS.isEmpty {
                                DetailRow(label: "DNS", value: viewModel.alert.reverseDNS)
                            }
                            if let geo = viewModel.alert.geoLocation {
                                DetailRow(label: "Location", value: geo)
                            }
                            if let whois = viewModel.alert.whoisData {
                                DetailRow(label: "WHOIS", value: whois)
                            }
                        }
                    }
                }
                
                // Details
                if !viewModel.details.isEmpty {
                    GroupBox("Analysis") {
                        Text(viewModel.details)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                
                // Risks
                if !viewModel.risks.isEmpty {
                    GroupBox("Risks") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(viewModel.risks, id: \.self) { risk in
                                HStack(alignment: .top) {
                                    Text("•")
                                        .foregroundColor(.orange)
                                    Text(risk)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                
                Spacer()
            }
            .padding()
        }
        .frame(minWidth: 380, minHeight: 300)
    }
    
    private var recommendationColor: Color {
        if viewModel.isLoadingAnalysis { return .gray }
        switch viewModel.recommendation {
        case .allow: return .green
        case .block: return .red
        case .caution: return .orange
        case .unknown: return .gray
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack(alignment: .top) {
            Text(label + ":")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            
            Spacer()
        }
    }
}

// MARK: - Inline API Key Input

struct APIKeyInputSection: View {
    @ObservedObject var claudeClient: ClaudeAPIClient
    @State private var newKey: String = ""
    @State private var showKey = false
    @State private var statusMessage: String?
    @State private var showingKeys = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            
            Text("Add API Key")
                .font(.caption)
                .fontWeight(.medium)
            
            // Key input
            HStack {
                if showKey {
                    TextField("sk-ant-api03-...", text: $newKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                } else {
                    SecureField("sk-ant-api03-...", text: $newKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                }
                
                Button(action: { showKey.toggle() }) {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                
                Button(action: addKey) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.green)
                }
                .buttonStyle(.borderless)
                .disabled(newKey.isEmpty)
            }
            
            // Status or instructions
            if let status = statusMessage {
                Text(status)
                    .font(.caption2)
                    .foregroundColor(status.contains("✓") ? .green : .orange)
            }
            
            // Show configured keys
            DisclosureGroup("Keys: \(claudeClient.apiKeysConfigured) configured", isExpanded: $showingKeys) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(claudeClient.listKeys(), id: \.slot) { keyInfo in
                        if keyInfo.hasKey {
                            HStack {
                                Text(keyInfo.prefix ?? "sk-ant-...")
                                    .font(.caption2.monospaced())
                                Spacer()
                                Button(action: {
                                    claudeClient.removeAPIKey(slot: keyInfo.slot)
                                }) {
                                    Image(systemName: "trash")
                                        .font(.caption2)
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption2)
            
            // Help text
            HStack {
                Text("Or run:")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("claude setup-token")
                    .font(.caption2.monospaced())
                    .foregroundColor(.blue)
                    .textSelection(.enabled)
            }
            
            Link(destination: URL(string: "https://console.anthropic.com/")!) {
                HStack {
                    Image(systemName: "arrow.up.right.square")
                    Text("Get API Key")
                }
                .font(.caption2)
            }
        }
    }
    
    private func addKey() {
        guard !newKey.isEmpty else { return }
        
        // Clean the key first
        let cleanedKey = newKey.components(separatedBy: .whitespacesAndNewlines).joined()
        
        if !cleanedKey.hasPrefix("sk-ant-") {
            statusMessage = "⚠️ Invalid format (should start with sk-ant-)"
            return
        }
        
        let slot = claudeClient.nextAvailableSlot()
        claudeClient.addAPIKey(cleanedKey, slot: slot)
        newKey = ""
        statusMessage = "✓ Key added! Click Retry."
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            statusMessage = nil
        }
    }
}
