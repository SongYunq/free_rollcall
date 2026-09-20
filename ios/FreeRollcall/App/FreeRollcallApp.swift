import SwiftUI

@main struct FreeRollcallApp: App {
    private let state: AppState?
    init() {
        do {
            #if DEBUG
            let fixture = ProcessInfo.processInfo.arguments.contains("--ui-fixture")
            #else
            let fixture = false
            #endif
            let store = try LocalStore(inMemory: fixture)
            let state = AppState(store: store)
            #if DEBUG
            if fixture { try state.installFixture() }
            #endif
            self.state = state
        } catch { state = nil }
    }
    var body: some Scene {
        WindowGroup {
            Group {
                if let state { RootView(state: state) }
                else {
                    ContentUnavailableView("本地数据暂时无法打开", systemImage: "externaldrive.badge.exclamationmark",
                        description: Text("请检查设备可用空间后重新打开应用"))
                }
            }
            .tint(.black)
            .preferredColorScheme(.light)
        }
    }
}
