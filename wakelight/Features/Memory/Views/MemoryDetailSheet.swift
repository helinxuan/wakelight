import SwiftUI
import GRDB

enum MemoryDetailItem: Identifiable {
    case unhandled(VisitLayer)
    case story(StoryNode)

    var id: String {
        switch self {
        case .unhandled(let layer): return "unhandled-\(layer.id)"
        case .story(let node): return "story-\(node.id)"
        }
    }
}

struct MemoryDetailSheet: View {
    struct PhotoGroup: Identifiable {
        let id: UUID
        let title: String
        let location: String?
        let photoLocatorKeys: [String]
    }

    let item: MemoryDetailItem
    let clusterNames: [UUID: String]
    let onRequestAddFromUnhandled: ((StoryNode) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var summaryTitle: String = ""
    @State private var editText: String = ""
    @State private var photoGroups: [PhotoGroup] = []
    @State private var flattenedLocatorKeys: [String] = []
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?
    @State private var selectedPhotoIndex: Int?
    @State private var currentStoryLayerIds: [UUID] = []

    private let gridColumns: [GridItem] = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    private var isStoryItem: Bool {
        if case .story = item { return true }
        return false
    }

    var body: some View {
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

                    if isStoryItem {
                        storyCompositionSection
                            .padding(.horizontal, 16)
                    }

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
                                ForEach(group.photoLocatorKeys, id: \.self) { key in
                                    ThumbnailView(locatorKey: key, size: CGSize(width: 120, height: 120))
                                        .clipped()
                                        .onTapGesture {
                                            if let globalIdx = flattenedLocatorKeys.firstIndex(of: key) {
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
            ToolbarItem(placement: .navigationBarLeading) {
                Button("关闭") { dismiss() }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: save) {
                    HStack(spacing: 4) {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        }
                        Text("保存")
                            .fontWeight(.bold)
                    }
                }
                .disabled(isSaving)
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
            PhotoPreviewPager(locatorKeys: flattenedLocatorKeys, startIndex: preview.index)
        }
    }

    @ViewBuilder
    private var storyCompositionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("故事片段")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if case .story(let node) = item {
                    Button {
                        onRequestAddFromUnhandled?(node)
                        dismiss()
                    } label: {
                        Label("去未加入故事添加", systemImage: "plus")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                }
            }

            if currentStoryLayerIds.isEmpty {
                Text("请至少保留一个片段")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ForEach(currentStoryLayerIds, id: \.self) { id in
                    if let group = photoGroups.first(where: { $0.id == id }) {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.title)
                                    .font(.caption.weight(.medium))
                                    .foregroundColor(.primary)
                                if let location = group.location {
                                    Text(location)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                currentStoryLayerIds.removeAll { $0 == id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    private func generateSmartText() {
        let location = photoGroups.first?.location ?? "这里"
        let count = flattenedLocatorKeys.count

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
            let currentItem = self.item

            switch currentItem {
            case .unhandled(let layer):
                let locatorKeys = try await loadLocatorsForVisitLayer(visitLayerId: layer.id)
                let title = Self.dateRangeText(startAt: layer.startAt, endAt: layer.endAt)
                let location = try await DatabaseContainer.shared.db.reader.read { db in
                    try PlaceCluster.fetchOne(db, key: layer.placeClusterId)
                        .map { $0.detailedAddress ?? $0.cityName ?? "未知地点" }
                }

                await MainActor.run {
                    self.editText = layer.userText ?? ""
                    self.summaryTitle = title
                    let group = PhotoGroup(
                        id: layer.id,
                        title: title,
                        location: location,
                        photoLocatorKeys: locatorKeys
                    )
                    self.photoGroups = [group]
                    self.flattenedLocatorKeys = locatorKeys
                }

            case .story(let node):
                let (minStart, maxEnd) = try await loadTimeRangeForStory(node)
                let groups = try await loadGroupsForStory(node)
                await MainActor.run {
                    self.editText = node.mainSummary ?? ""
                    if let minStart, let maxEnd {
                        self.summaryTitle = Self.dateRangeText(startAt: minStart, endAt: maxEnd)
                    }
                    self.currentStoryLayerIds = node.subVisitLayerIds
                    self.photoGroups = groups
                    self.flattenedLocatorKeys = groups.flatMap { $0.photoLocatorKeys }
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = String(describing: error)
            }
        }
    }

    private func loadGroupsForStory(_ node: StoryNode) async throws -> [PhotoGroup] {
        let visitLayerIds = node.subVisitLayerIds
        guard !visitLayerIds.isEmpty else { return [] }

        let layersData: [(layer: VisitLayer, locationName: String, locatorKeys: [String])] = try await DatabaseContainer.shared.db.reader.read { db in
            let layers = try VisitLayer
                .filter(visitLayerIds.contains(Column("id")))
                .order(Column("startAt").asc)
                .fetchAll(db)

            var result: [(VisitLayer, String, [String])] = []
            result.reserveCapacity(layers.count)

            for layer in layers {
                let cluster = try PlaceCluster.fetchOne(db, key: layer.placeClusterId)
                let locationName = cluster?.detailedAddress ?? cluster?.cityName ?? "未知地点"

                let links = try VisitLayerPhotoAsset
                    .filter(Column("visitLayerId") == layer.id)
                    .fetchAll(db)
                if links.isEmpty { continue }

                let photoIds = links.map { $0.photoAssetId }
                let photos = try PhotoAsset
                    .filter(photoIds.contains(Column("id")))
                    .order(Column("creationDate").asc)
                    .fetchAll(db)

                let locators = try PhotoAsset.fetchLocators(db: db, ids: photoIds)
                let locatorById = Dictionary(uniqueKeysWithValues: locators.map { ($0.photoAssetId, $0.locatorKey) })
                let locatorKeys = photos.compactMap { locatorById[$0.id] }

                result.append((layer, locationName, locatorKeys))
            }

            return result
        }

        var groups: [PhotoGroup] = []
        groups.reserveCapacity(layersData.count)

        for (layer, locationName, locatorKeys) in layersData {
            let title = await MainActor.run {
                Self.dateRangeText(startAt: layer.startAt, endAt: layer.endAt)
            }

            groups.append(PhotoGroup(
                id: layer.id,
                title: title,
                location: locationName,
                photoLocatorKeys: locatorKeys
            ))
        }

        return groups
    }

    private func save() {
        isSaving = true
        let currentItem = self.item
        Task {
            do {
                let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                switch currentItem {
                case .unhandled(let layer):
                    try await DatabaseContainer.shared.writer.write { db in
                        if var current = try VisitLayer.fetchOne(db, key: layer.id) {
                            current.userText = trimmed.isEmpty ? nil : trimmed
                            try current.update(db)
                        }
                    }
                case .story(let node):
                    try await UpdateStoryCompositionUseCase().run(
                        storyNodeId: node.id,
                        orderedVisitLayerIds: currentStoryLayerIds,
                        summaryText: trimmed
                    )
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

    private func loadLocatorsForVisitLayer(visitLayerId: UUID) async throws -> [String] {
        try await DatabaseContainer.shared.db.reader.read { db in
            let links = try VisitLayerPhotoAsset
                .filter(Column("visitLayerId") == visitLayerId)
                .fetchAll(db)
            let photoIds = links.map { $0.photoAssetId }
            let locators = try PhotoAsset.fetchLocators(db: db, ids: photoIds)
            let locatorById = Dictionary(uniqueKeysWithValues: locators.map { ($0.photoAssetId, $0.locatorKey) })
            return photoIds.compactMap { locatorById[$0] }
        }
    }

    private func loadTimeRangeForStory(_ node: StoryNode) async throws -> (Date?, Date?) {
        let ids = node.subVisitLayerIds
        return try await DatabaseContainer.shared.db.reader.read { db in
            let layers = try VisitLayer.filter(ids.contains(Column("id"))).fetchAll(db)
            return (layers.map(\.startAt).min(), layers.map(\.endAt).max())
        }
    }

    @MainActor
    private static func dateRangeText(startAt: Date, endAt: Date) -> String {
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
