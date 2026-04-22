// Views/SettingsView.swift
//
// Settings sheet. Hosts the user-facing UWB toggle the prompt asked for.
//
// The default for the toggle is ON when the device's NearbyInteraction
// capabilities report `supportsPreciseDistanceMeasurement == true`. Turning
// it OFF forces the BLE+bump path even on UWB-capable devices, which is
// useful for debugging cross-device matching against an SE-2-equivalent
// configuration.

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
                                 ? "Available on this device (iPhone 11+)."
                                 : "Not available on this device. BLE + bump only.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!uwbDeviceCapable)
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
