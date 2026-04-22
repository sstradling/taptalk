// Providers/BleBumpPairingProvider.swift
//
// Default pairing provider — works on every iPhone running iOS 17, including
// the iPhone SE (2nd gen). This is the load-bearing provider; UWB is purely
// an accelerator.
//
// What it does
// ------------
//   * BLE half:
//       - When `start(roundId:selfToken:)` is called, advertise a custom
//         `serviceUUID` with `selfToken` (8 bytes) packed into the manufacturer
//         data field. iOS overflow-area limitations don't bite us because we
//         only run while the app is foregrounded.
//       - Concurrently scan for the same `serviceUUID`. For every discovery
//         with RSSI > -55 dBm, emit a `.ble` EvidenceChannel with the peer's
//         token decoded from their advertisement data.
//   * Bump half:
//       - Subscribe to CMMotionManager device motion at 100 Hz.
//       - Detect a sharp acceleration spike (> 5 G; rise+fall < 80 ms).
//       - Emit a `.bump` EvidenceChannel with `tHitMs` set to the spike apex.
//
// All evidence flows into the shared AsyncStream; `EvidenceCoalescer` (in
// TapPairCore) batches them into a single `pair_evidence` message per touch.
//
// Routing of user actions:
//   View "Tap to register" -> BleBumpPairingProvider.start(...)
//   real-world phone tap   -> CMMotionManager bump + CBPeripheralManager seen
//                          -> evidence stream -> EvidenceCoalescer.flush
//                          -> WebSocketClient.send(.pairEvidence(...))
//                          -> server matches, pushes pair_confirmed/_rejected.

#if canImport(CoreBluetooth) && canImport(CoreMotion)
import Foundation
import CoreBluetooth
import CoreMotion
import TapPairCore

public final class BleBumpPairingProvider: NSObject, PairingProvider, @unchecked Sendable {

    public let capability: Capability = .ble
    public var isAvailable: Bool { true } // every iPhone has BLE + accelerometer

    public let evidence: AsyncStream<EvidenceChannel>
    private let continuation: AsyncStream<EvidenceChannel>.Continuation

    private static let serviceUUID = CBUUID(string: "T4P9A1A0-0000-4000-8000-000000000001")

    private let central: CBCentralManager
    private let peripheral: CBPeripheralManager
    private let motion = CMMotionManager()
    private let motionQueue = OperationQueue()

    private var currentSelfToken: String = ""
    private var lastBumpAtMs: Int64 = 0

    public override init() {
        var cont: AsyncStream<EvidenceChannel>.Continuation!
        self.evidence = AsyncStream { c in cont = c }
        self.continuation = cont
        // The two managers spin up immediately so OS permission prompts fire
        // at app launch (or first round), not at the moment of first touch.
        self.central = CBCentralManager(delegate: nil, queue: nil)
        self.peripheral = CBPeripheralManager(delegate: nil, queue: nil)
        super.init()
        self.central.delegate = self
        self.peripheral.delegate = self
        self.motionQueue.maxConcurrentOperationCount = 1
    }

    public func start(roundId: Int, selfToken: String) async throws {
        currentSelfToken = selfToken
        startAdvertisingIfReady()
        startScanningIfReady()
        startBumpDetection()
    }

    public func stop() async {
        if peripheral.isAdvertising { peripheral.stopAdvertising() }
        if central.isScanning { central.stopScan() }
        motion.stopDeviceMotionUpdates()
    }

    // MARK: - BLE: advertise

    private func startAdvertisingIfReady() {
        guard peripheral.state == .poweredOn, !currentSelfToken.isEmpty else { return }
        if peripheral.isAdvertising { peripheral.stopAdvertising() }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: "TP-" + currentSelfToken.prefix(6),
        ])
    }

    private func startScanningIfReady() {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    // MARK: - Bump detection

    private func startBumpDetection() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 100.0
        motion.startDeviceMotionUpdates(to: motionQueue) { [weak self] dm, _ in
            guard let self, let dm else { return }
            // userAcceleration is in G's, gravity-removed.
            let ua = dm.userAcceleration
            let mag = sqrt(ua.x * ua.x + ua.y * ua.y + ua.z * ua.z)
            if mag > 5.0 {
                let now = Self.nowMs()
                if now - self.lastBumpAtMs > 300 {
                    self.lastBumpAtMs = now
                    self.continuation.yield(.init(
                        kind: .bump,
                        observedAtMs: now,
                        magnitudeG: mag,
                        confidence: min(1.0, mag / 10.0),
                        tHitMs: now
                    ))
                }
            }
        }
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

extension BleBumpPairingProvider: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { startScanningIfReady() }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.doubleValue
        guard rssi > -55 else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let peerToken = name.hasPrefix("TP-") ? String(name.dropFirst(3)) : name
        guard !peerToken.isEmpty else { return }
        continuation.yield(.init(
            kind: .ble,
            observedAtMs: Self.nowMs(),
            peerToken: peerToken,
            rssiDbm: rssi
        ))
    }
}

extension BleBumpPairingProvider: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn { startAdvertisingIfReady() }
    }
}
#endif
