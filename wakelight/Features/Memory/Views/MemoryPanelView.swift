import SwiftUI
import Combine
import GRDB
import UIKit

struct MemoryPanelView: View {
    let placeCluster: PlaceCluster

    @StateObject private var viewModel: MemoryPanelViewModel

    init(placeCluster: PlaceCluster) {
        self.placeCluster = placeCluster
        _viewModel = StateObject(wrappedValue: MemoryPanelViewModel(placeCluster: placeCluster))
    }

    var body: some View {
        NavigationView {
            List {
                if viewModel.visitLayers.isEmpty {
                    Text("No visits yet")
                } else {
                    ForEach(viewModel.visitLayers, id: \.id) { layer in
                        VisitLayerRowView(layer: layer)
                            .padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

@MainActor
final class MemoryPanelViewModel: ObservableObject {
    @Published var visitLayers: [VisitLayer] = []
    private let placeCluster: PlaceCluster
    private var cancellables = Set<AnyCancellable>()

    init(placeCluster: PlaceCluster) {
        self.placeCluster = placeCluster
        observeVisitLayers()
    }

    private func observeVisitLayers() {
        ValueObservation
            .tracking { db in
                try VisitLayer
                    .filter(Column("placeClusterId") == self.placeCluster.id)
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
