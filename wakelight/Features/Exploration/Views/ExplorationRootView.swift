import SwiftUI

struct ExplorationRootView: View {
    @Environment(\.displayScale) private var displayScale

    @StateObject private var viewModel = ExploreViewModel()
    @State private var selectedCluster: PlaceCluster?
    @State private var awakenQueue: [PlaceCluster] = []
    @State private var revealedClusterIds: Set<UUID> = []
    @State private var isAwakenMode: Bool = false
    @State private var showBadges: Bool = false
    @State private var panelHeight: CGFloat = 380
    @State private var panelCityName: String? = nil
    private let minPanelHeight: CGFloat = 120
    private let defaultPanelHeight: CGFloat = 380

    var body: some View {
        ZStack {
            ExplorationMapView(
                viewModel: viewModel,
                selectedCluster: $selectedCluster,
                awakenQueue: $awakenQueue,
                isAwakenMode: $isAwakenMode,
                revealedClusterIds: $revealedClusterIds
            )
            .ignoresSafeArea()
            .task {
                let ids = await viewModel.loadHalfRevealedClusterIds()
                revealedClusterIds = ids
            }

            if isAwakenMode {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: {
                            selectedCluster = nil
                            awakenQueue.removeAll()
                            isAwakenMode = false
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundColor(.white.opacity(0.9))
                                .shadow(radius: 8)
                        }
                        .padding(.top, 8)
                        .padding(.trailing, 14)
                    }
                    Spacer()
                }
            }

            VStack(spacing: 0) {
                Spacer()

                if !isAwakenMode {
                    HStack(spacing: 12) {
                        Button(action: {
                            showBadges = true
                        }) {
                            Label("Badges", systemImage: "medal.fill")
                                .padding()
                                .background(Color.black.opacity(0.7))
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }

                        Button(action: {
                            viewModel.importPhotos()
                        }) {
                            Label("Import Photos", systemImage: "photo.on.rectangle")
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                    }
                    .padding()
                }

                if !awakenQueue.isEmpty, isAwakenMode {
                    VStack(spacing: 0) {
                        let headerHeight: CGFloat = 56

                        VStack(spacing: 0) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.45))
                                .frame(width: 36, height: 5)
                                .padding(.top, 10)
                                .padding(.bottom, 8)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                        .background(Color(.systemBackground))
                        .task(id: awakenQueue.map(\.id)) {
                            if let first = awakenQueue.first {
                                let name = try? await ResolvePlaceClusterCityNameUseCase().resolveCityName(for: first)
                                await MainActor.run {
                                    self.panelCityName = name
                                }
                            } else {
                                await MainActor.run {
                                    self.panelCityName = nil
                                }
                            }
                        }
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let newHeight = panelHeight - value.translation.height
                                    panelHeight = max(minPanelHeight, min(defaultPanelHeight + 40, newHeight))
                                }
                                .onEnded { _ in
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        if panelHeight < (defaultPanelHeight + minPanelHeight) / 2 {
                                            panelHeight = minPanelHeight
                                        } else {
                                            panelHeight = defaultPanelHeight
                                        }
                                    }
                                }
                        )

                        // 始终保留 MemoryPanelView 以维持其内部多选状态，仅通过高度和透明度控制视觉隐藏
                        MemoryPanelView(clusters: awakenQueue, selectedClusterId: selectedCluster?.id)
                            .opacity(panelHeight > minPanelHeight + 20 ? 1 : 0)
                            .frame(maxHeight: panelHeight > minPanelHeight + 20 ? .infinity : 0)
                            .clipped()
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: panelHeight)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: Color.black.opacity(0.15), radius: 20, x: 0, y: -5)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                    .transition(.asymmetric(insertion: .move(edge: .bottom), removal: .opacity))
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .animation(.easeInOut(duration: 0.22), value: awakenQueue.map(\.id))
        .sheet(isPresented: $showBadges) {
            BadgeWallView()
        }
    }
}

struct ExplorationRootView_Previews: PreviewProvider {
    static var previews: some View {
        ExplorationRootView()
    }
}
