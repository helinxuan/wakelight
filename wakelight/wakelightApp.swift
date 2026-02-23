//
//  wakelightApp.swift
//  wakelight
//
//  Created by helinxuan on 2026/2/12.
//

import SwiftUI

@main
struct wakelightApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    _ = AchievementService.shared
                    WebDAVBootstrap.shared.bootstrap()

                    // Start observing Photos library changes for incremental sync.
                    PhotosLibraryObserver.shared.start()

                    // Wire observer -> import manager (debounced inside manager).
                    PhotosLibraryObserver.shared.onChange = { change in
                        PhotoImportManager.shared.handlePhotosLibraryChange(change)
                    }
                }
        }
    }
}
