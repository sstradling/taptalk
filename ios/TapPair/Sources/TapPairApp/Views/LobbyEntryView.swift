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
            connectionSection
            Section("You") {
                TextField("Display name", text: $vmBinding.displayName)
                    .textInputAutocapitalization(.words)
            }
            Section("Start a game") {
                ForEach(GameMode.allCases, id: \.self) { mode in
                    Button(label(for: mode)) {
                        Task { await vm.createRoom(mode: mode) }
                    }
                    .disabled(!vm.canSendUserActions)
                }
            }
            Section("Or join") {
                TextField("ABCD", text: $roomCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button("Join room") {
                    Task { await vm.joinRoom(code: roomCode) }
                }
                .disabled(roomCode.count != 4 || !vm.canSendUserActions)
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

    @ViewBuilder
    private var connectionSection: some View {
        Section("Server") {
            HStack {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 10, height: 10)
                Text(connectionLabel)
                Spacer()
                Text(vm.serverURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !vm.canSendUserActions {
                Button("Reconnect") {
                    Task { await vm.connectAndHello() }
                }
            }
        }
    }

    private var connectionLabel: String {
        switch vm.state.connection {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected (handshaking)"
        case .helloed: "Connected"
        }
    }

    private var connectionColor: Color {
        switch vm.state.connection {
        case .disconnected: .red
        case .connecting: .orange
        case .connected: .yellow
        case .helloed: .green
        }
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
