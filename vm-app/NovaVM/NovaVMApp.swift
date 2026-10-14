// NovaVMApp.swift — App entry point.

import SwiftUI

@main
struct NovaVMApp: App {
    @StateObject private var engine = NovaVMEngine()

    var body: some Scene {
        WindowGroup {
            MainTabView(engine: engine)
        }
    }
}
