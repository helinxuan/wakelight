import SwiftUI

private struct FolderRow: View {
    let name: String
    let normalizedPath: String
    let isSelected: Bool
    let onEnter: () -> Void
    let onToggleSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            // 左侧：点按进入目录
            HStack(spacing: 12) {
                Image(systemName: "folder")
                Text(name)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onEnter)

            // 右侧：点圈直接选择/取消（扩大可点击区域）
            Button {
                onToggleSelect(normalizedPath)
            } label: {
                Group {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    } else {
                        Image(systemName: "circle")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        // 仍然保留长按切换，符合相册那种手感
        .onLongPressGesture { onToggleSelect(normalizedPath) }
    }
}

struct WebDAVFolderPickerView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: WebDAVFolderPickerViewModel
    @State private var selectedPaths: Set<String> = []
    /// 返回选中的所有目录（normalized path）
    let onSelect: ([String]) -> Void

    var body: some View {
        List {
            Section {
                HStack {
                    Text("当前路径")
                    Spacer()
                    Text(displayPath(viewModel.currentPath))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if !selectedPaths.isEmpty {
                Section("已选择 (\(selectedPaths.count))") {
                    ForEach(Array(selectedPaths).sorted(), id: \.self) { path in
                        HStack {
                            Text(path.isEmpty ? "/" : "/" + path)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                selectedPaths.remove(path)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Section {
                if viewModel.isLoading {
                    HStack {
                        ProgressView()
                        Text("加载中...")
                    }
                } else if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                } else if viewModel.folders.isEmpty {
                    Text("无子文件夹")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.folders) { folder in
                        let normalizedPath = WebDAVPath.normalizeDirectory(folder.path)
                        let isSelected = selectedPaths.contains(normalizedPath)

                        FolderRow(
                            name: folder.name,
                            normalizedPath: normalizedPath,
                            isSelected: isSelected,
                            onEnter: {
                                viewModel.goInto(folder)
                                Task { await viewModel.load() }
                            },
                            onToggleSelect: { path in
                                toggleSelection(for: path)
                            }
                        )
                    }
                }
            } header: {
                Text("子文件夹（点按进入，点右侧圆圈/长按多选）")
            }
        }
        .navigationTitle("选择文件夹")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("上一级") {
                    viewModel.goUp()
                    Task { await viewModel.load() }
                }
                .disabled(WebDAVPath.normalizeDirectory(viewModel.currentPath).isEmpty)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") {
                    onSelect(Array(selectedPaths).sorted())
                    dismiss()
                }
                .disabled(selectedPaths.isEmpty)
            }
        }
        .task(id: viewModel.currentPath) {
            await viewModel.load()
        }
    }

    private func displayPath(_ normalized: String) -> String {
        let p = WebDAVPath.normalizeDirectory(normalized)
        return p.isEmpty ? "/" : "/" + p
    }

    private func toggleSelection(for path: String) {
        if selectedPaths.contains(path) {
            selectedPaths.remove(path)
        } else {
            selectedPaths.insert(path)
        }
    }
}
