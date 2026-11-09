//
//  DeskController.swift
//  Desk Controller
//
//  Created by David Williames on 10/1/21.
//

import Cocoa


enum MovingDirection: Sendable {
    case up, down, none
}

@MainActor
class DeskController: NSObject {

    var onCurrentMovingDirectionChange: (MovingDirection) -> Void = { _ in }
    var currentMovingDirection: MovingDirection = .none {
        didSet {
            onCurrentMovingDirectionChange(currentMovingDirection)
        }
    }


    var movingToPosition: Position? = nil {
        didSet {
            if movingToPosition == nil {
                cancelReferenceMove()
            } else if shouldUseReferenceInput {
                startReferenceMove()
                return
            }
            moveIfNeeded()
        }
    }

    // MARK: - Reference Input drive state

    /// Interval between re-sent target heights; matches linak-controller.
    let referenceMoveInterval: TimeInterval = 0.4
    /// Safety cap on a single target move.
    let referenceMoveTimeout: TimeInterval = 60

    private var referenceMoveTimer: Timer?
    private var referenceMoveTicks = 0
    private var referenceMoveStartPosition: Float?
    /// Set when the desk ignored a reference-input move; the rest of that
    /// move (and following ones, until reconnect) uses the classic pulses.
    private var referenceInputUnresponsive = false

    private var shouldUseReferenceInput: Bool {
        Preferences.shared.useReferenceInputDrive
            && desk.referenceInputCharacteristic != nil
            && !referenceInputUnresponsive
    }

    let desk: DeskPeripheral

    let autoStand: AutoStand

    let distanceOffset: Float = 0.5
    let minDurationIncrements: TimeInterval = 0.5
    var lastMoveTime: Date

    let minMovementIncrements: Float = 0.5
    var previousMovementIncrement: Float

    static var shared: DeskController?

    private var positionChangeCallbacks = [(Float) -> Void]()

    init(desk: DeskPeripheral) {
        self.desk = desk
        self.lastMoveTime = Date().addingTimeInterval(-minDurationIncrements)
        self.previousMovementIncrement = minMovementIncrements
        self.autoStand = AutoStand()
        super.init()

        desk.onPositionChange = { [weak self] position in
            self?.moveIfNeeded()
            self?.positionChangeCallbacks.forEach { $0(position) }
            // Phase indicator (icon + popover label) is position-based; let
            // AutoStand reread and (de-duped) broadcast on every position
            // update so the indicator flips when the desk crosses midpoint.
            self?.autoStand.deskPositionChanged()
        }

        DeskController.shared = self

        autoStand.update()
        NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(onWakeNote(note:)),
                name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc func onWakeNote(note: NSNotification) {
        BluetoothManager.shared.reconnect()
    }


    func onPositionChange(_ callback: @escaping (Float) -> Void) {
        positionChangeCallbacks.append(callback)
    }


    func moveUp() {
        guard let characteristic = desk.controlCharacteristic else {
            dbg("moveUp: NO controlCharacteristic")
            return
        }

        if let data = Data(hexString: "4700") {
            dbg("moveUp: writing 4700 to \(characteristic.uuid.uuidString)")
            desk.peripheral.writeValue(data, for: characteristic, type: .withResponse)
            lastMoveTime = Date()
            currentMovingDirection = .up
        }
    }

    func moveDown() {
        guard let characteristic = desk.controlCharacteristic else {
            dbg("moveDown: NO controlCharacteristic")
            return
        }

        if let data = Data(hexString: "4600") {
            dbg("moveDown: writing 4600 to \(characteristic.uuid.uuidString)")
            desk.peripheral.writeValue(data, for: characteristic, type: .withResponse)
            lastMoveTime = Date()
            currentMovingDirection = .down
        }
    }

    func stopMoving() {
        dbg("stopMoving()")
        guard let characteristic = desk.controlCharacteristic else {
            dbg("stopMoving: NO controlCharacteristic")
            return
        }

        if let data = Data(hexString: "FF00") {
            dbg("stopMoving: writing FF00")
            desk.peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }

        stopHoldTimer()
        currentMovingDirection = .none
        movingToPosition = nil
        previousPosition = nil
    }

    func moveToPosition(_ position: Position) {
        // Clear `previousPosition` so `moveIfNeeded`'s "did the desk actually
        // move?" guard doesn't block the FIRST packet of a fresh move. The
        // guard exists to detect a non-responding desk during a multi-packet
        // travel; on a brand-new target the previous position is stale (from
        // the last move that ended) and `distSincePrev` would read as 0,
        // causing the first move-down/up command to be silently dropped.
        previousPosition = nil
        movingToPosition = position
    }

    func moveToHeight(_ height: Float) {
        previousPosition = nil
        movingToPosition = .custom(height: height)
    }

    // MARK: - Reference Input driver
    //
    // Newer Linak protocol (as used by rhyst/linak-controller): wake the
    // controller, then write the target height to the Reference Input
    // characteristic every ~400 ms. The desk ramps up/down and stops at the
    // target by itself. If the desk doesn't move at all, fall back to the
    // classic up/down pulses for the rest of the connection.

    private func startReferenceMove() {
        guard let target = movingToPosition else { return }
        stopHoldTimer()
        cancelReferenceMove()

        let targetHeight = Preferences.shared.forPosition(target)
        dbg("startReferenceMove: target=\(String(format: "%.1f", targetHeight))")

        referenceMoveStartPosition = desk.position
        referenceMoveTicks = 0
        if let position = desk.position {
            currentMovingDirection = targetHeight > position ? .up : (targetHeight < position ? .down : .none)
        }

        desk.wakeUp()
        desk.sendStop()
        desk.writeReferenceHeight(targetHeight)

        let timer = Timer(timeInterval: referenceMoveInterval, repeats: true) { @Sendable [weak self] _ in
            MainActor.assumeIsolated {
                self?.referenceMoveTick(targetHeight: targetHeight)
            }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        referenceMoveTimer = timer
    }

    private func referenceMoveTick(targetHeight: Float) {
        referenceMoveTicks += 1
        let elapsed = Double(referenceMoveTicks) * referenceMoveInterval
        guard let position = desk.position else {
            // No height reading yet; keep asserting the target.
            if elapsed > referenceMoveTimeout {
                stopMoving()
            } else {
                desk.writeReferenceHeight(targetHeight)
            }
            return
        }
        let speed = desk.speed

        // Arrived (don't rely solely on a final speed==0 notification).
        if referenceMoveTicks >= 2 && abs(position - targetHeight) < 0.3 {
            dbg("referenceMove: reached target at \(String(format: "%.1f", position))")
            finishReferenceMove()
            return
        }

        // Give the desk a couple of ticks to start moving before judging it.
        if referenceMoveTicks >= 2 && speed == 0 {
            let moved = abs(position - (referenceMoveStartPosition ?? position)) >= minMovementIncrements
            let atTarget = abs(position - targetHeight) < 1
            if !moved && !atTarget {
                dbg("referenceMove: desk didn't move; falling back to classic commands")
                referenceInputUnresponsive = true
                cancelReferenceMove()
                previousPosition = nil
                moveIfNeeded()   // continue this move with the pulse driver
                return
            }
            dbg("referenceMove: finished at \(String(format: "%.1f", position))")
            finishReferenceMove()
            return
        }

        if elapsed > referenceMoveTimeout {
            dbg("referenceMove: timeout")
            stopMoving()
            return
        }

        desk.writeReferenceHeight(targetHeight)
    }

    private func cancelReferenceMove() {
        referenceMoveTimer?.invalidate()
        referenceMoveTimer = nil
        referenceMoveStartPosition = nil
    }

    private func finishReferenceMove() {
        cancelReferenceMove()
        currentMovingDirection = .none
        movingToPosition = nil
        previousPosition = nil
    }

    // MARK: - Manual hold-button driver
    //
    // Linak desks need a `move` command resent every ~500ms to keep moving. The
    // `moveIfNeeded` loop is normally driven by incoming position notifications,
    // but those only fire while the desk is actually moving — chicken & egg if
    // the first packet doesn't budge the desk for any reason. For the arrow
    // buttons (manual hold-to-nudge) drive the resend with a timer instead so
    // the loop never depends on the desk talking back to us.

    private var holdTimer: Timer?

    func startHoldingDown() {
        startHolding(direction: .down)
    }

    func startHoldingUp() {
        startHolding(direction: .up)
    }

    private func startHolding(direction: MovingDirection) {
        dbg("startHolding(direction=\(direction))")
        stopHoldTimer()
        // Cancel any in-flight automatic target so `moveIfNeeded` (driven by
        // position notifications) doesn't fight us by issuing stopMoving when
        // it thinks we passed the target.
        movingToPosition = nil

        if Preferences.shared.useReferenceInputDrive {
            desk.wakeUp()
        }

        sendHoldPacket(direction: direction)

        let timer = Timer(timeInterval: 0.4, repeats: true) { @Sendable [weak self] _ in
            MainActor.assumeIsolated {
                dbg("hold timer fired (direction=\(direction))")
                self?.sendHoldPacket(direction: direction)
            }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func sendHoldPacket(direction: MovingDirection) {
        switch direction {
        case .up:   moveUp()
        case .down: moveDown()
        case .none: break
        }
    }

    private func stopHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }


    var previousPosition: Float?

    private func moveIfNeeded() {

        // The reference-input driver owns the move while its timer runs.
        guard referenceMoveTimer == nil else { return }

        guard let toPosition = movingToPosition, var position = desk.position else {
            if movingToPosition != nil {
                dbg("moveIfNeeded: target set but desk.position is nil")
            }
            return
        }

        let speed = desk.speed

        let timeSinceLastMove = lastMoveTime.distance(to: Date())
        let distanceSincePreviousPosition = abs((previousPosition ?? position + minMovementIncrements) - position)


        let positionToMoveTo = Preferences.shared.forPosition(toPosition)

        let dirInt = (currentMovingDirection == .up ? 1 : (currentMovingDirection == .down ? -1 : 0))
        dbg("moveIfNeeded: pos=\(String(format: "%.1f", position)) target=\(String(format: "%.1f", positionToMoveTo)) speed=\(String(format: "%.1f", speed)) dir=\(dirInt) tsLast=\(String(format: "%.2f", timeSinceLastMove)) distSincePrev=\(String(format: "%.2f", distanceSincePreviousPosition))")


        if positionToMoveTo > position {

            if currentMovingDirection == .up {
                position += distanceOffset
            }

            if position < positionToMoveTo && speed >= 0 {
                if timeSinceLastMove > minDurationIncrements && distanceSincePreviousPosition >= minMovementIncrements {
                    previousPosition = position
                    moveUp()
                }

            } else {
                stopMoving()
            }
        } else if positionToMoveTo < position {

            if currentMovingDirection == .down {
                position -= distanceOffset
            }

            if position > positionToMoveTo && speed <= 0 {
                if timeSinceLastMove > minDurationIncrements && distanceSincePreviousPosition >= minMovementIncrements {
                    previousPosition = position
                    moveDown()
                }
            } else {
                stopMoving()
            }
        }


    }
}
