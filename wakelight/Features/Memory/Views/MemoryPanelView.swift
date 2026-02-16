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

    @State private var selectedDetailItem: DetailItem?

    enum DetailItem: Identifiable {
        case unhandled(VisitLayer)
        case story(StoryNode)

        var id: String {
            switch self {
            case .unhandled(let layer): return "unhandled-\(layer.id)"
            case .story(let node): return "story-\(node.id)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Unified Single-line Toolbar
            HStack(alignment: .center) {
                if isMultiSelectMode {
                    Button("取消") {
                        withAnimation {
                            exitMultiSelect()
                        }
                    }
                    .font(.system(size: 15))
                    .frame(width: 60, alignment: .leading)
                } else {
                    Spacer().frame(width: 60)
                }

                Spacer()

                Text(panelTitle)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                if filterMode == .unhandled {
                    if isMultiSelectMode {
                        Button(action: {
                            mergeDraftSummary = ""
                            isPresentingMergeSheet = true
                        }) {
                            Text(selectedVisitLayerIds.count < 2 ? "合并" : "合并 (\(selectedVisitLayerIds.count))")
                                .fontWeight(.bold)
                                .foregroundColor(selectedVisitLayerIds.count < 2 ? .secondary : .blue)
                        }
                        .disabled(selectedVisitLayerIds.count < 2)
                        .frame(width: 60, alignment: .trailing)
                    } else {
                        Button("多选") {
                            withAnimation {
                                isMultiSelectMode = true
                            }
                        }
                        .font(.system(size: 15))
                        .frame(width: 60, alignment: .trailing)
                    }
                } else {
                    Spacer().frame(width: 60)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))

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
                .onTapGesture {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }

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
                        let groupedLayers = Dictionary(grouping: visibleLayers, by: { $0.placeClusterId })
                        let sortedClusterIds = Array(Set(visibleLayers.map { $0.placeClusterId })).sorted { id1, id2 in
                            if id1 == viewModel.selectedClusterId { return true }
                            if id2 == viewModel.selectedClusterId { return false }
                            let time1 = groupedLayers[id1]?.first?.startAt ?? Date.distantPast
                            let time2 = groupedLayers[id2]?.first?.startAt ?? Date.distantPast
                            return time1 > time2
                        }

                        ForEach(sortedClusterIds, id: \.self) { clusterId in
                            Section(header:
                                HStack(spacing: 4) {
                                    Image(systemName: "mappin.and.ellipse")
                                        .font(.system(size: 12, weight: .bold))
                                    Text(viewModel.clusterNames[clusterId] ?? "地点记忆")
                                        .font(.system(size: 14, weight: .bold))
                                }
                                .foregroundColor(.primary)
                                .padding(.vertical, 8)
                            ) {
                                ForEach(groupedLayers[clusterId] ?? [], id: \.id) { layer in
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
                                        },
                                        locationName: viewModel.clusterNames[layer.placeClusterId]
                                    )
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if isMultiSelectMode {
                                            if selectedVisitLayerIds.contains(layer.id) {
                                                selectedVisitLayerIds.remove(layer.id)
                                            } else {
                                                selectedVisitLayerIds.insert(layer.id)
                                            }
                                        } else {
                                            selectedDetailItem = .unhandled(layer)
                                        }
                                    }
                                }
                            }
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
                        let groupedStories = Dictionary(grouping: visibleStories, by: { $0.placeClusterId })
                        let sortedClusterIds = Array(Set(visibleStories.map { $0.placeClusterId })).sorted { id1, id2 in
                            if id1 == viewModel.selectedClusterId { return true }
                            if id2 == viewModel.selectedClusterId { return false }
                            let time1 = groupedStories[id1]?.first?.createdAt ?? Date.distantPast
                            let time2 = groupedStories[id2]?.first?.createdAt ?? Date.distantPast
                            return time1 > time2
                        }

                        ForEach(sortedClusterIds, id: \.self) { clusterId in
                            Section(header:
                                HStack(spacing: 4) {
                                    Image(systemName: "mappin.and.ellipse")
                                        .font(.system(size: 12, weight: .bold))
                                    Text(viewModel.clusterNames[clusterId] ?? "地点记忆")
                                        .font(.system(size: 14, weight: .bold))
                                }
                                .foregroundColor(.primary)
                                .padding(.vertical, 8)
                            ) {
                                ForEach(groupedStories[clusterId] ?? [], id: \.id) { node in
                                    StoryNodeRowView(node: node)
                                        .padding(.vertical, 6)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            selectedDetailItem = .story(node)
                                        }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .onTapGesture {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            .onChange(of: filterMode) { _, newValue in
                if newValue == .story {
                    exitMultiSelect()
                }
            }
            .sheet(item: $selectedDetailItem) { item in
                MemoryPhotoWallSheet(item: item, clusterNames: viewModel.clusterNames)
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

private struct MemoryPhotoWallSheet: View {
    struct PhotoGroup: Identifiable {
        let id: UUID
        let title: String
        let location: String?
        let photoLocalIdentifiers: [String]
    }

    let item: MemoryPanelView.DetailItem
    let clusterNames: [UUID: String]

    @Environment(\.dismiss) private var dismiss

    @State private var summaryTitle: String = ""
    @State private var editText: String = ""
    @State private var photoGroups: [PhotoGroup] = []
    @State private var flattenedPhotos: [String] = []
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?
    @State private var selectedPhotoIndex: Int?

    private let gridColumns: [GridItem] = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(summaryTitle)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.secondary)
                            
                            HStack(alignment: .top, spacing: 8) {
                                TextEditor(text: $editText)
                                    .frame(minHeight: 100)
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.secondary.opacity(0.08))
                                    )
                                
                                Button(action: generateSmartText) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.blue)
                                        .padding(10)
                                        .background(Circle().fill(Color.blue.opacity(0.1)))
                                }
                                .padding(.top, 4)
                            }

                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.footnote)
                                    .foregroundColor(.red)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                        ForEach(photoGroups) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    Image(systemName: "mappin.and.ellipse")
                                        .font(.system(size: 10, weight: .bold))
                                    Text("\(group.location ?? "未知地点") · \(group.title)")
                                        .font(.system(size: 13, weight: .bold))
                                }
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 16)

                                LazyVGrid(columns: gridColumns, spacing: 2) {
                                    ForEach(group.photoLocalIdentifiers, id: \.self) { id in
                                        ThumbnailView(localIdentifier: id, size: CGSize(width: 120, height: 120))
                                            .clipped()
                                            .onTapGesture {
                                                if let globalIdx = flattenedPhotos.firstIndex(of: id) {
                                                    selectedPhotoIndex = globalIdx
                                                }
                                            }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 20)
                    }
                }
            }
            .navigationTitle("照片墙")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: save) {
                        HStack(spacing: 4) {
                            if isSaving {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("保存")
                            }
                        }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.blue))
                    }
                    .disabled(isSaving)
                }
            }
        }
        .task {
            await load()
        }
        .fullScreenCover(item: Binding(get: {
            if let idx = selectedPhotoIndex {
                return PhotoPreviewItem(index: idx)
            }
            return nil
        }, set: { _ in
            selectedPhotoIndex = nil
        })) { preview in
            PhotoPreviewPager(localIdentifiers: flattenedPhotos, startIndex: preview.index)
        }
    }

    private func generateSmartText() {
        let location = photoGroups.first?.location ?? "这里"
        let count = flattenedPhotos.count
        
        var timePrefix = ""
        if let firstGroup = photoGroups.first, let range = firstGroup.title.components(separatedBy: " ").last {
            let hour = Int(range.prefix(2)) ?? 12
            switch hour {
            case 5...11: timePrefix = "清晨的"
            case 12...14: timePrefix = "正午的"
            case 15...18: timePrefix = "傍晚的"
            case 19...23: timePrefix = "深夜的"
            default: timePrefix = "这时候的"
            }
        }
        
        let templates = [
            "\(timePrefix)\(location)，留下了 \(count) 个瞬间。",
            "在这里度过了一段时光，捕捉到了 \(count) 张回忆。",
            "\(location) 的这几个小时，都在这些照片里了。",
            "又是充实的一天，在 \(location) 记录了 \(count) 个故事。"
        ]
        
        withAnimation {
            editText = templates.randomElement() ?? ""
        }
    }

    private func load() async {
        do {
            switch item {
            case .unhandled(let layer):
                editText = layer.userText ?? ""
                summaryTitle = dateRangeText(startAt: layer.startAt, endAt: layer.endAt)
                let photos = try await loadPhotosForVisitLayer(visitLayerId: layer.id)
                let group = PhotoGroup(
                    id: layer.id,
                    title: dateRangeText(startAt: layer.startAt, endAt: layer.endAt),
                    location: clusterNames[layer.placeClusterId],
                    photoLocalIdentifiers: photos
                )
                photoGroups = [group]
                flattenedPhotos = photos

            case .story(let node):
                editText = node.mainSummary ?? ""
                let (minStart, maxEnd) = try await loadTimeRangeForStory(node)
                if let minStart, let maxEnd {
                    summaryTitle = dateRangeText(startAt: minStart, endAt: maxEnd)
                }
                let groups = try await loadGroupsForStory(node)
                photoGroups = groups
                flattenedPhotos = groups.flatMap { $0.photoLocalIdentifiers }
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func loadGroupsForStory(_ node: StoryNode) async throws -> [PhotoGroup] {
        let visitLayerIds = node.subVisitLayerIds
        guard !visitLayerIds.isEmpty else { return [] }

        return try await DatabaseContainer.shared.db.reader.read { db in
            let layers = try VisitLayer
                .filter(visitLayerIds.contains(Column("id")))
                .order(Column("startAt").asc)
                .fetchAll(db)
            
            var groups: [PhotoGroup] = []
            for layer in layers {
                let links = try VisitLayerPhotoAsset
                    .filter(Column("visitLayerId") == layer.id)
                    .fetchAll(db)
                if links.isEmpty { continue }
                let photoIds = links.map { $0.photoAssetId }
                let photos = try PhotoAsset
                    .filter(photoIds.contains(Column("id")))
                    .order(Column("creationDate").asc)
                    .fetchAll(db)
                groups.append(PhotoGroup(
                    id: layer.id,
                    title: dateRangeText(startAt: layer.startAt, endAt: layer.endAt),
                    location: clusterNames[layer.placeClusterId],
                    photoLocalIdentifiers: photos.map { $0.localIdentifier }
                ))
            }
            return groups
        }
    }

    private func save() {
        isSaving = true
        Task {
            do {
                let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                try await DatabaseContainer.shared.writer.write { db in
                    switch item {
                    case .unhandled(let layer):
                        if var current = try VisitLayer.fetchOne(db, key: layer.id) {
                            current.userText = trimmed.isEmpty ? nil : trimmed
                            try current.update(db)
                        }
                    case .story(let node):
                        if var current = try StoryNode.fetchOne(db, key: node.id) {
                            current.mainSummary = trimmed.isEmpty ? nil : trimmed
                            current.updatedAt = Date()
                            try current.update(db)
                        }
                    }
                }
                await MainActor.run {
                    isSaving = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = String(describing: error)
                }
            }
        }
    }

    private func loadPhotosForVisitLayer(visitLayerId: UUID) async throws -> [String] {
        try await DatabaseContainer.shared.db.reader.read { db in
            let links = try VisitLayerPhotoAsset
                .filter(Column("visitLayerId") == visitLayerId)
                .fetchAll(db)
            let photoIds = links.map { $0.photoAssetId }
            let photos = try PhotoAsset
                .filter(photoIds.contains(Column("id")))
                .order(Column("creationDate").asc)
                .fetchAll(db)
            return photos.map { $0.localIdentifier }
        }
    }

    private func loadTimeRangeForStory(_ node: StoryNode) async throws -> (Date?, Date?) {
        let ids = node.subVisitLayerIds
        return try await DatabaseContainer.shared.db.reader.read { db in
            let layers = try VisitLayer.filter(ids.contains(Column("id"))).fetchAll(db)
            return (layers.map(\.startAt).min(), layers.map(\.endAt).max())
        }
    }

    private func dateRangeText(startAt: Date, endAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年MM月dd日 HH:mm"
        let start = formatter.string(from: startAt)
        if Calendar.current.isDate(startAt, inSameDayAs: endAt) {
            formatter.dateFormat = "HH:mm"
        }
        return "\(start) - \(formatter.string(from: endAt))"
    }

    private struct PhotoPreviewItem: Identifiable {
        let index: Int
        var id: Int { index }
    }
}

private struct PhotoPreviewPager: View {
    let localIdentifiers: [String]
    let startIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int

    init(localIdentifiers: [String], startIndex: Int) {
        self.localIdentifiers = localIdentifiers
        self.startIndex = startIndex
        _selection = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TabView(selection: $selection) {
                ForEach(Array(localIdentifiers.enumerated()), id: \.offset) { idx, id in
                    VStack {
                        Spacer()
                        ThumbnailView(localIdentifier: id, size: CGSize(width: 340, height: 340))
                            .scaledToFit()
                        Spacer()
                    }
                    .tag(idx)
                    .background(Color.black)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(16)
            }
        }
        .background(Color.black)
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

    init(visitLayers: [VisitLayer], summaryText: Binding<String>, isMerging: Binding<Bool>, errorMessage: Binding<String?>, onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
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
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("将 \(visitLayers.count) 个记忆合并为故事")
                        .font(.title3.weight(.bold))
                    if let rangeText = timeRangeText(visitLayers) {
                        Text(rangeText)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 10)

                VStack(alignment: .leading, spacing: 10) {
                    Text("故事摘要")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)

                    TextEditor(text: $localSummaryText)
                        .frame(minHeight: 120)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.secondary.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                        )
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .padding(.horizontal, 4)
                }

                Spacer()

                Button(action: {
                    summaryText = localSummaryText
                    onConfirm()
                }) {
                    HStack {
                        if isMerging {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Text("确认合并")
                        }
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Capsule()
                            .fill(localSummaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isMerging ? Color.blue.opacity(0.5) : Color.blue)
                    )
                }
                .disabled(isMerging || localSummaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.bottom, 10)
            }
            .padding(24)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { onCancel() }
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

extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

@MainActor
final class MemoryPanelViewModel: ObservableObject {
    @Published var visitLayers: [VisitLayer] = []
    @Published var storyNodes: [StoryNode] = []
    @Published var cityName: String?
    @Published var clusterNames: [UUID: String] = [:]
    var selectedClusterId: UUID? { didSet { applySorting() } }
    private var clusters: [PlaceCluster]
    private var cancellables = Set<AnyCancellable>()
    private var rawVisitLayers: [VisitLayer] = []
    private let resolveCityNameUseCase = ResolvePlaceClusterCityNameUseCase()

    init(clusters: [PlaceCluster], selectedClusterId: UUID? = nil) {
        self.clusters = clusters
        self.selectedClusterId = selectedClusterId
        observeData()
        resolveCityNameIfNeeded()
        resolveClusterNames()
    }

    func updateClusters(_ newClusters: [PlaceCluster]) {
        self.clusters = newClusters
        observeData()
        resolveCityNameIfNeeded()
        resolveClusterNames()
    }

    private func resolveClusterNames() {
        for cluster in clusters {
            Task {
                if let name = try? await resolveCityNameUseCase.resolveDetailedAddress(for: cluster) {
                    await MainActor.run { self.clusterNames[cluster.id] = name }
                }
            }
        }
    }

    private func observeData() {
        cancellables.removeAll()
        let clusterIds = clusters.map { $0.id }
        ValueObservation.tracking { db in
            try VisitLayer.filter(clusterIds.contains(Column("placeClusterId"))).order(Column("startAt").desc).fetchAll(db)
        }.publisher(in: DatabaseContainer.shared.db.reader).sink { _ in } receiveValue: { [weak self] layers in
            self?.rawVisitLayers = layers
            self?.applySorting()
        }.store(in: &cancellables)
        ValueObservation.tracking { db in
            try StoryNode.filter(clusterIds.contains(Column("placeClusterId"))).order(Column("createdAt").desc).fetchAll(db)
        }.publisher(in: DatabaseContainer.shared.db.reader).sink { _ in } receiveValue: { [weak self] nodes in
            self?.storyNodes = nodes
        }.store(in: &cancellables)
    }

    private func applySorting() {
        guard let selectedId = selectedClusterId else {
            self.visitLayers = rawVisitLayers
            return
        }
        self.visitLayers = rawVisitLayers.sorted { a, b in
            let aSel = a.placeClusterId == selectedId
            let bSel = b.placeClusterId == selectedId
            if aSel != bSel { return aSel }
            return a.startAt > b.startAt
        }
    }

    private func resolveCityNameIfNeeded() {
        guard cityName == nil, let first = clusters.first else { return }
        Task {
            let name = try? await resolveCityNameUseCase.resolveCityName(for: first)
            await MainActor.run { self.cityName = name }
        }
    }
}

private struct StoryNodeRowView: View {
    let node: StoryNode
    @State private var timeRangeText: String?
    @State private var coverLocalIdentifiers: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let timeRangeText {
                Text(timeRangeText).font(.subheadline.weight(.medium)).foregroundColor(.secondary)
            }
            if !coverLocalIdentifiers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(coverLocalIdentifiers, id: \.self) { id in
                            ThumbnailView(localIdentifier: id, size: CGSize(width: 80, height: 80)).clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            } else {
                ThumbnailView(localIdentifier: node.coverPhotoId, size: CGSize(width: 80, height: 80)).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if let summary = node.mainSummary, !summary.isEmpty {
                Text(summary).font(.subheadline).foregroundColor(.secondary).lineLimit(3)
            }
        }
        .task(id: node.id) {
            await loadTimeRange()
            await loadCoverLocalIdentifiers()
        }
    }

    private func loadCoverLocalIdentifiers() async {
        do {
            let ids: [String] = try await DatabaseContainer.shared.db.reader.read { db in
                let visitLayerIds = node.subVisitLayerIds
                guard !visitLayerIds.isEmpty else { return [] }
                let links = try VisitLayerPhotoAsset.filter(visitLayerIds.contains(Column("visitLayerId"))).fetchAll(db)
                if links.isEmpty { return [] }
                let photoIds = Array(Set(links.map { $0.photoAssetId }))
                let photos = try PhotoAsset.filter(photoIds.contains(Column("id"))).fetchAll(db)
                return photos.map { $0.localIdentifier }
            }
            await MainActor.run { self.coverLocalIdentifiers = Array(ids.prefix(12)) }
        } catch {}
    }

    private func loadTimeRange() async {
        do {
            let (minStart, maxEnd): (Date?, Date?) = try await DatabaseContainer.shared.db.reader.read { db in
                let ids = node.subVisitLayerIds
                guard !ids.isEmpty else { return (nil, nil) }
                let layers = try VisitLayer.filter(ids.contains(Column("id"))).fetchAll(db)
                return (layers.map(\.startAt).min(), layers.map(\.endAt).max())
            }
            guard let minStart, let maxEnd else { return }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy年MM月dd日 HH:mm"
            let start = formatter.string(from: minStart)
            if Calendar.current.isDate(minStart, inSameDayAs: maxEnd) { formatter.dateFormat = "HH:mm" }
            await MainActor.run { self.timeRangeText = "\(start) - \(formatter.string(from: maxEnd))" }
        } catch {}
    }
}

private struct VisitLayerRowView: View {
    let layer: VisitLayer
    let isMultiSelectMode: Bool
    let isSelected: Bool
    let onToggleSelected: () -> Void
    let onLongPressSelect: () -> Void
    let locationName: String?

    @State private var localIdentifiers: [String] = []
    @State private var draftText: String = ""
    @State private var isSaving: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isMultiSelectMode {
                Button(action: onToggleSelected) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle").font(.system(size: 22, weight: .semibold)).foregroundColor(isSelected ? .blue : .secondary).padding(.top, 2)
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(dateRangeText(layer)).font(.subheadline.weight(.medium)).foregroundColor(.secondary)
                if !localIdentifiers.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(localIdentifiers, id: \.self) { id in
                                ThumbnailView(localIdentifier: id, size: CGSize(width: 80, height: 80)).clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
                if let text = layer.userText, !text.isEmpty {
                    Text(text).font(.subheadline).foregroundColor(.primary)
                } else if !isMultiSelectMode {
                    InputAreaView(draftText: $draftText, isSaving: isSaving, onSave: save, onSmartFill: generateAIText)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if isMultiSelectMode { onToggleSelected() } }
        .onLongPressGesture(minimumDuration: 0.35) { onLongPressSelect() }
        .buttonStyle(.plain)
        .onAppear { draftText = layer.userText ?? "" }
        .task { await loadLocalIdentifiers() }
    }

    private func generateAIText() {
        let loc = locationName ?? "这里"
        let count = localIdentifiers.count
        let hour = Calendar.current.component(.hour, from: layer.startAt)
        var timePrefix = ""
        switch hour {
        case 5...11: timePrefix = "清晨的"
        case 12...14: timePrefix = "正午的"
        case 15...18: timePrefix = "傍晚的"
        case 19...23: timePrefix = "深夜的"
        default: timePrefix = "这时候的"
        }
        let templates = ["\(timePrefix)\(loc)，留下了 \(count) 个瞬间。", "在这里捕捉到了 \(count) 张回忆。", "\(loc) 的这段时光都在这里了。"]
        withAnimation { draftText = templates.randomElement() ?? "" }
    }

    private struct InputAreaView: View {
        @Binding var draftText: String
        let isSaving: Bool
        let onSave: () -> Void
        let onSmartFill: () -> Void

        var body: some View {
            VStack(alignment: .trailing, spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("记录此刻的想法...", text: $draftText, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.secondary.opacity(0.1))
                        )
                    
                    Button(action: onSmartFill) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.blue)
                            .padding(8)
                            .background(Circle().fill(Color.blue.opacity(0.1)))
                    }
                }
                
                Button(action: onSave) {
                    HStack(spacing: 4) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "plus.circle.fill")
                            Text("加入故事")
                        }
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(draftText.isEmpty ? Color.gray.opacity(0.5) : Color.blue)
                    )
                }
                .disabled(isSaving || draftText.isEmpty)
            }
            .padding(4)
        }
    }

    private func loadLocalIdentifiers() async {
        do {
            let ids: [String] = try await DatabaseContainer.shared.db.reader.read { db in
                let links = try VisitLayerPhotoAsset.filter(Column("visitLayerId") == layer.id).fetchAll(db)
                if links.isEmpty { return [] }
                let photoIds = links.map { $0.photoAssetId }
                let photos = try PhotoAsset.filter(photoIds.contains(Column("id"))).fetchAll(db)
                return photos.map { $0.localIdentifier }
            }
            await MainActor.run { self.localIdentifiers = ids }
        } catch {}
    }

    private func save() {
        isSaving = true
        Task {
            do {
                try await SettleStoryNodeUseCase().run(visitLayerId: layer.id, text: draftText)
                await MainActor.run { isSaving = false }
            } catch { await MainActor.run { isSaving = false } }
        }
    }

    private func dateRangeText(_ layer: VisitLayer) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年MM月dd日 HH:mm"
        let start = formatter.string(from: layer.startAt)
        if Calendar.current.isDate(layer.startAt, inSameDayAs: layer.endAt) { formatter.dateFormat = "HH:mm" }
        return "\(start) - \(formatter.string(from: layer.endAt))"
    }
}
