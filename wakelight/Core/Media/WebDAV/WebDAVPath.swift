import Foundation

enum WebDAVPath {
    static func normalizeDirectory(_ path: String) -> String {
        let trimmed = normalizeFile(path)
        return trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
    }

    static func normalizeFile(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }

    static func parentDirectory(of directoryPath: String) -> String? {
        var p = normalizeDirectory(directoryPath)
        if p.isEmpty { return nil }
        if p.hasSuffix("/") { p.removeLast() }
        if let idx = p.lastIndex(of: "/") {
            return String(p[..<idx])
        }
        return ""
    }

    static func hrefToRelativePath(href: String, baseURL: URL) -> String {
        let decoded = href.removingPercentEncoding ?? href

        if let hrefURL = URL(string: decoded), let baseHost = baseURL.host, hrefURL.host == baseHost {
            let basePath = baseURL.path
            let hrefPath = hrefURL.path
            if hrefPath.hasPrefix(basePath) {
                let rel = String(hrefPath.dropFirst(basePath.count))
                return normalizeFile(rel)
            }
        }

        return normalizeFile(decoded)
    }
}
