import Foundation

struct WebDAVCredentials {
    let username: String
    let password: String
}

struct WebDAVDirectoryItem: Sendable {
    let href: String
    let isCollection: Bool
    let displayName: String?
    let contentType: String?
    let contentLength: Int?
    let etag: String?
    let lastModified: Date?
}

enum WebDAVError: Error {
    case invalidBaseURL
    case invalidResponse
    case httpStatus(Int)
    case parseError(String)
}

final class WebDAVClient {
    let baseURL: URL
    private let credentials: WebDAVCredentials
    private let session: URLSession

    init(baseURL: URL, credentials: WebDAVCredentials, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.session = session
    }

    func propfind(path: String, depth: String = "1") async throws -> [WebDAVDirectoryItem] {
        let url = try makeURL(path: path)
        print("[WebDAVClient] PROPFIND Request: \(url.absoluteString) (depth: \(depth))")
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.setValue(basicAuthHeader(), forHTTPHeaderField: "Authorization")

        let body = Self.propfindBody
        request.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { 
                print("[WebDAVClient] PROPFIND Error: Not an HTTP response")
                throw WebDAVError.invalidResponse 
            }
            print("[WebDAVClient] PROPFIND Response Status: \(http.statusCode)")
            
            guard (200...299).contains(http.statusCode) || http.statusCode == 207 else {
                print("[WebDAVClient] PROPFIND Error: HTTP \(http.statusCode)")
                throw WebDAVError.httpStatus(http.statusCode)
            }

            let items = try WebDAVPropfindParser.parse(data: data)
            print("[WebDAVClient] PROPFIND Parsed \(items.count) items")
            return items
        } catch {
            print("[WebDAVClient] PROPFIND Exception: \(error.localizedDescription)")
            throw error
        }
    }

    func get(path: String) async throws -> Data {
        let url = try makeURL(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(basicAuthHeader(), forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw WebDAVError.httpStatus(http.statusCode)
        }
        return data
    }

    /// Downloads a remote resource to a local temporary file.
    /// This avoids holding large files (RAW/video) entirely in memory.
    func downloadToTemporaryFile(path: String, fileExtension: String? = nil) async throws -> URL {
        let url = try makeURL(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(basicAuthHeader(), forHTTPHeaderField: "Authorization")

        let (tempURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw WebDAVError.httpStatus(http.statusCode)
        }

        // Move into our own temp location so the caller can manage lifetime.
        let ext = (fileExtension?.isEmpty == false) ? fileExtension! : "tmp"
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    private func makeURL(path: String) throws -> URL {
        // Normalize base URL to always end with a slash so relative paths resolve correctly.
        var base = baseURL
        if !base.absoluteString.hasSuffix("/") {
            base.appendPathComponent("")
        }

        // If caller passes "/", we should hit the base URL itself.
        if path == "/" || path.isEmpty {
            return base
        }

        // If caller passes an absolute URL, allow it.
        if let absolute = URL(string: path), absolute.scheme != nil {
            return absolute
        }

        // Otherwise treat as a relative path.
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: relative, relativeTo: base) else {
            throw WebDAVError.invalidBaseURL
        }
        return url
    }

    private func basicAuthHeader() -> String {
        let raw = "\(credentials.username):\(credentials.password)"
        let encoded = Data(raw.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    private static let propfindBody = """
    <?xml version=\"1.0\" encoding=\"utf-8\" ?>
    <d:propfind xmlns:d=\"DAV:\">
      <d:prop>
        <d:displayname />
        <d:getcontenttype />
        <d:getcontentlength />
        <d:getetag />
        <d:getlastmodified />
        <d:resourcetype />
      </d:prop>
    </d:propfind>
    """
}
