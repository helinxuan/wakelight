import Foundation

enum MediaLocator: Hashable, Codable {
    case library(localIdentifier: String)
    case file(url: URL)
    case webdav(profileId: String, remotePath: String)

    init(localIdentifier: String) {
        self = .library(localIdentifier: localIdentifier)
    }

    var stableKey: String {
        switch self {
        case .library(let id):
            return "library://\(id)"
        case .file(let url):
            return url.absoluteString
        case .webdav(let profileId, let remotePath):
            return "webdav://\(profileId)/\(remotePath)"
        }
    }

    static func parse(_ raw: String) -> MediaLocator? {
        if raw.hasPrefix("library://") {
            return .library(localIdentifier: String(raw.dropFirst("library://".count)))
        }
        if raw.hasPrefix("webdav://") {
            let rest = raw.dropFirst("webdav://".count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            let profileId = String(rest[..<slash])
            let path = String(rest[rest.index(after: slash)...])
            return .webdav(profileId: profileId, remotePath: path)
        }
        if let url = URL(string: raw), url.isFileURL {
            return .file(url: url)
        }
        return nil
    }
}
