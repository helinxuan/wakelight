import SwiftUI

struct ExplorationRootView: View {
    @StateObject private var viewModel = ExploreViewModel()
    @State private var selectedCluster: PlaceCluster?
    @State private var showBadges: Bool = false

    var body: some View {
        ZStack {
            ExplorationMapView(viewModel: viewModel, selectedCluster: $selectedCluster)
                .ignoresSafeArea()

            VStack {
                Spacer()
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
        }
        .sheet(item: $selectedCluster) { cluster in
            MemoryPanelView(placeCluster: cluster)
        }
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
