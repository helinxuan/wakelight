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

                        // 4) 有 WebDAV 配置则前台按顺序执行：WebDAV -> 缩略图 -> 整理
                        let hasWebDAVProfile = await WebDAVBootstrap.shared.hasSavedProfile()
                        if hasWebDAVProfile {
                            _ = await PhotoImportManager.shared.runWebDAVImportInBackgroundIfPossible(reason: "app-launch-foreground")
                        } else {
                            // 无 WebDAV 配置时，至少跑一轮整理
                            await MainActor.run {
                                PhotoImportManager.shared.startPreprocessImportedPhotos(reason: "app-launch-no-webdav")
                            }
                        }

                        // 5) 启动后仍调度后台 WebDAV 机会任务
                        BackgroundImportScheduler.shared.scheduleWebDAVImportAfterLaunch()

                        // 6) 补偿上次中断的缩略图任务
                        PhotoImportManager.shared.resumeThumbnailBackfillIfNeeded()
                    }
                }
        }
    }
}
