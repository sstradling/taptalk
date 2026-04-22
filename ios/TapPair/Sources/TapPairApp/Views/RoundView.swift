// Views/RoundView.swift
//
// Active round screen: shows the player's cue and a big "tap to register"
// button (which in dev builds sends a fake-touch evidence; on a real phone the
// `BleBumpPairingProvider` reacts to the physical bump and the user just
// touches phones).

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import TapPairCore

struct RoundView: View {
    @Environment(AppViewModel.self) private var vm
    @State private var fakePeerToken: String = ""

    var body: some View {
        VStack(spacing: 24) {
            if let assignment = vm.state.lastAssignment {
                badge(assignment.role)
                Text(assignment.cue.payload["text"] ?? "")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center)
                    .padding()
                Text(assignment.cue.complementHint)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let conf = vm.state.lastConfirmation {
                Label("Paired with \(conf.partnerDisplayName)", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            }
            if let err = vm.state.lastError {
                Text(err).foregroundStyle(.red)
            }
            #if DEBUG
            DisclosureGroup("Debug: simulate touch") {
                TextField("partner self-token", text: $fakePeerToken)
                    .textInputAutocapitalization(.never)
                Button("Inject fake UWB tap") {
                    Task { await vm.injectFakeTouch(peerToken: fakePeerToken) }
                }
            }
            .padding()
            #endif
            Text("Bring phones together to confirm.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .navigationTitle("Round")
    }

    @ViewBuilder
    private func badge(_ role: PairRole) -> some View {
        switch role {
        case .pair:
            EmptyView()
        case .poison_apple:
            Label("You're the Poison Apple", systemImage: "exclamationmark.triangle.fill")
                .padding(8)
                .background(.red.opacity(0.15))
                .clipShape(Capsule())
        }
    }
}
#endif
