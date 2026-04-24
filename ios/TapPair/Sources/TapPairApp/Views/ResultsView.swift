// Views/ResultsView.swift
//
// Post-round standings. Shows ranked outcomes and a button to advance to the
// next round (or end the game).

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import TapPairCore

struct ResultsView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        VStack(spacing: 16) {
            Text("Round results").font(.largeTitle).bold()
            if let res = vm.state.lastResolution {
                List(res.results.sorted(by: { $0.totalScore > $1.totalScore })) { row in
                    HStack {
                        Text(displayName(for: row.playerId))
                        Spacer()
                        Text(outcomeLabel(row.outcome)).foregroundStyle(color(for: row.outcome))
                        Text("+\(row.scoreDelta)").monospacedDigit().foregroundStyle(.secondary)
                        Text("\(row.totalScore)").monospacedDigit().bold()
                    }
                }
                if res.nextPhase == .ended {
                    Text("Game over").font(.title2)
                    Button("Back to lobby") { Task { await vm.leaveRoom() } }
                } else {
                    Button("Next round") { Task { await vm.startRound() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
    }

    private func displayName(for pid: String) -> String {
        vm.state.room?.players.first(where: { $0.playerId == pid })?.displayName ?? pid
    }

    private func outcomeLabel(_ o: PairOutcome) -> String {
        switch o {
        case .found: "Paired"
        case .eliminated: "Out"
        case .poison_won: "Poison won"
        case .poison_lost: "Poison lost"
        }
    }

    private func color(for o: PairOutcome) -> Color {
        switch o {
        case .found, .poison_won: .green
        case .eliminated, .poison_lost: .red
        }
    }
}
#endif
