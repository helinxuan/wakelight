import Foundation
import Combine
import MapKit
import GRDB

final class ExploreViewModel: ObservableObject {
    @Published var clusters: [PlaceCluster] = []
    @Published var storyThumbnails: [UUID: String] = [:] // clusterId -> localIdentifier
    
    private let db: AppDatabase
    private var cancellables = Set<AnyCancellable>()
    
    init(db: AppDatabase = DatabaseContainer.shared.db) {
        self.db = db
        observeClusters()
    }

    func loadHalfRevealedClusterIds() async -> Set<UUID> {
        do {
            return try await db.reader.read { db in
                let ids = try UUID.fetchAll(
                    db,
                    sql: "SELECT placeClusterId FROM awakenState WHERE isHalfRevealed = 1"
                )
                return Set(ids)
            }
        } catch {
            print("Failed to load awakenState: \(error)")
            return []
        }
    }

    func markClusterHalfRevealed(placeClusterId: UUID) async {
        let now = Date()
        do {
            try await db.writer.write { db in
                if var existing = try AwakenState.fetchOne(db, sql: "SELECT * FROM awakenState WHERE placeClusterId = ?", arguments: [placeClusterId]) {
                    existing.isHalfRevealed = true
                    existing.awakenedPointCount += 1
                    existing.lastAwakenedAt = now
                    existing.updatedAt = now
                    try existing.update(db)
                } else {
                    var state = AwakenState(placeClusterId: placeClusterId)
                    state.isHalfRevealed = true
                    state.awakenedPointCount = 1
                    state.lastAwakenedAt = now
                    state.updatedAt = now
                    try state.insert(db)
                }
            }
        } catch {
            print("Failed to upsert awakenState: \(error)")
        }
    }
    
    private func observeClusters() {
        ValueObservation
            .tracking { db in
                let clusters = try PlaceCluster.fetchAll(db)
                var thumbnails: [UUID: String] = [:]
                
                for cluster in clusters where cluster.hasStory {
                    // 优化：取最新沉淀的 Story (settledAt DESC) 的第一张图
                    let sql = """
                        SELECT p.localIdentifier 
                        FROM photoAsset p
                        JOIN visitLayerPhotoAsset vlp ON vlp.photoAssetId = p.id
                        JOIN visitLayer vl ON vl.id = vlp.visitLayerId
                        WHERE vl.placeClusterId = ? AND vl.isStoryNode = 1
                        ORDER BY vl.settledAt DESC
                        LIMIT 1
                    """
                    if let localId = try String.fetchOne(db, sql: sql, arguments: [cluster.id]) {
                        thumbnails[cluster.id] = localId
                    }
                }
                return (clusters, thumbnails)
            }
            .publisher(in: db.reader)
            .sink { completion in
                if case .failure(let error) = completion {
                    print("Error observing clusters: \(error)")
                }
            } receiveValue: { [weak self] (clusters, thumbnails) in
                self?.clusters = clusters
                self?.storyThumbnails = thumbnails
            }
            .store(in: &cancellables)
    }
    
    func importPhotos() {
        Task {
            do {
                _ = try await ImportPhotosUseCase().run()
                _ = try await GeneratePlaceClustersUseCase().run()
                _ = try await GenerateVisitLayersUseCase().run()
            } catch {
                print("Failed to import photos: \(error)")
            }
        }
    }

    func generateClustersFromImportedPhotos() {
        Task {
            do {
                _ = try await GeneratePlaceClustersUseCase().run()
            } catch {
                print("Failed to generate clusters: \(error)")
            }
        }
    }
}

// 适配 MKAnnotation
final class ClusterAnnotation: NSObject, MKAnnotation {
    let cluster: PlaceCluster
    let coordinate: CLLocationCoordinate2D
    
    init(cluster: PlaceCluster) {
        self.cluster = cluster
        self.coordinate = CLLocationCoordinate2D(latitude: cluster.centerLatitude, longitude: cluster.centerLongitude)
        super.init()
    }
    
    var title: String? {
        "\(cluster.photoCount) Photos"
    }
}
