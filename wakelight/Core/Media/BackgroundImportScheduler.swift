import Foundation
import BackgroundTasks

/// 负责注册与调度后台导入任务（WebDAV 自动同步 + 缩略图补全）
final class BackgroundImportScheduler {
    static let shared = BackgroundImportScheduler()

    static let webdavTaskIdentifier = "com.wakelight.bg.webdav-import"

    private init() {}

    func registerTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.webdavTaskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            self.handleWebDAVImportTask(processingTask)
        }
    }

    func scheduleWebDAVImportAfterLaunch() {
        let request = BGProcessingTaskRequest(identifier: Self.webdavTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 10)

        do {
            try BGTaskScheduler.shared.submit(request)
            print("[BackgroundImportScheduler] scheduled webdav task")
        } catch {
            print("[BackgroundImportScheduler] schedule failed: \(error)")
        }
    }

    private func handleWebDAVImportTask(_ task: BGProcessingTask) {
        // 每次执行完重新调度下一次，形成后台周期机会。
        scheduleWebDAVImportAfterLaunch()

        let job = Task.detached(priority: .background) {
            // 确保 WebDAV Reader 已注册
            await WebDAVBootstrap.shared.bootstrap()

            // 顺序由 ImportManager 内部保证：
            // WebDAV 导入 -> 缩略图补全 -> 照片预处理
            _ = await PhotoImportManager.shared.runWebDAVImportInBackgroundIfPossible(reason: "bg-task")
        }

        task.expirationHandler = {
            job.cancel()
        }

        Task.detached(priority: .utility) {
            _ = await job.result
            task.setTaskCompleted(success: !job.isCancelled)
        }
    }
}
