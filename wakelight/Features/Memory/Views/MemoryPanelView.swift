import SwiftUI
import Combine
import GRDB
import UIKit
import CoreLocation

struct MemoryPanelView: View {
    let clusters: [PlaceCluster]

    @StateObject private var viewModel: MemoryPanelViewModel

    private var panelTitle: String {
        if let cityName = viewModel.cityName {
            return "\(cityName)记忆"
        }
        return clusters.count == 1 ? "地点记忆" : "\(clusters.count) 个地点记忆"
    }

    private var emptyStateText: String {
        switch filterMode {
        case .unhandled:
            return "暂无未加入故事的记忆"
        case .story:
            return "暂无已成故事的记忆"
        }
    }

    private enum FilterMode: String, CaseIterable, Identifiable {
        case unhandled
        case story

        var id: String { rawValue }
        var title: String {
            switch self {
            case .unhandled: return "未加入故事"
            case .story: return "已成故事"
            }
        }
    }

    @State private var filterMode: FilterMode = .unhandled

    @State private var isMultiSelectMode: Bool = false
    @State private var selectedVisitLayerIds: Set<UUID> = []

    @State private var isPresentingMergeSheet: Bool = false
    @State private var mergeDraftSummary: String = ""
    @State private var isMerging: Bool = false
    @State private var mergeErrorMessage: String?

    init(clusters: [PlaceCluster]) {
        self.clusters = clusters
        _viewModel = StateObject(wrappedValue: MemoryPanelViewModel(clusters: clusters))
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Picker("筛选", selection: $filterMode) {
                        ForEach(FilterMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                }
                .listSectionSeparator(.hidden)

                let visibleLayers = viewModel.visitLayers.filter { layer in
                    switch filterMode {
                    case .unhandled:
                        return layer.isStoryNode == false
                    case .story:
                        return layer.isStoryNode == true
                    }
                }

                if visibleLayers.isEmpty {
                    VStack(spacing: 20) {
                        Text(emptyStateText)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(visibleLayers, id: \.id) { layer in
                        VisitLayerRowView(
                            layer: layer,
                            isMultiSelectMode: isMultiSelectMode,
                            isSelected: selectedVisitLayerIds.contains(layer.id),
                            onToggleSelected: {
                                if selectedVisitLayerIds.contains(layer.id) {
                                    selectedVisitLayerIds.remove(layer.id)
                                } else {
                                    selectedVisitLayerIds.insert(layer.id)
                                }
                            },
                            onLongPressSelect: {
                                if !isMultiSelectMode {
                                    isMultiSelectMode = true
                                }
                                selectedVisitLayerIds.insert(layer.id)
                            }
                        )
                        .padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle(panelTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("多选") {
                        isMultiSelectMode = true
                    }
                    .opacity(isMultiSelectMode ? 0 : 1)
                    .disabled(isMultiSelectMode)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isMultiSelectMode {
                    HStack(spacing: 12) {
                        Button("取消选择") {
                            selectedVisitLayerIds.removeAll()
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button("合并为 1 个故事 (\(selectedVisitLayerIds.count))") {
                            mergeDraftSummary = ""
                            isPresentingMergeSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedVisitLayerIds.count < 2)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                }
            }
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $isPresentingMergeSheet) {
            MergeVisitLayersSheet(
                visitLayers: viewModel.visitLayers.filter { selectedVisitLayerIds.contains($0.id) },
                summaryText: $mergeDraftSummary,
                isMerging: $isMerging,
                errorMessage: $mergeErrorMessage,
                onConfirm: {
                    mergeErrorMessage = nil
                    isMerging = true
                    Task {
                        do {
                            _ = try await MergeVisitLayersUseCase().run(
                                visitLayerIds: Array(selectedVisitLayerIds),
                                summaryText: mergeDraftSummary
                            )
                            await MainActor.run {
                                isMerging = false
                                isPresentingMergeSheet = false
                                isMultiSelectMode = false
                                selectedVisitLayerIds.removeAll()
                            }
                        } catch {
                            await MainActor.run {
                                isMerging = false
                                mergeErrorMessage = String(describing: error)
                            }
                        }
                    }
                },
                onCancel: {
                    isPresentingMergeSheet = false
                }
            )
        }
        .onChange(of: clusters.map(\.id)) { _, _ in
            viewModel.updateClusters(clusters)
        }
    }
}

private struct MergeVisitLayersSheet: View {
    let visitLayers: [VisitLayer]

    @Binding var summaryText: String
    @Binding var isMerging: Bool
    @Binding var errorMessage: String?

    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                Text("将 \(visitLayers.count) 个记忆合并为 1 个故事")
                    .font(.headline)

                if let rangeText = timeRangeText(visitLayers) {
                    Text(rangeText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                TextEditor(text: $summaryText)
                    .frame(minHeight: 140)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(.red)
                }

                Spacer()
            }
            .padding(16)
            .navigationTitle("合并确认")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { onCancel() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(isMerging ? "合并中..." : "确认") {
                        onConfirm()
                    }
                    .disabled(isMerging || summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func timeRangeText(_ layers: [VisitLayer]) -> String? {
        guard let minStart = layers.map(\.startAt).min(), let maxEnd = layers.map(\.endAt).max() else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年MM月dd日 HH:mm"
        return "\(formatter.string(from: minStart)) - \(formatter.string(from: maxEnd))"
    }
}


@MainActor
final class MemoryPanelViewModel: ObservableObject {
    @Published var visitLayers: [VisitLayer] = []
    @Published var cityName: String?

    private var clusters: [PlaceCluster]
    private var cancellables = Set<AnyCancellable>()

    private let resolveCityNameUseCase = ResolvePlaceClusterCityNameUseCase()

    init(clusters: [PlaceCluster]) {
        self.clusters = clusters
        observeVisitLayers()
        resolveCityNameIfNeeded()
    }

    func updateClusters(_ newClusters: [PlaceCluster]) {
        self.clusters = newClusters
        observeVisitLayers()
        resolveCityNameIfNeeded()
    }

    private func resolveCityNameIfNeeded() {
        guard let first = clusters.first else {
            cityName = nil
            return
        }

        Task {
            do {
                let name = try await resolveCityNameUseCase.run(cluster: first)
                await MainActor.run {
                    self.cityName = name
                }
            } catch {
                print("Failed to resolve city name: \(error)")
            }
        }
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
    let isMultiSelectMode: Bool
    let isSelected: Bool
    let onToggleSelected: () -> Void
    let onLongPressSelect: () -> Void

    @State private var localIdentifiers: [String] = []
    @State private var draftText: String = ""
    @State private var isSaving: Bool = false

    private let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isMultiSelectMode {
                Button(action: onToggleSelected) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(isSelected ? .blue : .secondary)
                        .padding(.top, 2)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(dateRangeText(layer))
                    .font(.headline)

                if !localIdentifiers.isEmpty {
                    let cellSpacing: CGFloat = 4
                    let rowWidth = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? 375
                    let cellSize = floor((rowWidth - 32 - cellSpacing * 3) / 4)

                    LazyVGrid(columns: columns, spacing: cellSpacing) {
                        ForEach(localIdentifiers.prefix(4), id: \.self) { id in
                            ThumbnailView(localIdentifier: id, size: CGSize(width: cellSize, height: cellSize))
                        }
                    }
                }

                if let text = layer.userText, !text.isEmpty {
                    Text(text)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else if !isMultiSelectMode {
                    HStack(spacing: 8) {
                        TextField("写一句...", text: $draftText)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        Button(action: {
                            save()
                        }) {
                            if isSaving {
                                ProgressView()
                            } else {
                                Text("加入故事")
                            }
                        }
                        .disabled(isSaving || draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isMultiSelectMode {
                onToggleSelected()
            }
        }
        .onLongPressGesture(minimumDuration: 0.35) {
            onLongPressSelect()
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
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年MM月dd日 HH:mm"
        let start = formatter.string(from: layer.startAt)
        
        // 如果结束日期和开始日期是同一天，简化显示
        let calendar = Calendar.current
        if calendar.isDate(layer.startAt, inSameDayAs: layer.endAt) {
            formatter.dateFormat = "HH:mm"
        }
        let end = formatter.string(from: layer.endAt)
        
        return "\(start) - \(end)"
    }
}
