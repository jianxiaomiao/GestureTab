import AppKit
import ApplicationServices

/// 触发多任务切换视图的手势模式
enum GestureMode: String, CaseIterable, Identifiable {
    /// 四指滑动呼出与二维步进选框（与系统“三指拖移”完全零冲突，推荐）
    case fourFinger = "fourFinger"
    /// 三指姿态区分模式（三指水平并排走原生拖移，竖向/斜向排布触发多任务切换）
    case threeFingerTilted = "threeFingerTilted"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fourFinger:
            return "四指滑动切换（推荐 · 与三指拖移零冲突）"
        case .threeFingerTilted:
            return "三指竖向/倾斜姿态切换（实验性）"
        }
    }
}

/// 多任务视图的展示风格
enum DisplayStyle: String, CaseIterable, Identifiable {
    /// 居中毛玻璃小面板（自动缩放卡片禁止滚动）
    case compactPanel = "compactPanel"
    /// 仿 macOS 调度中心全屏视图（铺满屏幕大图展示 + 底部 App 图标）
    case missionControl = "missionControl"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compactPanel:
            return "紧凑悬浮面板（自动缩放 · 禁止滚动）"
        case .missionControl:
            return "全屏调度视图（仿调度中心风格）"
        }
    }
}

/// 本机已安装应用信息（用于忽略名单配置）
struct InstalledAppInfo: Identifiable, Hashable {
    let id: String // bundleIdentifier 或 appName
    let name: String
    let bundleID: String?
    let url: URL
    let icon: NSImage?
}

/// 单个可切换窗口的数据模型
struct WindowItem: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let appIcon: NSImage?
    let axElement: AXUIElement?
    let runningApp: NSRunningApplication?
    var isMinimized: Bool
    let isFullScreen: Bool
    let isOnScreen: Bool
    let isWindowlessApp: Bool
    var thumbnail: NSImage?

    static func syntheticID(for pid: pid_t) -> CGWindowID {
        0x8000_0000 | UInt32(bitPattern: pid)
    }

    var ignoreKey: String {
        runningApp?.bundleIdentifier ?? appName
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? appName : trimmed
    }
}

/// 用户偏好设置（持久化在 UserDefaults）
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let settingsVersion = "settingsVersion"
        static let gestureMode = "gestureMode"
        static let displayStyle = "displayStyle"
        static let qQuitEnabled = "qQuitEnabled"
        static let wCloseEnabled = "wCloseEnabled"
        static let mMinimizeEnabled = "mMinimizeEnabled"
        static let horizontalStep = "horizontalStep"
        static let verticalStep = "verticalStep"
        static let columnsCount = "columnsCount"
        static let hapticEnabled = "hapticEnabled"
        static let autoRepeatEnabled = "autoRepeatEnabled"
        static let velocityBoostEnabled = "velocityBoostEnabled"
        static let optionTabEnabled = "optionTabEnabled"
        static let trackpadPersistentMode = "trackpadPersistentMode"
        static let ignoredApps = "ignoredApps"
    }

    @Published var gestureMode: GestureMode {
        didSet { UserDefaults.standard.set(gestureMode.rawValue, forKey: Keys.gestureMode) }
    }

    @Published var displayStyle: DisplayStyle {
        didSet { UserDefaults.standard.set(displayStyle.rawValue, forKey: Keys.displayStyle) }
    }

    /// 按 Q 键关闭选中窗口所属进程（程序）
    @Published var qQuitEnabled: Bool {
        didSet { UserDefaults.standard.set(qQuitEnabled, forKey: Keys.qQuitEnabled) }
    }

    /// 按 W 键关闭当前选中的单个窗口
    @Published var wCloseEnabled: Bool {
        didSet { UserDefaults.standard.set(wCloseEnabled, forKey: Keys.wCloseEnabled) }
    }

    /// 按 M 键最小化 / 恢复当前选中的窗口
    @Published var mMinimizeEnabled: Bool {
        didSet { UserDefaults.standard.set(mMinimizeEnabled, forKey: Keys.mMinimizeEnabled) }
    }

    /// 水平方向每步进一格所需的归一化触控板位移（默认 0.095，约半块触控板可覆盖 5~6 列）
    @Published var horizontalStep: Double {
        didSet { UserDefaults.standard.set(horizontalStep, forKey: Keys.horizontalStep) }
    }

    /// 垂直方向每步进一行所需的归一化触控板位移（默认 0.115）
    @Published var verticalStep: Double {
        didSet { UserDefaults.standard.set(verticalStep, forKey: Keys.verticalStep) }
    }

    /// 网格每行最多显示的窗口列数（默认 6，与截图一致）
    @Published var columnsCount: Int {
        didSet { UserDefaults.standard.set(columnsCount, forKey: Keys.columnsCount) }
    }

    /// 步进切换时是否触发触控板震动反馈
    @Published var hapticEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticEnabled, forKey: Keys.hapticEnabled) }
    }

    /// 滑到触控板物理边缘按住时，是否自动延续方向步进
    @Published var autoRepeatEnabled: Bool {
        didSet { UserDefaults.standard.set(autoRepeatEnabled, forKey: Keys.autoRepeatEnabled) }
    }

    /// 速度甩动加成（慢滑精准 1 格，快滑自动跨 2~3 格）
    @Published var velocityBoostEnabled: Bool {
        didSet { UserDefaults.standard.set(velocityBoostEnabled, forKey: Keys.velocityBoostEnabled) }
    }

    /// 启用 Option + Tab 辅助快捷键呼出（默认开启，持久打开直到按 Enter/空格进入或 Esc 退出）
    @Published var optionTabEnabled: Bool {
        didSet { UserDefaults.standard.set(optionTabEnabled, forKey: Keys.optionTabEnabled) }
    }

    /// 触控板呼出后是否也保持持久停留（默认关闭，松手即切入；开启后松手不切，需按 Enter/空格/点击进入）
    @Published var trackpadPersistentMode: Bool {
        didSet { UserDefaults.standard.set(trackpadPersistentMode, forKey: Keys.trackpadPersistentMode) }
    }

    /// 忽略名单（key = bundleIdentifier 或 appName, value = 展示名称）
    @Published var ignoredApps: [String: String] {
        didSet { UserDefaults.standard.set(ignoredApps, forKey: Keys.ignoredApps) }
    }

    func isAppIgnored(key: String) -> Bool {
        ignoredApps[key] != nil
    }

    func isAppIgnored(bundleID: String?, appName: String) -> Bool {
        if let bundleID, ignoredApps[bundleID] != nil {
            return true
        }
        if ignoredApps[appName] != nil {
            return true
        }
        let lowerName = appName.lowercased()
        return ignoredApps.contains { key, val in
            key.lowercased() == lowerName || val.lowercased() == lowerName
        }
    }

    func toggleIgnoredApp(key: String, name: String) {
        if ignoredApps[key] != nil {
            ignoredApps.removeValue(forKey: key)
        } else {
            ignoredApps[key] = name
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: Keys.settingsVersion) < 3 {
            defaults.removeObject(forKey: Keys.horizontalStep)
            defaults.removeObject(forKey: Keys.verticalStep)
            defaults.set(3, forKey: Keys.settingsVersion)
        }

        if let raw = defaults.string(forKey: Keys.gestureMode),
           let mode = GestureMode(rawValue: raw) {
            self.gestureMode = mode
        } else {
            self.gestureMode = .fourFinger
        }

        if let rawStyle = defaults.string(forKey: Keys.displayStyle),
           let style = DisplayStyle(rawValue: rawStyle) {
            self.displayStyle = style
        } else {
            self.displayStyle = .compactPanel
        }

        if defaults.object(forKey: Keys.qQuitEnabled) != nil {
            self.qQuitEnabled = defaults.bool(forKey: Keys.qQuitEnabled)
        } else {
            self.qQuitEnabled = true
        }

        if defaults.object(forKey: Keys.wCloseEnabled) != nil {
            self.wCloseEnabled = defaults.bool(forKey: Keys.wCloseEnabled)
        } else {
            self.wCloseEnabled = true
        }

        if defaults.object(forKey: Keys.mMinimizeEnabled) != nil {
            self.mMinimizeEnabled = defaults.bool(forKey: Keys.mMinimizeEnabled)
        } else {
            self.mMinimizeEnabled = true
        }

        let hStep = defaults.double(forKey: Keys.horizontalStep)
        self.horizontalStep = hStep > 0.01 ? hStep : 0.095

        let vStep = defaults.double(forKey: Keys.verticalStep)
        self.verticalStep = vStep > 0.01 ? vStep : 0.115

        let cols = defaults.integer(forKey: Keys.columnsCount)
        self.columnsCount = cols >= 3 ? cols : 6

        if defaults.object(forKey: Keys.hapticEnabled) != nil {
            self.hapticEnabled = defaults.bool(forKey: Keys.hapticEnabled)
        } else {
            self.hapticEnabled = true
        }

        if defaults.object(forKey: Keys.autoRepeatEnabled) != nil {
            self.autoRepeatEnabled = defaults.bool(forKey: Keys.autoRepeatEnabled)
        } else {
            self.autoRepeatEnabled = true
        }

        if defaults.object(forKey: Keys.velocityBoostEnabled) != nil {
            self.velocityBoostEnabled = defaults.bool(forKey: Keys.velocityBoostEnabled)
        } else {
            self.velocityBoostEnabled = true
        }

        if defaults.object(forKey: Keys.optionTabEnabled) != nil {
            self.optionTabEnabled = defaults.bool(forKey: Keys.optionTabEnabled)
        } else {
            self.optionTabEnabled = true
        }

        if defaults.object(forKey: Keys.trackpadPersistentMode) != nil {
            self.trackpadPersistentMode = defaults.bool(forKey: Keys.trackpadPersistentMode)
        } else {
            self.trackpadPersistentMode = false
        }

        self.ignoredApps = (defaults.dictionary(forKey: Keys.ignoredApps) as? [String: String]) ?? [:]
    }
}

/// 通过标准 macOS LaunchAgent 管理开机自启动（兼容本地自签名及任意放置路径）
enum LaunchAtLoginManager {
    private static let label = "com.gesturetab.app"

    private static var launchAgentsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private static var plistURL: URL {
        launchAgentsDir.appendingPathComponent("\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            return writePlist()
        } else {
            do {
                if FileManager.default.fileExists(atPath: plistURL.path) {
                    try FileManager.default.removeItem(at: plistURL)
                }
                return true
            } catch {
                return false
            }
        }
    }

    /// 若用户移动了 GestureTab.app 所在目录，启动时自动同步最新可执行路径
    static func syncPathIfNeeded() {
        guard isEnabled, let exePath = Bundle.main.executablePath else { return }
        if let dict = NSDictionary(contentsOf: plistURL) as? [String: Any],
           let args = dict["ProgramArguments"] as? [String],
           args.first == exePath {
            return
        }
        _ = writePlist()
    }

    private static func writePlist() -> Bool {
        guard let exePath = Bundle.main.executablePath else { return false }
        do {
            try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [exePath],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive"
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

/// 扫描本机已安装的应用程序（含 /Applications、系统应用及当前运行的应用）
enum InstalledAppScanner {
    static func scanInstalledApps() -> [InstalledAppInfo] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let searchRoots: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities")
        ]

        var byID: [String: InstalledAppInfo] = [:]
        let selfBundleID = Bundle.main.bundleIdentifier

        for root in searchRoots {
            guard fm.fileExists(atPath: root.path) else { continue }
            collectApps(in: root, depth: 0, maxDepth: 2, selfBundleID: selfBundleID, into: &byID)
        }

        // 合并当前正在运行但可能存放在其他目录的应用
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let url = app.bundleURL else { continue }
            let bundleID = app.bundleIdentifier
            if let bundleID, bundleID == selfBundleID { continue }
            let name = app.localizedName ?? url.deletingPathExtension().lastPathComponent
            let key = bundleID ?? name
            if byID[key] == nil {
                byID[key] = InstalledAppInfo(
                    id: key,
                    name: name,
                    bundleID: bundleID,
                    url: url,
                    icon: app.icon ?? NSWorkspace.shared.icon(forFile: url.path)
                )
            }
        }

        return byID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func collectApps(
        in dir: URL,
        depth: Int,
        maxDepth: Int,
        selfBundleID: String?,
        into map: inout [String: InstalledAppInfo]
    ) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for url in contents {
            if url.pathExtension == "app" {
                let bundle = Bundle(url: url)
                let bundleID = bundle?.bundleIdentifier
                if let bundleID, bundleID == selfBundleID { continue }
                let displayName = fm.displayName(atPath: url.path)
                    .replacingOccurrences(of: ".app", with: "")
                let infoName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? displayName
                let name = displayName.isEmpty ? infoName : displayName
                let key = bundleID ?? name
                if map[key] == nil {
                    let icon = NSWorkspace.shared.icon(forFile: url.path)
                    map[key] = InstalledAppInfo(id: key, name: name, bundleID: bundleID, url: url, icon: icon)
                }
            } else if depth < maxDepth {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    collectApps(in: url, depth: depth + 1, maxDepth: maxDepth, selfBundleID: selfBundleID, into: &map)
                }
            }
        }
    }
}
