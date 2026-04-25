// Providers/LobbyTouchJoinProvider.swift
//
// Lets players join a lobby by physically touching phones with the host.
//
// Host flow:
//   - After create_room succeeds and the host receives room_state, advertise
//     the 4-character room code via a lobby-specific BLE service.
//
// Joiner flow:
//   - Scan for that lobby-specific service while on the entry screen.
//   - Cache strong RSSI sightings.
//   - When a bump is detected close to a recent sighting, call back with the
//     room code. AppViewModel then sends the existing join_room message.
//
// This keeps the WebSocket protocol unchanged: "touch to join" is a UX layer
// over the existing room-code join.

#if canImport(CoreBluetooth) && canImport(CoreMotion)
import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import CoreMotion

public final class LobbyTouchJoinProvider: NSObject, @unchecked Sendable {

    public var onRoomCodeDetected: (@Sendable (String) -> Void)?

    private nonisolated(unsafe) static let serviceUUID = CBUUID(string: "A4F9A1A0-0000-4000-8000-000000000002")

    private let central: CBCentralManager
    private let peripheral: CBPeripheralManager
    private let motion = CMMotionManager()
    private let motionQueue = OperationQueue()
    private let stateLock = NSLock()

    private var hostedRoomCode: String?
    private var recentRoomSightings: [String: Int64] = [:]
    private var lastBumpAtMs: Int64 = 0
    private var lastEmittedRoomCode: String?
    private var lastEmittedAtMs: Int64 = 0

    public override init() {
        self.central = CBCentralManager(delegate: nil, queue: nil)
        self.peripheral = CBPeripheralManager(delegate: nil, queue: nil)
        super.init()
        self.central.delegate = self
        self.peripheral.delegate = self
        self.motionQueue.maxConcurrentOperationCount = 1
    }

    public func startScanning() {
        startScanningIfReady()
        startBumpDetection()
    }

    public func startHosting(roomCode: String) {
        let code = roomCode.uppercased()
        guard Self.isValidRoomCode(code) else { return }
        stateLock.locked { hostedRoomCode = code }
        startAdvertisingIfReady()
        startScanning()
    }

    public func stopHosting() {
        stateLock.locked { hostedRoomCode = nil }
        if peripheral.isAdvertising { peripheral.stopAdvertising() }
    }

    public func stopAll() {
        stopHosting()
        if central.isScanning { central.stopScan() }
        motion.stopDeviceMotionUpdates()
        stateLock.locked {
            recentRoomSightings.removeAll()
            lastBumpAtMs = 0
            lastEmittedRoomCode = nil
            lastEmittedAtMs = 0
        }
    }

    private func startAdvertisingIfReady() {
        guard peripheral.state == .poweredOn else { return }
        guard let code = stateLock.locked({ hostedRoomCode }) else { return }
        if peripheral.isAdvertising { peripheral.stopAdvertising() }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: code,
        ])
    }

    private func startScanningIfReady() {
        guard central.state == .poweredOn, !central.isScanning else { return }
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func startBumpDetection() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 100.0
        motion.startDeviceMotionUpdates(to: motionQueue) { [weak self] dm, _ in
            guard let self, let dm else { return }
            let ua = dm.userAcceleration
            let mag = sqrt(ua.x * ua.x + ua.y * ua.y + ua.z * ua.z)
            guard mag > 5.0 else { return }

            let now = Self.nowMs()
            let roomCodes = self.stateLock.locked {
                guard now - self.lastBumpAtMs > 300 else { return [String]() }
                self.lastBumpAtMs = now
                self.pruneSightings(now: now)
                return Array(self.recentRoomSightings.keys)
            }
            for code in roomCodes {
                self.emitRoomCodeIfAllowed(code, now: now)
            }
        }
    }

    private func emitRoomCodeIfAllowed(_ code: String, now: Int64) {
        let shouldEmit = stateLock.locked { () -> Bool in
            guard Self.isValidRoomCode(code) else { return false }
            if lastEmittedRoomCode == code && now - lastEmittedAtMs < 3_000 {
                return false
            }
            lastEmittedRoomCode = code
            lastEmittedAtMs = now
            return true
        }
        if shouldEmit {
            onRoomCodeDetected?(code)
        }
    }

    private func pruneSightings(now: Int64) {
        let cutoff = now - 5_000
        recentRoomSightings = recentRoomSightings.filter { _, seenAt in seenAt >= cutoff }
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func isValidRoomCode(_ code: String) -> Bool {
        code.count == 4 && code.unicodeScalars.allSatisfy { scalar in
            (65...90).contains(Int(scalar.value)) || (50...57).contains(Int(scalar.value))
        }
    }
}

extension LobbyTouchJoinProvider: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { startScanningIfReady() }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.doubleValue
        guard rssi > -55 else { return }
        let code = ((advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard Self.isValidRoomCode(code) else { return }

        let now = Self.nowMs()
        let bumpWasRecent = stateLock.locked {
            recentRoomSightings[code] = now
            pruneSightings(now: now)
            return now - lastBumpAtMs <= 2_000
        }
        if bumpWasRecent {
            emitRoomCodeIfAllowed(code, now: now)
        }
    }
}

extension LobbyTouchJoinProvider: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn { startAdvertisingIfReady() }
    }
}
#endif
