import SwiftUI

struct ExplorationRootView: View {
    @StateObject private var viewModel = ExploreViewModel()
    @State private var selectedCluster: PlaceCluster?

    var body: some View {
        ZStack {
            ExplorationMapView(viewModel: viewModel, selectedCluster: $selectedCluster)
                .ignoresSafeArea()
            
            VStack {
                Spacer()
                HStack {
                    Button(action: {
                        viewModel.importPhotos()
                    }) {
                        Label("Import Photos", systemImage: "photo.on.rectangle")
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .padding()
                }
            }
        }
        .sheet(item: $selectedCluster) { cluster in
            MemoryPanelView(placeCluster: cluster)
        }
    }
}

struct ExplorationRootView_Previews: PreviewProvider {
    static var previews: some View {
        ExplorationRootView()
    }
}
