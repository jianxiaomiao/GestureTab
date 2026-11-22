import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let multitouch = MultitouchManager()
    private let switcher = SwitcherController()
    private var permissionPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupMenuBar()
        setupConnections()

        WindowService.shared.startMonitoring()
        multitouch.start()

        checkPermissionsOnLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionPollTimer?.invalidate()
        multitouch.stop()
        WindowService.shared.stopMonitoring()
    }

    private func setupConnections() {
        multitouch.onShowSwitcher = { [weak self] in
            self?.switcher.show()
        }
        multitouch.onStep = { [weak self] dx, dy in
            self?.switcher.step(deltaCol: dx, deltaRow: dy)
        }
        multitouch.onCommit = { [weak self] in
            self?.switcher.commitAndHide()
        }
        multitouch.onCancel = { [weak self] in
            self?.switcher.cancelAndHide()
        }
        switcher.onUserEscCancel = { [weak self] in
            self?.multitouch.cancelCurrentGesture()
        }
    }

    // MARK: - Permissions

    private func checkPermissionsOnLaunch() {
        let hasAX = WindowService.hasAccessibilityPermission(prompt: false)
        let hasSR = WindowService.hasScreenRecordingPermission()

        if !hasAX || !hasSR {
            if !hasAX {
                _ = WindowService.hasAccessibilityPermission(prompt: true)
            }
            if !hasSR {
                WindowService.requestScreenRecordingPermission()
            }

            // 轮询直到用户授权完成，刷新菜单状态与重启 EventTap
            permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                guard let self else { return }
                let axNow = WindowService.hasAccessibilityPermission(prompt: false)
                let srNow = WindowService.hasScreenRecordingPermission()
                self.rebuildMenu()
                if axNow {
                    self.multitouch.restart()
                }
                if axNow && srNow {
                    timer.invalidate()
                    self.permissionPollTimer = nil
                }
            }
        }
    }

    // MARK: - Menu Bar UI

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "GestureTab")
            button.image?.isTemplate = true
        }
        rebuildMenu()
    }

    @objc private func rebuildMenu() {
        let menu = NSMenu()
        let settings = AppSettings.shared

        let axGranted = WindowService.hasAccessibilityPermission(prompt: false)
        let srGranted = WindowService.hasScreenRecordingPermission()

        let titleItem = NSMenuItem(title: "GestureTab 多任务手势切换", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let mtStatus = multitouch.isRunning ? "触控板监听：运行中" : "触控板监听：未启动"
        let mtItem = NSMenuItem(title: mtStatus, action: nil, keyEquivalent: "")
        mtItem.isEnabled = false
        menu.addItem(mtItem)

        let tapStatus = multitouch.isEventTapActive ? "背景防滚动拦截：已开启" : "背景防滚动拦截：需辅助功能权限"
        let tapItem = NSMenuItem(title: tapStatus, action: nil, keyEquivalent: "")
        tapItem.isEnabled = false
        menu.addItem(tapItem)

        menu.addItem(.separator())

        if !axGranted {
            let item = NSMenuItem(title: "⚠️ 授予「辅助功能」权限（必选：切窗口）", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "✅ 辅助功能权限已开启", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if !srGranted {
            let item = NSMenuItem(title: "⚠️ 授予「屏幕录制」权限（用于缩略图）", action: #selector(openScreenRecordingSettings), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "✅ 屏幕录制权限已开启", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let previewItem = NSMenuItem(title: "预览多任务视图（按 Esc 关闭）", action: #selector(previewSwitcher), keyEquivalent: "")
        previewItem.target = self
        menu.addItem(previewItem)

        // 视图显示模式子菜单
        let styleMenu = NSMenu()
        for style in DisplayStyle.allCases {
            let sItem = NSMenuItem(title: style.displayName, action: #selector(selectDisplayStyle(_:)), keyEquivalent: "")
            sItem.target = self
            sItem.representedObject = style.rawValue
            sItem.state = (settings.displayStyle == style) ? .on : .off
            styleMenu.addItem(sItem)
        }
        let styleParent = NSMenuItem(title: "视图显示模式", action: nil, keyEquivalent: "")
        styleParent.submenu = styleMenu
        menu.addItem(styleParent)

        // 手势模式子菜单
        let modeMenu = NSMenu()
        for mode in GestureMode.allCases {
            let mItem = NSMenuItem(title: mode.displayName, action: #selector(selectGestureMode(_:)), keyEquivalent: "")
            mItem.target = self
            mItem.representedObject = mode.rawValue
            mItem.state = (settings.gestureMode == mode) ? .on : .off
            modeMenu.addItem(mItem)
        }
        let modeParent = NSMenuItem(title: "手势触发模式", action: nil, keyEquivalent: "")
        modeParent.submenu = modeMenu
        menu.addItem(modeParent)

        // 步进灵敏度子菜单
        let sensMenu = NSMenu()
        let presets: [(String, Double, Double)] = [
            ("偏灵敏（轻滑跳格）", 0.075, 0.095),
            ("适中顺滑（推荐默认 · 类 Windows 步距）", 0.095, 0.115),
            ("稳重防滑（大幅度滑动）", 0.135, 0.150)
        ]
        for (label, hx, vy) in presets {
            let sItem = NSMenuItem(title: label, action: #selector(selectSensitivity(_:)), keyEquivalent: "")
            sItem.target = self
            sItem.representedObject = [hx, vy]
            sItem.state = abs(settings.horizontalStep - hx) < 0.005 ? .on : .off
            sensMenu.addItem(sItem)
        }
        let sensParent = NSMenuItem(title: "触控板滑动灵敏度", action: nil, keyEquivalent: "")
        sensParent.submenu = sensMenu
        menu.addItem(sensParent)

        // 每行列数子菜单
        let colMenu = NSMenu()
        for col in [5, 6, 7] {
            let cItem = NSMenuItem(title: "每行 \(col) 个窗口", action: #selector(selectColumns(_:)), keyEquivalent: "")
            cItem.target = self
            cItem.tag = col
            cItem.state = (settings.columnsCount == col) ? .on : .off
            colMenu.addItem(cItem)
        }
        let colParent = NSMenuItem(title: "网格每行列数", action: nil, keyEquivalent: "")
        colParent.submenu = colMenu
        menu.addItem(colParent)

        let hapticItem = NSMenuItem(title: "切换时触控板震动反馈", action: #selector(toggleHaptic), keyEquivalent: "")
        hapticItem.target = self
        hapticItem.state = settings.hapticEnabled ? .on : .off
        menu.addItem(hapticItem)

        let repeatItem = NSMenuItem(title: "物理边缘 10% 自动连选", action: #selector(toggleAutoRepeat), keyEquivalent: "")
        repeatItem.target = self
        repeatItem.state = settings.autoRepeatEnabled ? .on : .off
        menu.addItem(repeatItem)

        let boostItem = NSMenuItem(title: "速度甩动加成（快滑自动跨 2~3 格）", action: #selector(toggleVelocityBoost), keyEquivalent: "")
        boostItem.target = self
        boostItem.state = settings.velocityBoostEnabled ? .on : .off
        menu.addItem(boostItem)

        menu.addItem(.separator())

        let trackpadTipItem = NSMenuItem(title: "打开系统「触控板」设置（关闭原生四指防冲突）", action: #selector(openTrackpadSettings), keyEquivalent: "")
        trackpadTipItem.target = self
        menu.addItem(trackpadTipItem)

        let restartItem = NSMenuItem(title: "重启触控板监听", action: #selector(restartMultitouch), keyEquivalent: "")
        restartItem.target = self
        menu.addItem(restartItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 GestureTab", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func previewSwitcher() {
        switcher.show()
    }

    @objc private func selectGestureMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let mode = GestureMode(rawValue: raw) {
            AppSettings.shared.gestureMode = mode
            rebuildMenu()
        }
    }

    @objc private func selectDisplayStyle(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let style = DisplayStyle(rawValue: raw) {
            AppSettings.shared.displayStyle = style
            rebuildMenu()
        }
    }

    @objc private func selectSensitivity(_ sender: NSMenuItem) {
        if let pair = sender.representedObject as? [Double], pair.count == 2 {
            AppSettings.shared.horizontalStep = pair[0]
            AppSettings.shared.verticalStep = pair[1]
            rebuildMenu()
        }
    }

    @objc private func selectColumns(_ sender: NSMenuItem) {
        AppSettings.shared.columnsCount = sender.tag
        rebuildMenu()
    }

    @objc private func toggleHaptic() {
        AppSettings.shared.hapticEnabled.toggle()
        rebuildMenu()
    }

    @objc private func toggleAutoRepeat() {
        AppSettings.shared.autoRepeatEnabled.toggle()
        rebuildMenu()
    }

    @objc private func toggleVelocityBoost() {
        AppSettings.shared.velocityBoostEnabled.toggle()
        rebuildMenu()
    }

    @objc private func restartMultitouch() {
        multitouch.start()
        rebuildMenu()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openTrackpadSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }
}
