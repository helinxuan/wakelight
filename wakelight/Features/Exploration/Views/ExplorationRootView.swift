import SwiftUI

struct ExplorationRootView: View {
    @StateObject private var viewModel = ExploreViewModel()
    @State private var selectedCluster: PlaceCluster?
    @State private var isAwakenMode: Bool = false
    @State private var showBadges: Bool = false

    var body: some View {
        ZStack {
            ExplorationMapView(
                viewModel: viewModel,
                selectedCluster: $selectedCluster,
                isAwakenMode: $isAwakenMode
            )
            .ignoresSafeArea()

            if isAwakenMode {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: {
                            selectedCluster = nil
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

                if let cluster = selectedCluster, isAwakenMode {
                    MemoryPanelView(placeCluster: cluster)
                        .frame(maxWidth: .infinity)
                        .frame(height: UIScreen.main.bounds.height * 0.5)
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(radius: 18)
                        .transition(.move(edge: .bottom))
                }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: selectedCluster?.id)
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
