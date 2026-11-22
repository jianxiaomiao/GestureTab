import AppKit
import CoreGraphics
import Foundation

// MARK: - MultitouchSupport C ABI Definitions

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

/// 与 macOS MultitouchSupport.framework 中 MTTouch 结构体完全对齐（96 字节）
private struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var fingerID: Int32
    var handID: Int32
    var normalizedVector: MTVector
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absoluteVector: MTVector
    var zero2: Int32
    var zero3: Int32
    var zDensity: Float
}

private typealias MTContactCallbackFn = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer?,
    Int32,
    Double,
    Int32
) -> Int32

private typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
private typealias MTRegisterContactFrameCallbackFn = @convention(c) (UnsafeMutableRawPointer, MTContactCallbackFn) -> Void
private typealias MTUnregisterContactFrameCallbackFn = @convention(c) (UnsafeMutableRawPointer, MTContactCallbackFn) -> Void
private typealias MTDeviceStartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
private typealias MTDeviceStopFn = @convention(c) (UnsafeMutableRawPointer) -> Void

private weak var sharedMultitouchManager: MultitouchManager?

private let mtFrameCallback: MTContactCallbackFn = { _, dataPtr, numFingers, timestamp, _ in
    guard let dataPtr, numFingers > 0, let manager = sharedMultitouchManager else {
        sharedMultitouchManager?.handleEmptyFrame()
        return 0
    }

    let count = Int(numFingers)
    let touches = dataPtr.assumingMemoryBound(to: MTTouch.self)
    var active: [(id: Int32, x: Float, y: Float)] = []
    active.reserveCapacity(count)

    for i in 0..<count {
        let t = touches[i]
        // state 3 = makeTouch, 4 = touching
        if t.state == 3 || t.state == 4 {
            active.append((id: t.fingerID, x: t.normalizedVector.position.x, y: t.normalizedVector.position.y))
        }
    }

    manager.handleTouches(active, timestamp: timestamp)
    return 0
}

// MARK: - MultitouchManager

final class MultitouchManager {
    enum State {
        case idle
        case armed(anchorTouches: [Int32: (x: Float, y: Float)], accumulatedX: Float, accumulatedY: Float)
        case active
        case cancelled
    }

    var onShowSwitcher: (() -> Void)?
    var onStep: ((_ deltaCol: Int, _ deltaRow: Int) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    private var frameworkHandle: UnsafeMutableRawPointer?
    private var devices: [UnsafeMutableRawPointer] = []

    private var fnCreateList: MTDeviceCreateListFn?
    private var fnRegisterCallback: MTRegisterContactFrameCallbackFn?
    private var fnUnregisterCallback: MTUnregisterContactFrameCallbackFn?
    private var fnStart: MTDeviceStartFn?
    private var fnStop: MTDeviceStopFn?

    private let lock = NSLock()
    private var state: State = .idle
    private var previousTouches: [Int32: (x: Float, y: Float)] = [:]
    private var stepAccumX: Double = 0
    private var stepAccumY: Double = 0
    private var lastStepTimestamp: Double = 0
    private let stepCooldown: Double = 0.08
    private var lowFingerWorkItem: DispatchWorkItem?

    // 边缘 / 持续推力自动步进状态
    private var activeOriginX: Double = 0.5
    private var activeOriginY: Double = 0.5
    private var currentCentroidX: Double = 0.5
    private var currentCentroidY: Double = 0.5
    private var lastSlideUptime: TimeInterval = 0
    private var lastAutoRepeatUptime: TimeInterval = 0
    private var edgeEnteredUptime: TimeInterval?
    private var holdRepeatTimer: Timer?

    // CGEventTap 背景滚动/拖拽拦截状态
    private var isSuppressingInput = false
    private var suppressedMouseDown = false
    private var scrollBlockGraceUntil: TimeInterval = 0

    private var wakeObserver: NSObjectProtocol?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?

    private(set) var isRunning = false
    var isEventTapActive: Bool { eventTap != nil }

    init() {
        sharedMultitouchManager = self
        loadFramework()
    }

    deinit {
        stop()
    }

    private func loadFramework() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_LAZY) else { return }
        frameworkHandle = handle

        if let sym = dlsym(handle, "MTDeviceCreateList") {
            fnCreateList = unsafeBitCast(sym, to: MTDeviceCreateListFn.self)
        }
        if let sym = dlsym(handle, "MTRegisterContactFrameCallback") {
            fnRegisterCallback = unsafeBitCast(sym, to: MTRegisterContactFrameCallbackFn.self)
        }
        if let sym = dlsym(handle, "MTUnregisterContactFrameCallback") {
            fnUnregisterCallback = unsafeBitCast(sym, to: MTUnregisterContactFrameCallbackFn.self)
        }
        if let sym = dlsym(handle, "MTDeviceStart") {
            fnStart = unsafeBitCast(sym, to: MTDeviceStartFn.self)
        }
        if let sym = dlsym(handle, "MTDeviceStop") {
            fnStop = unsafeBitCast(sym, to: MTDeviceStopFn.self)
        }
    }

    func start() {
        stop()
        setupEventTapIfPossible()

        guard let fnCreateList, let fnRegisterCallback, let fnStart,
              let cfArray = fnCreateList()?.takeRetainedValue() else {
            return
        }

        let count = CFArrayGetCount(cfArray)
        for i in 0..<count {
            if let rawPtr = CFArrayGetValueAtIndex(cfArray, i) {
                let dev = UnsafeMutableRawPointer(mutating: rawPtr)
                fnRegisterCallback(dev, mtFrameCallback)
                fnStart(dev, 0)
                devices.append(dev)
            }
        }

        isRunning = !devices.isEmpty

        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.restart()
            }
        }
    }

    func restart() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.start()
        }
    }

    func stop() {
        stopHoldRepeatTimer()
        for dev in devices {
            fnUnregisterCallback?(dev, mtFrameCallback)
            fnStop?(dev)
        }
        devices.removeAll()
        isRunning = false
        resetState()
        teardownEventTap()

        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// 外部按 Esc 取消当前切换
    func cancelCurrentGesture() {
        lock.lock()
        let wasActive: Bool
        switch state {
        case .active:
            wasActive = true
            state = .cancelled
        case .armed:
            wasActive = false
            state = .cancelled
        default:
            wasActive = false
        }
        isSuppressingInput = false
        scrollBlockGraceUntil = ProcessInfo.processInfo.systemUptime + 0.18
        lowFingerWorkItem?.cancel()
        lowFingerWorkItem = nil
        lock.unlock()

        stopHoldRepeatTimer()

        if wasActive {
            DispatchQueue.main.async { [weak self] in
                self?.onCancel?()
            }
        }
    }

    private func resetState() {
        lock.lock()
        state = .idle
        previousTouches = [:]
        stepAccumX = 0
        stepAccumY = 0
        lastStepTimestamp = 0
        edgeEnteredUptime = nil
        isSuppressingInput = false
        suppressedMouseDown = false
        scrollBlockGraceUntil = 0
        lowFingerWorkItem?.cancel()
        lowFingerWorkItem = nil
        lock.unlock()
        stopHoldRepeatTimer()
    }

    // MARK: - Hold-to-Advance Timer (Edge & Sustained Offset)

    private func startHoldRepeatTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.holdRepeatTimer?.invalidate()
            self.holdRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.evaluateHoldRepeat()
            }
        }
    }

    private func stopHoldRepeatTimer() {
        if Thread.isMainThread {
            holdRepeatTimer?.invalidate()
            holdRepeatTimer = nil
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.holdRepeatTimer?.invalidate()
                self?.holdRepeatTimer = nil
            }
        }
    }

    private func evaluateHoldRepeat() {
        guard AppSettings.shared.autoRepeatEnabled else { return }

        let now = ProcessInfo.processInfo.systemUptime

        lock.lock()
        guard case .active = state else {
            lock.unlock()
            return
        }

        let cx = currentCentroidX
        let cy = currentCentroidY
        let lastRepeat = lastAutoRepeatUptime
        let edgeEntered = edgeEnteredUptime

        var dirCol = 0
        var dirRow = 0
        var holdStartTime = now
        let requiredHoldDelay: TimeInterval = 0.20
        let repeatInterval: TimeInterval = 0.21

        // 仅在真正触及触控板最外圈物理边缘（10% 边界区）时才触发边缘连选；
        // 中间区域停住手指绝对保持静止，不自动偏移。
        let edgeMargin = 0.10
        let inRightEdge = cx >= (1.0 - edgeMargin)
        let inLeftEdge = cx <= edgeMargin
        let inTopEdge = cy >= (1.0 - edgeMargin)
        let inBottomEdge = cy <= edgeMargin

        if inRightEdge || inLeftEdge || inTopEdge || inBottomEdge {
            let edgeDistX = inRightEdge ? (cx - (1.0 - edgeMargin)) : (inLeftEdge ? (edgeMargin - cx) : 0)
            let edgeDistY = inTopEdge ? (cy - (1.0 - edgeMargin)) : (inBottomEdge ? (edgeMargin - cy) : 0)

            if edgeDistX >= edgeDistY {
                dirCol = inRightEdge ? 1 : -1
            } else {
                dirRow = inTopEdge ? -1 : 1
            }
            if edgeEntered == nil {
                edgeEnteredUptime = now
            }
            holdStartTime = edgeEnteredUptime ?? now
        } else {
            edgeEnteredUptime = nil
        }

        let shouldFire = (dirCol != 0 || dirRow != 0)
            && (now - holdStartTime >= requiredHoldDelay)
            && (now - lastRepeat >= repeatInterval)

        if shouldFire {
            lastAutoRepeatUptime = now
            stepAccumX = 0
            stepAccumY = 0
        }
        lock.unlock()

        if shouldFire {
            onStep?(dirCol, dirRow)
        }
    }

    // MARK: - Touch Frame State Machine

    fileprivate func handleEmptyFrame() {
        handleTouches([], timestamp: 0)
    }

    fileprivate func handleTouches(_ touches: [(id: Int32, x: Float, y: Float)], timestamp: Double) {
        let mode = AppSettings.shared.gestureMode
        let hStep = AppSettings.shared.horizontalStep
        let vStep = AppSettings.shared.verticalStep
        let haptic = AppSettings.shared.hapticEnabled
        let now = ProcessInfo.processInfo.systemUptime

        var currentMap: [Int32: (x: Float, y: Float)] = [:]
        var sumX: Double = 0
        var sumY: Double = 0
        for t in touches {
            currentMap[t.id] = (t.x, t.y)
            sumX += Double(t.x)
            sumY += Double(t.y)
        }

        lock.lock()
        defer {
            previousTouches = currentMap
            lock.unlock()
        }

        let count = touches.count
        if count > 0 {
            currentCentroidX = sumX / Double(count)
            currentCentroidY = sumY / Double(count)
        }

        // 所有手指离开触控板
        if count == 0 {
            lowFingerWorkItem?.cancel()
            lowFingerWorkItem = nil
            let prevState = state
            state = .idle
            stepAccumX = 0
            stepAccumY = 0
            lastStepTimestamp = 0
            edgeEnteredUptime = nil
            if isSuppressingInput {
                scrollBlockGraceUntil = now + 0.18
            }
            isSuppressingInput = false
            suppressedMouseDown = false

            if case .active = prevState {
                stopHoldRepeatTimer()
                DispatchQueue.main.async { [weak self] in
                    self?.onCommit?()
                }
            }
            return
        }

        switch state {
        case .cancelled:
            // 等待全部手指离开后回到 idle
            return

        case .idle:
            if shouldArm(touches: touches, mode: mode) {
                state = .armed(anchorTouches: currentMap, accumulatedX: 0, accumulatedY: 0)
                // 一进入预备态即屏蔽底层滚动与拖拽，避免滑出前带偏原界面
                isSuppressingInput = true
            }

        case .armed(let anchorTouches, var accX, var accY):
            let requiredCount = (mode == .fourFinger) ? 4 : 3
            if count < requiredCount {
                state = .idle
                isSuppressingInput = false
                scrollBlockGraceUntil = now + 0.12
                return
            }

            let (dx, dy) = sharedDelta(from: previousTouches, to: currentMap)
            accX += dx
            accY += dy

            let distance = hypot(accX, accY)
            if distance >= 0.024 {
                state = .active
                isSuppressingInput = true
                stepAccumX = 0
                stepAccumY = 0
                lastStepTimestamp = timestamp
                activeOriginX = currentCentroidX
                activeOriginY = currentCentroidY
                lastSlideUptime = now
                lastAutoRepeatUptime = now
                edgeEnteredUptime = nil

                startHoldRepeatTimer()
                DispatchQueue.main.async { [weak self] in
                    self?.onShowSwitcher?()
                    if haptic {
                        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                    }
                }
            } else {
                state = .armed(anchorTouches: anchorTouches, accumulatedX: accX, accumulatedY: accY)
            }

        case .active:
            // 当手指数量掉到 1 根或以下时，启动短防抖，确认用户正在松手
            if count <= 1 {
                if lowFingerWorkItem == nil {
                    let item = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.lock.lock()
                        let stillActive: Bool
                        if case .active = self.state {
                            stillActive = true
                            self.state = .idle
                            self.stepAccumX = 0
                            self.stepAccumY = 0
                            self.lastStepTimestamp = 0
                            self.edgeEnteredUptime = nil
                            self.isSuppressingInput = false
                            self.scrollBlockGraceUntil = ProcessInfo.processInfo.systemUptime + 0.18
                        } else {
                            stillActive = false
                        }
                        self.lowFingerWorkItem = nil
                        self.lock.unlock()

                        if stillActive {
                            self.stopHoldRepeatTimer()
                            DispatchQueue.main.async {
                                self.onCommit?()
                            }
                        }
                    }
                    lowFingerWorkItem = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.045, execute: item)
                }
                return
            } else {
                lowFingerWorkItem?.cancel()
                lowFingerWorkItem = nil
            }

            let (dx, dy) = sharedDelta(from: previousTouches, to: currentMap)
            if hypot(dx, dy) > 0.0025 {
                lastSlideUptime = now

                // 若手指往当前偏移的反方向回拉，重新锚定起点以立刻停止同向自动步进
                let offX = currentCentroidX - activeOriginX
                let offY = currentCentroidY - activeOriginY
                if (Double(dx) * offX < -0.015) || (Double(dy) * offY < -0.015) {
                    activeOriginX = currentCentroidX
                    activeOriginY = currentCentroidY
                }
            }

            // 步进冷却期内吸收余波，避免快滑连跳多格
            if timestamp - lastStepTimestamp < stepCooldown {
                return
            }

            stepAccumX += Double(dx)
            stepAccumY += Double(dy)

            let ratioX = abs(stepAccumX) / hStep
            let ratioY = abs(stepAccumY) / vStep

            var deltaCol = 0
            var deltaRow = 0

            if ratioX >= 1.0 && ratioX >= ratioY {
                deltaCol = stepAccumX > 0 ? 1 : -1
            } else if ratioY >= 1.0 {
                // 触控板归一化 y 轴向上增大，网格行号向上减小
                deltaRow = stepAccumY > 0 ? -1 : 1
            }

            if deltaCol != 0 || deltaRow != 0 {
                stepAccumX = 0
                stepAccumY = 0
                lastStepTimestamp = timestamp
                lastAutoRepeatUptime = now
                DispatchQueue.main.async { [weak self] in
                    self?.onStep?(deltaCol, deltaRow)
                }
            }
        }
    }

    private func shouldArm(touches: [(id: Int32, x: Float, y: Float)], mode: GestureMode) -> Bool {
        switch mode {
        case .fourFinger:
            return touches.count >= 4

        case .threeFingerTilted:
            guard touches.count == 3 else { return false }
            let xs = touches.map(\.x)
            let ys = touches.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max() else {
                return false
            }
            let spanX = maxX - minX
            let spanY = maxY - minY
            return spanY / max(spanX, 0.01) >= 0.45
        }
    }

    private func sharedDelta(
        from prev: [Int32: (x: Float, y: Float)],
        to curr: [Int32: (x: Float, y: Float)]
    ) -> (Float, Float) {
        var sumX: Float = 0
        var sumY: Float = 0
        var sharedCount: Float = 0

        for (id, currPos) in curr {
            if let prevPos = prev[id] {
                sumX += currPos.x - prevPos.x
                sumY += currPos.y - prevPos.y
                sharedCount += 1
            }
        }

        guard sharedCount > 0 else { return (0, 0) }
        return (sumX / sharedCount, sumY / sharedCount)
    }

    // MARK: - CGEventTap (Suppress Scroll/Drag Leakage During Gestures)

    private func setupEventTapIfPossible() {
        teardownEventTap()

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << 29) | // NSEventTypeGesture
            (1 << 30) | // NSEventTypeMagnify
            (1 << 31)   // NSEventTypeSwipe

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<MultitouchManager>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = manager.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let now = ProcessInfo.processInfo.systemUptime
            manager.lock.lock()
            let suppress = manager.isSuppressingInput
            let inGrace = now < manager.scrollBlockGraceUntil

            if suppress {
                switch type {
                case .leftMouseDown:
                    manager.suppressedMouseDown = true
                    manager.lock.unlock()
                    return nil
                case .leftMouseUp:
                    let shouldSwallow = manager.suppressedMouseDown
                    manager.suppressedMouseDown = false
                    manager.lock.unlock()
                    return shouldSwallow ? nil : Unmanaged.passUnretained(event)
                default:
                    manager.lock.unlock()
                    return nil
                }
            } else if inGrace {
                let raw = type.rawValue
                let isScrollOrGesture = (type == .scrollWheel || raw == 29 || raw == 30 || raw == 31)
                manager.lock.unlock()
                return isScrollOrGesture ? nil : Unmanaged.passUnretained(event)
            }

            manager.lock.unlock()
            return Unmanaged.passUnretained(event)
        }

        let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        ) ?? CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        )

        guard let tap else { return }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTapSource = source
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func teardownEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        eventTapSource = nil
    }
}
