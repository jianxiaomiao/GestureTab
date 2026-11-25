import AppKit
import SwiftUI

final class PreferencesWindowController {
    static let shared = PreferencesWindowController()
    private var window: NSWindow?
    var onRestartMultitouch: (() -> Void)?

    private init() {}

    func show() {
        if window == nil {
            let rootView = PreferencesView(onRestartMultitouch: { [weak self] in
                self?.onRestartMultitouch?()
            })
            let hosting = NSHostingView(rootView: rootView)
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.title = "GestureTab 偏好设置"
            win.isReleasedWhenClosed = false
            win.contentView = hosting
            win.center()
            self.window = win
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct PreferencesView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin: Bool = LaunchAtLoginManager.isEnabled
    @State private var axGranted: Bool = WindowService.hasAccessibilityPermission(prompt: false)
    @State private var srGranted: Bool = WindowService.hasScreenRecordingPermission()
    @State private var hText: String = String(format: "%.3f", AppSettings.shared.horizontalStep)
    @State private var vText: String = String(format: "%.3f", AppSettings.shared.verticalStep)

    let onRestartMultitouch: () -> Void

    var body: some View {
        TabView {
            gestureTab
                .tabItem { Label("手势与切换", systemImage: "rectangle.3.group") }

            snapTab
                .tabItem { Label("桌面分屏", systemImage: "rectangle.split.2x2") }

            dockTab
                .tabItem { Label("程序坞预览", systemImage: "dock.rectangle") }

            systemTab
                .tabItem { Label("忽略与系统", systemImage: "gearshape") }
        }
        .padding(16)
        .frame(width: 640, height: 540)
        .onAppear {
            refreshStatus()
        }
    }

    // MARK: - Tab 1: 手势与切换

    private var gestureTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("视图与触发模式") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("视图显示模式：", selection: $settings.displayStyle) {
                            ForEach(DisplayStyle.allCases) { style in
                                Text(style.displayName).tag(style)
                            }
                        }

                        Picker("手势触发模式：", selection: $settings.gestureMode) {
                            ForEach(GestureMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }

                        Picker("网格每行列数：", selection: $settings.columnsCount) {
                            Text("5 列").tag(5)
                            Text("6 列（推荐）").tag(6)
                            Text("7 列").tag(7)
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(6)
                }

                GroupBox("触控板滑动灵敏度（数值越小越灵敏，可直接输入后回车）") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Text("左右步距")
                                .frame(width: 64, alignment: .leading)
                            Slider(
                                value: Binding(
                                    get: { SensitivityRange.clampHorizontal(settings.horizontalStep) },
                                    set: {
                                        let v = SensitivityRange.clampHorizontal($0)
                                        settings.horizontalStep = v
                                        hText = String(format: "%.3f", v)
                                    }
                                ),
                                in: SensitivityRange.horizontalMin...SensitivityRange.horizontalMax
                            )
                            TextField("", text: $hText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .frame(width: 66)
                                .onSubmit {
                                    if let val = Double(hText.trimmingCharacters(in: .whitespaces)) {
                                        let clamped = SensitivityRange.clampHorizontal(val)
                                        settings.horizontalStep = clamped
                                        hText = String(format: "%.3f", clamped)
                                    } else {
                                        hText = String(format: "%.3f", settings.horizontalStep)
                                    }
                                }
                            Text("0.075~0.135")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 10) {
                            Text("上下步距")
                                .frame(width: 64, alignment: .leading)
                            Slider(
                                value: Binding(
                                    get: { SensitivityRange.clampVertical(settings.verticalStep) },
                                    set: {
                                        let v = SensitivityRange.clampVertical($0)
                                        settings.verticalStep = v
                                        vText = String(format: "%.3f", v)
                                    }
                                ),
                                in: SensitivityRange.verticalMin...SensitivityRange.verticalMax
                            )
                            TextField("", text: $vText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .frame(width: 66)
                                .onSubmit {
                                    if let val = Double(vText.trimmingCharacters(in: .whitespaces)) {
                                        let clamped = SensitivityRange.clampVertical(val)
                                        settings.verticalStep = clamped
                                        vText = String(format: "%.3f", clamped)
                                    } else {
                                        vText = String(format: "%.3f", settings.verticalStep)
                                    }
                                }
                            Text("0.095~0.150")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Spacer()
                            Button("恢复默认 (0.095 / 0.115)") {
                                settings.horizontalStep = SensitivityRange.horizontalDefault
                                settings.verticalStep = SensitivityRange.verticalDefault
                                hText = String(format: "%.3f", SensitivityRange.horizontalDefault)
                                vText = String(format: "%.3f", SensitivityRange.verticalDefault)
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(6)
                }

                GroupBox("操控与视图内快捷键") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("启用 Option + Tab 呼出（持久打开，按 / 或 ⌘F 可即打即搜窗口）", isOn: $settings.optionTabEnabled)
                        Toggle("触控板呼出后保持持久停留（松手不切，需按回车/空格/点击进入）", isOn: $settings.trackpadPersistentMode)
                        Toggle("切换时触控板震动反馈", isOn: $settings.hapticEnabled)
                        Toggle("触控板物理边缘 10% 自动连选", isOn: $settings.autoRepeatEnabled)
                        Toggle("速度甩动加成（快滑自动跨 2~3 格）", isOn: $settings.velocityBoostEnabled)

                        Divider().padding(.vertical, 2)

                        HStack(spacing: 18) {
                            Toggle("Q 退出进程", isOn: $settings.qQuitEnabled)
                            Toggle("W 关闭单窗", isOn: $settings.wCloseEnabled)
                            Toggle("M 最小化/恢复", isOn: $settings.mMinimizeEnabled)
                        }
                    }
                    .padding(6)
                }
            }
            .padding(.trailing, 4)
        }
    }

    // MARK: - Tab 2: 桌面分屏

    private var snapTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("类 Windows 拖拽分屏") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("启用拖拽边缘 / 四角 / 顶部悬浮布局分屏", isOn: Binding(
                            get: { settings.snapEnabled },
                            set: { newVal in
                                settings.snapEnabled = newVal
                                if newVal { WindowSnapManager.shared.start() } else { WindowSnapManager.shared.stop() }
                            }
                        ))

                        Toggle("分屏后空区自动弹出窗口缩略图 (Snap Assist)", isOn: $settings.snapAssistEnabled)

                        Picker("顶部热区模式：", selection: $settings.topSnapZoneMode) {
                            ForEach(TopSnapZoneMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }

                        HStack {
                            Text("提示：建议关闭 macOS 原生「将窗口移到屏幕边缘以拼贴」，避免与本分屏冲突。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("打开系统设置...") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(6)
                }

                GroupBox("键盘快捷键分屏") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("启用全局键盘分屏快捷键（与拖拽分屏共享尺寸还原记忆）", isOn: $settings.keyboardSnapEnabled)

                        Divider()

                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                            shortcutRow("⌃⌥ ←  /  ⌃⌥ →", "左半屏 / 右半屏（1/2）")
                            shortcutRow("⌃⌥ ↑  /  ⌃⌥ ↓", "上半屏 / 下半屏（1/2）")
                            shortcutRow("⌃⌥ ↵ (回车)", "最大化铺满工作区")
                            shortcutRow("⌃⌥ U / I / J / K", "左上 / 右上 / 左下 / 右下（1/4 四宫格）")
                            shortcutRow("⌃⌥ ⌫ (退格)", "还原当前窗口分屏前原始尺寸")
                        }
                        .font(.system(size: 12))
                    }
                    .padding(6)
                }
            }
            .padding(.trailing, 4)
        }
    }

    private func shortcutRow(_ keys: String, _ desc: String) -> some View {
        GridRow {
            Text(keys)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(nsColor: .controlAccentColor))
                .frame(width: 160, alignment: .leading)
            Text(desc)
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Tab 3: 程序坞预览

    private var dockTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("程序坞（Dock）悬停缩略图预览") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("启用程序坞（Dock）悬停窗口缩略图预览", isOn: Binding(
                        get: { settings.dockPreviewEnabled },
                        set: { newVal in
                            settings.dockPreviewEnabled = newVal
                            if newVal { DockPreviewManager.shared.start() } else { DockPreviewManager.shared.stop() }
                        }
                    ))

                    Toggle("悬停缩略图卡片 0.45s 临时前置「瞄一眼（Peek）」，移开自动还原", isOn: $settings.dockHoverPeekEnabled)
                        .disabled(!settings.dockPreviewEnabled)
                }
                .padding(6)
            }

            GroupBox("交互说明") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("悬停在运行中应用的 Dock 图标 0.15s 自动弹出横向缩略图条，横向移至相邻图标 0ms 无缝切换。", systemImage: "cursorarrow.motionlines")
                    Label("支持点击缩略图直接激活/取消最小化；卡片右上角支持一键最小化/恢复（−）与关闭单窗（×）。", systemImage: "macwindow")
                    Label("自动适配底部、左侧、右侧程序坞，并在图标与预览条间提供过渡走廊防止斜移闪退。", systemImage: "dock.arrow.up.rectangle")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(6)
            }

            Spacer()
        }
    }

    // MARK: - Tab 4: 忽略与系统

    private var systemTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("忽略应用名单") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前已忽略 \(settings.ignoredApps.count) 个应用")
                            .font(.system(size: 13, weight: .medium))
                        Text("可搜索勾选任意已安装软件、从磁盘选择 .app 或手动输入 Bundle ID。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("打开忽略名单管理器...") {
                        IgnoreListWindowController.shared.show()
                    }
                }
                .padding(6)
            }

            GroupBox("系统权限状态") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: axGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(axGranted ? .green : .orange)
                        Text(axGranted ? "辅助功能权限已开启（切窗 / 分屏 / Dock 预览可用）" : "缺少「辅助功能」权限（必选）")
                        Spacer()
                        Button("系统设置...") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }

                    HStack {
                        Image(systemName: srGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(srGranted ? .green : .orange)
                        Text(srGranted ? "屏幕录制权限已开启（实时与缓存缩略图可用）" : "缺少「屏幕录制」权限（用于缩略图）")
                        Spacer()
                        Button("系统设置...") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }

                    HStack {
                        Spacer()
                        Button("刷新权限状态") { refreshStatus() }
                            .controlSize(.small)
                    }
                }
                .padding(6)
            }

            GroupBox("启动与维护") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("开机自动启动 GestureTab", isOn: Binding(
                        get: { launchAtLogin },
                        set: { newVal in
                            _ = LaunchAtLoginManager.setEnabled(newVal)
                            launchAtLogin = LaunchAtLoginManager.isEnabled
                        }
                    ))

                    HStack(spacing: 10) {
                        Button("打开系统「触控板」设置（关闭原生四指防冲突）") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Button("重启触控板监听") {
                            onRestartMultitouch()
                        }
                    }
                    .controlSize(.small)
                }
                .padding(6)
            }

            Spacer()
        }
    }

    private func refreshStatus() {
        axGranted = WindowService.hasAccessibilityPermission(prompt: false)
        srGranted = WindowService.hasScreenRecordingPermission()
        launchAtLogin = LaunchAtLoginManager.isEnabled
        hText = String(format: "%.3f", settings.horizontalStep)
        vText = String(format: "%.3f", settings.verticalStep)
    }
}
