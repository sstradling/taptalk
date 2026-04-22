// Views/RoomLobbyView.swift
//
// In-room pre-round screen. Shows the room code, the player list, and (for
// the host) a "Start round" button.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import TapPairCore

struct RoomLobbyView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        VStack(spacing: 24) {
            if let room = vm.state.room {
                Text(room.roomCode)
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .tracking(8)
                    .accessibilityLabel("Room code \(room.roomCode.map(String.init).joined(separator: " "))")
                Text(modeLabel(room.mode))
                    .font(.title3).foregroundStyle(.secondary)
                List(room.players) { player in
                    HStack {
                        Text(player.displayName)
                        Spacer()
                        if player.playerId == room.hostPlayerId { Text("host").font(.caption).foregroundStyle(.secondary) }
                        if player.capabilities.contains(.uwb) { Image(systemName: "antenna.radiowaves.left.and.right") }
                    }
                }
                Button {
                    Task { await vm.startRound() }
                } label: {
                    Text("Start round").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .disabled(room.players.count < 2)
                Button("Leave") { Task { await vm.leaveRoom() } }
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .navigationTitle("Lobby")
    }

    private func modeLabel(_ m: GameMode) -> String {
        switch m {
        case .musical_chairs: "Musical Chairs"
        case .poison_apple:   "Poison Apple"
        case .scavenger_hunt: "Scavenger Hunt"
        }
    }
}
#endif
