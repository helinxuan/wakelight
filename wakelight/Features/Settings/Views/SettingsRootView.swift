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

    private var phaseText: String {
        switch importManager.progress.phase {
        case .idle: return "-"
        case .preprocess: return "预处理中（筛选照片/生成光点）"
        case .photos: return "写入本地照片"
        case .webdav: return "WebDAV"
        case .generateClusters: return "生成聚类"
        case .generateVisitLayers: return "生成 Visit Layers"
        case .done: return "完成"
        }
    }

    var body: some View {
        Form {
            Section("功能说明") {
                Text("对已导入的系统照片重跑智能筛选，更新保留/待确认/已过滤分桶，不会重复导入照片文件。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("处理进度") {
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

                HStack {
                    Text("保留")
                    Spacer()
                    Text("\(importManager.progress.meaningfulKept)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("待确认")
                    Spacer()
                    Text("\(importManager.progress.reviewBucketCount)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("已过滤")
                    Spacer()
                    Text("\(importManager.progress.filteredArchivedCount)")
                        .foregroundStyle(.secondary)
                }

                if let notice = importManager.progress.lastNotice, !notice.isEmpty {
                    Text("完成提示: \(notice)")
                        .foregroundStyle(.green)
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
            }
        }
        .navigationTitle("智能照片整理")
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
                    // 修改上限后，立即尝试修剪一次
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
