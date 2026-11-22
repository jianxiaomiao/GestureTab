import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

/// 程序坞（Dock）悬停窗口缩略图预览的数据模型
final class DockPreviewViewModel: ObservableObject {
    @Published var appName: String = ""
    @Published var appIcon: NSImage? = nil
    @Published var windows: [WindowItem] = []
    @Published var hoveredWindowID: CGWindowID? = nil
}

/// 程序坞（Dock）悬停缩略图预览控制器（类 Windows 任务栏悬停预览）
final class DockPreviewManager {
    static let shared = DockPreviewManager()

    /// 外部抑制条件（例如多任务切换面板打开或正在拖拽分屏时不弹出 Dock 预览）
    var shouldSuppressPreview: (() -> Bool)?

    private enum DockEdge {
        case bottom
        case left
        case right
    }

    private struct DockIconHit {
        let app: NSRunningApplication
        let iconCocoaRect: CGRect
        let screen: NSScreen
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRunning = false

    private var panel: NSPanel?
    private let viewModel = DockPreviewViewModel()

    private var cachedDockPID: pid_t?
    private var lastDockQueryTime: CFAbsoluteTime = 0

    private var currentHoveredPID: pid_t?
    private var currentIconCocoaRect: CGRect = .zero
    private var currentDockEdge: DockEdge = .bottom
    private var currentScreen: NSScreen?

    private var pendingPID: pid_t?
    private var pendingHit: DockIconHit?
    private var showWorkItem: DispatchWorkItem?
    private var hideWorkItem: DispatchWorkItem?

    private let cardWidth: CGFloat = 212
    private let cardHeight: CGFloat = 152
    private let cardSpacing: CGFloat = 10
    private let hPadding: CGFloat = 14
    private let vPadding: CGFloat = 12
    private let headerHeight: CGFloat = 26

    private init() {}

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func start() {
        guard !isRunning else { return }
        guard AppSettings.shared.dockPreviewEnabled else { return }
        guard WindowService.hasAccessibilityPermission(prompt: false) else { return }

        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<DockPreviewManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.handleEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        hideImmediately()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
    }

    func hideImmediately() {
        cancelShowTimer()
        cancelHideTimer()
        currentHoveredPID = nil
        currentIconCocoaRect = .zero
        pendingPID = nil
        pendingHit = nil
        viewModel.hoveredWindowID = nil
        panel?.orderOut(nil)
    }

    // MARK: - Event Handling

    private func handleEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        guard AppSettings.shared.dockPreviewEnabled else {
            if isVisible {
                DispatchQueue.main.async { [weak self] in self?.hideImmediately() }
            }
            return
        }

        let axLoc = event.location

        switch type {
        case .leftMouseDown:
            if isVisible {
                let cocoaLoc = axPointToCocoa(axLoc)
                DispatchQueue.main.async { [weak self] in
                    guard let self, let panel = self.panel, panel.isVisible else { return }
                    if !panel.frame.contains(cocoaLoc) {
                        self.hideImmediately()
                    }
                }
            }
        case .rightMouseDown:
            if isVisible || pendingPID != nil {
                DispatchQueue.main.async { [weak self] in
                    self?.hideImmediately()
                }
            }
        case .mouseMoved:
            DispatchQueue.main.async { [weak self] in
                self?.processMouseMoved(axPoint: axLoc)
            }
        default:
            break
        }
    }

    private func processMouseMoved(axPoint: CGPoint) {
        if shouldSuppressPreview?() == true {
            if isVisible || pendingPID != nil {
                hideImmediately()
            }
            return
        }

        let cocoaPoint = axPointToCocoa(axPoint)

        // 1) 若预览面板已打开且鼠标位于面板或“图标 -> 面板”过渡桥接区内，保持显示不闪退
        if let panel, panel.isVisible {
            if panel.frame.insetBy(dx: -8, dy: -8).contains(cocoaPoint) {
                cancelHideTimer()
                cancelShowTimer()
                return
            }
            if isPointInBridgeZone(cocoaPoint, panelFrame: panel.frame) {
                cancelHideTimer()
                return
            }
        }

        // 2) 极速边缘过滤：鼠标远离任何屏幕的底/左/右 Dock 区域时直接跳过 AX 查询（几乎 0% CPU）
        guard let screen = screenContaining(cocoaPoint: cocoaPoint),
              isNearPossibleDockEdge(cocoaPoint: cocoaPoint, screen: screen) else {
            cancelShowTimer()
            if isVisible {
                scheduleHide()
            }
            return
        }

        // 3) 节流查询 Dock AX 元素（30ms 间隔，兼顾 0 延迟感与低 IPC 开销）
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastDockQueryTime < 0.030 {
            return
        }
        lastDockQueryTime = now

        guard let hit = hitTestDockApp(atAXPoint: axPoint, screen: screen) else {
            cancelShowTimer()
            if isVisible {
                scheduleHide()
            }
            return
        }

        let targetPID = hit.app.processIdentifier
        cancelHideTimer()

        // 已显示当前 App：仅更新图标位置（防止 Dock 放大特效偏移）
        if isVisible && currentHoveredPID == targetPID {
            currentIconCocoaRect = hit.iconCocoaRect
            return
        }

        // 已显示其他 App 的预览：0ms 即时切换过去，丝滑连贯
        if isVisible {
            cancelShowTimer()
            presentPreview(for: hit, animatedMove: true)
            return
        }

        // 尚未显示：150ms 悬停防误触延迟后弹出
        if pendingPID == targetPID {
            pendingHit = hit
            return
        }

        cancelShowTimer()
        pendingPID = targetPID
        pendingHit = hit
        let work = DispatchWorkItem { [weak self] in
            guard let self, let latestHit = self.pendingHit else { return }
            self.pendingPID = nil
            self.pendingHit = nil
            guard self.shouldSuppressPreview?() != true else { return }
            self.presentPreview(for: latestHit, animatedMove: false)
        }
        showWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: - Dock AX Hit Testing

    private func resolveDockPID() -> pid_t? {
        if let pid = cachedDockPID,
           let app = NSRunningApplication(processIdentifier: pid),
           !app.isTerminated {
            return pid
        }
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .first(where: { !$0.isTerminated })?
            .processIdentifier
        cachedDockPID = pid
        return pid
    }

    private func hitTestDockApp(atAXPoint axPoint: CGPoint, screen: NSScreen) -> DockIconHit? {
        guard let dockPID = resolveDockPID() else { return nil }
        let dockAppAX = AXUIElementCreateApplication(dockPID)

        var elementRef: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(dockAppAX, Float(axPoint.x), Float(axPoint.y), &elementRef)
        guard err == .success, var el = elementRef else { return nil }

        // 向上查找最多 4 层，找到 AXApplicationDockItem
        var dockItem: AXUIElement?
        for _ in 0..<4 {
            var subroleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subroleRef)
            if (subroleRef as? String) == "AXApplicationDockItem" {
                dockItem = el
                break
            }
            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parentRef) == .success,
               let parent = parentRef {
                el = (parent as! AXUIElement)
            } else {
                break
            }
        }

        guard let item = dockItem else { return nil }

        // 若 Dock 明确标记该应用未运行，直接跳过
        var runningRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(item, "AXIsApplicationRunning" as CFString, &runningRef) == .success,
           let isAppRunning = runningRef as? Bool, !isAppRunning {
            return nil
        }

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleRef)
        let dockTitle = (titleRef as? String) ?? ""

        var urlRef: CFTypeRef?
        AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &urlRef)
        let dockURL: URL? = (urlRef as? URL) ?? (urlRef as? NSURL as URL?)

        guard let matchedApp = matchRunningApplication(dockURL: dockURL, dockTitle: dockTitle) else {
            return nil
        }

        // 获取 Dock 图标实际位置与尺寸
        var iconCocoaRect = CGRect(
            x: axPointToCocoa(axPoint).x - 28,
            y: axPointToCocoa(axPoint).y - 28,
            width: 56,
            height: 56
        )
        if let iconAXRect = WindowService.shared.getWindowFrame(item),
           iconAXRect.width > 10, iconAXRect.height > 10 {
            iconCocoaRect = WindowService.axRectToCocoaRect(iconAXRect)
        }

        return DockIconHit(app: matchedApp, iconCocoaRect: iconCocoaRect, screen: screen)
    }

    private func matchRunningApplication(dockURL: URL?, dockTitle: String) -> NSRunningApplication? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != selfPID && !$0.isTerminated
        }

        if let dockURL {
            let stdDockURL = dockURL.standardizedFileURL
            if let exact = running.first(where: { $0.bundleURL?.standardizedFileURL == stdDockURL }) {
                return exact
            }
            if let bid = Bundle(url: stdDockURL)?.bundleIdentifier,
               let byBundle = running.first(where: { $0.bundleIdentifier == bid }) {
                return byBundle
            }
        }

        if !dockTitle.isEmpty {
            if let byName = running.first(where: { $0.localizedName == dockTitle }) {
                return byName
            }
        }

        return nil
    }

    // MARK: - Present / Layout / Actions

    private func presentPreview(for hit: DockIconHit, animatedMove: Bool) {
        let windows = WindowService.shared.fetchWindows(for: hit.app)
        guard !windows.isEmpty else {
            // 该应用当前没有打开窗口（例如只有菜单栏/无窗口），不弹空框
            if isVisible {
                hideImmediately()
            }
            return
        }

        currentHoveredPID = hit.app.processIdentifier
        currentIconCocoaRect = hit.iconCocoaRect
        currentScreen = hit.screen
        currentDockEdge = detectDockEdge(iconRect: hit.iconCocoaRect, screen: hit.screen)

        viewModel.appName = hit.app.localizedName ?? "App"
        viewModel.appIcon = hit.app.icon
        viewModel.windows = windows
        viewModel.hoveredWindowID = nil

        ensurePanel()
        let targetFrame = computePanelFrame(
            windowCount: windows.count,
            iconRect: hit.iconCocoaRect,
            screen: hit.screen,
            edge: currentDockEdge
        )

        guard let panel else { return }
        if !panel.isVisible {
            panel.setFrame(targetFrame, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else if animatedMove {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(targetFrame, display: true)
            }
        } else {
            panel.setFrame(targetFrame, display: true)
        }

        // 异步补抓/刷新最新缩略图
        let targetPID = hit.app.processIdentifier
        let ids = Set(windows.map(\.id))
        WindowService.shared.refreshThumbnailsAsync(for: ids) { [weak self] wid, img in
            guard let self, self.isVisible, self.currentHoveredPID == targetPID else { return }
            if let idx = self.viewModel.windows.firstIndex(where: { $0.id == wid }) {
                self.viewModel.windows[idx].thumbnail = img
            }
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 260, height: 210),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
        p.isReleasedWhenClosed = false
        p.acceptsMouseMovedEvents = true
        p.contentView = NSHostingView(rootView: DockPreviewView(
            viewModel: viewModel,
            cardWidth: cardWidth,
            cardHeight: cardHeight,
            cardSpacing: cardSpacing,
            hPadding: hPadding,
            vPadding: vPadding,
            headerHeight: headerHeight,
            onSelect: { [weak self] item in
                self?.activateWindow(item)
            },
            onToggleMinimize: { [weak self] item in
                self?.toggleMinimize(item)
            },
            onClose: { [weak self] item in
                self?.closeWindow(item)
            }
        ))
        self.panel = p
    }

    private func activateWindow(_ item: WindowItem) {
        hideImmediately()
        WindowService.shared.activateWindow(item)
        if AppSettings.shared.hapticEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func toggleMinimize(_ item: WindowItem) {
        guard let newMin = WindowService.shared.toggleMinimizeWindow(item) else { return }
        if let idx = viewModel.windows.firstIndex(where: { $0.id == item.id }) {
            viewModel.windows[idx].isMinimized = newMin
        }
        if AppSettings.shared.hapticEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
    }

    private func closeWindow(_ item: WindowItem) {
        guard WindowService.shared.closeWindow(item) else { return }
        viewModel.windows.removeAll { $0.id == item.id }
        if AppSettings.shared.hapticEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }

        if viewModel.windows.isEmpty {
            hideImmediately()
            return
        }

        if let screen = currentScreen {
            let newFrame = computePanelFrame(
                windowCount: viewModel.windows.count,
                iconRect: currentIconCocoaRect,
                screen: screen,
                edge: currentDockEdge
            )
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel?.animator().setFrame(newFrame, display: true)
            }
        }
    }

    // MARK: - Geometry Helpers

    private func detectDockEdge(iconRect: CGRect, screen: NSScreen) -> DockEdge {
        let sf = screen.frame
        let distBottom = abs(iconRect.minY - sf.minY)
        let distLeft = abs(iconRect.minX - sf.minX)
        let distRight = abs(sf.maxX - iconRect.maxX)

        if distLeft < distBottom && distLeft < distRight && distLeft < 130 {
            return .left
        }
        if distRight < distBottom && distRight < distLeft && distRight < 130 {
            return .right
        }
        return .bottom
    }

    private func computePanelFrame(
        windowCount: Int,
        iconRect: CGRect,
        screen: NSScreen,
        edge: DockEdge
    ) -> CGRect {
        let sf = screen.frame
        let count = max(windowCount, 1)
        let maxW = max(cardWidth + hPadding * 2, sf.width - 48)
        let idealW = hPadding * 2 + CGFloat(count) * cardWidth + CGFloat(count - 1) * cardSpacing
        let panelW = min(idealW, maxW)
        let panelH = vPadding * 2 + headerHeight + 8 + cardHeight

        var originX: CGFloat
        var originY: CGFloat

        switch edge {
        case .bottom:
            originX = round(iconRect.midX - panelW / 2)
            originY = round(iconRect.maxY + 12)
        case .left:
            originX = round(iconRect.maxX + 12)
            originY = round(iconRect.midY - panelH / 2)
        case .right:
            originX = round(iconRect.minX - panelW - 12)
            originY = round(iconRect.midY - panelH / 2)
        }

        // 限制在屏幕可见边界内，留出 12pt 边距
        originX = max(sf.minX + 12, min(originX, sf.maxX - panelW - 12))
        originY = max(sf.minY + 12, min(originY, sf.maxY - panelH - 12))

        return CGRect(x: originX, y: originY, width: panelW, height: panelH)
    }

    /// 图标与悬浮面板之间的“无感过渡走廊”：斜向从 Dock 图标移往缩略图卡片时绝不提前消失，且不遮挡左右相邻 Dock 图标
    private func isPointInBridgeZone(_ pt: CGPoint, panelFrame: CGRect) -> Bool {
        guard currentIconCocoaRect != .zero else { return false }
        let icon = currentIconCocoaRect
        switch currentDockEdge {
        case .bottom:
            let minY = icon.maxY - 2
            let maxY = panelFrame.minY + 4
            guard pt.y >= minY && pt.y <= maxY else { return false }
            let minX = min(icon.minX - 10, panelFrame.minX)
            let maxX = max(icon.maxX + 10, panelFrame.maxX)
            return pt.x >= minX && pt.x <= maxX
        case .left:
            let minX = icon.maxX - 2
            let maxX = panelFrame.minX + 4
            guard pt.x >= minX && pt.x <= maxX else { return false }
            let minY = min(icon.minY - 10, panelFrame.minY)
            let maxY = max(icon.maxY + 10, panelFrame.maxY)
            return pt.y >= minY && pt.y <= maxY
        case .right:
            let minX = panelFrame.maxX - 4
            let maxX = icon.minX + 2
            guard pt.x >= minX && pt.x <= maxX else { return false }
            let minY = min(icon.minY - 10, panelFrame.minY)
            let maxY = max(icon.maxY + 10, panelFrame.maxY)
            return pt.y >= minY && pt.y <= maxY
        }
    }

    private func isNearPossibleDockEdge(cocoaPoint: CGPoint, screen: NSScreen) -> Bool {
        let sf = screen.frame
        let edgeDepth: CGFloat = 120
        return cocoaPoint.y <= sf.minY + edgeDepth
            || cocoaPoint.x <= sf.minX + edgeDepth
            || cocoaPoint.x >= sf.maxX - edgeDepth
    }

    private func screenContaining(cocoaPoint: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(cocoaPoint) })
    }

    private func axPointToCocoa(_ axPoint: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 900
        return CGPoint(x: axPoint.x, y: primaryHeight - axPoint.y)
    }

    // MARK: - Timers

    private func cancelShowTimer() {
        showWorkItem?.cancel()
        showWorkItem = nil
        pendingPID = nil
        pendingHit = nil
    }

    private func cancelHideTimer() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    private func scheduleHide() {
        guard hideWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.hideWorkItem = nil
            self?.hideImmediately()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26, execute: work)
    }
}

// MARK: - SwiftUI Dock Preview Strip

private struct DockPreviewView: View {
    @ObservedObject var viewModel: DockPreviewViewModel
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let cardSpacing: CGFloat
    let hPadding: CGFloat
    let vPadding: CGFloat
    let headerHeight: CGFloat
    let onSelect: (WindowItem) -> Void
    let onToggleMinimize: (WindowItem) -> Void
    let onClose: (WindowItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 顶栏：App 图标 + 名称 + 窗口计数
            HStack(spacing: 8) {
                if let icon = viewModel.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                }
                Text(viewModel.appName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("\(viewModel.windows.count) 个窗口")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Spacer(minLength: 0)
            }
            .frame(height: headerHeight)

            // 窗口缩略图横向条
            ScrollView(.horizontal, showsIndicators: viewModel.windows.count > 5) {
                HStack(spacing: cardSpacing) {
                    ForEach(viewModel.windows) { item in
                        DockPreviewCard(
                            item: item,
                            width: cardWidth,
                            height: cardHeight,
                            isHovered: viewModel.hoveredWindowID == item.id,
                            onSelect: { onSelect(item) },
                            onToggleMinimize: { onToggleMinimize(item) },
                            onClose: { onClose(item) }
                        )
                        .onHover { hovering in
                            if hovering {
                                viewModel.hoveredWindowID = item.id
                            } else if viewModel.hoveredWindowID == item.id {
                                viewModel.hoveredWindowID = nil
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, hPadding)
        .padding(.vertical, vPadding)
        .background(
            ZStack {
                VisualEffectBackdrop(material: .hudWindow, blendingMode: .behindWindow)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.24), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
    }
}

private struct DockPreviewCard: View {
    let item: WindowItem
    let width: CGFloat
    let height: CGFloat
    let isHovered: Bool
    let onSelect: () -> Void
    let onToggleMinimize: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 卡片顶部标题栏 + 快捷按钮
            HStack(spacing: 5) {
                HStack(spacing: 5) {
                    Text(item.displayTitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 2)

                    if let badge = statusBadge {
                        Text(badge)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(badgeColor))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)

                if !item.isFullScreen {
                    Button(action: onToggleMinimize) {
                        Image(systemName: item.isMinimized ? "arrow.up.left.and.arrow.down.right" : "minus")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.primary.opacity(0.85))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.primary.opacity(isHovered ? 0.14 : 0.08)))
                    }
                    .buttonStyle(.plain)
                    .help(item.isMinimized ? "恢复窗口" : "最小化窗口")
                }

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(isHovered ? .white : .primary.opacity(0.85))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(isHovered ? Color.red.opacity(0.82) : Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("关闭窗口")
            }
            .frame(height: 20)

            // 缩略图内容区域
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.16))

                if let thumb = item.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .padding(3)
                } else if let icon = item.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 48, height: 48)
                        .opacity(0.92)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
        }
        .padding(8)
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? Color(nsColor: .controlAccentColor).opacity(0.18) : Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isHovered ? Color(nsColor: .controlAccentColor) : Color.white.opacity(0.12),
                    lineWidth: isHovered ? 2 : 1
                )
        )
    }

    private var statusBadge: String? {
        if item.isMinimized { return "最小化" }
        if item.isFullScreen { return "全屏" }
        if !item.isOnScreen { return "其他桌面" }
        return nil
    }

    private var badgeColor: Color {
        if item.isMinimized { return .orange.opacity(0.88) }
        if item.isFullScreen { return .purple.opacity(0.88) }
        return .blue.opacity(0.82)
    }
}
