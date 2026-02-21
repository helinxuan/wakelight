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
                Text("导入会在 App 启动或 WebDAV 保存成功后自动在后台运行（不阻塞 UI）。")
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

            Section {
                Button {
                    importManager.startImport(reason: "manual")
                } label: {
                    Text("手动触发导入")
                }

                if importManager.isRunning {
                    Button(role: .destructive) {
                        importManager.cancelImport()
                    } label: {
                        Text("停止导入")
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
