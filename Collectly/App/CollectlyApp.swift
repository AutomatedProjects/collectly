import SwiftUI

@main
struct CollectlyApp: App {
    @State private var model = AppModel.makeDefault()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}
