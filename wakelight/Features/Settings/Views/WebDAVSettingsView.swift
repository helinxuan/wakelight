import SwiftUI

struct WebDAVSettingsView: View {
    @StateObject var viewModel: WebDAVSettingsViewModel

    var body: some View {
        Form {
            Section("服务器") {
                TextField("Base URL", text: $viewModel.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)

                NavigationLink {
                    WebDAVFolderPickerView(
                        viewModel: WebDAVFolderPickerViewModel(initialPath: viewModel.rootPath) {
                            guard let url = URL(string: viewModel.baseURL) else {
                                throw WebDAVError.invalidBaseURL
                            }
                            return WebDAVClient(
                                baseURL: url,
                                credentials: .init(username: viewModel.username, password: viewModel.password)
                            )
                        },
                        onSelect: { paths in
                            // 这里暂时只取第一个作为根目录，后续你可以改为保存多目录配置
                            if let first = paths.first {
                                viewModel.rootPath = WebDAVPath.normalizeDirectory(first)
                            }
                        }
                    )
                } label: {
                    HStack {
                        Text("根目录")
                        Spacer()
                        Text(viewModel.rootPath.isEmpty ? "/" : "/" + WebDAVPath.normalizeDirectory(viewModel.rootPath))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
