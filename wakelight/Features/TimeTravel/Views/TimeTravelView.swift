import SwiftUI

struct TimeTravelView: View {
    @StateObject private var viewModel = TimeTravelViewModel()
    @State private var selectedDetailItem: MemoryDetailItem?

    var body: some View {
        ZStack {
            TimeTravelMapView(nodes: viewModel.nodes, selectedIndex: viewModel.selectedIndex)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button {
                        withAnimation(.spring()) {
                            if viewModel.isPlaying {
                                viewModel.pause()
                            } else {
                                viewModel.play()
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            Text(viewModel.isPlaying ? "暂停" : "播放")
                        }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .frame(height: 44)
                        .background(viewModel.isPlaying ? Color.orange : Color.blue)
                        .clipShape(Capsule())
                        .shadow(color: (viewModel.isPlaying ? Color.orange : Color.blue).opacity(0.3), radius: 8, y: 4)
                    }

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer()

                if viewModel.nodes.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("开启时光旅行，回顾精彩故事")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.bottom, 40)
                } else {
                    TimelineCarouselView(nodes: viewModel.nodes, selectedIndex: $viewModel.selectedIndex) { node in
                        print("DEBUG: TimeTravelView - onShowDetail nodeId=\(node.id) visitLayerId=\(node.visitLayerId) hasVisitLayer=\(node.visitLayer != nil)")
                        if let layer = node.visitLayer {
                            selectedDetailItem = .unhandled(layer)
                        } else {
                            print("DEBUG: TimeTravelView - visitLayer is nil, cannot present sheet")
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .sheet(item: $selectedDetailItem) { item in
            MemoryDetailSheet(item: item, clusterNames: [:])
        }
    }
}
