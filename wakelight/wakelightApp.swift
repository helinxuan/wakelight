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
                    Task { @MainActor in
                        await WebDAVBootstrap.shared.bootstrap()
                        // Resume interrupted thumbnail generation jobs (e.g. app terminated during WebDAV import).
                        PhotoImportManager.shared.resumeThumbnailBackfillIfNeeded()

                        // Auto-run one curation pass after app launch.
                        PhotoImportManager.shared.startPreprocessImportedPhotos(reason: "app-launch")
                    }

                    // 启动后调度一次后台 WebDAV 自动导入任务。
                    BackgroundImportScheduler.shared.scheduleWebDAVImportAfterLaunch()

                    // Start observing Photos library changes for incremental sync.
                    PhotosLibraryObserver.shared.start()

                    // Wire observer -> import manager (debounced inside manager).
                    PhotosLibraryObserver.shared.onChange = { change in
                        print("[PhotosObserver] change inserted=\(change.insertedLocalIdentifiers.count) changed=\(change.changedLocalIdentifiers.count) removed=\(change.removedLocalIdentifiers.count)")
                        PhotoImportManager.shared.handlePhotosLibraryChange(change)
                    }

                }
        }
    }
}
