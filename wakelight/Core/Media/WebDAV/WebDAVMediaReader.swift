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

        let data = try await client.get(path: remotePath)
        return .data(data)
    }
}
