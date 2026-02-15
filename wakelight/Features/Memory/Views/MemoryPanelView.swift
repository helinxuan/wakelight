import SwiftUI
import Combine
import GRDB
import UIKit
import CoreLocation

struct MemoryPanelView: View {
    let clusters: [PlaceCluster]
    let selectedClusterId: UUID?

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

    private func exitMultiSelect() {
        isMultiSelectMode = false
        selectedVisitLayerIds.removeAll()
    }

    @State private var isMultiSelectMode: Bool = false
    @State private var selectedVisitLayerIds: Set<UUID> = []

    @State private var isPresentingMergeSheet: Bool = false
    @State private var mergeDraftSummary: String = ""
    @State private var isMerging: Bool = false
    @State private var mergeErrorMessage: String?

    init(clusters: [PlaceCluster], selectedClusterId: UUID? = nil) {
        self.clusters = clusters
        self.selectedClusterId = selectedClusterId
        _viewModel = StateObject(wrappedValue: MemoryPanelViewModel(clusters: clusters, selectedClusterId: selectedClusterId))
    }

    var body: some View {
        VStack(spacing: 0) {
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

                switch filterMode {
                case .unhandled:
                    let visibleLayers = viewModel.visitLayers.filter { $0.isStoryNode == false }

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

                case .story:
                    let visibleStories = viewModel.storyNodes

                    if visibleStories.isEmpty {
                        VStack(spacing: 20) {
                            Text(emptyStateText)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(visibleStories, id: \.id) { node in
                            StoryNodeRowView(node: node)
                                .padding(.vertical, 6)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .onChange(of: filterMode) { _, newValue in
                if newValue == .story {
                    exitMultiSelect()
                }
            }
            .safeAreaInset(edge: .bottom) {
                if filterMode == .unhandled && isMultiSelectMode {
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
        .onChange(of: selectedClusterId) { _, newValue in
            viewModel.selectedClusterId = newValue
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

    @State private var localSummaryText: String

    init(
        visitLayers: [VisitLayer],
        summaryText: Binding<String>,
        isMerging: Binding<Bool>,
        errorMessage: Binding<String?>,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.visitLayers = visitLayers
        self._summaryText = summaryText
        self._isMerging = isMerging
        self._errorMessage = errorMessage
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self._localSummaryText = State(initialValue: summaryText.wrappedValue)
    }

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

                TextEditor(text: $localSummaryText)
                    .frame(minHeight: 140)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                    // 避免每次输入都向父层回传，导致父视图（包含大 List）频繁刷新而卡顿。
                    // 这里仅在确认时把 localSummaryText 写回 summaryText。


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
                        summaryText = localSummaryText
                        onConfirm()
                    }
                    .disabled(isMerging || localSummaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    @Published var storyNodes: [StoryNode] = []
    @Published var cityName: String?
    
    var selectedClusterId: UUID? {
        didSet {
            applySorting()
        }
    }

    private var clusters: [PlaceCluster]
    private var cancellables = Set<AnyCancellable>()
    private var rawVisitLayers: [VisitLayer] = []

    private let resolveCityNameUseCase = ResolvePlaceClusterCityNameUseCase()

    init(clusters: [PlaceCluster], selectedClusterId: UUID? = nil) {
        self.clusters = clusters
        self.selectedClusterId = selectedClusterId
        observeData()
        resolveCityNameIfNeeded()
    }

    func updateClusters(_ newClusters: [PlaceCluster]) {
        self.clusters = newClusters
        observeData()
        resolveCityNameIfNeeded()
    }

    private func observeData() {
        cancellables.removeAll()
        let clusterIds = clusters.map { $0.id }
        
        // 观察 VisitLayer
        ValueObservation
            .tracking { db in
                try VisitLayer
                    .filter(clusterIds.contains(Column("placeClusterId")))
                    .order(Column("startAt").desc)
                    .fetchAll(db)
            }
            .publisher(in: DatabaseContainer.shared.db.reader)
            .sink { _ in } receiveValue: { [weak self] layers in
                guard let self = self else { return }
                self.rawVisitLayers = layers
                self.applySorting()
            }
            .store(in: &cancellables)

        // 观察 StoryNode
        ValueObservation
            .tracking { db in
                try StoryNode
                    .filter(clusterIds.contains(Column("placeClusterId")))
                    .order(Column("createdAt").desc)
                    .fetchAll(db)
            }
            .publisher(in: DatabaseContainer.shared.db.reader)
            .sink { _ in } receiveValue: { [weak self] nodes in
                self?.storyNodes = nodes
            }
            .store(in: &cancellables)
    }

    private func applySorting() {
        guard let selectedId = selectedClusterId else {
            self.visitLayers = rawVisitLayers
            return
        }
        
        self.visitLayers = rawVisitLayers.sorted { a, b in
            let aIsSelected = a.placeClusterId == selectedId
            let bIsSelected = b.placeClusterId == selectedId
            
            if aIsSelected != bIsSelected {
                return aIsSelected // 选中的排在前面
            }
            
            return a.startAt > b.startAt // 相同优先级按时间倒序
        }
    }

    private func resolveCityNameIfNeeded() {
        guard cityName == nil else { return }
        Task {
            let name = await resolveCityNameUseCase.run(clusters: clusters)
            await MainActor.run {
                self.cityName = name
            }
        }
    }
}

private struct StoryNodeRowView: View {
    let node: StoryNode

    @State private var timeRangeText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let timeRangeText {
                Text(timeRangeText)
                    .font(.headline)
            }

            HStack(alignment: .top, spacing: 10) {
                ThumbnailView(localIdentifier: node.coverPhotoId, size: CGSize(width: 72, height: 72))

                VStack(alignment: .leading, spacing: 6) {
                    if let title = node.mainTitle, !title.isEmpty {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                    }

                    if let summary = node.mainSummary, !summary.isEmpty {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    } else {
                        Text("(无摘要)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .task(id: node.id) {
            await loadTimeRange()
        }
    }

    private func loadTimeRange() async {
        do {
            let (minStart, maxEnd): (Date?, Date?) = try await DatabaseContainer.shared.db.reader.read { db in
                let ids = node.subVisitLayerIds
                guard !ids.isEmpty else { return (nil, nil) }

                let layers = try VisitLayer
                    .filter(ids.contains(Column("id")))
                    .fetchAll(db)

                return (layers.map(\.startAt).min(), layers.map(\.endAt).max())
            }

            guard let minStart, let maxEnd else { return }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy年MM月dd日 HH:mm"

            let start = formatter.string(from: minStart)

            let calendar = Calendar.current
            if calendar.isDate(minStart, inSameDayAs: maxEnd) {
                formatter.dateFormat = "HH:mm"
            }
            let end = formatter.string(from: maxEnd)

            await MainActor.run {
                self.timeRangeText = "\(start) - \(end)"
            }
        } catch {
            // ignore
        }
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
                    InputAreaView(draftText: $draftText, isSaving: isSaving, onSave: save)
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
        .buttonStyle(.plain)
        .onAppear {
            draftText = layer.userText ?? ""
        }
        .task {
            await loadLocalIdentifiers()
        }
    }

    private struct InputAreaView: View {
        @Binding var draftText: String
        let isSaving: Bool
        let onSave: () -> Void

        var body: some View {
            HStack(spacing: 8) {
                TextField("写一句...", text: $draftText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())

                Button(action: { onSave() }) {
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
