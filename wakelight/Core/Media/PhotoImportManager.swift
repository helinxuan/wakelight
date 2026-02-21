import Foundation
import Combine

enum ImportStatus: String, Codable {
    case idle
    case importing
    case completed
    case failed
    case cancelled
}

enum ImportPhase: String, Codable {
    case idle
    case photos
    case webdav
    case generateClusters
    case generateVisitLayers
    case done
}

struct ImportProgress: Codable {
    var status: ImportStatus = .idle
    var phase: ImportPhase = .idle

    var totalItems: Int = 0
    var processedItems: Int = 0

    var lastError: String?
    var lastCompletedAt: Date?

    var progress: Double {
        guard totalItems > 0 else { return 0 }
        return Double(processedItems) / Double(totalItems)
    }
}

@MainActor
final class PhotoImportManager: ObservableObject {
    static let shared = PhotoImportManager()

    @Published private(set) var progress = ImportProgress()

    @Published private(set) var isRunning = false
    private var runningTask: Task<Void, Never>?

    private init() {
        loadProgress()
    }

    /// 停止当前正在运行的导入任务
    func cancelImport() {
        guard isRunning else { return }
        print("[ImportManager] Cancelling import...")
        runningTask?.cancel()
        runningTask = nil
        isRunning = false
        progress.status = .cancelled
        progress.phase = .idle
        progress.lastError = "已手动停止导入"
        saveProgress()
    }

    /// 非阻塞 UI：用 Task 在后台执行（但仍在 app 进程内运行，不用 BGTaskScheduler）
    func startImportIfNeeded(reason: String) {
        guard !isRunning else {
            print("[ImportManager] Skip startImport (already running). reason=\(reason)")
            return
        }
        startImport(reason: reason)
    }

    func startImport(reason: String) {
        guard !isRunning else { return }
        isRunning = true

        print("[ImportManager] Starting import. reason=\(reason)")

        runningTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }

            // A) 本地 Photos 导入（宽松模式：权限拒绝只跳过，不让整个导入失败）
            await self.updateStatus(.importing, phase: .photos, resetCounts: true)

            do {
                let photosImported = try await ImportPhotosUseCase().run(limit: nil) { processed, total in
                    PhotoImportManager.shared.reportProgress(processed: processed, total: total)
                }
                print("[ImportManager] Local Photos imported: \(photosImported)")
            } catch {
                print("[ImportManager] Local Photos import skipped/failed: \(error)")
                await self.recordNonFatalError("本地 Photos 导入跳过: \(error.localizedDescription)")
            }

            do {
                // B) WebDAV 导入（带进度）
                await self.updateStatus(.importing, phase: .webdav, resetCounts: true)

                let webdavImported = try await ImportWebDAVPhotosUseCase().run(profileId: nil) { processed, total in
                    PhotoImportManager.shared.reportProgress(processed: processed, total: total)
                }
                print("[ImportManager] WebDAV imported: \(webdavImported)")

                // C) 生成聚类
                await self.updateStatus(.importing, phase: .generateClusters, resetCounts: false)
                _ = try await GeneratePlaceClustersUseCase().run()

                // D) 生成 visit layers
                await self.updateStatus(.importing, phase: .generateVisitLayers, resetCounts: false)
                _ = try await GenerateVisitLayersUseCase().run()

                await self.completeImport()
            } catch {
                await self.failImport(error: error.localizedDescription)
            }

            await MainActor.run {
                self.isRunning = false
                self.runningTask = nil
            }
        }
    }

    @MainActor
    private func updateStatus(_ status: ImportStatus, phase: ImportPhase, resetCounts: Bool) {
        progress.status = status
        progress.phase = phase

        if resetCounts {
            progress.processedItems = 0
            progress.totalItems = 0
        }

        if status == .importing {
            progress.lastError = nil
        }

        saveProgress()
    }

    @MainActor
    private func completeImport() {
        progress.status = .completed
        progress.phase = .done
        progress.lastCompletedAt = Date()
        saveProgress()
    }

    @MainActor
    private func recordNonFatalError(_ message: String) {
        // 宽松模式：记录但不中断整体任务
        if let existing = progress.lastError, !existing.isEmpty {
            progress.lastError = existing + "\n" + message
        } else {
            progress.lastError = message
        }
        saveProgress()
    }

    /// “提示/警告”类信息：不会让导入失败，但会在导入页展示出来（复用 progress.lastError）。
    func reportNonFatalWarning(_ message: String) {
        recordNonFatalError("提示: \(message)")
    }

    @MainActor
    private func failImport(error: String) {
        progress.status = .failed
        progress.lastError = error
        saveProgress()
    }

    @MainActor
    func reportProgress(processed: Int, total: Int) {
        progress.processedItems = processed
        progress.totalItems = total
        // 不必每次都保存，减少 IO
    }

    private let progressKey = "com.wakelight.import.progress"

    private func saveProgress() {
        if let data = try? JSONEncoder().encode(progress) {
            UserDefaults.standard.set(data, forKey: progressKey)
        }
    }

    private func loadProgress() {
        if let data = UserDefaults.standard.data(forKey: progressKey),
           let saved = try? JSONDecoder().decode(ImportProgress.self, from: data) {
            self.progress = saved
        }
    }
}
