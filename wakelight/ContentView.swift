//
//  ContentView.swift
//  wakelight
//
//  Created by helinxuan on 2026/2/12.
//

import SwiftUI

struct ContentView: View {
    @State private var unlockedAchievement: Achievement?
    @State private var isShowingAchievementToast = false

    var body: some View {
        ZStack(alignment: .top) {
            TabView {
                ExplorationRootView()
                    .tabItem {
                        Label("Explore", systemImage: "map.fill")
                    }

                TimeTravelView()
                    .tabItem {
                        Label("Time Travel", systemImage: "clock.arrow.circlepath")
                    }

                SettingsRootView()
                    .tabItem {
                        Label("Settings", systemImage: "gearshape")
                    }
            }

            if let achievement = unlockedAchievement, isShowingAchievementToast {
                AchievementUnlockToastView(achievement: achievement)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            isShowingAchievementToast = false
                        }
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wakelightAchievementUnlocked)) { notification in
            guard let achievement = notification.object as? Achievement else { return }
            unlockedAchievement = achievement
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isShowingAchievementToast = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    isShowingAchievementToast = false
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
