import Foundation
import Combine
import MapKit

@MainActor
final class TimeTravelViewModel: ObservableObject {
    @Published var nodes: [TimeRouteNode] = []
    @Published var selectedIndex: Int = 0
    @Published var isPlaying: Bool = false

    private var playTask: Task<Void, Never>?

    init() {
        Task {
            await reload()
        }
    }

    func reload() async {
        do {
            let newNodes = try await GenerateTimeRouteUseCase().run()
            nodes = newNodes
            if selectedIndex >= nodes.count {
                selectedIndex = max(0, nodes.count - 1)
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
