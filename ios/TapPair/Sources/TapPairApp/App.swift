// App.swift — SwiftUI entry point.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

@main
struct TapPairApp: App {
    @State private var vm = AppViewModel()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(vm)
                .task { await vm.start() }
        }
    }
}

struct RootView: View {
    @Environment(AppViewModel.self) private var vm
    var body: some View {
        NavigationStack {
            if vm.state.room == nil {
                LobbyEntryView()
            } else if vm.state.lastResolution != nil {
                ResultsView()
            } else if vm.state.lastAssignment != nil {
                RoundView()
            } else {
                RoomLobbyView()
            }
        }
    }
}
#endif
