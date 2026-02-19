//
//  ContentView.swift
//  wakelight
//
//  Created by helinxuan on 2026/2/12.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
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
    }
}

#Preview {
    ContentView()
}
