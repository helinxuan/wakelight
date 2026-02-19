import SwiftUI

struct WebDAVFolderPickerView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: WebDAVFolderPickerViewModel
    let onSelect: (String) -> Void

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
                        Button {
                            viewModel.goInto(folder)
                            Task { await viewModel.load() }
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                Text(folder.name)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } header: {
                Text("子文件夹")
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
                Button("选择") {
                    onSelect(WebDAVPath.normalizeDirectory(viewModel.currentPath))
                }
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
}
