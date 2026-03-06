import SwiftUI
import GRDB
import UIKit

struct TimeTravelView: View {
    @StateObject private var viewModel = TimeTravelViewModel()
    @State private var selectedDetailItem: MemoryDetailItem?

    var body: some View {
        ZStack {
            TimeTravelMapView(nodes: viewModel.nodes, selectedIndex: viewModel.selectedIndex)
                .saturation(0.8)
                .brightness(0.03)
                .ignoresSafeArea()

            Color.black
                .opacity(0.26)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if !viewModel.nodes.isEmpty {
                TimeTravelScrubberView(
                    nodes: viewModel.nodes,
                    selectedIndex: $viewModel.selectedIndex,
                    isPlaying: viewModel.isPlaying,
                    onCruiseTap: {
                        withAnimation(.spring()) {
                            if viewModel.isPlaying {
                                viewModel.pause()
                            } else {
                                viewModel.play()
                            }
                        }
                    },
                    onDragStart: {
                        if viewModel.isPlaying {
                            viewModel.pause()
                        }
                    }
                )
                .padding(.top, 8)
                .zIndex(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            VStack(spacing: 0) {
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
                        print("DEBUG: TimeTravelView - onShowDetail nodeId=\(node.id) visitLayerId=\(node.visitLayerId) storyId=\(node.storyId?.uuidString ?? "nil") hasVisitLayer=\(node.visitLayer != nil)")
                        if let storyId = node.storyId {
                            Task {
                                do {
                                    let story = try await DatabaseContainer.shared.db.reader.read { db in
                                        try StoryNode.fetchOne(db, key: storyId)
                                    }
                                    if let story {
                                        await MainActor.run {
                                            selectedDetailItem = .story(story)
                                        }
                                    } else if let layer = node.visitLayer {
                                        await MainActor.run {
                                            selectedDetailItem = .unhandled(layer)
                                        }
                                    }
                                } catch {
                                    if let layer = node.visitLayer {
                                        await MainActor.run {
                                            selectedDetailItem = .unhandled(layer)
                                        }
                                    }
                                }
                            }
                        } else if let layer = node.visitLayer {
                            selectedDetailItem = .unhandled(layer)
                        } else {
                            print("DEBUG: TimeTravelView - visitLayer is nil, cannot present sheet")
                        }
                    }
                    .padding(.bottom, 36)
                }
            }
        }
        .sheet(item: $selectedDetailItem) { item in
            NavigationStack {
                MemoryDetailSheet(item: item, clusterNames: [:], onRequestAddFromUnhandled: nil)
            }
        }
    }
}

private struct TimeTravelScrubberView: View {
    let nodes: [TimeRouteNode]
    @Binding var selectedIndex: Int
    let isPlaying: Bool
    let onCruiseTap: () -> Void
    let onDragStart: () -> Void

    @State private var isDragging = false
    @State private var focusedProgress: CGFloat = 0
    @State private var lastStoryFeedbackIndex: Int = -1
    @State private var lastTickFeedbackIndex: Int = -1

    private let minTickSpacing: CGFloat = 6
    private let maxTickCount: Int = 90

    private var totalCount: Int { nodes.count }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                let tickCount = resolvedTickCount(for: width)
                let focusX = focusedX(width: width)

                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(0..<tickCount, id: \.self) { tick in
                        Capsule()
                            .fill(barColor(forTick: tick, tickCount: tickCount, focusX: focusX, width: width))
                            .frame(width: 2, height: barHeight(forTick: tick, tickCount: tickCount, focusX: focusX, width: width))

                        if tick < tickCount - 1 {
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .animation(.easeOut(duration: 0.08), value: selectedIndex)
                .animation(.easeOut(duration: 0.08), value: focusedProgress)
                .contentShape(Rectangle())
                .highPriorityGesture(dragGesture(width: width, tickCount: tickCount), including: .all)
            }
            .frame(height: 30)

            HStack(alignment: .center) {
                Text(currentTimeLabel)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.38))
                    .clipShape(Capsule())

                Spacer()

                Button(action: onCruiseTap) {
                    HStack(spacing: 6) {
                        Text(isPlaying ? "❚❚" : "▶")
                        Text("巡航")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.3))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .onAppear {
            focusedProgress = progress(for: selectedIndex)
            HapticPlayer.warmUpIfNeeded()
            SystemSoundPlayer.warmUpIfNeeded()
            print("[TimeTravel][Feedback] warmUp done")
        }
        .onChange(of: selectedIndex) { _, newValue in
            guard !isDragging else { return }
            focusedProgress = progress(for: newValue)
        }
    }

    private var currentTimeLabel: String {
        guard nodes.indices.contains(selectedIndex) else { return "--:--" }
        if let title = nodes[selectedIndex].displayTitle, !title.isEmpty {
            return title
        }
        return "第\(selectedIndex + 1)段"
    }

    private func resolvedTickCount(for width: CGFloat) -> Int {
        let widthBased = Int(width / minTickSpacing)
        return min(max(widthBased, 24), maxTickCount)
    }

    private func progress(for index: Int) -> CGFloat {
        guard totalCount > 1 else { return 0 }
        return CGFloat(index) / CGFloat(totalCount - 1)
    }

    private func focusedX(width: CGFloat) -> CGFloat {
        min(max(focusedProgress, 0), 1) * width
    }

    private func bubbleX(width: CGFloat) -> CGFloat {
        let x = focusedX(width: width)
        return min(max(x, 42), max(width - 42, 42))
    }

    private func tickX(for tick: Int, tickCount: Int, width: CGFloat) -> CGFloat {
        guard tickCount > 1 else { return width / 2 }
        let tickProgress = CGFloat(tick) / CGFloat(tickCount - 1)
        return tickProgress * width
    }

    private func distanceScore(forTick tick: Int, tickCount: Int, focusX: CGFloat, width: CGFloat) -> CGFloat {
        let distance = abs(tickX(for: tick, tickCount: tickCount, width: width) - focusX)
        let influenceRadius = max(width * 0.1, 34)
        let normalized = min(distance / influenceRadius, 1)
        return 1 - normalized
    }

    private func barHeight(forTick tick: Int, tickCount: Int, focusX: CGFloat, width: CGFloat) -> CGFloat {
        let score = distanceScore(forTick: tick, tickCount: tickCount, focusX: focusX, width: width)
        return 8 + score * 13
    }

    private func barColor(forTick tick: Int, tickCount: Int, focusX: CGFloat, width: CGFloat) -> Color {
        let score = distanceScore(forTick: tick, tickCount: tickCount, focusX: focusX, width: width)
        return Color.white.opacity(0.26 + score * 0.7)
    }

    private func dragGesture(width: CGFloat, tickCount: Int) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard totalCount > 0 else { return }

                if !isDragging {
                    isDragging = true
                    onDragStart()
                    HapticPlayer.play(forCount: 5)
                    SystemSoundPlayer.playTick()
                    print("[TimeTravel][Feedback] drag begin")
                    lastStoryFeedbackIndex = selectedIndex
                    lastTickFeedbackIndex = nearestRenderTickIndex(progress: focusedProgress, tickCount: tickCount)
                }

                let progress = min(max(value.location.x / width, 0), 1)
                focusedProgress = progress

                let tickIndex = nearestRenderTickIndex(progress: progress, tickCount: tickCount)
                if tickIndex != lastTickFeedbackIndex {
                    HapticPlayer.light()
                    lastTickFeedbackIndex = tickIndex
                }

                let targetIndex = nearestStoryIndex(progress: progress)
                if targetIndex != selectedIndex {
                    withAnimation(.easeOut(duration: 0.08)) {
                        selectedIndex = targetIndex
                    }
                    HapticPlayer.play(forCount: 8)
                    SystemSoundPlayer.playTick()
                    print("[TimeTravel][Feedback] story=\(targetIndex)")
                    lastStoryFeedbackIndex = targetIndex
                }
            }
            .onEnded { _ in
                isDragging = false
                focusedProgress = progress(for: selectedIndex)
                lastTickFeedbackIndex = -1
                print("[TimeTravel][Feedback] drag end")
            }
    }

    private func nearestRenderTickIndex(progress: CGFloat, tickCount: Int) -> Int {
        Int(round(min(max(progress, 0), 1) * CGFloat(max(tickCount - 1, 0))))
    }

    private func nearestStoryIndex(progress: CGFloat) -> Int {
        Int(round(min(max(progress, 0), 1) * CGFloat(max(totalCount - 1, 0))))
    }
}
