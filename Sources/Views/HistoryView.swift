import SwiftUI

struct HistoryView: View {
    @ObservedObject private var history = HistoryManager.shared
    @State private var selectedID: UUID?
    
    var body: some View {
        VStack(spacing: 0) {
            if history.entries.isEmpty {
                Spacer()
                Text("No analysis history yet")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                // Picker
                HStack {
                    Picker("Entry:", selection: $selectedID) {
                        Text("Select an entry...").tag(nil as UUID?)
                        ForEach(history.entries) { entry in
                            Text(entry.pickerLabel).tag(entry.id as UUID?)
                        }
                    }
                    .labelsHidden()
                    
                    Spacer()
                    
                    Button("Clear All") {
                        history.clear()
                        selectedID = nil
                    }
                    .foregroundColor(.red)
                }
                .padding()
                
                Divider()
                
                // Detail
                if let entry = history.entries.first(where: { $0.id == selectedID }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            // Recommendation header
                            HStack {
                                Text("\(entry.recommendationEmoji) \(entry.recommendation)")
                                    .font(.title2.bold())
                                if let service = entry.knownService {
                                    Text("(\(service))")
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(String(format: "%.0f%% confidence", entry.confidence * 100))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            // Connection info
                            GroupBox("Connection") {
                                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                                    GridRow {
                                        Text("Process").fontWeight(.medium)
                                        Text(entry.processName.isEmpty ? "Unknown" : entry.processName)
                                            .font(.system(.body, design: .monospaced))
                                    }
                                    if !entry.processPath.isEmpty {
                                        GridRow {
                                            Text("Path").fontWeight(.medium)
                                            Text(entry.processPath)
                                                .font(.caption.monospaced())
                                                .lineLimit(2)
                                        }
                                    }
                                    GridRow {
                                        Text("Destination").fontWeight(.medium)
                                        Text("\(entry.ipAddress):\(entry.port) (\(entry.proto))")
                                            .font(.system(.body, design: .monospaced))
                                    }
                                    if !entry.reverseDNS.isEmpty {
                                        GridRow {
                                            Text("DNS").fontWeight(.medium)
                                            Text(entry.reverseDNS)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                            }
                            
                            // AI Analysis
                            GroupBox("AI Analysis") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(entry.summary)
                                        .fontWeight(.medium)
                                    Text(entry.details)
                                        .foregroundColor(.secondary)
                                    
                                    if !entry.risks.isEmpty {
                                        Divider()
                                        Text("Risks:")
                                            .fontWeight(.medium)
                                        ForEach(entry.risks, id: \.self) { risk in
                                            HStack(alignment: .top) {
                                                Text("•")
                                                Text(risk)
                                            }
                                            .foregroundColor(.orange)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                            }
                            
                            HStack {
                                Text(entry.formattedTimestamp)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let model = entry.model {
                                    Text("Model: \(model)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding()
                    }
                } else {
                    Spacer()
                    Text("Select an entry above to view details")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            if selectedID == nil { selectedID = history.entries.first?.id }
        }
    }
}
