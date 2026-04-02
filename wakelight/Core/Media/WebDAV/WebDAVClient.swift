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

    init(baseURL: URL, credentials: WebDAVCredentials, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.credentials = credentials

        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            // 5G/内网穿透等高延迟环境：放宽超时，避免大文件频繁 -1001。
            config.timeoutIntervalForRequest = 90
            config.timeoutIntervalForResource = 15 * 60
            config.waitsForConnectivity = true
            config.allowsExpensiveNetworkAccess = true
            config.allowsConstrainedNetworkAccess = true
            self.session = URLSession(configuration: config)
        }
    }

    func propfind(path: String, depth: String = "1") async throws -> [WebDAVDirectoryItem] {
        let url = try makeURL(path: path)
        // print("[WebDAVClient] PROPFIND Request: \(url.absoluteString) (depth: \(depth))")
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
            // print("[WebDAVClient] PROPFIND Response Status: \(http.statusCode)")
            
            guard (200...299).contains(http.statusCode) || http.statusCode == 207 else {
                print("[WebDAVClient] PROPFIND Error: HTTP \(http.statusCode)")
                throw WebDAVError.httpStatus(http.statusCode)
            }

            let items = try WebDAVPropfindParser.parse(data: data)
            // print("[WebDAVClient] PROPFIND Parsed \(items.count) items")
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

        return try await withRetry(operation: "GET", path: path) {
            let (data, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
            guard (200...299).contains(http.statusCode) else {
                throw WebDAVError.httpStatus(http.statusCode)
            }
            return data
        }
    }

    /// Downloads a remote resource to a local temporary file.
    /// This avoids holding large files (RAW/video) entirely in memory.
    func downloadToTemporaryFile(path: String, fileExtension: String? = nil) async throws -> URL {
        let url = try makeURL(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(basicAuthHeader(), forHTTPHeaderField: "Authorization")

        return try await withRetry(operation: "DOWNLOAD", path: path) {
            let (tempURL, response) = try await self.session.download(for: request)
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

    private func withRetry<T>(operation: String, path: String, maxAttempts: Int = 3, work: @escaping () async throws -> T) async throws -> T {
        var attempt = 0
        var lastError: Error?

        while attempt < maxAttempts {
            attempt += 1
            do {
                return try await work()
            } catch {
                lastError = error

                let shouldRetry: Bool = {
                    if let urlError = error as? URLError {
                        switch urlError.code {
                        case .timedOut, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .notConnectedToInternet, .dnsLookupFailed:
                            return true
                        default:
                            return false
                        }
                    }

                    let nsError = error as NSError
                    if nsError.domain == NSURLErrorDomain {
                        switch nsError.code {
                        case NSURLErrorTimedOut,
                             NSURLErrorNetworkConnectionLost,
                             NSURLErrorCannotFindHost,
                             NSURLErrorCannotConnectToHost,
                             NSURLErrorNotConnectedToInternet,
                             NSURLErrorDNSLookupFailed:
                            return true
                        default:
                            return false
                        }
                    }

                    return false
                }()

                if !shouldRetry || attempt >= maxAttempts {
                    throw error
                }

                let backoff = UInt64(pow(2.0, Double(attempt - 1)) * 1_000_000_000)
                print("[WebDAVClient] \(operation) retry \(attempt)/\(maxAttempts) path=\(path) error=\(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: backoff)
            }
        }

        throw lastError ?? WebDAVError.invalidResponse
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
