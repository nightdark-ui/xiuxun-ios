import SwiftUI

@main
struct POCApp: App {
    init() { MemoryGuard.shared.start() }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
