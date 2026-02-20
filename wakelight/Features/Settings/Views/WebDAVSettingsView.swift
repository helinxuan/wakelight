import SwiftUI

struct WebDAVSettingsView: View {
    @StateObject var viewModel: WebDAVSettingsViewModel

    private var selectedPathsSummary: String {
        let paths = viewModel.rootPaths
            .map { WebDAVPath.normalizeDirectory($0) }
            .filter { !$0.isEmpty }

        if paths.isEmpty {
            return "/"
        }
        if paths.count == 1 {
            return "/" + paths[0]
        }
        // Show count for multi-select to avoid overly long trailing text
        return "已选择 \(paths.count) 个目录"
    }

    var body: some View {
        Form {
            Section("服务器") {
                TextField("Base URL", text: $viewModel.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)

                NavigationLink {
                    WebDAVFolderPickerView(
                        viewModel: WebDAVFolderPickerViewModel(
                            initialPath: viewModel.rootPaths.first ?? viewModel.rootPath
                        ) {
                            guard let url = URL(string: viewModel.baseURL) else {
                                throw WebDAVError.invalidBaseURL
                            }
                            return WebDAVClient(
                                baseURL: url,
                                credentials: .init(username: viewModel.username, password: viewModel.password)
                            )
                        },
                        onSelect: { paths in
                            // Multi-root: store all selected directories
                            let normalized = paths
                                .map { WebDAVPath.normalizeDirectory($0) }
                                .filter { !$0.isEmpty }
                            viewModel.rootPaths = normalized
                            viewModel.rootPath = normalized.first ?? ""
                        }
                    )
                } label: {
                    HStack {
                        Text("导入目录")
                        Spacer()
                        Text(selectedPathsSummary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if !viewModel.rootPaths.isEmpty {
                    Section("已选择目录") {
                        ForEach(viewModel.rootPaths
                            .map { WebDAVPath.normalizeDirectory($0) }
                            .filter { !$0.isEmpty }, id: \.self) { path in
                            Text("/" + path)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }

                        Button(role: .destructive) {
                            viewModel.rootPaths = []
                            viewModel.rootPath = ""
                        } label: {
                            Text("清空已选目录")
                        }
                    }
                }
            }

            Section("账号") {
                TextField("用户名", text: $viewModel.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                SecureField("密码", text: $viewModel.password)
            }

            Section {
                Button {
                    Task { await viewModel.testConnection() }
                } label: {
                    if viewModel.isTesting {
                        HStack {
                            ProgressView()
                            Text("测试连接中...")
                        }
                    } else {
                        Text("测试连接")
                    }
                }
                .disabled(viewModel.isTesting)

                Button {
                    Task { await viewModel.save() }
                } label: {
                    if viewModel.isSaving {
                        HStack {
                            ProgressView()
                            Text("保存中...")
                        }
                    } else {
                        Text("保存")
                    }
                }
                .disabled(!viewModel.isSuccess || viewModel.isSaving)
            }

            if let result = viewModel.testResult {
                Section("结果") {
                    Text(result)
                        .foregroundStyle(viewModel.isSuccess ? .green : .red)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("WebDAV")
    }
}
