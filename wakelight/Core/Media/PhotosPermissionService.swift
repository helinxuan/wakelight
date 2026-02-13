import Foundation
import Photos

enum PhotosPermissionStatus {
    case notDetermined
    case restricted
    case denied
    case authorized
    case limited
}

protocol PhotosPermissionServiceProtocol {
    func currentStatus() -> PhotosPermissionStatus
    func requestAuthorization() async -> PhotosPermissionStatus
}

final class PhotosPermissionService: PhotosPermissionServiceProtocol {
    func currentStatus() -> PhotosPermissionStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return map(status)
    }

    func requestAuthorization() async -> PhotosPermissionStatus {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return map(status)
    }

    private func map(_ status: PHAuthorizationStatus) -> PhotosPermissionStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .limited
        @unknown default:
            return .denied
        }
    }
}
