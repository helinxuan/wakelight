import SwiftUI

struct TimeTravelView: View {
    @StateObject private var viewModel = TimeTravelViewModel()

    var body: some View {
        ZStack {
            TimeTravelMapView(nodes: viewModel.nodes, selectedIndex: viewModel.selectedIndex)
                .ignoresSafeArea()

            VStack {
                HStack(spacing: 12) {
                    Button {
                        Task { await viewModel.reload() }
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.65))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    Button {
                        if viewModel.isPlaying {
                            viewModel.pause()
                        } else {
                            viewModel.play()
                        }
                    } label: {
                        Label(viewModel.isPlaying ? "Pause" : "Play", systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(viewModel.isPlaying ? Color.orange : Color.blue)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Spacer()

                if viewModel.nodes.isEmpty {
                    Text("No Story Nodes yet")
                        .padding(12)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.bottom, 10)
                } else {
                    TimelineCarouselView(nodes: viewModel.nodes, selectedIndex: $viewModel.selectedIndex)
                }
            }
        }
    }
}
