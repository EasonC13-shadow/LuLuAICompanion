import Foundation

/// Persists analysis history as JSON in Application Support
class HistoryManager: ObservableObject {
    static let shared = HistoryManager()
    
    @Published var entries: [HistoryEntry] = []
    
    private let fileManager = FileManager.default
    private let fileName = "analysis_history.json"
    
    var maxCount: Int {
        get { max(10, UserDefaults.standard.integer(forKey: "historyMaxCount").nonZero ?? 100) }
        set { UserDefaults.standard.set(min(1000, max(10, newValue)), forKey: "historyMaxCount") }
    }
    
    private var fileURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("LuLuAICompanion")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }
    
    private init() {
        load()
    }
    
    // MARK: - Public API
    
    func save(alert: ConnectionAlert, analysis: AIAnalysis, model: String? = nil) {
        let entry = HistoryEntry(
            timestamp: Date(),
            processName: alert.processName,
            processPath: alert.processPath,
            ipAddress: alert.ipAddress,
            port: alert.port,
            proto: alert.proto,
            reverseDNS: alert.reverseDNS,
            recommendation: analysis.recommendation.rawValue,
            confidence: analysis.confidence,
            summary: analysis.summary,
            details: analysis.details,
            risks: analysis.risks,
            knownService: analysis.knownService,
            model: model
        )
        entries.insert(entry, at: 0)
        trim()
        persist()
    }
    
    func getAll() -> [HistoryEntry] {
        return entries
    }
    
    func clear() {
        entries.removeAll()
        persist()
    }
    
    // MARK: - Private
    
    private func trim() {
        if entries.count > maxCount {
            entries = Array(entries.prefix(maxCount))
        }
    }
    
    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }
    
    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - History Entry

struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let processName: String
    let processPath: String
    let ipAddress: String
    let port: String
    let proto: String
    let reverseDNS: String
    let recommendation: String
    let confidence: Double
    let summary: String
    let details: String
    let risks: [String]
    let knownService: String?
    let model: String?
    
    init(timestamp: Date, processName: String, processPath: String, ipAddress: String,
         port: String, proto: String, reverseDNS: String, recommendation: String,
         confidence: Double, summary: String, details: String, risks: [String], knownService: String?, model: String? = nil) {
        self.id = UUID()
        self.timestamp = timestamp
        self.processName = processName
        self.processPath = processPath
        self.ipAddress = ipAddress
        self.port = port
        self.proto = proto
        self.reverseDNS = reverseDNS
        self.recommendation = recommendation
        self.confidence = confidence
        self.summary = summary
        self.details = details
        self.risks = risks
        self.knownService = knownService
        self.model = model
    }
    
    var recommendationEmoji: String {
        switch recommendation {
        case "Allow": return "✅"
        case "Block": return "🚫"
        case "Caution": return "⚠️"
        default: return "❓"
        }
    }
    
    var displayHost: String {
        reverseDNS.isEmpty ? ipAddress : reverseDNS
    }
    
    var formattedTimestamp: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: timestamp)
    }
    
    var pickerLabel: String {
        "\(recommendationEmoji) \(recommendation.uppercased()) \(displayHost) (\(formattedTimestamp))\(model != nil ? " [\(model!)]" : "")"
    }
}

// Helper
private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
