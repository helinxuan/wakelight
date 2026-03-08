import Foundation
import Combine
import MapKit
import GRDB

@MainActor
final class TimeTravelViewModel: ObservableObject {
    @Published var nodes: [TimeRouteNode] = []
    @Published var selectedIndex: Int = 0
    @Published var isPlaying: Bool = false

    private var playTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private let resolvePlaceClusterCityNameUseCase = ResolvePlaceClusterCityNameUseCase()
    private var inFlightBackfillClusterIDs = Set<UUID>()
    private var attemptedBackfillClusterIDs = Set<UUID>()

    init() {
        observeStoryNodes()
    }

    private func observeStoryNodes() {
        // 监听 StoryNode + VisitLayer + PlaceCluster 的变化，避免时光模式地点文案不刷新。
        ValueObservation.tracking { db in
            let stories = try StoryNode.fetchAll(db)

            for story in stories {
                let layerIds = story.subVisitLayerIds
                guard !layerIds.isEmpty else { continue }

                let layers = try VisitLayer.fetchAll(db, keys: layerIds)
                for layer in layers {
                    _ = try PlaceCluster.fetchOne(db, key: layer.placeClusterId)
                }

                _ = try PlaceCluster.fetchOne(db, key: story.placeClusterId)
            }

            return stories.map(\.id)
        }
        .publisher(in: DatabaseContainer.shared.db.reader)
        .sink { completion in
            if case .failure(let error) = completion {
                print("Observation failed: \(error)")
            }
        } receiveValue: { [weak self] _ in
            Task { @MainActor in
                await self?.reload()
            }
        }
        .store(in: &cancellables)
    }

    func reload() async {
        do {
            let newNodes = try await GenerateTimeRouteUseCase().run()
            // 如果节点数量发生变化，才重置选择索引
            if newNodes.count != nodes.count {
                nodes = newNodes
                if selectedIndex >= nodes.count {
                    selectedIndex = max(0, nodes.count - 1)
                }
            } else {
                nodes = newNodes
            }

            triggerLocationBackfillIfNeeded(for: newNodes)
        } catch {
            print("Failed to load time route: \(error)")
            nodes = []
            selectedIndex = 0
        }
    }

    func select(index: Int) {
        guard nodes.indices.contains(index) else { return }
        selectedIndex = index
    }

    func play(stepSeconds: TimeInterval = 2.2) {
        guard !nodes.isEmpty else { return }
        isPlaying = true
        playTask?.cancel()
        playTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(stepSeconds * 1_000_000_000))
                if Task.isCancelled { return }
                if self.selectedIndex < self.nodes.count - 1 {
                    self.selectedIndex += 1
                } else {
                    self.isPlaying = false
                    return
                }
            }
        }
    }

    func pause() {
        isPlaying = false
        playTask?.cancel()
        playTask = nil
    }

    private func triggerLocationBackfillIfNeeded(for nodes: [TimeRouteNode]) {
        for node in nodes {
            guard let cluster = node.placeCluster else { continue }
            guard needsBackfill(cluster: cluster) else { continue }
            guard !attemptedBackfillClusterIDs.contains(cluster.id) else { continue }
            guard !inFlightBackfillClusterIDs.contains(cluster.id) else { continue }

            attemptedBackfillClusterIDs.insert(cluster.id)
            inFlightBackfillClusterIDs.insert(cluster.id)

            Task { [weak self] in
                guard let self else { return }
                defer {
                    Task { @MainActor [weak self] in
                        self?.inFlightBackfillClusterIDs.remove(cluster.id)
                    }
                }

                do {
                    _ = try await self.resolvePlaceClusterCityNameUseCase.resolveCityName(for: cluster)
                    _ = try await self.resolvePlaceClusterCityNameUseCase.resolveDetailedAddress(for: cluster)
                } catch {
                    print("[TimeTravel][Backfill][Error] cluster=\(cluster.id) error=\(error)")
                }
            }
        }
    }

    private func needsBackfill(cluster: PlaceCluster) -> Bool {
        let city = cluster.cityName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detailed = cluster.detailedAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let cityMissing = city.isEmpty || city == "未知城市"
        let detailedMissing = detailed.isEmpty || detailed == "未知地点"

        return cityMissing || detailedMissing
    }
}
