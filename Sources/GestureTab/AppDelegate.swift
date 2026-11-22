import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let multitouch = MultitouchManager()
    private let switcher = SwitcherController()
    private var permissionPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例保护，避免开机自启与手动打开重复出现两个菜单栏图标
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty {
                NSApp.terminate(nil)
                return
            }
        }

        NSApp.setActivationPolicy(.accessory)
        LaunchAtLoginManager.syncPathIfNeeded()

        setupMenuBar()
        setupConnections()

        WindowService.shared.startMonitoring()
        multitouch.start()
        WindowSnapManager.shared.start()
        DockPreviewManager.shared.shouldSuppressPreview = { [weak self] in
            (self?.switcher.isVisible ?? false) || WindowSnapManager.shared.isDraggingWindow
        }
        DockPreviewManager.shared.start()

        checkPermissionsOnLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionPollTimer?.invalidate()
        DockPreviewManager.shared.stop()
        WindowSnapManager.shared.stop()
        multitouch.stop()
        WindowService.shared.stopMonitoring()
    }

    private func setupConnections() {
        multitouch.onShowSwitcher = { [weak self] in
            self?.switcher.show()
        }
        multitouch.onShowPersistentSwitcher = { [weak self] reverse in
            self?.switcher.show(persistent: true, reverseInitial: reverse)
        }
        multitouch.onStep = { [weak self] dx, dy in
            self?.switcher.step(deltaCol: dx, deltaRow: dy)
        }
        multitouch.onCommit = { [weak self] in
            self?.switcher.commitOnTrackpadRelease()
        }
        multitouch.onForceCommit = { [weak self] in
            self?.switcher.commitAndHide()
        }
        multitouch.onCancel = { [weak self] in
            self?.switcher.cancelAndHide()
        }
        multitouch.onPressQ = { [weak self] in
            self?.switcher.performQKeyAction()
        }
        multitouch.onPressW = { [weak self] in
            self?.switcher.performWKeyAction()
        }
        multitouch.onPressM = { [weak self] in
            self?.switcher.performMKeyAction()
        }
        switcher.onUserEscCancel = { [weak self] in
            self?.multitouch.cancelCurrentGesture()
        }
        switcher.onVisibilityChanged = { [weak self] visible in
            self?.multitouch.setSwitcherVisible(visible)
            if visible {
                DockPreviewManager.shared.hideImmediately()
            }
        }
        switcher.shouldInstallFallbackKeyMonitors = { [weak self] in
            !(self?.multitouch.isEventTapActive ?? false)
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
                    WindowSnapManager.shared.start()
                    DockPreviewManager.shared.start()
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

        // 视图内快捷键开关子菜单
        let keyMenu = NSMenu()
        let qToggle = NSMenuItem(title: "按 Q 键：退出选中窗口所属程序（进程）", action: #selector(toggleQQuit), keyEquivalent: "")
        qToggle.target = self
        qToggle.state = settings.qQuitEnabled ? .on : .off
        keyMenu.addItem(qToggle)

        let wToggle = NSMenuItem(title: "按 W 键：关闭当前选中窗口", action: #selector(toggleWClose), keyEquivalent: "")
        wToggle.target = self
        wToggle.state = settings.wCloseEnabled ? .on : .off
        keyMenu.addItem(wToggle)

        let mToggle = NSMenuItem(title: "按 M 键：最小化 / 恢复当前窗口", action: #selector(toggleMMinimize), keyEquivalent: "")
        mToggle.target = self
        mToggle.state = settings.mMinimizeEnabled ? .on : .off
        keyMenu.addItem(mToggle)

        let keyParent = NSMenuItem(title: "选中窗口快捷键（Q / W / M）", action: nil, keyEquivalent: "")
        keyParent.submenu = keyMenu
        menu.addItem(keyParent)

        // 忽略名单子菜单
        let ignoreMenu = NSMenu()
        let manageIgnoreItem = NSMenuItem(title: "管理全部已安装应用 / 手动添加...", action: #selector(openIgnoreListManager), keyEquivalent: "")
        manageIgnoreItem.target = self
        ignoreMenu.addItem(manageIgnoreItem)
        ignoreMenu.addItem(.separator())

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPID && !$0.isTerminated }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        var seenKeys = Set<String>()
        for app in runningApps {
            let name = app.localizedName ?? "App"
            let key = app.bundleIdentifier ?? name
            guard seenKeys.insert(key).inserted else { continue }
            let aItem = NSMenuItem(title: name, action: #selector(toggleIgnoredApp(_:)), keyEquivalent: "")
            aItem.target = self
            aItem.representedObject = [key, name]
            aItem.state = settings.isAppIgnored(key: key) ? .on : .off
            ignoreMenu.addItem(aItem)
        }

        // 展示未运行但仍在忽略名单里的应用
        let offlineIgnored = settings.ignoredApps.filter { !seenKeys.contains($0.key) }
            .sorted { $0.value < $1.value }
        if !offlineIgnored.isEmpty {
            ignoreMenu.addItem(.separator())
            for (key, name) in offlineIgnored {
                let aItem = NSMenuItem(title: "\(name)（未运行）", action: #selector(toggleIgnoredApp(_:)), keyEquivalent: "")
                aItem.target = self
                aItem.representedObject = [key, name]
                aItem.state = .on
                ignoreMenu.addItem(aItem)
            }
        }

        if !settings.ignoredApps.isEmpty {
            ignoreMenu.addItem(.separator())
            let clearItem = NSMenuItem(title: "清空忽略名单", action: #selector(clearIgnoredApps), keyEquivalent: "")
            clearItem.target = self
            ignoreMenu.addItem(clearItem)
        }

        let ignoreTitle = settings.ignoredApps.isEmpty
            ? "忽略应用名单（过滤不显示）"
            : "忽略应用名单（已忽略 \(settings.ignoredApps.count) 个）"
        let ignoreParent = NSMenuItem(title: ignoreTitle, action: nil, keyEquivalent: "")
        ignoreParent.submenu = ignoreMenu
        menu.addItem(ignoreParent)

        let optionTabItem = NSMenuItem(title: "启用 Option + Tab 呼出（持久打开）", action: #selector(toggleOptionTab), keyEquivalent: "")
        optionTabItem.target = self
        optionTabItem.state = settings.optionTabEnabled ? .on : .off
        menu.addItem(optionTabItem)

        let persistentItem = NSMenuItem(title: "触控板呼出后保持持久停留（回车/空格进入）", action: #selector(toggleTrackpadPersistent), keyEquivalent: "")
        persistentItem.target = self
        persistentItem.state = settings.trackpadPersistentMode ? .on : .off
        menu.addItem(persistentItem)

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

        let loginItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LaunchAtLoginManager.isEnabled ? .on : .off
        menu.addItem(loginItem)

        // 桌面拖拽分屏（类 Wins）子菜单
        let snapMenu = NSMenu()
        let snapToggle = NSMenuItem(title: "启用拖拽边缘/角落/顶部分屏", action: #selector(toggleSnapEnabled), keyEquivalent: "")
        snapToggle.target = self
        snapToggle.state = settings.snapEnabled ? .on : .off
        snapMenu.addItem(snapToggle)

        let snapAssistToggle = NSMenuItem(title: "分屏后空区弹出窗口缩略图 (Snap Assist)", action: #selector(toggleSnapAssist), keyEquivalent: "")
        snapAssistToggle.target = self
        snapAssistToggle.state = settings.snapAssistEnabled ? .on : .off
        snapMenu.addItem(snapAssistToggle)

        snapMenu.addItem(.separator())
        let topModeHeader = NSMenuItem(title: "顶部热区触发模式：", action: nil, keyEquivalent: "")
        topModeHeader.isEnabled = false
        snapMenu.addItem(topModeHeader)

        for tMode in TopSnapZoneMode.allCases {
            let tItem = NSMenuItem(title: tMode.displayName, action: #selector(selectTopSnapMode(_:)), keyEquivalent: "")
            tItem.target = self
            tItem.representedObject = tMode.rawValue
            tItem.state = (settings.topSnapZoneMode == tMode) ? .on : .off
            snapMenu.addItem(tItem)
        }

        snapMenu.addItem(.separator())
        let dockTipItem = NSMenuItem(title: "打开系统「桌面与程序坞」设置（建议关闭原生边缘拼贴）", action: #selector(openDesktopDockSettings), keyEquivalent: "")
        dockTipItem.target = self
        snapMenu.addItem(dockTipItem)

        let snapParent = NSMenuItem(title: "桌面拖拽分屏（类 Windows）", action: nil, keyEquivalent: "")
        snapParent.submenu = snapMenu
        menu.addItem(snapParent)

        let dockPreviewItem = NSMenuItem(title: "启用程序坞（Dock）悬停缩略图预览", action: #selector(toggleDockPreview), keyEquivalent: "")
        dockPreviewItem.target = self
        dockPreviewItem.state = settings.dockPreviewEnabled ? .on : .off
        menu.addItem(dockPreviewItem)

        menu.addItem(.separator())

        let trackpadTipItem = NSMenuItem(title: "打开系统「触控板」设置（关闭原生四指防冲突）", action: #selector(openTrackpadSettings), keyEquivalent: "")
        trackpadTipItem.target = self
        menu.addItem(trackpadTipItem)

        let dockSettingsItem = NSMenuItem(title: "打开系统「桌面与程序坞」设置（关闭原生磁吸防冲突）", action: #selector(openDesktopDockSettings), keyEquivalent: "")
        dockSettingsItem.target = self
        menu.addItem(dockSettingsItem)

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
        switcher.show(persistent: true)
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

    @objc private func toggleQQuit() {
        AppSettings.shared.qQuitEnabled.toggle()
        rebuildMenu()
    }

    @objc private func toggleWClose() {
        AppSettings.shared.wCloseEnabled.toggle()
        rebuildMenu()
    }

    @objc private func toggleMMinimize() {
        AppSettings.shared.mMinimizeEnabled.toggle()
        rebuildMenu()
    }

    @objc private func openIgnoreListManager() {
        IgnoreListWindowController.shared.show()
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

    @objc private func toggleLaunchAtLogin() {
        _ = LaunchAtLoginManager.setEnabled(!LaunchAtLoginManager.isEnabled)
        rebuildMenu()
    }

    @objc private func toggleOptionTab() {
        AppSettings.shared.optionTabEnabled.toggle()
        rebuildMenu()
    }

    @objc private func toggleTrackpadPersistent() {
        AppSettings.shared.trackpadPersistentMode.toggle()
        rebuildMenu()
    }

    @objc private func toggleSnapEnabled() {
        AppSettings.shared.snapEnabled.toggle()
        if AppSettings.shared.snapEnabled {
            WindowSnapManager.shared.start()
        } else {
            WindowSnapManager.shared.stop()
        }
        rebuildMenu()
    }

    @objc private func toggleSnapAssist() {
        AppSettings.shared.snapAssistEnabled.toggle()
        rebuildMenu()
    }

    @objc private func toggleDockPreview() {
        AppSettings.shared.dockPreviewEnabled.toggle()
        if AppSettings.shared.dockPreviewEnabled {
            DockPreviewManager.shared.start()
        } else {
            DockPreviewManager.shared.stop()
        }
        rebuildMenu()
    }

    @objc private func selectTopSnapMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let mode = TopSnapZoneMode(rawValue: raw) {
            AppSettings.shared.topSnapZoneMode = mode
            rebuildMenu()
        }
    }

    @objc private func toggleIgnoredApp(_ sender: NSMenuItem) {
        if let pair = sender.representedObject as? [String], pair.count == 2 {
            AppSettings.shared.toggleIgnoredApp(key: pair[0], name: pair[1])
            rebuildMenu()
        }
    }

    @objc private func clearIgnoredApps() {
        AppSettings.shared.ignoredApps.removeAll()
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

    @objc private func openDesktopDockSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
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
