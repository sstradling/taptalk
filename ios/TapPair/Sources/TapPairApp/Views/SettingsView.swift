// Views/SettingsView.swift
//
// Settings sheet. Hosts the user-facing UWB toggle the prompt asked for.
//
// The toggle is intentionally disabled in this phase-0 prototype. The UI still
// reports hardware capability so testers can verify whether a device would be
// eligible once PLAN.md phase 4 adds server-relayed NIDiscoveryToken exchange.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import TapPairCore
#if canImport(NearbyInteraction)
import NearbyInteraction
#endif

struct SettingsView: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    private var uwbDeviceCapable: Bool {
        #if canImport(NearbyInteraction)
        if #available(iOS 16.0, *) {
            return NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
        }
        return NISession.isSupported
        #else
        return false
        #endif
    }

    private var uwbPrototypeEnabled: Bool {
        // The UWB UI remains visible so testers know whether their hardware is
        // capable, but active NearbyInteraction pairing is gated until the
        // server relays NIDiscoveryToken values (PLAN.md phase 4).
        false
    }

    var body: some View {
        @Bindable var vmBinding = vm
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledContent("URL", value: vm.serverURL.absoluteString)
                }
                Section("Pairing") {
                    Toggle(isOn: $vmBinding.uwbEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use UWB precise pairing")
                            Text(uwbDeviceCapable
                                 ? "Hardware available; server token relay is not implemented yet."
                                 : "Not available on this device. BLE + bump only.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!uwbDeviceCapable || !uwbPrototypeEnabled)
                    Text("Default pairing uses BLE + accelerometer bump and works on every iPhone, including the iPhone SE (2nd gen). UWB, when available, makes the tap-to-confirm crisper.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
#endif
