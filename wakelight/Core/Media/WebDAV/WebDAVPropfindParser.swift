import Foundation

final class WebDAVPropfindParser: NSObject {
    private struct CurrentResponse {
        var href: String?
        var displayName: String?
        var contentType: String?
        var contentLength: Int?
        var etag: String?
        var lastModifiedString: String?
        var isCollection: Bool = false
    }

    private var items: [WebDAVDirectoryItem] = []

    private var currentResponse: CurrentResponse?
    private var currentElementPath: [String] = []
    private var currentText: String = ""

    static func parse(data: Data) throws -> [WebDAVDirectoryItem] {
        let parser = XMLParser(data: data)
        let delegate = WebDAVPropfindParser()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            throw WebDAVError.parseError(parser.parserError?.localizedDescription ?? "Unknown XML parse error")
        }

        return delegate.items
    }

    private static let rfc1123Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    /// Normalize a PROPFIND href into a stable server path.
    ///
    /// Handles:
    /// - Absolute href (e.g. "http://host:port/photo/a.jpg")
    /// - Path-only href (e.g. "/photo/a.jpg")
    /// - Removes query/fragment (e.g. "/photo/#recycle/" -> "/photo/")
    /// - Percent-decodes
    static func normalizeHref(_ href: String) -> String {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }

        if let url = URL(string: trimmed), url.scheme != nil {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.query = nil
            comps?.fragment = nil
            let path = comps?.percentEncodedPath ?? url.path
            return (path.removingPercentEncoding ?? path).isEmpty ? "/" : (path.removingPercentEncoding ?? path)
        }

        // Treat as a path. Use URLComponents to strip query/fragment if present.
        if var comps = URLComponents(string: trimmed) {
            comps.query = nil
            comps.fragment = nil
            let path = comps.percentEncodedPath
            let decoded = path.removingPercentEncoding ?? path
            if decoded.isEmpty { return "/" }
            return decoded.hasPrefix("/") ? decoded : "/" + decoded
        }

        let decoded = trimmed.removingPercentEncoding ?? trimmed
        if decoded.isEmpty { return "/" }
        return decoded.hasPrefix("/") ? decoded : "/" + decoded
    }

    private func flushCurrentResponseIfNeeded() {
        guard let r = currentResponse else { return }
        guard let href = r.href else { return }

        let lastModified: Date?
        if let s = r.lastModifiedString {
            lastModified = Self.rfc1123Formatter.date(from: s.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            lastModified = nil
        }

        let normalizedHref = WebDAVPropfindParser.normalizeHref(href)

        let item = WebDAVDirectoryItem(
            href: normalizedHref,
            isCollection: r.isCollection,
            displayName: r.displayName?.removingPercentEncoding ?? r.displayName,
            contentType: r.contentType,
            contentLength: r.contentLength,
            etag: r.etag,
            lastModified: lastModified
        )
        items.append(item)
    }
}

extension WebDAVPropfindParser: XMLParserDelegate {
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElementPath.append(elementName.lowercased())
        currentText = ""

        if elementName.lowercased() == "response" {
            currentResponse = CurrentResponse()
        }

        if elementName.lowercased() == "collection" {
            currentResponse?.isCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        func pathEnds(with suffix: [String]) -> Bool {
            guard currentElementPath.count >= suffix.count else { return false }
            return Array(currentElementPath.suffix(suffix.count)) == suffix
        }

        if name == "href", pathEnds(with: ["response", "href"]) {
            currentResponse?.href = text
        } else if name == "displayname" {
            currentResponse?.displayName = text
        } else if name == "getcontenttype" {
            currentResponse?.contentType = text
        } else if name == "getcontentlength" {
            currentResponse?.contentLength = Int(text)
        } else if name == "getetag" {
            currentResponse?.etag = text
        } else if name == "getlastmodified" {
            currentResponse?.lastModifiedString = text
        }

        if name == "response" {
            flushCurrentResponseIfNeeded()
            currentResponse = nil
        }

        _ = currentElementPath.popLast()
        currentText = ""
    }
}
