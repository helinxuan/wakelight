import SwiftUI

struct ExplorationRootView: View {
    @Environment(\.displayScale) private var displayScale

    @StateObject private var viewModel = ExploreViewModel()
    @State private var selectedCluster: PlaceCluster?
    @State private var awakenQueue: [PlaceCluster] = []
    @State private var revealedClusterIds: Set<UUID> = [] // session-only: 半显影（白点）
    @State private var isAwakenMode: Bool = false
    @State private var showBadges: Bool = false
    @State private var panelHeight: CGFloat = 380
    @State private var panelCityName: String? = nil
    private let minPanelHeight: CGFloat = 120
    private let defaultPanelHeight: CGFloat = 380

    @State private var didShowFirstLightPopupThisSession: Bool = false
    @State private var popupText: String? = nil
    @State private var firstLightText: String? = nil // 独立存储生成的文案，用于持久条
    @State private var popupCityName: String = ""
    @State private var popupSourcePoint: CGPoint = .zero
    @State private var memoryPanelTopCenter: CGPoint = .zero
    @State private var showPersistentFirstLight: Bool = false

    var body: some View {
        ZStack {
            ExplorationMapView(
                viewModel: viewModel,
                selectedCluster: $selectedCluster,
                awakenQueue: $awakenQueue,
                isAwakenMode: $isAwakenMode,
                revealedClusterIds: $revealedClusterIds,
                onFirstAwakenInSession: { cluster, screenPoint in
                    guard !didShowFirstLightPopupThisSession else { return }
                    didShowFirstLightPopupThisSession = true
                    popupSourcePoint = screenPoint
                    popupCityName = cluster.cityName ?? "新地点"
                    generateFirstLightText(for: cluster)
                }
            )
            .ignoresSafeArea()

            if let popupText {
                FirstLightPopupInlineView(
                    cityName: popupCityName,
                    text: popupText,
                    source: popupSourcePoint,
                    target: memoryPanelTopCenter
                ) {
                    self.popupText = nil
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        self.showPersistentFirstLight = true
                    }
                }
                .zIndex(999)
            }

            if isAwakenMode {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: {
                            selectedCluster = nil
                            awakenQueue.removeAll()
                            revealedClusterIds.removeAll() // 退出即清空白点（恢复灰点）
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

                    }
                    .padding(.horizontal)
                    .padding(.top)
                    .padding(.bottom, 90)
                }

                if !awakenQueue.isEmpty, isAwakenMode {
                    VStack(spacing: 0) {
                        let _ = 56 as CGFloat

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
                        VStack(spacing: 0) {
                            if showPersistentFirstLight, let displayText = firstLightText {
                                Button(action: {
                                    // 点击还原弹窗
                                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                        self.showPersistentFirstLight = false
                                        self.popupText = displayText // 还原弹窗
                                    }
                                }) {
                                    HStack(spacing: 10) {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.yellow)
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(popupCityName)
                                                .font(.system(size: 13, weight: .bold))
                                            Text(displayText)
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(Color.secondary.opacity(0.1))
                                    .cornerRadius(12)
                                }
                                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                                .transition(.move(edge: .top).combined(with: .opacity))
                            }

                            MemoryPanelView(clusters: awakenQueue, selectedClusterId: selectedCluster?.id)
                                .opacity(panelHeight > minPanelHeight + 20 ? 1 : 0)
                                .frame(maxHeight: panelHeight > minPanelHeight + 20 ? .infinity : 0)
                                .clipped()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: panelHeight)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: Color.black.opacity(0.15), radius: 20, x: 0, y: -5)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                    .transition(.asymmetric(insertion: .move(edge: .bottom), removal: .opacity))
                    .overlay {
                        GeometryReader { geo in
                            Color.clear
                                .preference(
                                    key: MemoryPanelTopCenterPreferenceKey.self,
                                    value: CGPoint(x: geo.frame(in: .global).midX, y: geo.frame(in: .global).minY + 18)
                                )
                        }
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .animation(.easeInOut(duration: 0.22), value: awakenQueue.map(\.id))
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .sheet(isPresented: $showBadges) {
            BadgeWallView()
        }
        .onPreferenceChange(MemoryPanelTopCenterPreferenceKey.self) { p in
            self.memoryPanelTopCenter = p
        }
        .onChange(of: isAwakenMode) { _, newValue in
            // 只要离开唤醒模式，就彻底复位本次 Session 状态（白点 + 面板 + 选中项）
            guard newValue == false else { return }
            selectedCluster = nil
            awakenQueue.removeAll()
            revealedClusterIds.removeAll()
            panelCityName = nil
            panelHeight = defaultPanelHeight
            didShowFirstLightPopupThisSession = false
            popupText = nil
        }
    }

    private func generateFirstLightText(for cluster: PlaceCluster) {
        let geohash6 = String(cluster.geohash.prefix(6))
        let city = cluster.cityName ?? "未知城市"

        let fallbackText = "光点显影成一段新的记忆"
        let cacheKey = "firstLight:\(geohash6)"

        let systemPrompt = """
        你是一位克制而有文化气质的城市书写者。
        请为“地图刮开后出现的城市显影弹窗”撰写一段文字。
        要求：
        - 3~4段结构
        - 第一段：城市整体气质或历史基调
        - 第二段：简洁的历史或地理知识真实，不编造
        - 第三段：当地生活或文化
        - 最后一段：一段两句完整的，与城市相关的诗词。
        整体字数 90到110字左右。
        禁止：
        - 使用“著名”“历史悠久”“文化名城”“旅游胜地”等宣传词
        - 使用感叹号
        - 编造历史事件或诗句
        """

        let userPrompt = """
        城市：\(city)
        坐标：(\(cluster.centerLatitude), \(cluster.centerLongitude))
        geohash_6：\(geohash6)
        """

        let request = AITextRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            cacheKey: cacheKey,
            fallbackText: fallbackText
        )

        Task {
            let text = await AITextEngine.shared.generateText(for: request)
            await MainActor.run {
                self.popupText = text
                self.firstLightText = text
            }
        }
    }
}

private struct MemoryPanelTopCenterPreferenceKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {
        value = nextValue()
    }
}

private struct FirstLightPopupInlineView: View {
    let cityName: String
    let text: String
    let source: CGPoint
    let target: CGPoint
    let onFinished: () -> Void

    @State private var phase: Phase = .appear

    private enum Phase {
        case appear
        case stay
        case fly
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.yellow)

                Text("第一个光点")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))

                Spacer(minLength: 0)
            }

            Text(cityName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)

            Text(text)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.22), radius: 18, x: 0, y: 10)
        .scaleEffect(scale)
        .opacity(opacity)
        .position(position)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
                phase = .stay
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                withAnimation(.easeInOut(duration: 0.55)) {
                    phase = .fly
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    onFinished()
                }
            }
        }
    }

    private var position: CGPoint {
        switch phase {
        case .fly:
            return target == .zero ? source : target
        default:
            return CGPoint(x: UIScreen.main.bounds.midX, y: 140)
        }
    }

    private var scale: CGFloat {
        switch phase {
        case .appear: return 0.2
        case .stay: return 1.0
        case .fly: return 0.2
        }
    }

    private var opacity: Double {
        switch phase {
        case .appear: return 0
        case .stay: return 1
        case .fly: return 0
        }
    }
}

struct ExplorationRootView_Previews: PreviewProvider {
    static var previews: some View {
        ExplorationRootView()
    }
}
