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

    private enum RestoreTarget: String, CaseIterable, Identifiable {
        case review
        case keep

        var id: String { rawValue }

        var label: String {
            switch self {
            case .review: return "恢复到待确认"
            case .keep: return "恢复到保留"
            }
        }

        var bucket: String { rawValue }
        var reason: String {
            switch self {
            case .review: return ImportDecisionReason.needsReview.rawValue
            case .keep: return ImportDecisionReason.autoKeep.rawValue
            }
        }
    }

    let filter: BucketFilter

    @State private var rows: [Row] = []
    @State private var isLoading = false
    @State private var selectedIds = Set<UUID>()
    @State private var isApplyingBatch = false
    @State private var batchTarget: RestoreTarget = .review

    var body: some View {
        Group {
            if rows.isEmpty, !isLoading {
                ContentUnavailableView("暂无数据", systemImage: "tray", description: Text("当前分组下没有可展示的照片记录"))
            } else {
                List(selection: $selectedIds) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.localIdentifier)
                                .font(.caption)
                                .lineLimit(1)
                            Text("reason: \(row.selectionReason ?? "-") · score: \(Int(row.bestShotScore ?? 0))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            if filter == .archived {
                                HStack(spacing: 8) {
                                    Button("恢复到待确认") {
                                        Task { await restoreSingle(row: row, target: .review) }
                                    }
                                    .buttonStyle(.bordered)

                                    Button("恢复到保留") {
                                        Task { await restoreSingle(row: row, target: .keep) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                                .font(.caption2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle(filter.title)
        .toolbar {
            if filter == .archived {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if filter == .archived, !selectedIds.isEmpty {
                VStack(spacing: 10) {
                    HStack {
                        Text("已选择 \(selectedIds.count) 项")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    HStack {
                        Picker("批量恢复目标", selection: $batchTarget) {
                            ForEach(RestoreTarget.allCases) { target in
                                Text(target.label).tag(target)
                            }
                        }
                        .pickerStyle(.segmented)

                        Button(isApplyingBatch ? "处理中..." : "批量恢复") {
                            Task { await restoreBatch(target: batchTarget) }
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
        .task { await load() }
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
            await MainActor.run {
                rows = fetched
                selectedIds = selectedIds.intersection(Set(fetched.map(\.id)))
                isLoading = false
            }
        } catch {
            await MainActor.run {
                rows = []
                selectedIds.removeAll()
                isLoading = false
            }
        }
    }

    private func restoreSingle(row: Row, target: RestoreTarget) async {
        do {
            try await DatabaseContainer.shared.writer.write { db in
                _ = try PhotoAsset
                    .filter(Column("id") == row.id)
                    .updateAll(
                        db,
                        Column("curationBucket").set(to: target.bucket),
                        Column("selectionReason").set(to: target.reason),
                        Column("isRecoverableArchived").set(to: false)
                    )
            }
            await load()
            await MainActor.run {
                PhotoImportManager.shared.refreshCurationCountsFromDatabase()
            }
        } catch {
            // keep minimal usable behavior for now
        }
    }

    private func restoreBatch(target: RestoreTarget) async {
        guard !selectedIds.isEmpty else { return }
        await MainActor.run { isApplyingBatch = true }

        let ids = Array(selectedIds)
        do {
            try await DatabaseContainer.shared.writer.write { db in
                _ = try PhotoAsset
                    .filter(ids.contains(Column("id")))
                    .updateAll(
                        db,
                        Column("curationBucket").set(to: target.bucket),
                        Column("selectionReason").set(to: target.reason),
                        Column("isRecoverableArchived").set(to: false)
                    )
            }
            await MainActor.run { selectedIds.removeAll() }
            await load()
            await MainActor.run {
                PhotoImportManager.shared.refreshCurationCountsFromDatabase()
                isApplyingBatch = false
            }
        } catch {
            await MainActor.run { isApplyingBatch = false }
        }
    }
}

private struct Row: Identifiable, FetchableRecord, TableRecord, Decodable {
    static let databaseTableName = "photoAsset"

    var id: UUID
    var localIdentifier: String
    var bestShotScore: Double?
    var selectionReason: String?
}
