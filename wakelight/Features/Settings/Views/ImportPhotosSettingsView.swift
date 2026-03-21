import SwiftUI

struct ImportPhotosSettingsView: View {
    @StateObject private var importManager = PhotoImportManager.shared

    private enum ProgressSource {
        case sync
        case curation
    }

    private var progressSource: ProgressSource {
        if importManager.isCurationRunning { return .curation }
        if importManager.isSyncRunning { return .sync }

        let syncAt = importManager.syncProgress.lastCompletedAt ?? .distantPast
        let curationAt = importManager.curationProgress.lastCompletedAt ?? .distantPast
        return curationAt > syncAt ? .curation : .sync
    }

    private var statusText: String {
        let status: ImportStatus = progressSource == .curation
            ? importManager.curationProgress.status
            : importManager.syncProgress.status

        switch status {
        case .idle: return "空闲"
        case .importing: return progressSource == .curation ? "整理中" : "同步中"
        case .completed: return "完成"
        case .failed: return "失败"
        case .cancelled: return "已停止"
        }
    }

    private var syncPhaseText: String {
        if progressSource == .curation {
            switch importManager.curationProgress.phase {
            case .idle: return "-"
            case .preprocess: return "智能整理"
            case .generateClusters, .generateVisitLayers: return "整理收尾中"
            case .done: return "完成"
            }
        }

        switch importManager.syncProgress.phase {
        case .idle: return "-"
        case .photos: return "本地增量同步"
        case .webdav: return "WebDAV 扫描"
        case .generateClusters, .generateVisitLayers: return "同步收尾中"
        case .done: return "完成"
        }
    }

    private var effectiveIsImporting: Bool {
        progressSource == .curation
            ? importManager.curationProgress.status == .importing
            : importManager.syncProgress.status == .importing
    }

    private var effectiveProcessedItems: Int {
        progressSource == .curation
            ? importManager.curationProgress.processedItems
            : importManager.syncProgress.processedItems
    }

    private var effectiveTotalItems: Int {
        progressSource == .curation
            ? importManager.curationProgress.totalItems
            : importManager.syncProgress.totalItems
    }

    private var effectiveProgress: Double {
        progressSource == .curation
            ? importManager.curationProgress.progress
            : importManager.syncProgress.progress
    }

    private var effectiveLastError: String? {
        progressSource == .curation
            ? importManager.curationProgress.lastError
            : importManager.syncProgress.lastError
    }

    private var effectiveLastNotice: String? {
        progressSource == .curation
            ? importManager.curationProgress.lastNotice
            : importManager.syncProgress.lastNotice
    }

    var body: some View {
        Form {
            Section("数据同步") {
                Text("本页只负责数据同步（系统相册增量 / WebDAV 扫描），不包含智能整理。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("系统相册导入会在 App 启动或检测到变化时自动在后台运行（不阻塞 UI）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("WebDAV 导入需要全量扫描远端目录，耗时且耗电，建议仅在有大量新照片上传后手动触发。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("同步状态") {
                HStack {
                    Text("状态")
                    Spacer()
                    Text(statusText)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("阶段")
                    Spacer()
                    Text(syncPhaseText)
                        .foregroundStyle(.secondary)
                }

                if effectiveIsImporting {
                    if effectiveTotalItems > 0 {
                        ProgressView(value: effectiveProgress) {
                            Text("\(effectiveProcessedItems) / \(effectiveTotalItems)")
                        }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let last = importManager.syncProgress.lastCompletedAt {
                    HStack {
                        Text("上次同步")
                        Spacer()
                        Text(last.formatted(date: .numeric, time: .standard))
                            .foregroundStyle(.secondary)
                    }
                }

                if let notice = effectiveLastNotice, !notice.isEmpty {
                    Text("结果提示: \(notice)")
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                }

                if let err = effectiveLastError, !err.isEmpty {
                    Text("错误/提示: \(err)")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section("手动执行") {
                Button {
                    importManager.startLocalPhotosImport(reason: "manual")
                } label: {
                    HStack {
                        Image(systemName: "photo.on.rectangle")
                        Text("同步系统相册")
                    }
                }
                .disabled(importManager.isRunning)

                Button {
                    importManager.startWebDAVImport(reason: "manual")
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "network")
                            Text("WebDAV 全量扫描导入")
                        }
                        Text("警告：会递归扫描所有目录，照片多时非常耗时")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
                .disabled(importManager.isRunning)

                if importManager.isRunning {
                    Button(role: .destructive) {
                        importManager.cancelImport()
                    } label: {
                        HStack {
                            Image(systemName: "stop.circle.fill")
                            Text(importManager.isSyncRunning ? "停止同步" : "停止当前任务")
                        }
                    }
                }
            }
        }
        .navigationTitle("照片导入")
    }
}

#Preview {
    NavigationStack {
        ImportPhotosSettingsView()
    }
}
