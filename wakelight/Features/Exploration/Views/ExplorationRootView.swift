import SwiftUI
import UIKit
import AVFoundation
import Combine

struct ExplorationRootView: View {
    @StateObject private var viewModel = ExploreViewModel()
    @State private var selectedCluster: PlaceCluster?
    @State private var awakenQueue: [PlaceCluster] = []
    @State private var revealedClusterIds: Set<UUID> = [] // session-only: 半显影（白点）
    @State private var isAwakenMode: Bool = false
    @State private var showBadges: Bool = false
    @State private var panelHeight: CGFloat = 380
    @State private var panelCityName: String? = nil
    @State private var dragStartPanelHeight: CGFloat? = nil
    private let minPanelHeight: CGFloat = 120
    private let defaultPanelHeight: CGFloat = 380
    private var dragHandleHotZoneHeight: CGFloat {
        // 仅在“点击再看”提示条出现时预留额外高度，避免顶部出现过大空白
        (popupText != nil && !isFirstLightPopupPresented) ? 83 : 28
    }

    @State private var didShowFirstLightPopupThisSession: Bool = false
    @State private var popupText: String? = nil
    @State private var popupCityName: String = ""
    @State private var isFirstLightPopupPresented: Bool = false
    @State private var blowUnlockSignal: Int = 0
    @State private var isPanelContentReady: Bool = false
    @StateObject private var blowDetector = BlowDetector()

    var body: some View {
        ZStack {
            ExplorationMapView(
                viewModel: viewModel,
                selectedCluster: $selectedCluster,
                awakenQueue: $awakenQueue,
                isAwakenMode: $isAwakenMode,
                revealedClusterIds: $revealedClusterIds,
                blowUnlockSignal: $blowUnlockSignal,
                onFirstAwakenInSession: { cluster, _ in
                    guard !didShowFirstLightPopupThisSession else { return }
                    didShowFirstLightPopupThisSession = true

                    Task {
                        // 确保在生成文案前，城市名已被解析
                        let resolvedCity = (try? await ResolvePlaceClusterCityNameUseCase().resolveCityName(for: cluster)) ?? cluster.cityName ?? "新地点"
                        await MainActor.run {
                            self.popupCityName = resolvedCity
                            generateFirstLightText(for: cluster, resolvedCity: resolvedCity)
                        }
                    }
                }
            )
            .ignoresSafeArea()

            if isFirstLightPopupPresented, let popupText {
                VStack {
                    FirstLightPopupInlineView(
                        cityName: popupCityName,
                        text: popupText,
                        onClose: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                self.isFirstLightPopupPresented = false
                            }
                        }
                    )
                    .padding(.top, 90)

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(999)
                .transition(.opacity)
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
                            if let popupText, !isFirstLightPopupPresented {
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        self.isFirstLightPopupPresented = true
                                    }
                                }) {
                                    HStack(alignment: .center, spacing: 8) {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.yellow)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(popupCityName)")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)

                                            Text(popupText)
                                                .font(.system(size: 11, weight: .regular))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }

                                        Spacer(minLength: 0)

                                        Text("点击再看")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(Color.secondary.opacity(0.12))
                                    )
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                            }

                            Capsule()
                                .fill(Color.secondary.opacity(0.45))
                                .frame(width: 36, height: 5)
                                .padding(.top, 10)
                                .padding(.bottom, 8)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: dragHandleHotZoneHeight, alignment: .top)
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
                        .highPriorityGesture(panelDragGesture)
                        .simultaneousGesture(panelDragGesture)

                        // 始终保留 MemoryPanelView 以维持其内部多选状态，仅通过高度和透明度控制视觉隐藏
                        VStack(spacing: 0) {
                            MemoryPanelView(
                                clusters: awakenQueue,
                                selectedClusterId: selectedCluster?.id,
                                onHeaderDragChanged: { value in
                                    handlePanelDragChanged(value)
                                },
                                onHeaderDragEnded: { value in
                                    handlePanelDragEnded(value)
                                }
                            )
                            .opacity(isPanelContentReady && panelHeight > minPanelHeight + 20 ? 1 : 0)
                            .frame(maxHeight: isPanelContentReady && panelHeight > minPanelHeight + 20 ? .infinity : 0)
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
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .animation(.easeInOut(duration: 0.22), value: awakenQueue.map(\.id))
        .task {
            await blowDetector.startIfNeeded()
        }
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .sheet(isPresented: $showBadges) {
            BadgeWallView()
        }
        .onReceive(blowDetector.$didDetectBlow.removeDuplicates()) { didDetect in
            guard didDetect, isAwakenMode else { return }
            blowUnlockSignal += 1
            blowDetector.consumeDetection()
        }
        .onChange(of: awakenQueue.map(\.id)) { _, newValue in
            guard isAwakenMode, !newValue.isEmpty else {
                isPanelContentReady = false
                return
            }
            isPanelContentReady = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                guard self.isAwakenMode, !self.awakenQueue.isEmpty else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    self.isPanelContentReady = true
                }
            }
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
            popupCityName = ""
            isPanelContentReady = false
            blowDetector.consumeDetection()
        }
    }

    private var maxPanelHeight: CGFloat {
        let screenHeight = UIScreen.main.bounds.height
        let bottomInset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?
            .safeAreaInsets.bottom ?? 0

        let dynamicMax = screenHeight * 0.82 - bottomInset
        return max(defaultPanelHeight + 40, dynamicMax)
    }

    private var panelDragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                handlePanelDragChanged(value)
            }
            .onEnded { value in
                handlePanelDragEnded(value)
            }
    }

    private func handlePanelDragChanged(_ value: DragGesture.Value) {
        if dragStartPanelHeight == nil {
            dragStartPanelHeight = panelHeight
        }

        let start = dragStartPanelHeight ?? panelHeight
        let newHeight = start - value.translation.height
        panelHeight = max(minPanelHeight, min(maxPanelHeight, newHeight))
    }

    private func handlePanelDragEnded(_ value: DragGesture.Value) {
        let current = max(minPanelHeight, min(maxPanelHeight, panelHeight))
        let lowerSnapThreshold = minPanelHeight + 28
        let upperSnapThreshold = maxPanelHeight - 40

        let target: CGFloat
        if current <= lowerSnapThreshold || value.predictedEndTranslation.height > 140 {
            target = minPanelHeight
        } else if current >= upperSnapThreshold || value.predictedEndTranslation.height < -180 {
            target = maxPanelHeight
        } else {
            target = current
        }

        withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.86)) {
            panelHeight = target
        }
        dragStartPanelHeight = nil
    }

    private func generateFirstLightText(for cluster: PlaceCluster, resolvedCity: String) {
        let geohash6 = String(cluster.geohash.prefix(6))
        let city = resolvedCity

        #if DEBUG
        let debugCityName = cluster.cityName ?? "nil"
        let debugPanelCityName = panelCityName ?? "nil"
        print("[FirstLight] generateFirstLightText clusterId=\(cluster.id) geohash=\(cluster.geohash) geohash6=\(geohash6) cityName=\(debugCityName) panelCityName=\(debugPanelCityName) lat=\(cluster.centerLatitude) lng=\(cluster.centerLongitude)")
        #endif

        let fallbackText = "光点显影成一段新的记忆"
        let cacheKey = "firstLight:\(geohash6)"

        let systemPrompt = """
        你是一位克制而有文化气质的城市书写者。
        请简要撰写一段文字。
        要求：
        - 3~4段结构
        - 第一段：城市整体气质或历史基调
        - 第二段：简洁的历史或地理知识真实，不编造
        - 第三段：当地生活或文化
        - 最后一段：一段两句完整的，与城市相关的诗词。
        整体字数 90到110字。
        禁止：
        - 使用“著名”“历史悠久”“文化名城”“旅游胜地”等宣传词
        - 使用感叹号
        - 编造历史事件或诗句
        """

        let userPrompt = """
        城市：\(city)
        坐标：(\(cluster.centerLatitude), \(cluster.centerLongitude))
        geohash_6：\(geohash6)
        如果坐标在名胜古迹等景点附近，那么就着重介绍景点，不要介绍城市
        请简要撰写一段文字，整体文字精炼，字数90到110字
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
                // 首次扫光阶段避免与面板/地图动画同帧叠加，先仅展示“点击再看”提示条
                self.popupText = text
                self.isFirstLightPopupPresented = false
            }
        }
    }
}

private struct FirstLightPopupInlineView: View {
    let cityName: String
    let text: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.yellow)

                Spacer(minLength: 0)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .frame(width: 26, height: 26)
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial)
                        )
                }
                .buttonStyle(.plain)
            }

            Text(cityName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.primary)

            Text(text)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color.primary.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemBackground).opacity(0.84))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 10)
    }
}

struct ExplorationRootView_Previews: PreviewProvider {
    static var previews: some View {
        ExplorationRootView()
    }
}

@MainActor
final class BlowDetector: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var didDetectBlow: Bool = false

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var isStarted: Bool = false
    private var didRequestPermission: Bool = false
    private var baselineDb: Float = -60
    private var consecutiveHits: Int = 0

    func startIfNeeded() async {
        guard !isStarted else { return }
        isStarted = true

        let granted = await requestPermissionIfNeeded()
        guard granted else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true, options: [])

            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("blow_detector_temp.caf")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatAppleIMA4,
                AVSampleRateKey: 22050,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 12800,
                AVLinearPCMBitDepthKey: 16,
                AVEncoderAudioQualityKey: AVAudioQuality.low.rawValue
            ]

            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.isMeteringEnabled = true
            recorder?.delegate = self
            recorder?.prepareToRecord()
            recorder?.record()

            startMeteringLoop()
        } catch {
            print("[BlowDetector] failed to start: \(error)")
        }
    }

    func consumeDetection() {
        didDetectBlow = false
    }

    private func requestPermissionIfNeeded() async -> Bool {
        if didRequestPermission {
            return AVAudioSession.sharedInstance().recordPermission == .granted
        }
        didRequestPermission = true

        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func startMeteringLoop() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.sampleMeter()
        }
        RunLoop.main.add(meterTimer!, forMode: .common)
    }

    private func sampleMeter() {
        guard let recorder else { return }
        recorder.updateMeters()

        let level = recorder.averagePower(forChannel: 0)

        if level < -5 {
            baselineDb = baselineDb * 0.92 + level * 0.08
        }

        let dynamicThreshold = max(-22, baselineDb + 15)

        if level > dynamicThreshold {
            consecutiveHits += 1
        } else {
            consecutiveHits = max(0, consecutiveHits - 1)
        }

        if consecutiveHits >= 3 {
            didDetectBlow = true
            consecutiveHits = 0
        }
    }

    deinit {
        meterTimer?.invalidate()
        recorder?.stop()
    }
}
