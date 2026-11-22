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

    /// 记录已被分屏/最大化的窗口原始尺寸，拖离边缘时自动还原
    private var snappedOriginalFrames: [CGWindowID: CGRect] = [:]

    var isDraggingWindow: Bool {
        if case .dragging = dragState { return true }
        return false
    }

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

            // 窗口位置整体移动 >= 3pt，确认为拖动窗口
            if hypot(curFrame.origin.x - startFrame.origin.x, curFrame.origin.y - startFrame.origin.y) >= 3 {
                SnapAssistController.shared.dismiss()
                dragState = .dragging(axWin: axWin, wid: wid, startFrame: startFrame, restoredOnce: false)
                evaluateHotZones(at: axLocation)
                return
            }

            // 鼠标移动超过 28pt 但窗口没动：若在窗口内容区（非标题栏顶边夹紧情况），说明在框选文字/拖内容
            let clickedInTitlebar = (downMouseAX.y - startFrame.origin.y) <= 60
            let pushedAtTopClamp = axLocation.y <= startFrame.origin.y + 8
            if clickedInTitlebar && pushedAtTopClamp {
                SnapAssistController.shared.dismiss()
                dragState = .dragging(axWin: axWin, wid: wid, startFrame: startFrame, restoredOnce: false)
                evaluateHotZones(at: axLocation)
                return
            }

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

        let targetAXRect = target.axRect
        WindowService.shared.setWindowFrame(axWin, axFrame: targetAXRect)
        // 部分应用（如 Electron/Antigravity/Chrome）在松手同一帧会覆盖尺寸，60ms 后补设一次保证宽高精确生效
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            WindowService.shared.setWindowFrame(axWin, axFrame: targetAXRect)
        }

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
        previewOverlay.hide()
        layoutBar.hide()
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
        let barTriggerAX = layoutBar.expectedBarTriggerAXRect(on: screen, margin: 24)

        // 1) 若鼠标位于顶部悬浮分屏布局栏显示区域及周围一圈，直接显示并命中具体布局格
        if barTriggerAX.contains(axLocation) {
            if !layoutBar.isVisible {
                layoutBar.show(on: screen)
            }
            if let barTarget = layoutBar.hitTest(cocoaMouse: cocoaMouse) {
                selectTarget(barTarget)
            } else {
                currentTarget = nil
                previewOverlay.hide()
            }
            return
        } else if layoutBar.isVisible {
            layoutBar.hide()
        }

        // 2) 四角 1/4 分屏热区（L 形角落判定，优先于单边）
        let cornerW = min(130, visibleAX.width * 0.10)
        let cornerH = min(110, visibleAX.height * 0.12)
        let edgeStrip: CGFloat = 20
        let topStrip: CGFloat = 42

        let nearLeftEdge = axLocation.x <= screenAX.minX + edgeStrip
        let nearRightEdge = axLocation.x >= screenAX.maxX - edgeStrip
        let nearTopEdge = axLocation.y <= visibleAX.minY + topStrip
        let nearBottomEdge = axLocation.y >= min(visibleAX.maxY, screenAX.maxY) - edgeStrip

        let inLeftBand = axLocation.x <= screenAX.minX + cornerW
        let inRightBand = axLocation.x >= screenAX.maxX - cornerW
        let inTopBand = axLocation.y <= visibleAX.minY + cornerH
        let inBottomBand = axLocation.y >= screenAX.maxY - cornerH

        if (nearTopEdge && inLeftBand) || (nearLeftEdge && inTopBand) {
            selectTarget(SnapTarget(screen: screen, layout: .quarters, zoneIndex: 0))
            return
        }
        if (nearTopEdge && inRightBand) || (nearRightEdge && inTopBand) {
            selectTarget(SnapTarget(screen: screen, layout: .quarters, zoneIndex: 1))
            return
        }
        if (nearBottomEdge && inLeftBand) || (nearLeftEdge && inBottomBand) {
            selectTarget(SnapTarget(screen: screen, layout: .quarters, zoneIndex: 2))
            return
        }
        if (nearBottomEdge && inRightBand) || (nearRightEdge && inBottomBand) {
            selectTarget(SnapTarget(screen: screen, layout: .quarters, zoneIndex: 3))
            return
        }

        // 3) 顶部两侧热区（布局栏周围区域之外的顶边）
        if nearTopEdge {
            switch AppSettings.shared.topSnapZoneMode {
            case .centerLayoutSidesMaximize:
                selectTarget(SnapTarget(screen: screen, layout: .maximize, zoneIndex: 0))
            case .fullTopLayout:
                layoutBar.show(on: screen)
                if let barTarget = layoutBar.hitTest(cocoaMouse: cocoaMouse) {
                    selectTarget(barTarget)
                } else {
                    currentTarget = nil
                    previewOverlay.hide()
                }
            }
            return
        }

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
        if let hit = axWindowViaHitTest(at: axLocation) {
            return hit
        }
        return axWindowViaCGWindowList(at: axLocation)
    }

    private func axWindowViaHitTest(at axLocation: CGPoint) -> (axWin: AXUIElement, wid: CGWindowID?, frame: CGRect)? {
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
        for _ in 0..<24 {
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
        return validateDraggableWindow(axWin)
    }

    private func axWindowViaCGWindowList(at axLocation: CGPoint) -> (axWin: AXUIElement, wid: CGWindowID?, frame: CGRect)? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for dict in list {
            guard let layer = dict[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = dict[kCGWindowOwnerPID as String] as? pid_t, pid != selfPID,
                  let wid = dict[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary else {
                continue
            }
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds),
                  bounds.width >= 100, bounds.height >= 80,
                  bounds.contains(axLocation) else {
                continue
            }
            if let axWin = WindowService.shared.findAXWindow(pid: pid, windowID: wid) {
                return validateDraggableWindow(axWin)
            }
        }
        return nil
    }

    private func validateDraggableWindow(_ axWin: AXUIElement) -> (axWin: AXUIElement, wid: CGWindowID?, frame: CGRect)? {
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
