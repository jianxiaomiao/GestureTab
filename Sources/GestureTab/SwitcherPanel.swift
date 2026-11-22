import AppKit
import SwiftUI

final class FloatingSwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class SwitcherController {
    let viewModel = SwitcherViewModel()
    private var panel: FloatingSwitcherPanel?
    private var hostingView: NSHostingView<SwitcherView>?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var pendingStepWorkItems: [DispatchWorkItem] = []

    var onUserEscCancel: (() -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?
    var shouldInstallFallbackKeyMonitors: (() -> Bool)?

    private(set) var isVisible = false

    func show(persistent: Bool? = nil, reverseInitial: Bool = false) {
        // 若面板已经处于打开状态（如先由 Option+Tab 持久打开，再结合触控板滑动选窗），不重置当前列表与选中项
        if isVisible { return }

        let items = WindowService.shared.fetchAllSwitchableWindows()
        let settings = AppSettings.shared
        let isPersistent = persistent ?? settings.trackpadPersistentMode
        let screen = screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens.first
        let screenSize = screen?.frame.size ?? CGSize(width: 1440, height: 900)

        viewModel.load(
            items: items,
            screenSize: screenSize,
            style: settings.displayStyle,
            preferredColumns: settings.columnsCount,
            persistent: isPersistent,
            reverseInitial: reverseInitial
        )

        ensurePanel()
        layoutAndShowPanel(on: screen, style: settings.displayStyle)
        isVisible = true
        onVisibilityChanged?(true)
        if shouldInstallFallbackKeyMonitors?() ?? true {
            installKeyMonitors()
        }

        // 异步刷新最新缩略图（优先命中缓存瞬间显示，再补充最新画面）
        let ids = Set(items.map(\.id))
        WindowService.shared.refreshThumbnailsAsync(for: ids) { [weak self] wid, img in
            guard let self, self.isVisible else { return }
            self.viewModel.updateThumbnail(windowID: wid, image: img)
        }
    }

    func step(deltaCol: Int, deltaRow: Int) {
        guard isVisible else { return }
        cancelPendingSteps()

        let colSteps = abs(deltaCol)
        let rowSteps = abs(deltaRow)
        let totalSteps = max(colSteps, rowSteps)
        guard totalSteps > 0 else { return }

        if totalSteps == 1 {
            performSingleStep(deltaCol: deltaCol, deltaRow: deltaRow)
            return
        }

        // 多格快滑拆分为 42ms/格 的逐格可见过渡动画，做到“看到蓝框停在哪，松手就进哪”
        let dirCol = deltaCol == 0 ? 0 : (deltaCol > 0 ? 1 : -1)
        let dirRow = deltaRow == 0 ? 0 : (deltaRow > 0 ? 1 : -1)

        for i in 0..<totalSteps {
            let stepC = i < colSteps ? dirCol : 0
            let stepR = i < rowSteps ? dirRow : 0
            if i == 0 {
                performSingleStep(deltaCol: stepC, deltaRow: stepR)
            } else {
                let item = DispatchWorkItem { [weak self] in
                    guard let self, self.isVisible else { return }
                    self.performSingleStep(deltaCol: stepC, deltaRow: stepR)
                }
                pendingStepWorkItems.append(item)
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.042, execute: item)
            }
        }
    }

    private func performSingleStep(deltaCol: Int, deltaRow: Int) {
        if viewModel.moveSelection(deltaCol: deltaCol, deltaRow: deltaRow),
           AppSettings.shared.hapticEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func cancelPendingSteps() {
        for item in pendingStepWorkItems {
            item.cancel()
        }
        pendingStepWorkItems.removeAll()
    }

    func commitAndHide() {
        guard isVisible else { return }
        let target = viewModel.selectedItem
        hide()
        if let target {
            WindowService.shared.activateWindow(target)
        }
    }

    func cancelAndHide() {
        guard isVisible else { return }
        hide()
    }

    /// 触控板松手回调：非持久模式下立即切入；持久模式下保持打开等待 Enter/空格/点击或 Esc
    func commitOnTrackpadRelease() {
        guard isVisible, !viewModel.isPersistentSession else { return }
        commitAndHide()
    }

    /// 按 M 键一键最小化或恢复当前选中窗口
    func performMKeyAction() {
        guard AppSettings.shared.mMinimizeEnabled,
              isVisible,
              let target = viewModel.selectedItem else { return }
        if let newMinimized = WindowService.shared.toggleMinimizeWindow(target) {
            viewModel.setMinimized(windowID: target.id, isMinimized: newMinimized)
            if AppSettings.shared.hapticEnabled {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
    }

    /// 按 Q 键关闭/退出选中窗口所属进程（程序）
    func performQKeyAction() {
        guard AppSettings.shared.qQuitEnabled,
              isVisible,
              let target = viewModel.selectedItem else { return }
        cancelPendingSteps()

        if WindowService.shared.quitApp(target) {
            viewModel.removeItems(pid: target.pid)
            if AppSettings.shared.hapticEnabled {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }

        if viewModel.items.isEmpty {
            onUserEscCancel?()
        }
    }

    /// 按 W 键关闭当前选中的单个窗口
    func performWKeyAction() {
        guard AppSettings.shared.wCloseEnabled,
              isVisible,
              let target = viewModel.selectedItem else { return }
        cancelPendingSteps()

        if WindowService.shared.closeWindow(target) {
            viewModel.removeItem(id: target.id)
            if AppSettings.shared.hapticEnabled {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }

        if viewModel.items.isEmpty {
            onUserEscCancel?()
        }
    }

    private func hide() {
        isVisible = false
        onVisibilityChanged?(false)
        cancelPendingSteps()
        removeKeyMonitors()
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        if panel != nil { return }

        let rootView = SwitcherView(viewModel: viewModel) { [weak self] index in
            guard let self else { return }
            self.viewModel.selectedIndex = index
            self.commitAndHide()
        }

        let hosting = NSHostingView(rootView: rootView)
        let newPanel = FloatingSwitcherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        // 确保能够浮在全屏应用上方并在所有 Space 显示
        newPanel.level = .screenSaver
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        newPanel.isReleasedWhenClosed = false
        newPanel.contentView = hosting

        self.hostingView = hosting
        self.panel = newPanel
    }

    private func layoutAndShowPanel(on screen: NSScreen?, style: DisplayStyle) {
        guard let panel, let hostingView else { return }
        let targetScreen = screen ?? screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = targetScreen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        switch style {
        case .compactPanel:
            hostingView.layoutSubtreeIfNeeded()
            let fitting = hostingView.fittingSize
            let width = min(fitting.width, visibleFrame.width - 32)
            let height = min(fitting.height, visibleFrame.height - 40)
            let originX = visibleFrame.midX - width / 2
            let originY = visibleFrame.midY - height / 2
            panel.setFrame(NSRect(x: originX, y: originY, width: width, height: height), display: true)

        case .missionControl:
            panel.setFrame(visibleFrame, display: true)
        }
        panel.orderFrontRegardless()
    }

    private func screenUnderMouse() -> NSScreen? {
        let loc = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(loc) }
    }

    // MARK: - Esc Cancel & Keyboard Fallback

    private func installKeyMonitors() {
        removeKeyMonitors()

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyEvent(event) == true {
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitors() {
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard isVisible else { return false }
        switch event.keyCode {
        case 53: // Esc 取消切换
            DispatchQueue.main.async { [weak self] in
                self?.onUserEscCancel?()
            }
            return true
        case 12: // Q 退出选中程序
            guard AppSettings.shared.qQuitEnabled,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                return false
            }
            DispatchQueue.main.async { [weak self] in
                self?.performQKeyAction()
            }
            return true
        case 13: // W 关闭当前窗口
            guard AppSettings.shared.wCloseEnabled,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                return false
            }
            DispatchQueue.main.async { [weak self] in
                self?.performWKeyAction()
            }
            return true
        case 46: // M 最小化或恢复窗口
            guard AppSettings.shared.mMinimizeEnabled,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                return false
            }
            DispatchQueue.main.async { [weak self] in
                self?.performMKeyAction()
            }
            return true
        case 48: // Tab / Shift+Tab
            let reverse = event.modifierFlags.contains(.shift)
            step(deltaCol: reverse ? -1 : 1, deltaRow: 0)
            return true
        case 123: // Left Arrow
            step(deltaCol: -1, deltaRow: 0)
            return true
        case 124: // Right Arrow
            step(deltaCol: 1, deltaRow: 0)
            return true
        case 125: // Down Arrow
            step(deltaCol: 0, deltaRow: 1)
            return true
        case 126: // Up Arrow
            step(deltaCol: 0, deltaRow: -1)
            return true
        case 36, 76, 49: // Return / Numpad Enter / Space
            commitAndHide()
            return true
        default:
            return false
        }
    }
}
