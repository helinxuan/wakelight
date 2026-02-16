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

    init() {
        observeStoryNodes()
    }

    private func observeStoryNodes() {
        // 监听 StoryNode 表的变化，一旦有新故事产生或被修改，自动重新加载
        ValueObservation.tracking { db in
            try StoryNode.fetchAll(db)
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
}
