import SwiftUI

struct SettingsRootView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("缓存") {
                    ThumbnailCacheSettingsView()
                }

                Section("数据源 / 媒体来源") {
                    NavigationLink("WebDAV") {
                        let container = DatabaseContainer.shared
                        let repo = WebDAVProfileRepository(db: container.db)
                        WebDAVSettingsView(viewModel: WebDAVSettingsViewModel(repo: repo))
                    }

                    NavigationLink("照片导入") {
                        ImportPhotosSettingsView()
                    }
                }

                Section("智能整理") {
                    NavigationLink("智能照片整理") {
                        SmartPhotoCurationSettingsView()
                    }
                }
            }
            .navigationTitle("设置")
        }
    }
}

struct SmartPhotoCurationSettingsView: View {
    @StateObject private var importManager = PhotoImportManager.shared

    private var statusText: String {
        switch importManager.curationProgress.status {
        case .idle: return "空闲"
        case .importing: return "处理中"
        case .completed: return "完成"
        case .failed: return "失败"
        case .cancelled: return "已停止"
        }
    }

    private var phaseText: String {
        switch importManager.curationProgress.phase {
        case .idle: return "-"
        case .preprocess: return "预处理中（筛选 / 分桶 / 评分）"
        case .generateClusters: return "生成聚类"
        case .generateVisitLayers: return "生成 Visit Layers"
        case .done: return "完成"
        }
    }

    var body: some View {
        Form {
            Section("功能说明") {
                Text("智能照片整理统一负责预处理：筛选、分桶、评分与聚类触发。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("此页的手动执行不会重复导入文件，只会对已入库照片重跑预处理并更新统计。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("处理进度") {
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

                if importManager.curationProgress.status == .importing {
                    if importManager.curationProgress.totalItems > 0 {
                        ProgressView(value: importManager.curationProgress.progress) {
                            Text("\(importManager.curationProgress.processedItems) / \(importManager.curationProgress.totalItems)")
                        }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack {
                    Text("保留")
                    Spacer()
                    Text("\(importManager.curationProgress.meaningfulKept)")
                        .foregroundStyle(.secondary)
                }

                NavigationLink {
                    ImportCurationBucketListView(filter: .review)
                } label: {
                    HStack {
                        Text("待确认")
                        Spacer()
                        Text("\(importManager.curationProgress.reviewBucketCount)")
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    ImportCurationBucketListView(filter: .archived)
                } label: {
                    HStack {
                        Text("已过滤(可恢复)")
                        Spacer()
                        Text("\(importManager.curationProgress.filteredArchivedCount)")
                            .foregroundStyle(.secondary)
                    }
                }

                if let last = importManager.curationProgress.lastCompletedAt {
                    HStack {
                        Text("上次完成")
                        Spacer()
                        Text(last.formatted(date: .numeric, time: .standard))
                            .foregroundStyle(.secondary)
                    }
                }

                if let notice = importManager.curationProgress.lastNotice, !notice.isEmpty {
                    Text("完成提示: \(notice)")
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                }

                if let err = importManager.curationProgress.lastError, !err.isEmpty {
                    Text("错误/提示: \(err)")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section("手动执行") {
                Button {
                    importManager.startPreprocessImportedPhotos(reason: "manual-settings-entry")
                } label: {
                    HStack {
                        Image(systemName: "wand.and.stars")
                        Text("重跑照片预处理")
                    }
                }
                .disabled(importManager.isRunning)

                if importManager.isCurationRunning {
                    Button(role: .destructive) {
                        importManager.cancelImport()
                    } label: {
                        HStack {
                            Image(systemName: "stop.circle.fill")
                            Text("停止处理")
                        }
                    }
                }
            }
        }
        .navigationTitle("智能照片整理")
        .onAppear {
            importManager.refreshCurationCountsFromDatabase()
        }
    }
}

// MARK: - Thumbnail Cache Settings UI

struct ThumbnailCacheSettingsView: View {
    @State private var currentUsage: UInt64 = 0
    @State private var cacheLimitGB: Double = Double(MediaCache.shared.thumbnailCacheLimitBytes) / 1_073_741_824.0
    @State private var isClearing = false

    private let limitOptions: [Double] = [0.2, 0.5, 1.0, 2.0, 3.0, 5.0]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("当前占用")
                Spacer()
                Text(formatBytes(currentUsage))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("缓存上限: \(String(format: "%.1f", cacheLimitGB)) GB")
                    .font(.subheadline)

                Picker("上限", selection: $cacheLimitGB) {
                    ForEach(limitOptions, id: \.self) { option in
                        Text("\(String(format: "%.1f", option)) GB").tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: cacheLimitGB) { newValue in
                    MediaCache.shared.thumbnailCacheLimitBytes = UInt64(newValue * 1_073_741_824.0)
                    try? MediaCache.shared.trimThumbnailsIfNeeded()
                    refreshUsage()
                }
            }

            Button(role: .destructive) {
                isClearing = true
                Task {
                    try? MediaCache.shared.clearThumbnails()
                    refreshUsage()
                    isClearing = false
                }
            } label: {
                if isClearing {
                    ProgressView().controlSize(.small)
                } else {
                    Text("清空缩略图缓存")
                }
            }
            .disabled(isClearing)
        }
        .padding(.vertical, 4)
        .onAppear {
            refreshUsage()
        }
    }

    private func refreshUsage() {
        currentUsage = (try? MediaCache.shared.thumbnailsDiskUsageBytes()) ?? 0
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
