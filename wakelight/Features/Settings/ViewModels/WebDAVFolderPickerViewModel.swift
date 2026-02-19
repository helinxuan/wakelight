import Foundation
import Combine
import Combine

@MainActor
final class WebDAVFolderPickerViewModel: ObservableObject {
    struct FolderItem: Identifiable, Hashable {
        let id: String
        let name: String
        let path: String
    }

    @Published var currentPath: String
    @Published var isLoading: Bool = false
    @Published var folders: [FolderItem] = []
    @Published var errorMessage: String?

    private let clientProvider: () throws -> WebDAVClient

    init(initialPath: String = "", clientProvider: @escaping () throws -> WebDAVClient) {
        self.currentPath = WebDAVPath.normalizeDirectory(initialPath)
        self.clientProvider = clientProvider
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let client = try clientProvider()
            // Ensure path starts with /
            let requestPath = currentPath.hasPrefix("/") ? currentPath : "/" + currentPath
            let items = try await client.propfind(path: requestPath, depth: "1")

            var next: [FolderItem] = []
            next.reserveCapacity(items.count)

            for item in items {
                guard item.isCollection else { continue }

                // href is already percent-decoded by parser
                let rel = WebDAVPath.hrefToRelativePath(href: item.href, baseURL: client.baseURL)
                let normalized = WebDAVPath.normalizeDirectory(rel)

                // Skip self by comparing normalized paths
                let normCurrent = WebDAVPath.normalizeDirectory(currentPath)
                let normItem = WebDAVPath.normalizeDirectory(normalized)
                if normItem == normCurrent { continue }

                let name = item.displayName?.isEmpty == false ? item.displayName! : normalized.split(separator: "/").last.map(String.init) ?? "/"
                next.append(.init(id: normalized, name: name, path: normalized))
            }

            folders = next.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            folders = []
            errorMessage = error.localizedDescription
            print("[WebDAV] Folder load failed: \(error)")
        }
    }

    func goInto(_ folder: FolderItem) {
        currentPath = WebDAVPath.normalizeDirectory(folder.path)
    }

    func goUp() {
        if currentPath == "/" || currentPath.isEmpty { return }
        guard let parent = WebDAVPath.parentDirectory(of: currentPath) else {
            currentPath = ""
            return
        }
        currentPath = WebDAVPath.normalizeDirectory(parent)
    }
}
