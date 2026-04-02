//
//  wakelightApp.swift
//  wakelight
//
//  Created by helinxuan on 2026/2/12.
//

import SwiftUI

@main
struct wakelightApp: App {
    @State private var didRunStartupBootstrap = false
    private let firstLaunchLocalSyncDoneKey = "com.wakelight.firstLaunchLocalSyncDone"

    init() {
        BackgroundImportScheduler.shared.registerTasks()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    guard !didRunStartupBootstrap else { return }
                    didRunStartupBootstrap = true

                    _ = AchievementService.shared

                    Task {
                        // 1) 先尝试注册 WebDAV Reader
                        await WebDAVBootstrap.shared.bootstrap()

                        // 2) 启动观察系统相册变更（增量）
                        await MainActor.run {
                            PhotosLibraryObserver.shared.start()
                            PhotosLibraryObserver.shared.onChange = { change in
                                print("[PhotosObserver] change inserted=\(change.insertedLocalIdentifiers.count) changed=\(change.changedLocalIdentifiers.count) removed=\(change.removedLocalIdentifiers.count)")
                                PhotoImportManager.shared.handlePhotosLibraryChange(change)
                            }
                        }

                        // 3) 首次安装：自动跑一次系统相册同步
                        if !UserDefaults.standard.bool(forKey: firstLaunchLocalSyncDoneKey) {
                            await MainActor.run {
                                PhotoImportManager.shared.startLocalPhotosImport(reason: "first-launch")
                            }

                            // 等待首次同步结束后再进行下一步
                            while true {
                                let isRunning = await MainActor.run {
                                    PhotoImportManager.shared.isRunning
                                }
                                if !isRunning { break }
                                try? await Task.sleep(nanoseconds: 500_000_000)
                            }

                            UserDefaults.standard.set(true, forKey: firstLaunchLocalSyncDoneKey)
                        }

                        // 4) 启动阶段避免前台重任务，防止地图首屏交互卡顿。
                        //    重任务改为延迟+后台机会执行：让用户先获得流畅可交互首帧。
                        Task.detached(priority: .utility) {
                            try? await Task.sleep(nanoseconds: 8_000_000_000)

                            let startupBackfillCount = await PhotoImportManager.shared.backfillThumbnailsIfNeeded(limit: 120)
                            print("[AppLaunch] deferred thumbnail backfill enqueued=\(startupBackfillCount)")

                            let hasWebDAVProfile = await WebDAVBootstrap.shared.hasSavedProfile()
                            if hasWebDAVProfile {
                                _ = await PhotoImportManager.shared.runWebDAVImportInBackgroundIfPossible(reason: "app-launch-deferred")
                            }

                            // 无 WebDAV 配置时不在启动自动整理，交给用户手动触发，避免冷启动算力洪峰。
                            PhotoImportManager.shared.resumeThumbnailBackfillIfNeeded(limit: 120)
                        }

                        // 5) 启动后调度后台 WebDAV 机会任务
                        BackgroundImportScheduler.shared.scheduleWebDAVImportAfterLaunch()
                    }
                }
        }
    }
}
