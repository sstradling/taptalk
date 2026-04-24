// Views/LobbyEntryView.swift
//
// First screen the user sees: pick a display name, then either create a room
// or join one with a 4-letter code. Sub-navigation to SettingsView (the UWB
// toggle lives there).

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import TapPairCore

struct LobbyEntryView: View {
    @Environment(AppViewModel.self) private var vm
    @State private var roomCode: String = ""
    @State private var showSettings = false

    var body: some View {
        @Bindable var vmBinding = vm
        Form {
            Section("You") {
                TextField("Display name", text: $vmBinding.displayName)
                    .textInputAutocapitalization(.words)
            }
            Section("Start a game") {
                ForEach(GameMode.allCases, id: \.self) { mode in
                    Button(label(for: mode)) {
                        Task { await vm.createRoom(mode: mode) }
                    }
                }
            }
            Section("Or join") {
                TextField("ABCD", text: $roomCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button("Join room") {
                    Task { await vm.joinRoom(code: roomCode) }
                }
                .disabled(roomCode.count != 4)
            }
            if let err = vm.state.lastError {
                Section { Text(err).foregroundStyle(.red) }
            }
        }
        .navigationTitle("TapPair")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private func label(for mode: GameMode) -> String {
        switch mode {
        case .musical_chairs: "Musical Chairs"
        case .poison_apple:   "Poison Apple"
        case .scavenger_hunt: "Scavenger Hunt"
        }
    }
}
#endif
