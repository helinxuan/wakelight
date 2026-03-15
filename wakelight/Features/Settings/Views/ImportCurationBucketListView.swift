import SwiftUI
import GRDB
import Photos

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

    @State private var successToast: String?
    @State private var errorAlert: ErrorMessage?


    @State private var previewItems: [Row] = []
    @State private var previewSelection: UUID?
    @State private var previewKeepIds = Set<UUID>()
    @State private var previewGroupId: String?
    @State private var isShowingPreview = false

    @State private var displayNameMap: [String: String] = [:]
    @State private var locatorKeyMap: [UUID: String] = [:]
    @State private var keepSelections: [String: Set<UUID>] = [:]


    var body: some View {
        Group {
            if rows.isEmpty, !isLoading {
                ContentUnavailableView("暂无数据", systemImage: "tray", description: Text("当前分组下没有可展示的照片记录"))
            } else {
                List {
                    ForEach(Array(groupedDisplayItems.enumerated()), id: \.element.id) { index, group in
                        let keepIds = keepSelections[group.id] ?? []

                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .center, spacing: 10) {
                                Text("组 \(index + 1)")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Capsule())

                                Text(displayName(for: group.representative))
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)

                                Spacer(minLength: 0)

                                Text("重复 \(group.items.count) 张")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Button {
                                openPreview(for: group.representative, in: group.items)
                            } label: {
                                ZStack(alignment: .bottomLeading) {
                                    ThumbnailView(locatorKey: locatorKey(for: group.representative), size: CGSize(width: 220, height: 140))
                                        .clipShape(RoundedRectangle(cornerRadius: 12))

                                    HStack(spacing: 6) {
                                        if group.recommended?.id == group.representative.id {
                                            Text("AI推荐")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.yellow.opacity(0.85))
                                                .foregroundStyle(.black)
                                                .clipShape(Capsule())
                                        }

                                        Text("清晰度 \(String(format: "%.1f", group.representative.bestShotScore ?? 0))")
                                            .font(.caption2)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(.ultraThinMaterial)
                                            .clipShape(Capsule())
                                    }
                                    .padding(10)
                                }
                            }
                            .buttonStyle(.plain)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(group.items) { item in
                                        Button {
                                            toggleKeep(groupId: group.id, itemId: item.id)
                                        } label: {
                                            ThumbnailView(locatorKey: locatorKey(for: item), size: CGSize(width: 52, height: 52))
                                                .overlay {
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .stroke(keepIds.contains(item.id) ? Color.yellow : Color.clear, lineWidth: keepIds.contains(item.id) ? 2 : 0)
                                                }
                                                .overlay(alignment: .topLeading) {
                                                    if keepIds.contains(item.id) {
                                                        Text("保留")
                                                            .font(.system(size: 9, weight: .semibold))
                                                            .padding(.horizontal, 6)
                                                            .padding(.vertical, 2)
                                                            .background(Color.yellow.opacity(0.85))
                                                            .foregroundStyle(.black)
                                                            .clipShape(Capsule())
                                                            .offset(x: 4, y: 4)
                                                    }
                                                }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 2)
                            }

                            HStack(spacing: 10) {
                                Button("保留已选") {
                                    Task {
                                        await applyGroupKeepMultiple(groupId: group.id, allIds: group.items.map(\.id))
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(keepIds.isEmpty)

                                Button("删除其他") {
                                    Task {
                                        await applyGroupKeepMultiple(groupId: group.id, allIds: group.items.map(\.id))
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(keepIds.isEmpty)
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 6)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(screenTitle)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !groupedDisplayItems.isEmpty {
                    Button("智能保留最佳") {
                        Task {
                            await applyKeepBestForAllGroups()
                        }
                    }
                }
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
            Button("我知道了", role: .cancel) { errorAlert = nil }
        } message: { err in
            Text(err.message)
        }
        .fullScreenCover(isPresented: $isShowingPreview) {
            GroupPreviewSheet(
                items: previewItems,
                selection: $previewSelection,
                keepIds: $previewKeepIds,
                locatorKeyForRow: { row in locatorKey(for: row) },
                onApplyGroupKeep: { selectedId, allIds in
                    await applyGroupKeep(selectedId: selectedId, allIds: allIds)
                },
                onApplyGroupKeepMultiple: { keepIds, allIds in
                    await applyGroupKeepMultiple(groupId: previewGroupId ?? "", allIds: allIds)
                }
            ) { rowId, bucket in
                await applyFromPreview(rowId: rowId, bucket: bucket)
            }
            .onDisappear {
                if let groupId = previewGroupId {
                    keepSelections[groupId] = previewKeepIds
                }
                previewKeepIds = []
                previewGroupId = nil
            }
        }
        .task {
            await load()
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

            let allRows = fetched + groupRows
            let allIds = Array(Set(allRows.map(\.id)))
            let locators = await loadLocatorMap(photoIds: allIds)
            let names = await resolveDisplayNames(rows: allRows, locatorMap: locators)

            await MainActor.run {
                rows = fetched
                groupedRows = grouped
                locatorKeyMap = locators
                displayNameMap = names
                isLoading = false
            }
        } catch {
            await MainActor.run {
                rows = []
                groupedRows = [:]
                locatorKeyMap = [:]
                displayNameMap = [:]
                isLoading = false
            }
        }
    }

    private func loadLocatorMap(photoIds: [UUID]) async -> [UUID: String] {
        guard !photoIds.isEmpty else { return [:] }
        do {
            let locators = try await DatabaseContainer.shared.db.reader.read { db in
                try PhotoAsset.fetchLocators(db: db, ids: photoIds)
            }
            return Dictionary(uniqueKeysWithValues: locators.map { ($0.photoAssetId, $0.locatorKey) })
        } catch {
            return [:]
        }
    }

    private func locatorKey(for row: Row) -> String {
        if let key = locatorKeyMap[row.id], !key.isEmpty {
            return key
        }
        if let localIdentifier = row.localIdentifier, !localIdentifier.isEmpty {
            return ImportCurationBucketListViewHelper.locatorKey(for: localIdentifier)
        }
        return ""
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

        await MainActor.run {
            PhotoImportManager.shared.scheduleRecluster(reason: "curation-bucket-updated")
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
        previewSelection = row.id
        previewGroupId = sorted.first?.burstGroupId ?? row.id.uuidString
        previewKeepIds = keepSelections[previewGroupId ?? ""] ?? []

        let key = locatorKey(for: row)
        Task(priority: .userInitiated) {
            _ = await PhotoThumbnailLoader.shared.loadThumbnail(locatorKey: key, size: CGSize(width: 1200, height: 1200))
            _ = await PhotoThumbnailLoader.shared.loadFullImage(locatorKey: key)
        }

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

    private func applyGroupKeep(selectedId: UUID, allIds: [UUID]) async {
        guard !allIds.isEmpty else { return }
        let archivedIds = allIds.filter { $0 != selectedId }

        do {
            try await updateRows(ids: [selectedId], target: .keep)
            if !archivedIds.isEmpty {
                try await updateRows(ids: archivedIds, target: .archived)
            }
            await load()
            await MainActor.run {
                PhotoImportManager.shared.refreshCurationCountsFromDatabase()
                showSuccessToast("操作成功：保留 1，归档 \(archivedIds.count)")
            }
        } catch {
            await MainActor.run {
                errorAlert = ErrorMessage(message: error.localizedDescription)
            }
        }
    }

    private func applyGroupKeepMultiple(groupId: String, allIds: [UUID]) async {
        guard !allIds.isEmpty else { return }
        let keepIds = Array(keepSelections[groupId] ?? [])
        guard !keepIds.isEmpty else { return }
        let archivedIds = allIds.filter { !keepIds.contains($0) }

        do {
            try await updateRows(ids: keepIds, target: .keep)
            if !archivedIds.isEmpty {
                try await updateRows(ids: archivedIds, target: .archived)
            }
            await load()
            await MainActor.run {
                keepSelections[groupId] = []
                PhotoImportManager.shared.refreshCurationCountsFromDatabase()
                showSuccessToast("操作成功：保留 \(keepIds.count)，归档 \(archivedIds.count)")
            }
        } catch {
            await MainActor.run {
                errorAlert = ErrorMessage(message: error.localizedDescription)
            }
        }
    }

    private func applyKeepBestForAllGroups() async {
        for group in groupedDisplayItems {
            if let best = group.recommended {
                let allIds = group.items.map(\.id)
                await applyGroupKeep(selectedId: best.id, allIds: allIds)
            }
        }
    }

    private func toggleKeep(groupId: String, itemId: UUID) {
        var current = keepSelections[groupId] ?? []
        if current.contains(itemId) {
            current.remove(itemId)
        } else {
            current.insert(itemId)
        }
        keepSelections[groupId] = current
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

    private func displayName(for row: Row) -> String {
        if let key = locatorKeyMap[row.id], let name = displayNameMap[key], !name.isEmpty {
            return name
        }

        if let localIdentifier = row.localIdentifier, !localIdentifier.isEmpty {
            let fallbackKey = ImportCurationBucketListViewHelper.locatorKey(for: localIdentifier)
            if let name = displayNameMap[fallbackKey], !name.isEmpty {
                return name
            }
            return fallbackName(for: fallbackKey)
        }

        return "未命名媒体"
    }

    private func resolveDisplayNames(rows: [Row], locatorMap: [UUID: String]) async -> [String: String] {
        let keys = Array(Set(rows.compactMap { row in
            if let key = locatorMap[row.id], !key.isEmpty {
                return key
            }
            if let localId = row.localIdentifier, !localId.isEmpty {
                return ImportCurationBucketListViewHelper.locatorKey(for: localId)
            }
            return nil
        }))

        guard !keys.isEmpty else { return [:] }

        var result: [String: String] = [:]
        for key in keys {
            result[key] = await resolveDisplayName(locatorKey: key)
        }
        return result
    }

    private func resolveDisplayName(locatorKey: String) async -> String {
        if locatorKey.hasPrefix("webdav://") {
            return fallbackName(for: locatorKey)
        }

        if locatorKey.hasPrefix("library://") {
            let pureId = String(locatorKey.dropFirst("library://".count))
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [pureId], options: nil)
            if let asset = fetch.firstObject {
                let resources = PHAssetResource.assetResources(for: asset)
                if let original = resources.first(where: { !$0.originalFilename.isEmpty }) {
                    return original.originalFilename
                }
                if let first = resources.first, !first.originalFilename.isEmpty {
                    return first.originalFilename
                }
            }
            return fallbackName(for: locatorKey)
        }

        return fallbackName(for: locatorKey)
    }

    private func fallbackName(for locatorKey: String) -> String {
        if locatorKey.hasPrefix("webdav://") {
            return locatorKey.split(separator: "/").last.map(String.init) ?? locatorKey
        }
        if locatorKey.hasPrefix("library://") {
            return String(locatorKey.dropFirst("library://".count))
        }
        return locatorKey
    }

    private var groupedDisplayItems: [DisplayGroup] {
        let grouped = groupedRows.values.filter { $0.count > 1 }
        if grouped.isEmpty {
            return rows.map { DisplayGroup(id: $0.id.uuidString, items: [$0]) }
        }
        return grouped.map { items in
            let sorted = items.sorted { ($0.bestShotScore ?? 0) > ($1.bestShotScore ?? 0) }
            let id = sorted.first?.burstGroupId ?? sorted.first?.id.uuidString ?? UUID().uuidString
            return DisplayGroup(id: id, items: sorted)
        }
    }

    private var screenTitle: String {
        let groupCount = groupedDisplayItems.count
        let total = groupedDisplayItems.reduce(0) { $0 + $1.items.count }
        return "\(filter.title)（\(groupCount) 组 · 共 \(total) 张重复照片）"
    }
}

private struct GroupPreviewSheet: View {
    let items: [Row]
    @Binding var selection: UUID?
    @Binding var keepIds: Set<UUID>
    let locatorKeyForRow: (Row) -> String
    let onApplyGroupKeep: @Sendable (UUID, [UUID]) async -> Void
    let onApplyGroupKeepMultiple: @Sendable ([UUID], [UUID]) async -> Void
    let onApply: @Sendable (UUID, ImportDecisionBucket) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isApplying = false

    private var currentItem: Row? {
        guard let sel = selection else { return items.first }
        return items.first(where: { $0.id == sel }) ?? items.first
    }

    private var recommendedItem: Row? {
        items.max { ($0.bestShotScore ?? 0) < ($1.bestShotScore ?? 0) }
    }

    private var selectionIndex: Int? {
        guard let sel = selection else { return nil }
        return items.firstIndex(where: { $0.id == sel })
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if !items.isEmpty {
                    TabView(selection: Binding(
                        get: { selection ?? items.first?.id },
                        set: { selection = $0 }
                    )) {
                        ForEach(items) { item in
                            ZStack(alignment: .topTrailing) {
                                VStack(spacing: 12) {
                                    ZStack(alignment: .topTrailing) {
                                        FullImageView(locatorKey: locatorKeyForRow(item))
                                            .background(Color.black)

                                        HStack(spacing: 6) {
                                            if recommendedItem?.id == item.id {
                                                Text("AI推荐")
                                                    .font(.caption2.weight(.semibold))
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(Color.yellow.opacity(0.85))
                                                    .foregroundStyle(.black)
                                                    .clipShape(Capsule())
                                            }

                                            Text("清晰度 \(String(format: "%.1f", item.bestShotScore ?? 0))")
                                                .font(.caption2)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(.ultraThinMaterial)
                                                .clipShape(Capsule())
                                        }
                                        .padding(.trailing, 12)
                                        .padding(.top, 12)
                                    }

                                    Text(topSubtitle(for: item))
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.9))
                                }
                            }
                            .tag(item.id as UUID?)
                            .padding(.bottom, 12)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if !items.isEmpty {
                        thumbnailsStrip
                            .padding(.horizontal, 8)
                    }

                    if let current = currentItem {
                        HStack(spacing: 10) {
                            Button {
                                if keepIds.contains(current.id) {
                                    keepIds.remove(current.id)
                                } else {
                                    keepIds.insert(current.id)
                                }
                            } label: {
                                Text(keepIds.contains(current.id) ? "取消保留" : "保留这张")
                                    .font(.callout.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                Task {
                                    isApplying = true
                                    await onApplyGroupKeepMultiple(Array(keepIds), items.map(\.id))
                                    isApplying = false
                                    dismiss()
                                }
                            } label: {
                                Text("删除其他")
                                    .font(.callout.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.bordered)
                        }
                        .disabled(isApplying)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 2)
                    }
                }
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if let recommended = recommendedItem {
                        Button("智能保留最佳") {
                            Task {
                                isApplying = true
                                await onApplyGroupKeep(recommended.id, items.map(\.id))
                                isApplying = false
                                dismiss()
                            }
                        }
                        .disabled(isApplying)
                    }
                }
            }
        }
        .onAppear {
            if selection == nil {
                selection = recommendedItem?.id ?? items.first?.id
            }
        }
    }

    private func topSubtitle(for item: Row) -> String {
        let tag = ImportCurationBucketListViewHelper.bucketTag(item.curationBucket)
        let reason = ImportCurationBucketListViewHelper.userCategoryText(bucket: item.curationBucket, reason: item.selectionReason, groupId: item.burstGroupId)
        return "\(tag) · \(reason)"
    }

    private var thumbnailsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    Button {
                        selection = item.id
                        if keepIds.contains(item.id) {
                            keepIds.remove(item.id)
                        } else {
                            keepIds.insert(item.id)
                        }
                    } label: {
                        ZStack(alignment: .topLeading) {
                            ThumbnailView(locatorKey: locatorKeyForRow(item), size: CGSize(width: 52, height: 52))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(keepIds.contains(item.id) ? Color.yellow : Color.clear, lineWidth: keepIds.contains(item.id) ? 2 : 0)
                                }

                            if item.id == selection {
                                Text("当前")
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.yellow.opacity(0.85))
                                    .foregroundStyle(.black)
                                    .clipShape(Capsule())
                                    .offset(x: 4, y: 4)
                            }

                            if keepIds.contains(item.id) {
                                Text("保留")
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.yellow.opacity(0.85))
                                    .foregroundStyle(.black)
                                    .clipShape(Capsule())
                                    .offset(x: 4, y: 24)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func actionChip(title: String, isPrimary: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(isPrimary ? Color.white : Color.accentColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isPrimary ? Color.accentColor : Color.black.opacity(0.45))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled || isPrimary)
        .opacity((disabled || isPrimary) ? 0.7 : 1)
    }
}

private enum ImportCurationBucketListViewHelper {
    static func userCategoryText(bucket: String?, reason: String?, groupId: String?) -> String {
        if bucket == ImportDecisionBucket.keep.rawValue {
            return "已保留"
        }

        if reason == ImportDecisionReason.needsReview.rawValue, groupId != nil {
            return "重复照片（待确认）"
        }

        return reasonText(reason)
    }

    static func bucketTag(_ bucket: String?) -> String {
        switch bucket {
        case ImportDecisionBucket.keep.rawValue: return "保留"
        case ImportDecisionBucket.review.rawValue: return "待确认"
        case ImportDecisionBucket.archived.rawValue: return "归档"
        default: return "-"
        }
    }

    static func reasonText(_ reason: String?) -> String {
        switch reason {
        case ImportDecisionReason.duplicateNearTime.rawValue:
            return "重复照片"
        case ImportDecisionReason.filteredTextHighConfidence.rawValue:
            return "文本图片（高置信）"
        case ImportDecisionReason.filteredTextPossible.rawValue:
            return "文本图片（可能）"
        case ImportDecisionReason.filteredText.rawValue:
            return "文本图片"
        case ImportDecisionReason.needsReview.rawValue,
             ImportDecisionReason.missingCriticalMetadata.rawValue:
            return "待人工判断"
        case ImportDecisionReason.autoKeep.rawValue:
            return "保留"
        case .none:
            return "-"
        default:
            return reason ?? "-"
        }
    }

    static func locatorKey(for localIdentifier: String) -> String {
        if localIdentifier.contains("://") { return localIdentifier }
        return "library://\(localIdentifier)"
    }
}

private struct Row: Identifiable, FetchableRecord, TableRecord, Decodable {
    static let databaseTableName = "photoAsset"

    var id: UUID
    var localIdentifier: String?
    var bestShotScore: Double?
    var selectionReason: String?
    var curationBucket: String?
    var burstGroupId: String?
}

private struct DisplayGroup: Identifiable {
    let id: String
    let items: [Row]

    var recommended: Row? {
        items.max { ($0.bestShotScore ?? 0) < ($1.bestShotScore ?? 0) }
    }

    var representative: Row {
        recommended ?? items.first!
    }
}
