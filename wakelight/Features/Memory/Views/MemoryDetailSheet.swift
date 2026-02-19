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
        let photoLocalIdentifiers: [String]
    }

    let item: MemoryDetailItem
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
            let currentItem = self.item
            
            switch currentItem {
            case .unhandled(let layer):
                let photos = try await loadPhotosForVisitLayer(visitLayerId: layer.id)
                let title = Self.dateRangeText(startAt: layer.startAt, endAt: layer.endAt)
                let location = try await DatabaseContainer.shared.db.reader.read { db in
                    try PlaceCluster.fetchOne(db, key: layer.placeClusterId).map { $0.detailedAddress ?? $0.cityName ?? "未知地点" }
                }
                
                await MainActor.run {
                    self.editText = layer.userText ?? ""
                    self.summaryTitle = title
                    let group = PhotoGroup(
                        id: layer.id,
                        title: title,
                        location: location,
                        photoLocalIdentifiers: photos
                    )
                    self.photoGroups = [group]
                    self.flattenedPhotos = photos
                }

            case .story(let node):
                let (minStart, maxEnd) = try await loadTimeRangeForStory(node)
                let groups = try await loadGroupsForStory(node)
                await MainActor.run {
                    self.editText = node.mainSummary ?? ""
                    if let minStart, let maxEnd {
                        self.summaryTitle = Self.dateRangeText(startAt: minStart, endAt: maxEnd)
                    }
                    self.photoGroups = groups
                    self.flattenedPhotos = groups.flatMap { $0.photoLocalIdentifiers }
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

        return try await DatabaseContainer.shared.db.reader.read { db in
            let layers = try VisitLayer
                .filter(visitLayerIds.contains(Column("id")))
                .order(Column("startAt").asc)
                .fetchAll(db)
            
            var groups: [PhotoGroup] = []
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
                groups.append(PhotoGroup(
                    id: layer.id,
                    title: Self.dateRangeText(startAt: layer.startAt, endAt: layer.endAt),
                    location: locationName,
                    photoLocalIdentifiers: photos.compactMap { $0.localIdentifier }
                ))
            }
            return groups
        }
    }

    private func save() {
        isSaving = true
        let currentItem = self.item
        Task {
            do {
                let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                try await DatabaseContainer.shared.writer.write { db in
                    switch currentItem {
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
            return photos.compactMap { $0.localIdentifier }
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
        ZStack {
            Color.black.ignoresSafeArea()
            
            TabView(selection: $selection) {
                ForEach(Array(localIdentifiers.enumerated()), id: \.offset) { idx, id in
                    ZoomableScrollView {
                        FullImageView(localIdentifier: id)
                    }
                    .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white.opacity(0.8))
                            .padding()
                            .contentShape(Rectangle())
                    }
                }
                Spacer()
            }
            .padding(.top, 50)
            .zIndex(1)
        }
    }
}

private struct ZoomableScrollView<Content: View>: UIViewRepresentable {
    private var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 4
        scrollView.minimumZoomScale = 1
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear

        let hostedView = context.coordinator.hostingController.view!
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        hostedView.backgroundColor = .clear
        scrollView.addSubview(hostedView)

        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: scrollView.frameLayoutGuide.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: scrollView.frameLayoutGuide.bottomAnchor)
        ])

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.hostingController.rootView = content
        // 确保首次进入时为 1.0（适应屏幕的 Fit 由 SwiftUI 内容决定），避免“初始放大”
        if !context.coordinator.didSetInitialZoom {
            context.coordinator.didSetInitialZoom = true
            uiView.setZoomScale(1.0, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(hostingController: UIHostingController(rootView: content))
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        var hostingController: UIHostingController<Content>
        var didSetInitialZoom: Bool = false

        init(hostingController: UIHostingController<Content>) {
            self.hostingController = hostingController
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return hostingController.view
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            // 不要强行改 view.center，否则会造成缩小后“回弹/被拉回去”的观感
        }
    }
}
