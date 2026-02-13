import Foundation
import Combine
import MapKit
import GRDB

final class ExploreViewModel: ObservableObject {
    @Published var clusters: [PlaceCluster] = []
    
    private let db: AppDatabase
    private var cancellables = Set<AnyCancellable>()
    
    init(db: AppDatabase = DatabaseContainer.shared.db) {
        self.db = db
        observeClusters()
    }
    
    private func observeClusters() {
        // 监听数据库中 PlaceCluster 表的变化
        ValueObservation
            .tracking { db in
                try PlaceCluster.fetchAll(db)
            }
            .publisher(in: db.reader)
            .sink { completion in
                if case .failure(let error) = completion {
                    print("Error observing clusters: \(error)")
                }
            } receiveValue: { [weak self] clusters in
                self?.clusters = clusters
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
