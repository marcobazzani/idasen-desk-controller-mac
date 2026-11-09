//
//  DeskPeripheral.swift
//  Desk Controller
//
//  Created by David Williames on 10/1/21.
//

import Cocoa
@preconcurrency import CoreBluetooth

@MainActor
class DeskPeripheral: NSObject {

    public static let deskPositionServiceUUID = CBUUID.init(string: "99FA0020-338A-1024-8A49-009C0215F78A")
    public static let deskPositionCharacteristicUUID = CBUUID.init(string: "99FA0021-338A-1024-8A49-009C0215F78A")

    public static let deskControlServiceUUID = CBUUID.init(string: "99FA0001-338A-1024-8A49-009C0215F78A")
    public static let deskControlCharacteristicUUID = CBUUID.init(string: "99FA0002-338A-1024-8A49-009C0215F78A")

    // DPG service: capabilities, user ID, etc. (see rhyst/linak-controller)
    public static let deskDPGServiceUUID = CBUUID.init(string: "99FA0010-338A-1024-8A49-009C0215F78A")
    public static let deskDPGCharacteristicUUID = CBUUID.init(string: "99FA0011-338A-1024-8A49-009C0215F78A")

    // Reference Input: write a target height and the desk drives there itself.
    public static let deskReferenceInputServiceUUID = CBUUID.init(string: "99FA0030-338A-1024-8A49-009C0215F78A")
    public static let deskReferenceInputCharacteristicUUID = CBUUID.init(string: "99FA0031-338A-1024-8A49-009C0215F78A")

    static let heightPositionOffset: Float = 61.5 // min

    // Control-characteristic commands
    static let commandWakeUp = Data([0xFE, 0x00])
    static let commandStop = Data([0xFF, 0x00])

    // DPG commands
    static let dpgCommandUserID: UInt8 = 0x86


    let peripheral: CBPeripheral

    var positionService: CBService?
    var positionCharacteristic: CBCharacteristic?

    var controlService: CBService?
    var controlCharacteristic: CBCharacteristic?

    var dpgCharacteristic: CBCharacteristic?
    var referenceInputCharacteristic: CBCharacteristic?

    private enum DPGState {
        case idle, readingUserID, writingUserID
    }
    private var dpgState: DPGState = .idle


    var speed: Float = 0

    var hasLoadedPositionCharacteristicValues = false

    var onPositionChange: (Float) -> Void = { _ in }
    var position: Float? {
        didSet {
            if let position = position, hasLoadedPositionCharacteristicValues {
                onPositionChange(position)
            }
        }
    }

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral

        super.init()

        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    // MARK: - Writes

    /// Write using the type the characteristic supports (some Linak
    /// controllers only expose write-without-response on certain channels).
    func write(_ data: Data, to characteristic: CBCharacteristic) {
        let type: CBCharacteristicWriteType =
            characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: type)
    }

    /// Wake the controller. Once its Bluetooth has gone to sleep, the desk
    /// ignores movement commands until it has been woken.
    func wakeUp() {
        guard let controlCharacteristic else { return }
        dbg("wakeUp: writing FE00")
        write(DeskPeripheral.commandWakeUp, to: controlCharacteristic)
    }

    func sendStop() {
        guard let controlCharacteristic else { return }
        write(DeskPeripheral.commandStop, to: controlCharacteristic)
    }

    /// Ask the desk to drive to `height` (in the app's cm scale, i.e. the same
    /// scale as `position`). Must be re-sent periodically while moving.
    /// Returns false when the Reference Input characteristic isn't available.
    @discardableResult
    func writeReferenceHeight(_ height: Float) -> Bool {
        guard let referenceInputCharacteristic else { return false }
        // Inverse of the position decoding: position = raw / 100 + offset
        let raw = ((height - DeskPeripheral.heightPositionOffset) * 100).rounded()
        let clamped = UInt16(max(0, min(Float(UInt16.max), raw)))
        let data = Data([UInt8(clamped & 0xFF), UInt8(clamped >> 8)])
        dbg("writeReferenceHeight: \(String(format: "%.1f", height)) cm → raw \(clamped)")
        write(data, to: referenceInputCharacteristic)
        return true
    }

    // MARK: - DPG user ID

    /// Make sure the desk's user ID marks us as the "owner" (first byte 0x01),
    /// as linak-controller does. DPG1C (IKEA IDÅSEN) panels may otherwise ignore
    /// movement commands. Flow: subscribe → read request → (write if needed)
    /// → unsubscribe. The read request is sent once notifications are on.
    private func beginUserIDCheck() {
        guard let dpgCharacteristic, dpgState == .idle else { return }
        dbg("DPG: subscribing to check user ID")
        dpgState = .readingUserID
        peripheral.setNotifyValue(true, for: dpgCharacteristic)
    }

    private func handleDPGNotification(_ value: Data) {
        let bytes = [UInt8](value)
        dbg("DPG notification: \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")

        switch dpgState {
        case .readingUserID:
            guard bytes.count > 2, bytes[0] == 0x01 else {
                dbg("DPG: invalid user ID response, giving up")
                finishDPG()
                return
            }
            var userID = Array(bytes[2...])
            if userID.first == 0x01 {
                dbg("DPG: user ID already owner")
                finishDPG()
                return
            }
            userID[0] = 0x01
            dbg("DPG: setting user ID owner byte")
            dpgState = .writingUserID
            if let dpgCharacteristic {
                write(Data([0x7F, DeskPeripheral.dpgCommandUserID, 0x80] + userID), to: dpgCharacteristic)
            }
        case .writingUserID:
            // Acknowledgement of the write
            finishDPG()
        case .idle:
            break
        }
    }

    private func finishDPG() {
        dpgState = .idle
        if let dpgCharacteristic {
            peripheral.setNotifyValue(false, for: dpgCharacteristic)
        }
    }
}

extension DeskPeripheral: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil, peripheral == self.peripheral, let services = peripheral.services else {
                return
            }

            services.forEach { service in
                if service.uuid == DeskPeripheral.deskPositionServiceUUID {
                    positionService = service
                } else if service.uuid == DeskPeripheral.deskControlServiceUUID {
                    controlService = service
                } else if service.uuid == DeskPeripheral.deskDPGServiceUUID
                            || service.uuid == DeskPeripheral.deskReferenceInputServiceUUID {
                    // Characteristics captured in didDiscoverCharacteristics
                } else {
                    return
                }

                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil, peripheral == self.peripheral, let characteristics = service.characteristics else {
                dbg("didDiscoverCharacteristics: error=\(String(describing: error)) same=\(peripheral == self.peripheral) count=\(service.characteristics?.count ?? -1)")
                return
            }

            characteristics.forEach { characteristic in
                if characteristic.uuid == DeskPeripheral.deskPositionCharacteristicUUID {
                    dbg("found positionCharacteristic, subscribing")
                    positionCharacteristic = characteristic
                    peripheral.readValue(for: characteristic)
                    peripheral.setNotifyValue(true, for: characteristic)
                } else if characteristic.uuid == DeskPeripheral.deskControlCharacteristicUUID {
                    dbg("found controlCharacteristic")
                    controlCharacteristic = characteristic
                    if Preferences.shared.useReferenceInputDrive {
                        wakeUp()
                    }
                } else if characteristic.uuid == DeskPeripheral.deskDPGCharacteristicUUID {
                    dbg("found dpgCharacteristic")
                    dpgCharacteristic = characteristic
                    if Preferences.shared.useReferenceInputDrive {
                        beginUserIDCheck()
                    }
                } else if characteristic.uuid == DeskPeripheral.deskReferenceInputCharacteristicUUID {
                    dbg("found referenceInputCharacteristic")
                    referenceInputCharacteristic = characteristic
                } else {
                    return
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                dbg("didWriteValueFor \(characteristic.uuid.uuidString) ERROR: \(error.localizedDescription)")
            } else {
                dbg("didWriteValueFor \(characteristic.uuid.uuidString) OK")
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic == dpgCharacteristic, dpgState == .readingUserID else { return }
            if let error {
                dbg("DPG: enabling notifications failed: \(error.localizedDescription)")
                dpgState = .idle
                return
            }
            if characteristic.isNotifying {
                // Read request: [0x7F, command, 0x00]
                write(Data([0x7F, DeskPeripheral.dpgCommandUserID, 0x00]), to: characteristic)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if characteristic == dpgCharacteristic, let value = characteristic.value, error == nil {
                handleDPGNotification(value)
                return
            }
            if characteristic == positionCharacteristic, let value = characteristic.value, error == nil {

                hasLoadedPositionCharacteristicValues = true

                // Position = 16 Little Endian – Unsigned
                // Speed = 16 Little Endian – Signed

                let positionValue = [value[0], value[1]].withUnsafeBytes {
                    $0.load(as: UInt16.self)
                }

                let speedValue = [value[2], value[3]].withUnsafeBytes {
                    $0.load(as: Int16.self)
                }

                speed = Float(speedValue)
                position = Float(positionValue) / 100 + DeskPeripheral.heightPositionOffset
                dbg("position notification: raw=\(positionValue) speed=\(speedValue) → \(String(format: "%.1f", position ?? -1)) cm")
            }
        }
    }

}
