import Foundation

final class WebDAVMediaReader: MediaReaderProtocol {
    private let profileProvider: (String) async throws -> WebDAVProfile
    private let passwordProvider: (WebDAVProfile) async throws -> String

    init(
        profileProvider: @escaping (String) async throws -> WebDAVProfile,
        passwordProvider: @escaping (WebDAVProfile) async throws -> String
    ) {
        self.profileProvider = profileProvider
        self.passwordProvider = passwordProvider
    }

    func canHandle(locator: MediaLocator) -> Bool {
        if case .webdav = locator { return true }
        return false
    }

    func read(locator: MediaLocator) async throws -> MediaResource {
        guard case .webdav(let profileId, let remotePath) = locator else {
            throw NSError(domain: "WebDAVMediaReader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid locator type"])
        }

        let profile = try await profileProvider(profileId)
        guard let baseURL = profile.baseURL else {
            throw WebDAVError.invalidBaseURL
        }
        let password = try await passwordProvider(profile)

        let client = WebDAVClient(
            baseURL: baseURL,
            credentials: .init(username: profile.username, password: password)
        )

        // For RAW/large images and videos, avoid returning full Data.
        // Instead, download to a temporary file and return a URL resource.
        let lower = remotePath.lowercased()
        let isVideo = lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") || lower.hasSuffix(".m4v")
        let isLargeImage = lower.hasSuffix(".rw2") || lower.hasSuffix(".dng") || lower.hasSuffix(".nef") || lower.hasSuffix(".arw") || lower.hasSuffix(".cr2") || lower.hasSuffix(".cr3") || lower.hasSuffix(".orf") || lower.hasSuffix(".raf")

        if isVideo || isLargeImage {
            let ext = (remotePath as NSString).pathExtension
            let tempURL = try await client.downloadToTemporaryFile(path: remotePath, fileExtension: ext)
            return .url(tempURL)
        }

        // For small photos, keep the existing Data-based path.
        let data = try await client.get(path: remotePath)
        return .data(data)
    }
}
