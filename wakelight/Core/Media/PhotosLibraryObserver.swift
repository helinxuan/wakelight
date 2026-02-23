import Foundation
import Photos

/// Observes iOS Photos library changes and triggers incremental imports.
///
/// - Design: Core-layer service. It does not touch SwiftUI directly.
/// - It forwards changes via closures so higher layers (e.g. PhotoImportManager) decide what to do.
@MainActor
final class PhotosLibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    struct ChangeSet {
        var insertedLocalIdentifiers: [String] = []
        var changedLocalIdentifiers: [String] = []
        var removedLocalIdentifiers: [String] = []

        var isEmpty: Bool {
            insertedLocalIdentifiers.isEmpty && changedLocalIdentifiers.isEmpty && removedLocalIdentifiers.isEmpty
        }
    }

    static let shared = PhotosLibraryObserver()

    /// Called when Photos changes are detected.
    /// Note: May be called frequently; consumer should debounce if needed.
    var onChange: ((ChangeSet) -> Void)?

    /// A fetch result used as the baseline for change details.
    private var fetchResult: PHFetchResult<PHAsset>?

    private override init() {
        super.init()
    }

    func start() {
        // Keep a baseline fetchResult. Fetching all assets is OK here; Photos internally optimizes.
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        fetchResult = PHAsset.fetchAssets(with: options)

        PHPhotoLibrary.shared().register(self)
        print("[PhotosObserver] started")
    }

    func stop() {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        fetchResult = nil
        print("[PhotosObserver] stopped")
    }

    // MARK: - PHPhotoLibraryChangeObserver

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        guard let fetchResult else { return }
        guard let details = changeInstance.changeDetails(for: fetchResult) else { return }

        // Update baseline first.
        self.fetchResult = details.fetchResultAfterChanges

        var set = ChangeSet()

        // Insertions and removals are available through change details.
        if let removed = details.removedObjects as [PHAsset]? {
            set.removedLocalIdentifiers = removed.map { $0.localIdentifier }
        }
        if let inserted = details.insertedObjects as [PHAsset]? {
            set.insertedLocalIdentifiers = inserted.map { $0.localIdentifier }
        }
        if let changed = details.changedObjects as [PHAsset]? {
            set.changedLocalIdentifiers = changed.map { $0.localIdentifier }
        }

        if set.isEmpty { return }

        DispatchQueue.main.async {
            self.onChange?(set)
        }
    }
}
