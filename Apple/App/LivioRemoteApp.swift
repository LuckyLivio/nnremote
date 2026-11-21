import SwiftUI

@main
struct LivioRemoteApp: App {
    var body: some Scene {
        #if os(macOS)
        Window("Livio Remote", id: "main") {
            TabView {
                ViewerView().tabItem { Label("连接电脑", systemImage: "display") }
                MacHostView().tabItem { Label("共享这台 Mac", systemImage: "rectangle.on.rectangle") }
            }
            .frame(minWidth: 720, minHeight: 550)
        }
        .defaultSize(width: 940, height: 720)
        #else
        WindowGroup { ViewerView() }
        #endif
    }
}
