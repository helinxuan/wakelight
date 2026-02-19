import Foundation
import Photos
import UIKit

enum MediaResource {
    case data(Data)
    case url(URL)
    case phAsset(PHAsset)
}

protocol MediaReaderProtocol {
    func canHandle(locator: MediaLocator) -> Bool
    func read(locator: MediaLocator) async throws -> MediaResource
}

final class PhotosMediaReader: MediaReaderProtocol {
    func canHandle(locator: MediaLocator) -> Bool {
        if case .library = locator { return true }
        return false
    }

    func read(locator: MediaLocator) async throws -> MediaResource {
        guard case .library(let id) = locator else {
            throw NSError(domain: "MediaReader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid locator type"])
        }
        
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = assets.firstObject else {
            throw NSError(domain: "MediaReader", code: -404, userInfo: [NSLocalizedDescriptionKey: "PHAsset not found"])
        }
        return .phAsset(asset)
    }
}

final class LocalFileMediaReader: MediaReaderProtocol {
    func canHandle(locator: MediaLocator) -> Bool {
        if case .file = locator { return true }
        return false
    }

    func read(locator: MediaLocator) async throws -> MediaResource {
        guard case .file(let url) = locator else {
            throw NSError(domain: "MediaReader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid locator type"])
        }
        return .url(url)
    }
}

final class MediaResolver {
    static let shared = MediaResolver()
    private var readers: [MediaReaderProtocol] = [
        PhotosMediaReader(),
        LocalFileMediaReader()
    ]

    func register(reader: MediaReaderProtocol) {
        readers.append(reader)
    }

    func resolve(locator: MediaLocator) async throws -> MediaResource {
        for reader in readers {
            if reader.canHandle(locator: locator) {
                return try await reader.read(locator: locator)
            }
        }
        throw NSError(domain: "MediaResolver", code: -404, userInfo: [NSLocalizedDescriptionKey: "No reader found for locator"])
    }
}
