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

/// 选中窗口时按 Q 键执行的操作
enum QKeyAction: String, CaseIterable, Identifiable {
    /// 关闭当前高亮选中的单个窗口
    case closeWindow = "closeWindow"
    /// 退出当前高亮窗口所属的整个程序
    case quitApp = "quitApp"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .closeWindow:
            return "关闭当前选中窗口"
        case .quitApp:
            return "退出选中窗口所属程序"
        }
    }

    var shortHint: String {
        switch self {
        case .closeWindow:
            return "Q 关闭窗口"
        case .quitApp:
            return "Q 退出程序"
        }
    }
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
    let isMinimized: Bool
    let isFullScreen: Bool
    let isOnScreen: Bool
    var thumbnail: NSImage?

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
        static let qKeyAction = "qKeyAction"
        static let horizontalStep = "horizontalStep"
        static let verticalStep = "verticalStep"
        static let columnsCount = "columnsCount"
        static let hapticEnabled = "hapticEnabled"
        static let autoRepeatEnabled = "autoRepeatEnabled"
        static let velocityBoostEnabled = "velocityBoostEnabled"
    }

    @Published var gestureMode: GestureMode {
        didSet { UserDefaults.standard.set(gestureMode.rawValue, forKey: Keys.gestureMode) }
    }

    @Published var displayStyle: DisplayStyle {
        didSet { UserDefaults.standard.set(displayStyle.rawValue, forKey: Keys.displayStyle) }
    }

    @Published var qKeyAction: QKeyAction {
        didSet { UserDefaults.standard.set(qKeyAction.rawValue, forKey: Keys.qKeyAction) }
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

        if let rawQ = defaults.string(forKey: Keys.qKeyAction),
           let qAction = QKeyAction(rawValue: rawQ) {
            self.qKeyAction = qAction
        } else {
            self.qKeyAction = .closeWindow
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
    }
}
