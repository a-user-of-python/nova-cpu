// MainTabView.swift — 5-tab Liquid Glass bottom bar.
// Programs | Firmware | Run | App | VM
// iOS 26 applies Liquid Glass to TabView automatically; older iOS gets
// ultraThinMaterial fallback. Large labels for accessibility.

import SwiftUI

struct MainTabView: View {
    @ObservedObject var engine: NovaVMEngine
    @StateObject private var appSettings = AppSettings()

    var body: some View {
        TabView {
            ProgramsView(engine: engine)
                .tabItem {
                    Label("Programs", systemImage: "square.stack.fill")
                }

            FirmwareView(engine: engine)
                .tabItem {
                    Label("Firmware", systemImage: "cpu.fill")
                }

            VMView(engine: engine)
                .tabItem {
                    Label("Run", systemImage: "play.fill")
                }

            AppSettingsView()
                .tabItem {
                    Label("App", systemImage: "gearshape.fill")
                }

            SettingsView(engine: engine)
                .tabItem {
                    Label("VM", systemImage: "slider.horizontal.3")
                }
        }
        .font(.headline)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .environmentObject(appSettings)
    }
}
