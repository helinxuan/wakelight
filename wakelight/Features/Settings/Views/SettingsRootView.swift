import SwiftUI

struct SettingsRootView: View {
    var body: some View {
        NavigationStack {
            List {
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
