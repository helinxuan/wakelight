import SwiftUI
import AVKit
import Photos

struct VideoPlayerView: View {
    let locatorKey: String

    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var error: String?
    @State private var temporaryURL: URL?

    var body: some View {
        ZStack {
            if let player = player {
                VideoPlayer(player: player)
                    .onAppear {
                        player.play()
                    }
                    .onDisappear {
                        player.pause()
                    }
            } else if isLoading {
                ProgressView()
                    .tint(.white)
            } else if let error = error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text(error)
                        .font(.caption)
                }
                .foregroundColor(.white)
            }
        }
        .task(id: locatorKey) {
            await loadVideo()
        }
        .onDisappear {
            cleanup()
        }
    }

    private func loadVideo() async {
        isLoading = true
        error = nil

        guard let locator = MediaLocator.parse(locatorKey) else {
            error = "无法解析媒体地址"
            isLoading = false
            return
        }

        do {
            let resource = try await MediaResolver.shared.resolve(locator: locator)

            switch resource {
            case .phAsset(let asset):
                player = try await requestAVPlayer(for: asset)
            case .url(let url):
                player = AVPlayer(url: url)
            case .data(let data):
                // For WebDAV/Data, write to temp file for playback
                let ext = (locatorKey as NSString).pathExtension
                let fileExt = ext.isEmpty ? "mp4" : ext
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(fileExt)
                try data.write(to: tempURL)
                self.temporaryURL = tempURL
                player = AVPlayer(url: tempURL)
            }
        } catch {
            self.error = "视频加载失败: \(error.localizedDescription)"
        }

        isLoading = false
    }

    private func requestAVPlayer(for asset: PHAsset) async throws -> AVPlayer {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat

            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { playerItem, _ in
                if let playerItem = playerItem {
                    continuation.resume(returning: AVPlayer(playerItem: playerItem))
                } else {
                    continuation.resume(throwing: NSError(domain: "VideoPlayerView", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法获取视频播放项"]))
                }
            }
        }
    }

    private func cleanup() {
        player?.pause()
        player = nil
        if let url = temporaryURL {
            try? FileManager.default.removeItem(at: url)
            temporaryURL = nil
        }
    }
}
