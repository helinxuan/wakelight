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
            case .archived: return "回收站"
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

    private struct PreviewPayload: Identifiable {
        let id = UUID()
        var items: [Row]
        var selection: UUID?
        var groupId: String
        var keepIds: Set<UUID>
    }

    private enum DeleteScope {
        case current
        case all

        var actionTitle: String {
            switch self {
            case .current: return "删除当前页"
            case .all: return "清空回收站"
            }
        }
    }

    private var isTrashMode: Bool {
        filter == .archived
    }

    let filter: BucketFilter

    @State private var rows: [Row] = []
    @State private var groupedRows: [String: [Row]] = [:]
    @State private var isLoading = false

    @State private var successToast: String?
    @State private var errorAlert: ErrorMessage?


    @State private var previewPayload: PreviewPayload?

    @State private var displayNameMap: [String: String] = [:]
    @State private var locatorKeyMap: [UUID: String] = [:]
    @State private var keepSelections: [String: Set<UUID>] = [:]

    @State private var deleteScope: DeleteScope = .current
    @State private var showDeleteConfirm = false
    @State private var deleteMessage: String = ""
    @State private var deleteTargets: [Row]? = nil


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

                                if isTrashMode, let kept = group.keptRepresentative {
                                    Text("保留：\(displayName(for: kept))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

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
                                        if !isTrashMode, group.recommended?.id == group.representative.id {
                                            Text("AI推荐")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.yellow.opacity(0.85))
                                                .foregroundStyle(.black)
                                                .clipShape(Capsule())
                                        }

                                        if isTrashMode, !isArchived(group.representative) {
                                            Text("已保留")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.white.opacity(0.85))
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
                                            toggleKeep(groupId: group.id, item: item)
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
                                                    } else if isTrashMode, !isArchived(item) {
                                                        Text("已保留")
                                                            .font(.system(size: 9, weight: .semibold))
                                                            .padding(.horizontal, 6)
                                                            .padding(.vertical, 2)
                                                            .background(Color.white.opacity(0.85))
                                                            .foregroundStyle(.black)
                                                            .clipShape(Capsule())
                                                            .offset(x: 4, y: 4)
                                                    }
                                                }
                                                .opacity(isTrashMode && !isArchived(item) ? 0.6 : 1)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(isTrashMode && !isArchived(item))
                                    }
                                }
                                .padding(.vertical, 2)
                            }

                            HStack(spacing: 10) {
                                if isTrashMode {
                                    Button("恢复已选") {
                                        Task {
                                            await recoverSelected(groupId: group.id, allIds: group.items.map(\.id))
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(selectedArchivedIds(groupId: group.id).isEmpty)

                                    Button("彻底删除已选") {
                                        promptDeleteSelected(groupId: group.id, allIds: group.items)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(selectedArchivedIds(groupId: group.id).isEmpty)
                                } else {
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
                    if isTrashMode {
                        Button("全部恢复") {
                            Task {
                                await recoverAllArchived()
                            }
                        }
                    } else {
                        Button("智能保留最佳") {
                            Task {
                                await applyKeepBestForAllGroups()
                            }
                        }
                    }
                }
            }

            ToolbarItem(placement: .topBarLeading) {
                if isTrashMode, !groupedDisplayItems.isEmpty {
                    Button(role: .destructive) {
                        promptDelete(scope: .all)
                    } label: {
                        Label("清空回收站", systemImage: "trash")
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
        .alert("确认彻底删除", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("彻底删除", role: .destructive) {
                Task {
                    await performDelete(scope: deleteScope)
                }
            }
        } message: {
            Text(deleteMessage)
        }
        .fullScreenCover(item: $previewPayload) { payload in
            GroupPreviewSheet(
                items: payload.items,
                selection: Binding(
                    get: { previewPayload?.selection },
                    set: { previewPayload?.selection = $0 }
                ),
                keepIds: Binding(
                    get: { previewPayload?.keepIds ?? [] },
                    set: { previewPayload?.keepIds = $0 }
                ),
                isTrashMode: isTrashMode,
                locatorKeyForRow: { row in locatorKey(for: row) },
                displayNameForRow: { row in displayName(for: row) },
                onApplyGroupKeep: { selectedId, allIds in
                    await applyGroupKeep(selectedId: selectedId, allIds: allIds)
                },
                onApplyGroupKeepMultiple: { keepIds, allIds in
                    await applyGroupKeepMultiple(groupId: payload.groupId, allIds: allIds)
                },
                onRecoverSelected: { ids in
                    await recoverSelectedFromPreview(ids: ids)
                },
                onDeleteSelected: { rows in
                    await promptDeleteRows(rows)
                }
            ) { rowId, bucket in
                await applyFromPreview(rowId: rowId, bucket: bucket)
            }
            .onDisappear {
                keepSelections[payload.groupId] = previewPayload?.keepIds ?? []
                previewPayload = nil
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
                let query = Row
                    .filter(Column("curationBucket") == filter.rawValue)

                if filter == .archived {
                    return try query
                        .order(Column("archivedAt").desc, Column("bestShotScore").desc)
                        .fetchAll(db)
                }

                return try query
                    .order(Column("bestShotScore").desc)
                    .fetchAll(db)
            }

            let groupIds = fetched.compactMap(\.burstGroupId)
            let groupRows: [Row] = try await DatabaseContainer.shared.db.reader.read { db in
                guard !groupIds.isEmpty else { return [] }

                if filter == .archived {
                    return try Row
                        .filter(groupIds.contains(Column("burstGroupId")))
                        .filter(Column("curationBucket") == ImportDecisionBucket.keep.rawValue)
                        .order(Column("bestShotScore").desc)
                        .fetchAll(db)
                }

                return try Row
                    .filter(groupIds.contains(Column("burstGroupId")))
                    .order(Column("bestShotScore").desc)
                    .fetchAll(db)
            }

            var grouped: [String: [Row]] = [:]
            for item in fetched + groupRows {
                guard let gid = item.burstGroupId else { continue }
                var items = grouped[gid, default: []]
                if !items.contains(where: { $0.id == item.id }) {
                    items.append(item)
                }
                grouped[gid] = items
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

    private func localIdentifier(for row: Row) -> String? {
        if let localIdentifier = row.localIdentifier, !localIdentifier.isEmpty {
            return localIdentifier
        }
        if let key = locatorKeyMap[row.id], let locator = MediaLocator.parse(key), case .library(let id) = locator {
            return id
        }
        return nil
    }

    private func isArchived(_ row: Row) -> Bool {
        row.curationBucket == ImportDecisionBucket.archived.rawValue
    }

    private func selectedArchivedIds(groupId: String) -> [UUID] {
        let selections = keepSelections[groupId] ?? []
        guard !selections.isEmpty else { return [] }

        let items = groupedDisplayItems.first(where: { $0.id == groupId })?.items ?? []
        return items.filter { selections.contains($0.id) && isArchived($0) }.map(\.id)
    }

    private func updateRows(ids: [UUID], target: ActionTarget) async throws {
        let archivedAt: Date? = target == .archived ? Date() : nil

        try await DatabaseContainer.shared.writer.write { db in
            _ = try PhotoAsset
                .filter(ids.contains(Column("id")))
                .updateAll(
                    db,
                    Column("curationBucket").set(to: target.bucket),
                    Column("selectionReason").set(to: target.reason),
                    Column("isRecoverableArchived").set(to: target.isRecoverableArchived),
                    Column("archivedAt").set(to: archivedAt)
                )
        }

        await MainActor.run {
            PhotoImportManager.shared.scheduleRecluster(reason: "curation-bucket-updated")
        }
    }

    private func promptDelete(scope: DeleteScope) {
        Task {
            await prepareDeleteConfirmation(scope: scope, targetsOverride: nil)
        }
    }

    private func promptDeleteSelected(groupId: String, allIds: [Row]) {
        let selectedIds = selectedArchivedIds(groupId: groupId)
        guard !selectedIds.isEmpty else { return }
        let targets = allIds.filter { selectedIds.contains($0.id) }
        Task {
            await prepareDeleteConfirmation(scope: .current, targetsOverride: targets)
        }
    }

    private func prepareDeleteConfirmation(scope: DeleteScope, targetsOverride: [Row]?) async {
        do {
            let targets: [Row]
            if let targetsOverride {
                targets = targetsOverride
            } else {
                targets = try await archivedRows(for: scope)
            }
            guard !targets.isEmpty else {
                await MainActor.run {
                    errorAlert = ErrorMessage(message: "回收站里没有可删除的照片")
                }
                return
            }

            let localTargets = targets.filter { localIdentifier(for: $0) != nil }
            let webdavCount = targets.count - localTargets.count

            let base = "将从系统相册彻底删除 \(localTargets.count) 张照片，并清理本地记录。该操作不可恢复。"
            let note = webdavCount > 0 ? "\n\n包含 \(webdavCount) 张 WebDAV 照片，暂不支持物理删除，将会保留。" : ""

            await MainActor.run {
                deleteScope = scope
                deleteMessage = base + note
                deleteTargets = targets
                showDeleteConfirm = true
            }
        } catch {
            await MainActor.run {
                errorAlert = ErrorMessage(message: error.localizedDescription)
            }
        }
    }

    private func performDelete(scope: DeleteScope) async {
        do {
            let targets: [Row]
            if let deleteTargets {
                targets = deleteTargets
            } else {
                targets = try await archivedRows(for: scope)
            }
            self.deleteTargets = nil
            guard !targets.isEmpty else {
                await MainActor.run {
                    errorAlert = ErrorMessage(message: "回收站里没有可删除的照片")
                }
                return
            }

            let localTargets = targets.compactMap { row -> (Row, String)? in
                guard let identifier = localIdentifier(for: row) else { return nil }
                return (row, identifier)
            }

            guard !localTargets.isEmpty else {
                await MainActor.run {
                    errorAlert = ErrorMessage(message: "当前回收站没有可删除的本地照片（WebDAV 暂不支持）")
                }
                return
            }

            let localIdentifiers = localTargets.map { $0.1 }
            try await deleteLocalAssets(localIdentifiers: localIdentifiers)

            let deletedIds = localTargets.map { $0.0.id }
            try await PhotoImportManager.shared.cleanupDeletedPhotoAssets(photoIds: deletedIds)

            await load()
            await MainActor.run {
                PhotoImportManager.shared.refreshCurationCountsFromDatabase()
                let webdavCount = targets.count - localTargets.count
                let suffix = webdavCount > 0 ? "，WebDAV \(webdavCount) 张未处理" : ""
                showSuccessToast("已彻底删除 \(localTargets.count) 张\(suffix)")
            }
        } catch {
            await MainActor.run {
                errorAlert = ErrorMessage(message: error.localizedDescription)
            }
        }
    }

    private func archivedRows(for scope: DeleteScope) async throws -> [Row] {
        switch scope {
        case .current:
            return rows
        case .all:
            return try await DatabaseContainer.shared.db.reader.read { db in
                try Row
                    .filter(Column("curationBucket") == ImportDecisionBucket.archived.rawValue)
                    .order(Column("bestShotScore").desc)
                    .fetchAll(db)
            }
        }
    }

    private func deleteLocalAssets(localIdentifiers: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        guard assets.count > 0 else {
            throw NSError(domain: "ImportCurationBucketListView", code: -404, userInfo: [NSLocalizedDescriptionKey: "未在系统相册找到可删除的照片"])
        }

        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? NSError(domain: "ImportCurationBucketListView", code: -1, userInfo: [NSLocalizedDescriptionKey: "系统相册删除失败"]))
                }
            }
        }
    }

    @MainActor
    private func openPreview(for row: Row, in siblings: [Row]?) {
        let sorted: [Row]
        if let siblings, !siblings.isEmpty {
            sorted = siblings.sorted { ($0.bestShotScore ?? 0) > ($1.bestShotScore ?? 0) }
        } else {
            sorted = [row]
        }

        let groupId = sorted.first?.burstGroupId ?? row.id.uuidString
        let keepIds = keepSelections[groupId] ?? []

        previewPayload = PreviewPayload(
            items: sorted,
            selection: row.id,
            groupId: groupId,
            keepIds: keepIds
        )

        let key = locatorKey(for: row)
        print("[CurationPreview] open locator=\(key) rowId=\(row.id) groupId=\(groupId) items=\(sorted.count)")

        Task(priority: .userInitiated) {
            _ = await PhotoThumbnailLoader.shared.loadThumbnail(locatorKey: key, size: CGSize(width: 1200, height: 1200))
            _ = await PhotoThumbnailLoader.shared.loadFullImage(locatorKey: key)
        }
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
                    if let payload = previewPayload {
                        var updatedPayload = payload
                        updatedPayload.items = payload.items.map { $0.id == rowId ? updated : $0 }
                        previewPayload = updatedPayload
                    }
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

    private func recoverSelectedFromPreview(ids: [UUID]) async {
        guard !ids.isEmpty else { return }

        do {
            try await updateRows(ids: ids, target: .keep)
            await load()
            await MainActor.run {
                if let groupId = previewPayload?.groupId {
                    keepSelections[groupId] = []
                }
                PhotoImportManager.shared.refreshCurationCountsFromDatabase()
                showSuccessToast("已恢复 \(ids.count) 张")
            }
        } catch {
            await MainActor.run {
                errorAlert = ErrorMessage(message: error.localizedDescription)
            }
        }
    }

    private func promptDeleteRows(_ rows: [Row]) async {
        guard !rows.isEmpty else { return }
        await prepareDeleteConfirmation(scope: .current, targetsOverride: rows)
    }

    private func recoverSelected(groupId: String, allIds: [UUID]) async {
        guard !allIds.isEmpty else { return }
        let keepIds = selectedArchivedIds(groupId: groupId)
        guard !keepIds.isEmpty else { return }

        do {
            try await updateRows(ids: keepIds, target: .keep)
            await load()
            await MainActor.run {
                keepSelections[groupId] = []
                PhotoImportManager.shared.refreshCurationCountsFromDatabase()
                showSuccessToast("已恢复 \(keepIds.count) 张")
            }
        } catch {
            await MainActor.run {
                errorAlert = ErrorMessage(message: error.localizedDescription)
            }
        }
    }

    private func recoverAllArchived() async {
        do {
            let targets = try await archivedRows(for: .all)
            let ids = targets.map(\.id)
            guard !ids.isEmpty else {
                await MainActor.run {
                    errorAlert = ErrorMessage(message: "回收站为空")
                }
                return
            }

            try await updateRows(ids: ids, target: .keep)
            await load()
            await MainActor.run {
                keepSelections = [:]
                PhotoImportManager.shared.refreshCurationCountsFromDatabase()
                showSuccessToast("已恢复 \(ids.count) 张")
            }
        } catch {
            await MainActor.run {
                errorAlert = ErrorMessage(message: error.localizedDescription)
            }
        }
    }

    private func toggleKeep(groupId: String, item: Row) {
        if isTrashMode, !isArchived(item) {
            return
        }

        var current = keepSelections[groupId] ?? []
        if current.contains(item.id) {
            current.remove(item.id)
        } else {
            current.insert(item.id)
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
    let isTrashMode: Bool
    let locatorKeyForRow: (Row) -> String
    let displayNameForRow: (Row) -> String
    let onApplyGroupKeep: @Sendable (UUID, [UUID]) async -> Void
    let onApplyGroupKeepMultiple: @Sendable ([UUID], [UUID]) async -> Void
    let onRecoverSelected: @Sendable ([UUID]) async -> Void
    let onDeleteSelected: @Sendable ([Row]) async -> Void
    let onApply: @Sendable (UUID, ImportDecisionBucket) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isApplying = false

    private func isArchived(_ row: Row) -> Bool {
        row.curationBucket == ImportDecisionBucket.archived.rawValue
    }

    private func selectedArchivedIds() -> [UUID] {
        let selected = keepIds
        guard !selected.isEmpty else { return [] }
        return items.filter { selected.contains($0.id) && isArchived($0) }.map(\.id)
    }

    private func selectedArchivedRows() -> [Row] {
        let selected = keepIds
        guard !selected.isEmpty else { return [] }
        return items.filter { selected.contains($0.id) && isArchived($0) }
    }

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
                                            if !isTrashMode, recommendedItem?.id == item.id {
                                                Text("AI推荐")
                                                    .font(.caption2.weight(.semibold))
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(Color.yellow.opacity(0.85))
                                                    .foregroundStyle(.black)
                                                    .clipShape(Capsule())
                                            }

                                            if isTrashMode, !isArchived(item) {
                                                Text("已保留")
                                                    .font(.caption2.weight(.semibold))
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(Color.white.opacity(0.85))
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
                                    .onAppear {
                                        let key = locatorKeyForRow(item)
                                        print("[GroupPreview] item appear locator=\(key) id=\(item.id)")
                                    }

                                    VStack(spacing: 6) {
                                        Text(displayNameForRow(item))
                                            .font(.callout.weight(.semibold))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)

                                        Text(topSubtitle(for: item))
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.9))
                                    }
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
                            if isTrashMode {
                                Button {
                                    if keepIds.contains(current.id) {
                                        keepIds.remove(current.id)
                                    } else if isArchived(current) {
                                        keepIds.insert(current.id)
                                    }
                                } label: {
                                    Text(keepIds.contains(current.id) ? "取消选择" : "选择这张")
                                        .font(.callout.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!isArchived(current))

                                Button {
                                    Task {
                                        isApplying = true
                                        await onRecoverSelected(selectedArchivedIds())
                                        isApplying = false
                                        dismiss()
                                    }
                                } label: {
                                    Text("恢复已选")
                                        .font(.callout.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                }
                                .buttonStyle(.bordered)
                                .disabled(selectedArchivedIds().isEmpty)

                                Button {
                                    Task {
                                        isApplying = true
                                        await onDeleteSelected(selectedArchivedRows())
                                        isApplying = false
                                        dismiss()
                                    }
                                } label: {
                                    Text("彻底删除")
                                        .font(.callout.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                }
                                .buttonStyle(.bordered)
                                .disabled(selectedArchivedIds().isEmpty)
                            } else {
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
                    if !isTrashMode, let recommended = recommendedItem {
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
            print("[GroupPreview] sheet appear items=\(items.count) selection=\(selection?.uuidString ?? "nil")")
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
                        } else if !isTrashMode || isArchived(item) {
                            keepIds.insert(item.id)
                        }
                    } label: {
                        ZStack(alignment: .topLeading) {
                            ThumbnailView(locatorKey: locatorKeyForRow(item), size: CGSize(width: 52, height: 52))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(keepIds.contains(item.id) ? Color.yellow : Color.clear, lineWidth: keepIds.contains(item.id) ? 2 : 0)
                                }
                                .opacity(isTrashMode && !isArchived(item) ? 0.6 : 1)

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
                            } else if isTrashMode, !isArchived(item) {
                                Text("已保留")
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.white.opacity(0.85))
                                    .foregroundStyle(.black)
                                    .clipShape(Capsule())
                                    .offset(x: 4, y: 24)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isTrashMode && !isArchived(item))
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
    var archivedAt: Date?
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

    var keptRepresentative: Row? {
        items.first(where: { $0.curationBucket == ImportDecisionBucket.keep.rawValue })
    }
}
