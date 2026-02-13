import SwiftUI
import GRDB

struct MemoryPanelView: View {
    let placeCluster: PlaceCluster

    @State private var visitLayers: [VisitLayer] = []

    var body: some View {
        NavigationView {
            List {
                if visitLayers.isEmpty {
                    Text("No visits yet")
                } else {
                    ForEach(visitLayers, id: \.id) { layer in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(dateRangeText(layer))
                                .font(.headline)
                            if let text = layer.userText, !text.isEmpty {
                                Text(text)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.inline)
                        .onAppear {
                load()
            }
        }
    }

    private func load() {
        do {
            try DatabaseContainer.shared.db.reader.read { db in
                let rows = try VisitLayer
                    .filter(Column("placeClusterId") == placeCluster.id)
                    .order(Column("startAt").desc)
                    .fetchAll(db)
                DispatchQueue.main.async {
                    self.visitLayers = rows
                }
            }
        } catch {
            print("Failed to load visit layers: \(error)")
        }
    }

    private func dateRangeText(_ layer: VisitLayer) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(formatter.string(from: layer.startAt)) - \(formatter.string(from: layer.endAt))"
    }
}
