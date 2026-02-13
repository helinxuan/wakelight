import Foundation
import Photos

struct PhotosImportResult {
    var importedCount: Int
}

protocol PhotosImportServiceProtocol {
    func fetchAssets(limit: Int?) async throws -> [PHAsset]
}

final class PhotosImportService: PhotosImportServiceProtocol {
    func fetchAssets(limit: Int?) async throws -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let fetchResult = PHAsset.fetchAssets(with: options)
        if fetchResult.count == 0 { return [] }

        var assets: [PHAsset] = []
        assets.reserveCapacity(min(fetchResult.count, limit ?? fetchResult.count))

        let maxCount = limit ?? fetchResult.count
        var index = 0
        fetchResult.enumerateObjects { asset, _, stop in
            assets.append(asset)
            index += 1
            if index >= maxCount {
                stop.pointee = true
            }
        }

        return assets
    }
}
