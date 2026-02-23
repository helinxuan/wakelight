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

                    NavigationLink("Import Photos") {
                        ImportPhotosSettingsView()
                    }
                }
            }
            .navigationTitle("设置")
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
