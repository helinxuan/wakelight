import SwiftUI
import Combine
import GRDB
import UIKit
import CoreLocation

struct MemoryPanelView: View {
    private struct PreviewItem: Identifiable {
        let index: Int
        var id: Int { index }
    }

    let clusters: [PlaceCluster]
    let selectedClusterId: UUID?
    let onHeaderDragChanged: ((DragGesture.Value) -> Void)?
    let onHeaderDragEnded: ((DragGesture.Value) -> Void)?

    @StateObject private var viewModel: MemoryPanelViewModel

    @State private var previewLocatorKeys: [String] = []
    @State private var previewStartIndex: Int? = nil

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
    @State private var isLocationSectionCollapsed: [UUID: Bool] = [:]

    private func exitMultiSelect() {
        isMultiSelectMode = false
        selectedVisitLayerIds.removeAll()
        editingStoryTarget = nil
        appendErrorMessage = nil
    }

    @State private var isMultiSelectMode: Bool = false
    @State private var selectedVisitLayerIds: Set<UUID> = []

    @State private var isPresentingMergeSheet: Bool = false
    @State private var mergeDraftSummary: String = ""
    @State private var isMerging: Bool = false
    @State private var mergeErrorMessage: String?
    @State private var editingStoryTarget: StoryNode?
    @State private var appendErrorMessage: String?
    @State private var isPresentingDeleteStoryAlert: Bool = false
    @State private var deletingStoryTarget: StoryNode?
    @State private var isDeletingStory: Bool = false

    init(
        clusters: [PlaceCluster],
        selectedClusterId: UUID? = nil,
        onHeaderDragChanged: ((DragGesture.Value) -> Void)? = nil,
        onHeaderDragEnded: ((DragGesture.Value) -> Void)? = nil
    ) {
        self.clusters = clusters
        self.selectedClusterId = selectedClusterId
        self.onHeaderDragChanged = onHeaderDragChanged
        self.onHeaderDragEnded = onHeaderDragEnded
        _viewModel = StateObject(wrappedValue: MemoryPanelViewModel(clusters: clusters, selectedClusterId: selectedClusterId))
    }

    @State private var selectedDetailItem: MemoryDetailItem?

    var body: some View {
        VStack(spacing: 0) {
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
                    if let target = editingStoryTarget {
                        Button(action: {
                            Task {
                                await appendSelectedLayersToStory(target)
                            }
                        }) {
                            Text(selectedVisitLayerIds.isEmpty ? "加入" : "加入 (\(selectedVisitLayerIds.count))")
                                .fontWeight(.bold)
                                .foregroundColor(selectedVisitLayerIds.isEmpty ? .secondary : .blue)
                        }
                        .disabled(selectedVisitLayerIds.isEmpty)
                        .frame(width: 80, alignment: .trailing)
                    } else if isMultiSelectMode {
                        Button(action: {
                            mergeDraftSummary = ""
                            isPresentingMergeSheet = true
                        }) {
                            Text(selectedVisitLayerIds.count < 2 ? "合并" : "合并 (\(selectedVisitLayerIds.count))")
                                .fontWeight(.bold)
                                .foregroundColor(selectedVisitLayerIds.count < 2 ? .secondary : .blue)
                        }
                        .disabled(selectedVisitLayerIds.count < 2)
                        .frame(width: 80, alignment: .trailing)
                    } else {
                        Button("多选") {
                            withAnimation {
                                isMultiSelectMode = true
                            }
                        }
                        .font(.system(size: 15))
                        .frame(width: 80, alignment: .trailing)
                    }
                } else {
                    Spacer().frame(width: 80)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .background(Color(.systemBackground))
            .highPriorityGesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { value in onHeaderDragChanged?(value) }
                    .onEnded { value in onHeaderDragEnded?(value) }
            )

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

                if let target = editingStoryTarget, filterMode == .unhandled {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("正在为当前故事添加片段")
                                .font(.subheadline.weight(.semibold))
                            if let summary = target.mainSummary, !summary.isEmpty {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            if let appendErrorMessage {
                                Text(appendErrorMessage)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                        .padding(.vertical, 4)
                    }
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
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        toggleLocationSection(clusterId)
                                    }
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "mappin.and.ellipse")
                                            .font(.system(size: 12, weight: .bold))
                                        Text(viewModel.clusterNames[clusterId] ?? "地点记忆")
                                            .font(.system(size: 14, weight: .bold))

                                        Spacer(minLength: 0)

                                        Image(systemName: isLocationSectionCollapsed[clusterId] == true ? "chevron.right" : "chevron.down")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .foregroundColor(.primary)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                            ) {
                                if isLocationSectionCollapsed[clusterId] != true {
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
                                            locationName: viewModel.clusterNames[layer.placeClusterId],
                                            onPreview: { keys, index in
                                                previewLocatorKeys = keys
                                                previewStartIndex = index
                                            }
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
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        toggleLocationSection(clusterId)
                                    }
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "mappin.and.ellipse")
                                            .font(.system(size: 12, weight: .bold))
                                        Text(viewModel.clusterNames[clusterId] ?? "地点记忆")
                                            .font(.system(size: 14, weight: .bold))

                                        Spacer(minLength: 0)

                                        Image(systemName: isLocationSectionCollapsed[clusterId] == true ? "chevron.right" : "chevron.down")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .foregroundColor(.primary)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                            ) {
                                if isLocationSectionCollapsed[clusterId] != true {
                                    ForEach(groupedStories[clusterId] ?? [], id: \.id) { node in
                                        StoryNodeRowView(
                                            node: node,
                                            onPreview: { keys, index in
                                                previewLocatorKeys = keys
                                                previewStartIndex = index
                                            },
                                            onEdit: {
                                                selectedDetailItem = .story(node)
                                            },
                                            onDelete: {
                                                deletingStoryTarget = node
                                                isPresentingDeleteStoryAlert = true
                                            }
                                        )
                                        .padding(.vertical, 6)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            selectedDetailItem = .story(node)
                                        }
                                        .contextMenu {
                                            Button {
                                                selectedDetailItem = .story(node)
                                            } label: {
                                                Label("编辑故事", systemImage: "pencil")
                                            }

                                            Button(role: .destructive) {
                                                deletingStoryTarget = node
                                                isPresentingDeleteStoryAlert = true
                                            } label: {
                                                Label("删除故事", systemImage: "trash")
                                            }
                                        }
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            Button {
                                                selectedDetailItem = .story(node)
                                            } label: {
                                                Label("编辑", systemImage: "pencil")
                                            }
                                            .tint(.blue)

                                            Button(role: .destructive) {
                                                deletingStoryTarget = node
                                                isPresentingDeleteStoryAlert = true
                                            } label: {
                                                Label("删除", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .onChange(of: filterMode) { _, newValue in
                if newValue == .story {
                    exitMultiSelect()
                }
                if newValue == .unhandled, editingStoryTarget != nil {
                    isMultiSelectMode = true
                }
            }
            .sheet(item: $selectedDetailItem) { item in
                NavigationStack {
                    MemoryDetailSheet(
                        item: item,
                        clusterNames: viewModel.clusterNames,
                        onRequestAddFromUnhandled: { story in
                            editingStoryTarget = story
                            filterMode = .unhandled
                            isMultiSelectMode = true
                            selectedVisitLayerIds.removeAll()
                            appendErrorMessage = nil
                        }
                    )
                }
            }
            .fullScreenCover(item: Binding(get: {
                if let idx = previewStartIndex {
                    return PreviewItem(index: idx)
                }
                return nil
            }, set: { _ in
                previewStartIndex = nil
            })) { preview in
                PhotoPreviewPager(locatorKeys: previewLocatorKeys, startIndex: preview.index)
            }
        }
        .background(Color(.systemBackground))
        .alert("删除故事", isPresented: $isPresentingDeleteStoryAlert, presenting: deletingStoryTarget) { story in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task {
                    await deleteStory(story)
                }
            }
            .disabled(isDeletingStory)
        } message: { _ in
            Text("删除后会把该故事中的片段恢复为“未加入故事”，此操作不可撤销。")
        }
        .sheet(isPresented: $isPresentingMergeSheet) {
            MergeVisitLayersSheet(
                visitLayers: viewModel.visitLayers.filter { selectedVisitLayerIds.contains($0.id) },
                clusterNames: viewModel.clusterNames,
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

    private func toggleLocationSection(_ clusterId: UUID) {
        let isCollapsed = isLocationSectionCollapsed[clusterId] ?? false
        isLocationSectionCollapsed[clusterId] = !isCollapsed
    }

    private func appendSelectedLayersToStory(_ story: StoryNode) async {
        guard !selectedVisitLayerIds.isEmpty else { return }

        do {
            try await AppendVisitLayersToStoryUseCase().run(
                storyNodeId: story.id,
                visitLayerIds: Array(selectedVisitLayerIds)
            )

            let refreshedStory = try await DatabaseContainer.shared.db.reader.read { db in
                try StoryNode.fetchOne(db, key: story.id)
            }

            await MainActor.run {
                selectedVisitLayerIds.removeAll()
                isMultiSelectMode = false
                editingStoryTarget = nil
                appendErrorMessage = nil
                filterMode = .story
                if let refreshedStory {
                    selectedDetailItem = .story(refreshedStory)
                } else {
                    selectedDetailItem = .story(story)
                }
            }
        } catch {
            await MainActor.run {
                appendErrorMessage = "加入失败，请重试"
            }
        }
    }

    private func deleteStory(_ story: StoryNode) async {
        guard !isDeletingStory else { return }

        await MainActor.run {
            isDeletingStory = true
        }

        do {
            try await DeleteStoryNodeUseCase().run(storyNodeId: story.id)
            await MainActor.run {
                if case .story(let current)? = selectedDetailItem, current.id == story.id {
                    selectedDetailItem = nil
                }

                // 删除故事后统一退出“为故事添加片段”状态，避免回到未加入故事时文案残留
                editingStoryTarget = nil
                selectedVisitLayerIds.removeAll()
                isMultiSelectMode = false
                appendErrorMessage = nil
                filterMode = .unhandled

                deletingStoryTarget = nil
                isDeletingStory = false
            }
        } catch {
            await MainActor.run {
                deletingStoryTarget = nil
                isDeletingStory = false
            }
        }
    }
}

private struct MergeVisitLayersSheet: View {
    private static let aiThumbnailSize = CGSize(width: 512, height: 512)

    let visitLayers: [VisitLayer]
    let clusterNames: [UUID: String]
    @Binding var summaryText: String
    @Binding var isMerging: Bool
    @Binding var errorMessage: String?
    @State private var isGeneratingAI: Bool = false
    @State private var hasTriggeredInitialAI: Bool = false
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @State private var localSummaryText: String

    init(
        visitLayers: [VisitLayer],
        clusterNames: [UUID: String],
        summaryText: Binding<String>,
        isMerging: Binding<Bool>,
        errorMessage: Binding<String?>,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.visitLayers = visitLayers
        self.clusterNames = clusterNames
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
                    HStack {
                        Text("故事摘要")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.secondary)
                            .padding(.leading, 4)

                        Spacer()

                        Button(action: {
                            generateAIText(showSkeleton: true)
                        }) {
                            HStack(spacing: 4) {
                                if isGeneratingAI {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Image(systemName: "sparkles")
                                }
                                Text(isGeneratingAI ? "生成中" : "AI 润色")
                            }
                            .font(.caption.weight(.bold))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.blue.opacity(0.1)))
                        }
                        .disabled(isGeneratingAI)
                    }

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $localSummaryText)
                            .frame(minHeight: 120)
                            .padding(12)
                            .opacity(isGeneratingAI ? 0.65 : 1)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color.secondary.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                            )

                        if isGeneratingAI, localSummaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.secondary.opacity(0.18))
                                    .frame(height: 12)
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.secondary.opacity(0.16))
                                    .frame(height: 12)
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.secondary.opacity(0.12))
                                    .frame(width: 180, height: 12)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 22)
                            .redacted(reason: .placeholder)
                            .allowsHitTesting(false)
                        }
                    }
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
            .task {
                guard !hasTriggeredInitialAI else { return }
                hasTriggeredInitialAI = true

                if localSummaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    generateAIText(showSkeleton: true)
                }
            }
        }
    }

    private func generateAIText(showSkeleton: Bool = false) {
        guard !visitLayers.isEmpty, !isGeneratingAI else { return }

        if showSkeleton {
            withAnimation(.easeOut(duration: 0.15)) {
                localSummaryText = ""
            }
        }
        isGeneratingAI = true

        Task {
            AITextEngine.shared.setProvider(.doubao)

            let allLocators: [PhotoAssetLocator] = (try? await DatabaseContainer.shared.db.reader.read { db in
                let layerIds = visitLayers.map { $0.id }
                let links = try VisitLayerPhotoAsset.filter(layerIds.contains(Column("visitLayerId"))).fetchAll(db)
                if links.isEmpty { return [PhotoAssetLocator]() }
                let photoIds = Array(Set(links.map { $0.photoAssetId }))
                return try PhotoAsset.fetchLocators(db: db, ids: photoIds)
            }) ?? []

            // let analysis = await VisionImageAnalysisService.shared.analyzePhotos(locators: allLocators, maxPhotos: 15)
            // let prefilteredKeywords = analysis.sanitizedKeywords
            // let aiFilteredKeywords = await AITextEngine.shared.filterVisionKeywords(
            //     rawKeywords: prefilteredKeywords,
            //     cacheKey: "merge_diary_keywords_\(visitLayers.first?.id.uuidString ?? "")_\(visitLayers.count)_\(allLocators.count)"
            // )
            // let promptKeywords = aiFilteredKeywords.isEmpty ? prefilteredKeywords : aiFilteredKeywords
            // let keywords = promptKeywords.joined(separator: "、")

            let count = allLocators.count
            let timeRange = timeRangeText(visitLayers) ?? ""
            let uniquePlaces = Array(Set(visitLayers.map { $0.placeClusterId }))
            let placeNames = uniquePlaces.compactMap { clusterNames[$0] }.filter { !$0.isEmpty }
            let loc = placeNames.isEmpty ? "这里" : placeNames.prefix(4).joined(separator: "、")

            // let photoContentLine: String = {
            //     if keywords.isEmpty {
            //         return "照片内容：未提取到稳定主题（请侧重地点与时间氛围，不要硬编照片细节）"
            //     }
            //     return "照片内容：\(keywords)"
            // }()

            let systemPrompt = """
            你是回忆卡片的日记文案助手。
            你的任务：根据地点、时间氛围、照片内容，写一段像用户本人记录的简短回忆。
            要求：
            - 字数控制在40-60字。
            - 判断时间如果在节假日，就结合节假日来写。
            - 如果在名胜古迹等景点附近，那么可以结合景点来写。
            - 如果场景内容，地点合适，可以结合一句诗词来写，不合适不用硬加。
            - 文风像个人日记，语气自然。
            - 先介绍一段地点或者景点信息。
            - 只根据提供的信息写，不要编造不存在的细节。
            - 不要几张照片之类的描述。
            - 不要编造人物行为或事件。
            - 不要根据照片关键词推测具体场景（如工地、餐厅、商店等），只描述可见环境或整体氛围。
            - 不要逐个描述照片中的物品或人物类别，只描述整体场景或整体氛围。
            """


            let userPrompt = """
            这是用户回忆卡片的一段日记。
            地点：\(loc)
            时间：\(timeRange ?? "")
            直接输出正文，不需要加任何非正文的解释性文字来影响观感，输出格式要标准，每段段落前加tab
            """

            var imageInputs: [AITextImage] = []
            for locator in allLocators.prefix(6) {
                if let thumbnail = await PhotoThumbnailLoader.shared.loadThumbnailWithDiskCache(
                    locatorKey: locator.locatorKey,
                    size: Self.aiThumbnailSize
                ),
                let dataURL = thumbnail.toAIDataURL() {
                    imageInputs.append(dataURL)
                }
            }

            let request = AITextRequest(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                images: imageInputs,
                cacheKey: "merge_diary_\(visitLayers.first?.id.uuidString ?? "")_\(visitLayers.count)",
                fallbackText: "\(timeRange)，留下了 \(count) 个瞬间。",
                temperature: 0.35,
                topP: 0.85,
                maxTokens: 140
            )

            let text = await AITextEngine.shared.generateText(for: request)
            await MainActor.run {
                withAnimation {
                    self.localSummaryText = text
                    self.isGeneratingAI = false
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
                if let name = try? await resolveCityNameUseCase.resolveDisplayLocation(for: cluster) {
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
        guard let first = clusters.first else { return }

        if let cityName, !cityName.isEmpty, !looksLikeRoadName(cityName) {
            return
        }

        Task {
            let name = try? await resolveCityNameUseCase.resolveCityName(for: first)
            await MainActor.run {
                if let name, !name.isEmpty, !self.looksLikeRoadName(name) {
                    self.cityName = name
                } else {
                    self.cityName = nil
                }
            }
        }
    }

    private func looksLikeRoadName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        let latinRoadMarkers = [" street", " st", " road", " rd", " avenue", " ave", " lane", " ln", " drive", " dr", " boulevard", " blvd", " strasse", " straße", "gata", "weg"]
        let hasLatinRoadMarker = latinRoadMarkers.contains { lowercased.contains($0) }

        let zhRoadMarkers = ["路", "街", "巷", "道", "大道", "胡同", "弄", "段"]
        let hasZhRoadMarker = zhRoadMarkers.contains { trimmed.contains($0) }

        return hasZhRoadMarker || hasLatinRoadMarker
    }
}

private struct StoryNodeRowView: View {
    private static let aiThumbnailSize = CGSize(width: 512, height: 512)

    let node: StoryNode
    let onPreview: ([String], Int) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var timeRangeText: String?

    private struct StoryThumbnail: Identifiable {
        let locatorKey: String
        let hasRaw: Bool
        let hasLive: Bool
        var id: String { locatorKey }
    }

    @State private var thumbnails: [StoryThumbnail] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                if let timeRangeText {
                    Text(timeRangeText)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    Button(action: onEdit) {
                        Label("编辑", systemImage: "pencil")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)

                    Button(action: onDelete) {
                        Label("删除", systemImage: "trash")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !thumbnails.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(thumbnails.enumerated()), id: \.element.id) { idx, thumb in
                            ThumbnailView(locatorKey: thumb.locatorKey, size: CGSize(width: 80, height: 80), showRawBadge: thumb.hasRaw, showLiveBadge: thumb.hasLive)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .onTapGesture {
                                    onPreview(thumbnails.map { $0.locatorKey }, idx)
                                }
                        }
                    }
                }
            } else {
                ThumbnailView(locatorKey: node.coverPhotoId, size: CGSize(width: 80, height: 80))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture {
                        onPreview([node.coverPhotoId], 0)
                    }
            }
            if let summary = node.mainSummary, !summary.isEmpty {
                Text(summary).font(.subheadline).foregroundColor(.secondary).lineLimit(3)
            }
        }
        .task(id: node.id) {
            await loadTimeRange()

            do {
                for try await locators in ValueObservation
                    .tracking({ db in
                        let visitLayerIds = node.subVisitLayerIds
                        guard !visitLayerIds.isEmpty else { return [PhotoAssetLocator]() }
                        let links = try VisitLayerPhotoAsset.filter(visitLayerIds.contains(Column("visitLayerId"))).fetchAll(db)
                        if links.isEmpty { return [] }
                        let photoIds = Array(Set(links.map { $0.photoAssetId }))
                        return try PhotoAsset.fetchLocators(db: db, ids: photoIds)
                    })
                    .values(in: DatabaseContainer.shared.db.reader) {
                    self.thumbnails = Array(locators.prefix(12)).map { StoryThumbnail(locatorKey: $0.locatorKey, hasRaw: $0.hasRaw, hasLive: $0.hasLive) }
                }
            } catch {
            }
        }
        .contextMenu {
            Button {
                onEdit()
            } label: {
                Label("编辑故事", systemImage: "pencil")
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除故事", systemImage: "trash")
            }
        }
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
    private static let aiThumbnailSize = CGSize(width: 512, height: 512)

    let layer: VisitLayer
    let isMultiSelectMode: Bool
    let isSelected: Bool
    let onToggleSelected: () -> Void
    let onLongPressSelect: () -> Void
    let locationName: String?
    let onPreview: ([String], Int) -> Void

    private struct VisitLayerThumbnail: Identifiable {
        let locatorKey: String
        let hasRaw: Bool
        let hasLive: Bool
        var id: String { locatorKey }
    }

    @State private var thumbnails: [VisitLayerThumbnail] = []
    @State private var draftText: String = ""
    @State private var isSaving: Bool = false
    @State private var isGeneratingAI: Bool = false

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
                if !thumbnails.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(thumbnails.enumerated()), id: \.element.id) { idx, thumb in
                                ThumbnailView(locatorKey: thumb.locatorKey, size: CGSize(width: 80, height: 80), showRawBadge: thumb.hasRaw, showLiveBadge: thumb.hasLive)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .onTapGesture {
                                        onPreview(thumbnails.map { $0.locatorKey }, idx)
                                    }
                            }
                        }
                    }
                }
                if let text = layer.userText, !text.isEmpty {
                    Text(text).font(.subheadline).foregroundColor(.primary)
                } else if !isMultiSelectMode {
                    InputAreaView(
                        draftText: $draftText,
                        isSaving: isSaving,
                        isGeneratingAI: isGeneratingAI,
                        onSave: save,
                        onSmartFill: generateAIText
                    )
                    .opacity(isGeneratingAI ? 0.85 : 1)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if isMultiSelectMode { onToggleSelected() } }
        .onLongPressGesture(minimumDuration: 0.35) { onLongPressSelect() }
        .buttonStyle(.plain)
        .onAppear { draftText = layer.userText ?? "" }
        .task {
            do {
                for try await locators in ValueObservation
                    .tracking({ db in
                        let links = try VisitLayerPhotoAsset.filter(Column("visitLayerId") == layer.id).fetchAll(db)
                        if links.isEmpty { return [PhotoAssetLocator]() }
                        let photoIds = links.map { $0.photoAssetId }
                        return try PhotoAsset.fetchLocators(db: db, ids: photoIds)
                    })
                    .values(in: DatabaseContainer.shared.db.reader) {
                    self.thumbnails = locators.map { VisitLayerThumbnail(locatorKey: $0.locatorKey, hasRaw: $0.hasRaw, hasLive: $0.hasLive) }
                }
            } catch {
            }
        }
    }

    private func generateAIText() {
        guard !isGeneratingAI else { return }

        let loc = locationName ?? "这里"
        let count = thumbnails.count
        let hour = Calendar.current.component(.hour, from: layer.startAt)
        let timeText: String = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy年MM月dd日 HH:mm"
            return formatter.string(from: layer.startAt)
        }()

        let fallback = "\(timeText) 在\(loc)，留下了 \(count) 个瞬间。"

        let placeIdPart = layer.placeClusterId.uuidString
        let date = layer.startAt
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour], from: date)
        let bucketId = String(format: "%04d-%02d-%02d-%02d",
                              components.year ?? 0,
                              components.month ?? 0,
                              components.day ?? 0,
                              components.hour ?? 0)
        let cacheKey = "diary:\(placeIdPart):\(bucketId)"

        let systemPrompt = """
        你是回忆卡片的日记文案助手。
        你的任务：根据地点、时间氛围、照片内容，写一段像用户本人记录的简短回忆。
        要求：
        - 字数控制在40-60字。
        - 判断时间如果在节假日，就结合节假日来写。
        - 如果在名胜古迹等景点附近，那么可以结合景点来写。
        - 如果场景内容，地点合适，可以结合一句诗词来写，不合适不用硬加。
        - 文风像个人日记，语气自然。
        - 先介绍一段地点或者景点信息。
        - 只根据提供的信息写，不要编造不存在的细节。
        - 不要几张照片之类的描述。
        - 不要编造人物行为或事件。
        - 不要根据照片关键词推测具体场景（如工地、餐厅、商店等），只描述可见环境或整体氛围。
        - 不要逐个描述照片中的物品或人物类别，只描述整体场景或整体氛围。
        """

        isGeneratingAI = true
        Task {
            AITextEngine.shared.setProvider(.doubao)

            let locators: [PhotoAssetLocator] = (try? await DatabaseContainer.shared.db.reader.read { db in
                let links = try VisitLayerPhotoAsset.filter(Column("visitLayerId") == layer.id).fetchAll(db)
                if links.isEmpty { return [PhotoAssetLocator]() }
                let photoIds = links.map { $0.photoAssetId }
                return try PhotoAsset.fetchLocators(db: db, ids: photoIds)
            }) ?? []

            // let analysis = await VisionImageAnalysisService.shared.analyzePhotos(locators: locators)
            // let prefilteredKeywords = analysis.sanitizedKeywords
            // let aiFilteredKeywords = await AITextEngine.shared.filterVisionKeywords(
            //     rawKeywords: prefilteredKeywords,
            //     cacheKey: "diary_keywords_\(layer.id.uuidString)_\(locators.count)"
            // )
            // let promptKeywords = aiFilteredKeywords.isEmpty ? prefilteredKeywords : aiFilteredKeywords
            // let keywords = promptKeywords.joined(separator: "、")
            // let photoContentLine = keywords.isEmpty
            //     ? "照片内容：未提取到稳定主题（请侧重整体氛围，不要硬编细节）"
            //     : "照片内容：\(keywords)"

            let userPrompt = """
            这是用户回忆卡片的一段日记。
            地点：\(loc)
            时间：\(timeText)
            直接输出正文，不需要加任何非正文的解释性文字来影响观感，输出格式要标准，每段段落前加tab
            """

            var imageInputs: [AITextImage] = []
            for locator in locators.prefix(6) {
                if let thumbnail = await PhotoThumbnailLoader.shared.loadThumbnailWithDiskCache(
                    locatorKey: locator.locatorKey,
                    size: Self.aiThumbnailSize
                ),
                let dataURL = thumbnail.toAIDataURL() {
                    imageInputs.append(dataURL)
                }
            }

            let request = AITextRequest(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                images: imageInputs,
                cacheKey: cacheKey,
                fallbackText: fallback,
                temperature: 0.35,
                topP: 0.85,
                maxTokens: 120
            )

            let text = await AITextEngine.shared.generateText(for: request)
            await MainActor.run {
                withAnimation {
                    self.draftText = text
                }
            }
            await MainActor.run {
                self.isGeneratingAI = false
            }
        }
    }

    private struct InputAreaView: View {
        @Binding var draftText: String
        let isSaving: Bool
        let isGeneratingAI: Bool
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
                        if isGeneratingAI {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.blue)
                                .padding(8)
                                .background(Circle().fill(Color.blue.opacity(0.1)))
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.blue)
                                .padding(8)
                                .background(Circle().fill(Color.blue.opacity(0.1)))
                        }
                    }
                    .disabled(isGeneratingAI)
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
