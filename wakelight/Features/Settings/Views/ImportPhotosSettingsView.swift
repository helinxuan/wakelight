import SwiftUI

struct ImportPhotosSettingsView: View {
    @StateObject private var importManager = PhotoImportManager.shared

    private var statusText: String {
        switch importManager.progress.status {
        case .idle: return "空闲"
        case .importing: return "导入中"
        case .completed: return "完成"
        case .failed: return "失败"
        case .cancelled: return "已停止"
        }
    }

    private var phaseText: String {
        switch importManager.progress.phase {
        case .idle: return "-"
        case .photos: return "本地 Photos"
        case .webdav: return "WebDAV"
        case .generateClusters: return "生成聚类"
        case .generateVisitLayers: return "生成 Visit Layers"
        case .done: return "Done"
        }
    }

    var body: some View {
        Form {
            Section("导入") {
                Text("系统相册导入会在 App 启动或检测到变化时自动在后台运行（不阻塞 UI）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("WebDAV 导入需要全量扫描远端目录，耗时且耗电，建议仅在有大量新照片上传后手动触发。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("进度") {
                HStack {
                    Text("状态")
                    Spacer()
                    Text(statusText)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("阶段")
                    Spacer()
                    Text(phaseText)
                        .foregroundStyle(.secondary)
                }

                if importManager.progress.status == .importing {
                    if importManager.progress.totalItems > 0 {
                        ProgressView(value: importManager.progress.progress) {
                            Text("\(importManager.progress.processedItems) / \(importManager.progress.totalItems)")
                        }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if importManager.progress.meaningfulKept > 0 || importManager.progress.reviewBucketCount > 0 || importManager.progress.filteredArchivedCount > 0 {
                    HStack {
                        Text("保留")
                        Spacer()
                        Text("\(importManager.progress.meaningfulKept)")
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink {
                        ImportCurationBucketListView(filter: .review)
                    } label: {
                        HStack {
                            Text("待确认")
                            Spacer()
                            Text("\(importManager.progress.reviewBucketCount)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink {
                        ImportCurationBucketListView(filter: .archived)
                    } label: {
                        HStack {
                            Text("已过滤(可恢复)")
                            Spacer()
                            Text("\(importManager.progress.filteredArchivedCount)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let last = importManager.progress.lastCompletedAt {
                    HStack {
                        Text("上次完成")
                        Spacer()
                        Text(last.formatted(date: .numeric, time: .standard))
                            .foregroundStyle(.secondary)
                    }
                }

                if let err = importManager.progress.lastError, !err.isEmpty {
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
                            Text("停止导入")
                        }
                    }
                }
            }
        }
        .navigationTitle("Import Photos")
    }
}

#Preview {
    NavigationStack {
        ImportPhotosSettingsView()
    }
}
