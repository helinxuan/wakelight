import SwiftUI

struct ImportPhotosSettingsView: View {
    @StateObject private var importManager = PhotoImportManager.shared

    private var statusText: String {
        switch importManager.syncProgress.status {
        case .idle: return "空闲"
        case .importing: return "同步中"
        case .completed: return "完成"
        case .failed: return "失败"
        case .cancelled: return "已停止"
        }
    }

    private var syncPhaseText: String {
        switch importManager.syncProgress.phase {
        case .idle: return "-"
        case .photos: return "本地增量同步"
        case .webdav: return "WebDAV 扫描"
        case .generateClusters, .generateVisitLayers: return "同步收尾中"
        case .done: return "完成"
        }
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

                if importManager.syncProgress.status == .importing {
                    if importManager.syncProgress.totalItems > 0 {
                        ProgressView(value: importManager.syncProgress.progress) {
                            Text("\(importManager.syncProgress.processedItems) / \(importManager.syncProgress.totalItems)")
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

                if let notice = importManager.syncProgress.lastNotice, !notice.isEmpty {
                    Text("结果提示: \(notice)")
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                }

                if let err = importManager.syncProgress.lastError, !err.isEmpty {
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

                if importManager.isSyncRunning {
                    Button(role: .destructive) {
                        importManager.cancelImport()
                    } label: {
                        HStack {
                            Image(systemName: "stop.circle.fill")
                            Text("停止同步")
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
