import SwiftUI
import GRDB

struct ImportCurationBucketListView: View {
    enum BucketFilter: String {
        case review
        case archived

        var title: String {
            switch self {
            case .review: return "待确认组"
            case .archived: return "已过滤可恢复"
            }
        }
    }

    private enum ActionTarget: String, CaseIterable, Identifiable {
        case keep
        case review
        case archived

        var id: String { rawValue }
        var bucket: String { rawValue }

        var reason: String {
            switch self {
            case .keep: return ImportDecisionReason.autoKeep.rawValue
            case .review: return ImportDecisionReason.needsReview.rawValue
            case .archived: return ImportDecisionReason.duplicateNearTime.rawValue
            }
        }

        var isRecoverableArchived: Bool { self == .archived }
    }

    private struct ErrorMessage: Identifiable {
        let id = UUID()
        let message: String
    }

    let filter: BucketFilter

    @State private var rows: [Row] = []
    @State private var groupedRows: [String: [Row]] = [:]
    @State private var isLoading = false
    @State private var selectedIds = Set<UUID>()
    @State private var isApplyingBatch = false
    @State private var batchTarget: ActionTarget = .review

    @State private var successToast: String?
    @State private var errorAlert: ErrorMessage?

    @State private var previewItems: [Row] = []
    @State private var previewSelection: String?
    @State private var isShowingPreview = false

    private var batchOptions: [ActionTarget] {
        switch filter {
        case .archived: return [.review, .keep]
        case .review: return [.keep, .archived]
        }
    }

    var body: some View {
        Group {
            if rows.isEmpty, !isLoading {
                ContentUnavailableView("暂无数据", systemImage: "tray", description: Text("当前分组下没有可展示的照片记录"))
            } else {
                List(selection: $selectedIds) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 10) {
                                Button {
                                    openPreview(for: row, in: nil)
                                } label: {
                                    ThumbnailView(locatorKey: locatorKey(for: row.localIdentifier), size: CGSize(width: 62, height: 62))
                                }
                                .buttonStyle(.plain)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.localIdentifier)
                                        .font(.caption)
                                        .lineLimit(1)

                                    Text("reason: \(row.selectionReason ?? "-") · score: \(Int(row.bestShotScore ?? 0))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    if let groupId = row.burstGroupId,
                                       let siblings = groupedRows[groupId],
                                       siblings.count > 1 {
                                        Text("同组对比（保留/待确认/归档）")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 8) {
                                                ForEach(siblings) { item in
                                                    Button {
                                                        openPreview(for: item, in: siblings)
                                                    } label: {
                                                        VStack(spacing: 4) {
                                                            ThumbnailView(locatorKey: locatorKey(for: item.localIdentifier), size: CGSize(width: 48, height: 48))
                                                                .overlay {
                                                                    RoundedRectangle(cornerRadius: 6)
                                                                        .stroke(
                                                                            item.id == row.id ? Color.accentColor : Color.clear,
                                                                            lineWidth: item.id == row.id ? 2 : 0
                                                                        )
                                                                }
                                                            Text(bucketTag(item.curationBucket))
                                                                .font(.system(size: 9, weight: .semibold))
                                                                .padding(.horizontal, 4)
                                                                .padding(.vertical, 2)
                                                                .background(.ultraThinMaterial)
                                                                .clipShape(Capsule())
                                                        }
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                            .padding(.vertical, 2)
                                        }
                                    }
                                }
                                Spacer(minLength: 0)
                            }

                            actionButtons(for: row)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle(filter.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !selectedIds.isEmpty {
                VStack(spacing: 10) {
                    HStack {
                        Text("已选择 \(selectedIds.count) 项")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    HStack {
                        Picker("批量操作", selection: $batchTarget) {
                            ForEach(batchOptions) { target in
                                Text(actionLabel(target)).tag(target)
                            }
                        }
                        .pickerStyle(.segmented)

                        Button(isApplyingBatch ? "处理中..." : "执行") {
                            Task { await applyBatch(target: batchTarget) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isApplyingBatch)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
        }
        .overlay(alignment: .top) {
            if let successToast {
                Text(successToast)
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.green.opacity(0.9))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: successToast)
        .alert("操作失败", isPresented: .constant(errorAlert != nil), presenting: errorAlert) { _ in
            Button("我知道了", role: .cancel) {
                errorAlert = nil
            }
        } message: { err in
            Text(err.message)
        }
        .sheet(isPresented: $isShowingPreview) {
            GroupPreviewSheet(items: previewItems, selection: $previewSelection) { rowId, bucket in
                await applyFromPreview(rowId: rowId, bucket: bucket)
            }
        }
        .task {
            batchTarget = batchOptions.first ?? .review
            await load()
        }
    }

    @ViewBuilder
    private func actionButtons(for row: Row) -> some View {
        switch filter {
        case .archived:
            HStack(spacing: 8) {
                Button("恢复到待确认") {
                    Task { await applySingle(row: row, target: .review) }
                }
                .buttonStyle(.bordered)

                Button("恢复到保留") {
                    Task { await applySingle(row: row, target: .keep) }
                }
                .buttonStyle(.borderedProminent)
            }
            .font(.caption2)

        case .review:
            HStack(spacing: 8) {
                Button("确认保留") {
                    Task { await applySingle(row: row, target: .keep) }
                }
                .buttonStyle(.borderedProminent)

                Button("归档过滤") {
                    Task { await applySingle(row: row, target: .archived) }
                }
                .buttonStyle(.bordered)
            }
            .font(.caption2)
        }
    }

    private func load() async {
        await MainActor.run { isLoading = true }
        do {
            let fetched: [Row] = try await DatabaseContainer.shared.db.reader.read { db in
                try Row
                    .filter(Column("curationBucket") == filter.rawValue)
                    .order(Column("bestShotScore").desc)
                    .fetchAll(db)
            }

            let groupIds = fetched.compactMap(\.burstGroupId)
            let groupRows: [Row] = try await DatabaseContainer.shared.db.reader.read { db in
                guard !groupIds.isEmpty else { return [] }
                return try Row
                    .filter(groupIds.contains(Column("burstGroupId")))
                    .order(Column("bestShotScore").desc)
                    .fetchAll(db)
            }

            var grouped: [String: [Row]] = [:]
            for item in groupRows {
                guard let gid = item.burstGroupId else { continue }
                grouped[gid, default: []].append(item)
            }

            await MainActor.run {
                rows = fetched
                groupedRows = grouped
                selectedIds = selectedIds.intersection(Set(fetched.map(\.id)))
                isLoading = false
            }
        } catch {
            await MainActor.run {
                rows = []
                groupedRows = [:]
                selectedIds.removeAll()
                isLoading = false
            }
        }
    }

    private func applySingle(row: Row, target: ActionTarget) async {
        do {
            try await updateRows(ids: [row.id], target: target)
            await load()
            await MainActor.run {
                PhotoImportManager.shared.refreshCurationCountsFromDatabase()
                showSuccessToast("操作成功：1 项")
            }
        } catch {
            await MainActor.run {
                errorAlert = ErrorMessage(message: error.localizedDescription)
            }
        }
    }

    private func applyBatch(target: ActionTarget) async {
        guard !selectedIds.isEmpty else { return }
        await MainActor.run { isApplyingBatch = true }

        let ids = Array(selectedIds)
        do {
            try await updateRows(ids: ids, target: target)
            await MainActor.run { selectedIds.removeAll() }
            await load()
            await MainActor.run {
                PhotoImportManager.shared.refreshCurationCountsFromDatabase()
                isApplyingBatch = false
                showSuccessToast("操作成功：\(ids.count) 项")
            }
        } catch {
            await MainActor.run {
                isApplyingBatch = false
                errorAlert = ErrorMessage(message: error.localizedDescription)
            }
        }
    }

    private func updateRows(ids: [UUID], target: ActionTarget) async throws {
        try await DatabaseContainer.shared.writer.write { db in
            _ = try PhotoAsset
                .filter(ids.contains(Column("id")))
                .updateAll(
                    db,
                    Column("curationBucket").set(to: target.bucket),
                    Column("selectionReason").set(to: target.reason),
                    Column("isRecoverableArchived").set(to: target.isRecoverableArchived)
                )
        }
    }

    private func openPreview(for row: Row, in siblings: [Row]?) {
        let sorted: [Row]
        if let siblings, !siblings.isEmpty {
            sorted = siblings.sorted { ($0.bestShotScore ?? 0) > ($1.bestShotScore ?? 0) }
        } else {
            sorted = [row]
        }

        previewItems = sorted
        previewSelection = row.localIdentifier
        isShowingPreview = true
    }

    private func applyFromPreview(rowId: UUID, bucket: ImportDecisionBucket) async {
        let target: ActionTarget
        switch bucket {
        case .keep: target = .keep
        case .review: target = .review
        case .archived: target = .archived
        }

        do {
            try await updateRows(ids: [rowId], target: target)
            await load()
            await MainActor.run {
                if let updated = rows.first(where: { $0.id == rowId }) {
                    previewItems = previewItems.map { $0.id == rowId ? updated : $0 }
                }
                PhotoImportManager.shared.refreshCurationCountsFromDatabase()
                showSuccessToast("操作成功：1 项")
            }
        } catch {
            await MainActor.run {
                errorAlert = ErrorMessage(message: error.localizedDescription)
            }
        }
    }

    @MainActor
    private func showSuccessToast(_ message: String) {
        successToast = message
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            await MainActor.run {
                if successToast == message {
                    successToast = nil
                }
            }
        }
    }

    private func actionLabel(_ target: ActionTarget) -> String {
        switch target {
        case .keep: return "保留"
        case .review: return "到待确认"
        case .archived: return "归档"
        }
    }

    private func bucketTag(_ bucket: String?) -> String {
        switch bucket {
        case ImportDecisionBucket.keep.rawValue: return "保留"
        case ImportDecisionBucket.review.rawValue: return "待确认"
        case ImportDecisionBucket.archived.rawValue: return "归档"
        default: return "-"
        }
    }

    private func locatorKey(for localIdentifier: String) -> String {
        if localIdentifier.contains("://") { return localIdentifier }
        return "library://\(localIdentifier)"
    }
}

private struct GroupPreviewSheet: View {
    let items: [Row]
    @Binding var selection: String?
    let onApply: @Sendable (UUID, ImportDecisionBucket) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isApplying = false

    private var currentItem: Row? {
        guard let sel = selection else { return items.first }
        return items.first(where: { $0.localIdentifier == sel }) ?? items.first
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if !items.isEmpty {
                    TabView(selection: Binding(
                        get: { selection ?? items.first?.localIdentifier },
                        set: { selection = $0 }
                    )) {
                        ForEach(items) { item in
                            VStack(spacing: 12) {
                                FullImageView(locatorKey: locatorKey(for: item.localIdentifier))
                                    .background(Color.black)

                                HStack(spacing: 8) {
                                    Text(bucketTag(item.curationBucket))
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.ultraThinMaterial)
                                        .clipShape(Capsule())

                                    Text("score \(Int(item.bestShotScore ?? 0))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .foregroundStyle(.white)
                            }
                            .tag(item.localIdentifier as String?)
                            .padding(.bottom, 18)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .always))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let current = currentItem {
                    HStack(spacing: 8) {
                        Button("保留") {
                            Task {
                                isApplying = true
                                await onApply(current.id, .keep)
                                isApplying = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isApplying)

                        Button("待确认") {
                            Task {
                                isApplying = true
                                await onApply(current.id, .review)
                                isApplying = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isApplying)

                        Button("归档") {
                            Task {
                                isApplying = true
                                await onApply(current.id, .archived)
                                isApplying = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isApplying)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func bucketTag(_ bucket: String?) -> String {
        switch bucket {
        case ImportDecisionBucket.keep.rawValue: return "保留"
        case ImportDecisionBucket.review.rawValue: return "待确认"
        case ImportDecisionBucket.archived.rawValue: return "归档"
        default: return "-"
        }
    }

    private func locatorKey(for localIdentifier: String) -> String {
        if localIdentifier.contains("://") { return localIdentifier }
        return "library://\(localIdentifier)"
    }
}

private struct Row: Identifiable, FetchableRecord, TableRecord, Decodable {
    static let databaseTableName = "photoAsset"

    var id: UUID
    var localIdentifier: String
    var bestShotScore: Double?
    var selectionReason: String?
    var curationBucket: String?
    var burstGroupId: String?
}
