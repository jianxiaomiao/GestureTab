import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class WindowSnapManager {
    static let shared = WindowSnapManager()

    private enum DragState {
        case idle
        case candidate(axWin: AXUIElement, wid: CGWindowID?, startFrame: CGRect, downMouseAX: CGPoint)
        case dragging(axWin: AXUIElement, wid: CGWindowID?, startFrame: CGRect, restoredOnce: Bool)
        case ignored
    }

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var dragState: DragState = .idle

    private let previewOverlay = SnapPreviewOverlayController()
    private let layoutBar = SnapLayoutBarController()
    private var currentTarget: SnapTarget?
    private var topDwellStartTime: TimeInterval?
    private var topDwellWorkItem: DispatchWorkItem?

    /// 记录已被分屏/最大化的窗口原始尺寸，拖离边缘时自动还原
    private var snappedOriginalFrames: [CGWindowID: CGRect] = [:]

    private init() {
        SnapAssistController.shared.onWindowSnapped = { [weak self] wid, originalFrame, _ in
            if self?.snappedOriginalFrames[wid] == nil {
                self?.snappedOriginalFrames[wid] = originalFrame
            }
        }
    }

    deinit {
        stop()
    }

    func start() {
        stop()
        guard AppSettings.shared.snapEnabled else { return }

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<WindowSnapManager>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = manager.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let location = event.location
            DispatchQueue.main.async {
                manager.handleMouseEvent(type: type, axLocation: location)
            }
            return Unmanaged.passUnretained(event)
        }

        // 使用 listenOnly 被动监听：零延迟、不拦截鼠标事件，同时兼容系统三指拖移
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
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

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        eventTapSource = nil
        resetDrag()
    }

    // MARK: - Mouse Drag State Machine

    private func handleMouseEvent(type: CGEventType, axLocation: CGPoint) {
        guard AppSettings.shared.snapEnabled,
              WindowService.hasAccessibilityPermission(prompt: false) else {
            resetDrag()
            return
        }

        switch type {
        case .leftMouseDown:
            resetDrag()
            if let info = windowUnderCursor(at: axLocation) {
                dragState = .candidate(
                    axWin: info.axWin,
                    wid: info.wid,
                    startFrame: info.frame,
                    downMouseAX: axLocation
                )
            }

        case .leftMouseDragged:
            handleDragged(at: axLocation)

        case .leftMouseUp:
            handleMouseUp()

        default:
            break
        }
    }

    private func handleDragged(at axLocation: CGPoint) {
        switch dragState {
        case .idle, .ignored:
            return

        case .candidate(let axWin, let wid, let startFrame, let downMouseAX):
            guard let curFrame = WindowService.shared.getWindowFrame(axWin) else {
                dragState = .ignored
                return
            }

            // 尺寸发生变化说明用户正在拖拽边框调整窗口大小，非整窗移动
            if abs(curFrame.width - startFrame.width) > 2 || abs(curFrame.height - startFrame.height) > 2 {
                dragState = .ignored
                return
            }

            // 窗口位置整体移动 >= 4pt，确认为拖动窗口
            if hypot(curFrame.origin.x - startFrame.origin.x, curFrame.origin.y - startFrame.origin.y) >= 4 {
                SnapAssistController.shared.dismiss()
                dragState = .dragging(axWin: axWin, wid: wid, startFrame: startFrame, restoredOnce: false)
                evaluateHotZones(at: axLocation)
                return
            }

            // 鼠标在窗口内移动超过 28pt 但窗口没动，说明用户在框选文字或拖动网页内容
            if hypot(axLocation.x - downMouseAX.x, axLocation.y - downMouseAX.y) >= 28 {
                dragState = .ignored
            }

        case .dragging(let axWin, let wid, let startFrame, var restoredOnce):
            // 拖离之前已分屏/最大化的状态超过 28pt 时，自动恢复原始窗口尺寸
            if !restoredOnce,
               let wid,
               let origFrame = snappedOriginalFrames[wid],
               let curFrame = WindowService.shared.getWindowFrame(axWin),
               hypot(curFrame.origin.x - startFrame.origin.x, curFrame.origin.y - startFrame.origin.y) >= 28 {
                let restoredW = origFrame.width
                let restoredH = origFrame.height
                let centeredX = round(axLocation.x - restoredW / 2)
                let targetY = round(max(curFrame.origin.y, axLocation.y - 16))
                let restoredRect = CGRect(x: centeredX, y: targetY, width: restoredW, height: restoredH)
                WindowService.shared.setWindowFrame(axWin, axFrame: restoredRect)
                snappedOriginalFrames.removeValue(forKey: wid)
                restoredOnce = true
                dragState = .dragging(axWin: axWin, wid: wid, startFrame: startFrame, restoredOnce: true)
            }

            evaluateHotZones(at: axLocation)
        }
    }

    private func handleMouseUp() {
        defer { resetDrag() }

        guard case .dragging(let axWin, let wid, let startFrame, _) = dragState,
              let target = currentTarget else {
            return
        }

        if let wid, snappedOriginalFrames[wid] == nil {
            snappedOriginalFrames[wid] = startFrame
        }

        WindowService.shared.setWindowFrame(axWin, axFrame: target.axRect)

        if AppSettings.shared.hapticEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }

        if AppSettings.shared.snapAssistEnabled && target.layout.zones.count > 1 {
            let capturedScreen = target.screen
            let capturedLayout = target.layout
            let capturedZone = target.zoneIndex
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                SnapAssistController.shared.begin(
                    on: capturedScreen,
                    layout: capturedLayout,
                    filledZoneIndex: capturedZone,
                    primaryWindowID: wid
                )
            }
        }
    }

    private func resetDrag() {
        dragState = .idle
        currentTarget = nil
        cancelTopDwell()
        previewOverlay.hide()
        layoutBar.hide()
    }

    private func cancelTopDwell() {
        topDwellStartTime = nil
        topDwellWorkItem?.cancel()
        topDwellWorkItem = nil
    }

    // MARK: - Hot Zone Evaluation

    private func evaluateHotZones(at axLocation: CGPoint) {
        let cocoaMouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cocoaMouse) })
            ?? NSScreen.main
            ?? NSScreen.screens.first else {
            clearTarget()
            return
        }

        let screenAX = WindowService.cocoaRectToAXRect(screen.frame)
        let visibleAX = WindowService.cocoaRectToAXRect(screen.visibleFrame)
        let now = ProcessInfo.processInfo.systemUptime

        // 1) 若顶部悬浮分屏布局栏已展开，优先命中其中的具体布局格
        if layoutBar.isVisible {
            if let barTarget = layoutBar.hitTest(cocoaMouse: cocoaMouse) {
                currentTarget = barTarget
                previewOverlay.showPreview(cocoaRect: barTarget.cocoaRect)
                return
            }

            let barTopTolerance = visibleAX.minY + 145
            let barPF = layoutBar.panelFrame
            if axLocation.y <= barTopTolerance &&
               axLocation.x >= barPF.minX - 40 &&
               axLocation.x <= barPF.maxX + 40 {
                // 鼠标在布局栏边缘过渡地带，保持布局栏展开但清除错误预览
                currentTarget = nil
                previewOverlay.hide()
                return
            } else {
                layoutBar.hide()
            }
        }

        // 2) 四角 1/4 分屏热区（L 形角落判定，优先于单边）
        let cornerW = min(130, visibleAX.width * 0.11)
        let cornerH = min(110, visibleAX.height * 0.12)
        let edgeStrip: CGFloat = 18

        let nearLeftEdge = axLocation.x <= screenAX.minX + edgeStrip
        let nearRightEdge = axLocation.x >= screenAX.maxX - edgeStrip
        let nearTopEdge = axLocation.y <= visibleAX.minY + edgeStrip
        let nearBottomEdge = axLocation.y >= min(visibleAX.maxY, screenAX.maxY) - edgeStrip

        let inLeftBand = axLocation.x <= screenAX.minX + cornerW
        let inRightBand = axLocation.x >= screenAX.maxX - cornerW
        let inTopBand = axLocation.y <= visibleAX.minY + cornerH
        let inBottomBand = axLocation.y >= screenAX.maxY - cornerH

        if (nearTopEdge && inLeftBand) || (nearLeftEdge && inTopBand) {
            cancelTopDwell()
            selectTarget(SnapTarget(screen: screen, layout: .quarters, zoneIndex: 0))
            return
        }
        if (nearTopEdge && inRightBand) || (nearRightEdge && inTopBand) {
            cancelTopDwell()
            selectTarget(SnapTarget(screen: screen, layout: .quarters, zoneIndex: 1))
            return
        }
        if (nearBottomEdge && inLeftBand) || (nearLeftEdge && inBottomBand) {
            cancelTopDwell()
            selectTarget(SnapTarget(screen: screen, layout: .quarters, zoneIndex: 2))
            return
        }
        if (nearBottomEdge && inRightBand) || (nearRightEdge && inBottomBand) {
            cancelTopDwell()
            selectTarget(SnapTarget(screen: screen, layout: .quarters, zoneIndex: 3))
            return
        }

        // 3) 顶部热区：最大化 / 顶部悬浮分屏布局（支持两种可切换模式）
        if nearTopEdge {
            let relX = (axLocation.x - visibleAX.minX) / max(visibleAX.width, 1)

            switch AppSettings.shared.topSnapZoneMode {
            case .fixedCenterLayout:
                if relX >= 0.36 && relX <= 0.64 {
                    layoutBar.show(on: screen)
                    if let barTarget = layoutBar.hitTest(cocoaMouse: cocoaMouse) {
                        selectTarget(barTarget)
                    } else {
                        currentTarget = nil
                        previewOverlay.hide()
                    }
                } else {
                    selectTarget(SnapTarget(screen: screen, layout: .maximize, zoneIndex: 0))
                }

            case .hoverToExpand:
                let pushedVeryTop = axLocation.y <= screenAX.minY + 5
                let targetDelay: TimeInterval = pushedVeryTop ? 0.18 : 0.42

                if topDwellStartTime == nil {
                    topDwellStartTime = now
                    let item = DispatchWorkItem { [weak self] in
                        guard let self, case .dragging = self.dragState else { return }
                        self.layoutBar.show(on: screen)
                        let mouseNow = NSEvent.mouseLocation
                        if let barTarget = self.layoutBar.hitTest(cocoaMouse: mouseNow) {
                            self.selectTarget(barTarget)
                        } else {
                            self.currentTarget = nil
                            self.previewOverlay.hide()
                        }
                    }
                    topDwellWorkItem?.cancel()
                    topDwellWorkItem = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + targetDelay, execute: item)
                }

                let dwellDuration = now - (topDwellStartTime ?? now)
                if dwellDuration >= targetDelay {
                    topDwellWorkItem?.cancel()
                    topDwellWorkItem = nil
                    layoutBar.show(on: screen)
                    if let barTarget = layoutBar.hitTest(cocoaMouse: cocoaMouse) {
                        selectTarget(barTarget)
                    } else {
                        currentTarget = nil
                        previewOverlay.hide()
                    }
                } else {
                    selectTarget(SnapTarget(screen: screen, layout: .maximize, zoneIndex: 0))
                }
            }
            return
        }

        cancelTopDwell()

        // 4) 左右边缘 1/2 分屏
        if nearLeftEdge {
            selectTarget(SnapTarget(screen: screen, layout: .halves, zoneIndex: 0))
            return
        }
        if nearRightEdge {
            selectTarget(SnapTarget(screen: screen, layout: .halves, zoneIndex: 1))
            return
        }

        clearTarget()
    }

    private func selectTarget(_ target: SnapTarget) {
        if currentTarget != target {
            currentTarget = target
            if AppSettings.shared.hapticEnabled {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
        previewOverlay.showPreview(cocoaRect: target.cocoaRect)
    }

    private func clearTarget() {
        currentTarget = nil
        previewOverlay.hide()
    }

    // MARK: - Window Hit Testing

    private func windowUnderCursor(at axLocation: CGPoint) -> (axWin: AXUIElement, wid: CGWindowID?, frame: CGRect)? {
        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(axLocation.x),
            Float(axLocation.y),
            &elementRef
        ) == .success, let startEl = elementRef else {
            return nil
        }

        var current: AXUIElement? = startEl
        var resolvedWin: AXUIElement?
        for _ in 0..<10 {
            guard let el = current else { break }
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
               (roleRef as? String) == (kAXWindowRole as String) {
                resolvedWin = el
                break
            }
            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parentRef) == .success,
               let parent = parentRef {
                current = (parent as! AXUIElement)
            } else {
                break
            }
        }

        guard let axWin = resolvedWin else { return nil }

        var pid: pid_t = 0
        AXUIElementGetPid(axWin, &pid)
        guard pid != 0, pid != ProcessInfo.processInfo.processIdentifier else { return nil }

        // 忽略全屏窗口与非标准弹窗
        var fsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWin, "AXFullScreen" as CFString, &fsRef) == .success,
           (fsRef as? Bool) == true {
            return nil
        }

        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWin, kAXSubroleAttribute as CFString, &subroleRef)
        if let subrole = subroleRef as? String, subrole != "AXStandardWindow" && subrole != "AXDialog" {
            return nil
        }

        guard let frame = WindowService.shared.getWindowFrame(axWin) else { return nil }
        let wid = WindowService.shared.getWindowID(for: axWin)
        return (axWin, wid, frame)
    }
}
