import SwiftUI
import Combine
import GRDB
import UIKit

struct MemoryPanelView: View {
    let clusters: [PlaceCluster]

    @StateObject private var viewModel: MemoryPanelViewModel

    init(clusters: [PlaceCluster]) {
        self.clusters = clusters
        _viewModel = StateObject(wrappedValue: MemoryPanelViewModel(clusters: clusters))
    }

    var body: some View {
        NavigationView {
            List {
                if viewModel.visitLayers.isEmpty {
                    VStack(spacing: 20) {
                        ProgressView()
                        Text("唤醒记忆中...")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(viewModel.visitLayers, id: \.id) { layer in
                        VisitLayerRowView(layer: layer)
                            .padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle("\(clusters.count) 个地点的记忆")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: clusters.map(\.id)) { _, _ in
            viewModel.updateClusters(clusters)
        }
    }
}

@MainActor
final class MemoryPanelViewModel: ObservableObject {
    @Published var visitLayers: [VisitLayer] = []
    private var clusters: [PlaceCluster]
    private var cancellables = Set<AnyCancellable>()

    init(clusters: [PlaceCluster]) {
        self.clusters = clusters
        observeVisitLayers()
    }

    func updateClusters(_ newClusters: [PlaceCluster]) {
        self.clusters = newClusters
        observeVisitLayers()
    }

    private func observeVisitLayers() {
        cancellables.removeAll()

        let clusterIds = clusters.map { $0.id }
        
        ValueObservation
            .tracking { db in
                try VisitLayer
                    .filter(clusterIds.contains(Column("placeClusterId")))
                    .order(Column("startAt").desc)
                    .fetchAll(db)
            }
            .publisher(in: DatabaseContainer.shared.db.reader)
            .sink { _ in } receiveValue: { [weak self] layers in
                self?.visitLayers = layers
            }
            .store(in: &cancellables)
    }
}

private struct VisitLayerRowView: View {
    let layer: VisitLayer

    @State private var localIdentifiers: [String] = []
    @State private var draftText: String = ""
    @State private var isSaving: Bool = false

    private let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dateRangeText(layer))
                .font(.headline)

            if !localIdentifiers.isEmpty {
                let cellSpacing: CGFloat = 4
                let rowWidth = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? 375
                let cellSize = floor((rowWidth - 32 - cellSpacing * 2) / 3)

                LazyVGrid(columns: columns, spacing: cellSpacing) {
                    ForEach(localIdentifiers.prefix(9), id: \.self) { id in
                        ThumbnailView(localIdentifier: id, size: CGSize(width: cellSize, height: cellSize))
                    }
                }
            }

            if let text = layer.userText, !text.isEmpty {
                Text(text)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 8) {
                    TextField("Write a line...", text: $draftText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    Button(action: {
                        save()
                    }) {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(isSaving || draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            draftText = layer.userText ?? ""
        }
        .task {
            await loadLocalIdentifiers()
        }
    }

    private func loadLocalIdentifiers() async {
        do {
            let ids: [String] = try await DatabaseContainer.shared.db.reader.read { db in
                let links = try VisitLayerPhotoAsset
                    .filter(Column("visitLayerId") == layer.id)
                    .fetchAll(db)

                if links.isEmpty { return [] }

                let photoIds = links.map { $0.photoAssetId }
                let photos = try PhotoAsset
                    .filter(photoIds.contains(Column("id")))
                    .fetchAll(db)

                return photos.map { $0.localIdentifier }
            }

            await MainActor.run {
                self.localIdentifiers = ids
            }
        } catch {
            print("Failed to load photos for layer: \(error)")
        }
    }

    private func save() {
        guard !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSaving = true
        Task {
            do {
                try await SettleStoryNodeUseCase().run(visitLayerId: layer.id, text: draftText)
                // 成功后由数据库观察者或父视图刷新，这里简单处理
                await MainActor.run {
                    isSaving = false
                }
            } catch {
                print("Failed to save story: \(error)")
                await MainActor.run {
                    isSaving = false
                }
            }
        }
    }

    private func dateRangeText(_ layer: VisitLayer) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(formatter.string(from: layer.startAt)) - \(formatter.string(from: layer.endAt))"
    }
}
