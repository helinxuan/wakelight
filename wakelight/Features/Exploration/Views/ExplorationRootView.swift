import SwiftUI

struct ExplorationRootView: View {
    @StateObject private var viewModel = ExploreViewModel()
    
    var body: some View {
        ZStack {
            ExplorationMapView(viewModel: viewModel)
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
    }
}

struct ExplorationRootView_Previews: PreviewProvider {
    static var previews: some View {
        ExplorationRootView()
    }
}
