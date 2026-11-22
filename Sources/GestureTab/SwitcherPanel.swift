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

    var onUserEscCancel: (() -> Void)?

    private(set) var isVisible = false

    func show() {
        let items = WindowService.shared.fetchAllSwitchableWindows()
        let cols = AppSettings.shared.columnsCount
        viewModel.load(items: items, columns: cols)

        ensurePanel()
        layoutAndShowPanel()
        isVisible = true
        installKeyMonitors()

        // 异步刷新最新缩略图（优先命中缓存瞬间显示，再补充最新画面）
        let ids = Set(items.map(\.id))
        WindowService.shared.refreshThumbnailsAsync(for: ids) { [weak self] wid, img in
            guard let self, self.isVisible else { return }
            self.viewModel.updateThumbnail(windowID: wid, image: img)
        }
    }

    func step(deltaCol: Int, deltaRow: Int) {
        guard isVisible else { return }
        if viewModel.moveSelection(deltaCol: deltaCol, deltaRow: deltaRow),
           AppSettings.shared.hapticEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
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

    private func hide() {
        isVisible = false
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

    private func layoutAndShowPanel() {
        guard let panel, let hostingView else { return }
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let screen = screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let width = min(fitting.width, visibleFrame.width - 40)
        let height = min(fitting.height, visibleFrame.height - 60)
        let originX = visibleFrame.midX - width / 2
        let originY = visibleFrame.midY - height / 2

        panel.setFrame(NSRect(x: originX, y: originY, width: width, height: height), display: true)
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
        case 36: // Return
            commitAndHide()
            return true
        default:
            return false
        }
    }
}
