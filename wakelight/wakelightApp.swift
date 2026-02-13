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
                }
        }
    }
}
