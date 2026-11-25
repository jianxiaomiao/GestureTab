import AppKit
import Foundation

/// 触控板滑动灵敏度（当前数值范围常量）
enum SensitivityRange {
    static let horizontalMin: Double = 0.075
    static let horizontalMax: Double = 0.135
    static let horizontalDefault: Double = 0.095

    static let verticalMin: Double = 0.095
    static let verticalMax: Double = 0.150
    static let verticalDefault: Double = 0.115

    static func clampHorizontal(_ value: Double) -> Double {
        let clamped = min(horizontalMax, max(horizontalMin, value))
        return (clamped * 1000).rounded() / 1000
    }

    static func clampVertical(_ value: Double) -> Double {
        let clamped = min(verticalMax, max(verticalMin, value))
        return (clamped * 1000).rounded() / 1000
    }

    static func menuTitle(h: Double, v: Double) -> String {
        String(format: "触控板滑动灵敏度（%.3f / %.3f）", h, v)
    }
}

/// 嵌入 NSMenu 的触控板灵敏度滑块视图（支持实时拖动 + 点击右侧数值直接键入）
final class SensitivityMenuView: NSView {
    private let hSlider = NSSlider()
    private let vSlider = NSSlider()
    private let hValueButton = NSButton()
    private let vValueButton = NSButton()
    private weak var parentMenuItem: NSMenuItem?
    private weak var hostMenu: NSMenu?

    init(parentMenuItem: NSMenuItem?, hostMenu: NSMenu?) {
        self.parentMenuItem = parentMenuItem
        self.hostMenu = hostMenu
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 128))
        setupUI()
        syncFromSettings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        let settings = AppSettings.shared

        // 行 1：水平灵敏度（左右滑）
        let hLabel = makeRowLabel("左右步距")
        hLabel.frame = NSRect(x: 14, y: 92, width: 58, height: 18)
        addSubview(hLabel)

        hSlider.minValue = SensitivityRange.horizontalMin
        hSlider.maxValue = SensitivityRange.horizontalMax
        hSlider.doubleValue = SensitivityRange.clampHorizontal(settings.horizontalStep)
        hSlider.isContinuous = true
        hSlider.controlSize = .small
        hSlider.target = self
        hSlider.action = #selector(horizontalSliderChanged(_:))
        hSlider.frame = NSRect(x: 74, y: 91, width: 148, height: 20)
        addSubview(hSlider)

        configureValueButton(hValueButton, action: #selector(clickHorizontalValue))
        hValueButton.frame = NSRect(x: 228, y: 89, width: 58, height: 22)
        addSubview(hValueButton)

        // 行 2：垂直灵敏度（上下滑）
        let vLabel = makeRowLabel("上下步距")
        vLabel.frame = NSRect(x: 14, y: 58, width: 58, height: 18)
        addSubview(vLabel)

        vSlider.minValue = SensitivityRange.verticalMin
        vSlider.maxValue = SensitivityRange.verticalMax
        vSlider.doubleValue = SensitivityRange.clampVertical(settings.verticalStep)
        vSlider.isContinuous = true
        vSlider.controlSize = .small
        vSlider.target = self
        vSlider.action = #selector(verticalSliderChanged(_:))
        vSlider.frame = NSRect(x: 74, y: 57, width: 148, height: 20)
        addSubview(vSlider)

        configureValueButton(vValueButton, action: #selector(clickVerticalValue))
        vValueButton.frame = NSRect(x: 228, y: 55, width: 58, height: 22)
        addSubview(vValueButton)

        // 说明文字（范围提示）
        let hintLabel = NSTextField(labelWithString: "越小越灵敏 · 点击右侧数值可直接输入")
        hintLabel.font = .systemFont(ofSize: 10.5)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.frame = NSRect(x: 14, y: 31, width: 272, height: 15)
        addSubview(hintLabel)

        // 底部：范围标注 + 一键恢复默认
        let rangeLabel = NSTextField(labelWithString: "左右 0.075~0.135  上下 0.095~0.150")
        rangeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        rangeLabel.textColor = .tertiaryLabelColor
        rangeLabel.frame = NSRect(x: 14, y: 9, width: 202, height: 15)
        addSubview(rangeLabel)

        let resetBtn = NSButton(title: "恢复默认", target: self, action: #selector(resetDefaults))
        resetBtn.bezelStyle = .inline
        resetBtn.font = .systemFont(ofSize: 10.5, weight: .medium)
        resetBtn.frame = NSRect(x: 224, y: 7, width: 62, height: 19)
        addSubview(resetBtn)
    }

    private func makeRowLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        return label
    }

    private func configureValueButton(_ button: NSButton, action: Selector) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        button.target = self
        button.action = action
        button.toolTip = "点击直接输入数值"
    }

    private func syncFromSettings() {
        let h = SensitivityRange.clampHorizontal(AppSettings.shared.horizontalStep)
        let v = SensitivityRange.clampVertical(AppSettings.shared.verticalStep)
        hSlider.doubleValue = h
        vSlider.doubleValue = v
        hValueButton.title = String(format: "%.3f", h)
        vValueButton.title = String(format: "%.3f", v)
        parentMenuItem?.title = SensitivityRange.menuTitle(h: h, v: v)
    }

    @objc private func horizontalSliderChanged(_ sender: NSSlider) {
        let val = SensitivityRange.clampHorizontal(sender.doubleValue)
        AppSettings.shared.horizontalStep = val
        hValueButton.title = String(format: "%.3f", val)
        parentMenuItem?.title = SensitivityRange.menuTitle(h: val, v: AppSettings.shared.verticalStep)
    }

    @objc private func verticalSliderChanged(_ sender: NSSlider) {
        let val = SensitivityRange.clampVertical(sender.doubleValue)
        AppSettings.shared.verticalStep = val
        vValueButton.title = String(format: "%.3f", val)
        parentMenuItem?.title = SensitivityRange.menuTitle(h: AppSettings.shared.horizontalStep, v: val)
    }

    @objc private func resetDefaults() {
        AppSettings.shared.horizontalStep = SensitivityRange.horizontalDefault
        AppSettings.shared.verticalStep = SensitivityRange.verticalDefault
        syncFromSettings()
    }

    @objc private func clickHorizontalValue() {
        let anchor = NSEvent.mouseLocation
        dismissMenus()
        DispatchQueue.main.async {
            SensitivityInputPanelController.shared.show(
                axis: .horizontal,
                currentValue: AppSettings.shared.horizontalStep,
                near: anchor
            )
        }
    }

    @objc private func clickVerticalValue() {
        let anchor = NSEvent.mouseLocation
        dismissMenus()
        DispatchQueue.main.async {
            SensitivityInputPanelController.shared.show(
                axis: .vertical,
                currentValue: AppSettings.shared.verticalStep,
                near: anchor
            )
        }
    }

    private func dismissMenus() {
        hostMenu?.cancelTracking()
        enclosingMenuItem?.menu?.cancelTracking()
        parentMenuItem?.menu?.cancelTracking()
    }
}

/// 点击灵敏度数值后弹出的轻量直接输入小框（自动聚焦全选，回车确认 / Esc 取消）
final class SensitivityInputPanelController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = SensitivityInputPanelController()

    enum Axis {
        case horizontal
        case vertical

        var title: String {
            switch self {
            case .horizontal: return "设置左右滑动步距"
            case .vertical: return "设置上下滑动步距"
            }
        }

        var minVal: Double {
            switch self {
            case .horizontal: return SensitivityRange.horizontalMin
            case .vertical: return SensitivityRange.verticalMin
            }
        }

        var maxVal: Double {
            switch self {
            case .horizontal: return SensitivityRange.horizontalMax
            case .vertical: return SensitivityRange.verticalMax
            }
        }

        var rangeDescription: String {
            String(format: "范围 %.3f ~ %.3f（数值越小越灵敏）", minVal, maxVal)
        }
    }

    private var panel: NSPanel?
    private var textField: NSTextField?
    private var errorLabel: NSTextField?
    private var activeAxis: Axis = .horizontal

    private override init() {
        super.init()
    }

    func show(axis: Axis, currentValue: Double, near mousePoint: NSPoint) {
        panel?.close()
        activeAxis = axis

        let width: CGFloat = 276
        let height: CGFloat = 128

        let screen = NSScreen.screens.first(where: { $0.frame.contains(mousePoint) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var originX = round(mousePoint.x - width / 2)
        var originY = round(mousePoint.y - height - 8)
        originX = max(vf.minX + 12, min(originX, vf.maxX - width - 12))
        originY = max(vf.minY + 12, min(originY, vf.maxY - height - 12))

        let p = NSPanel(
            contentRect: NSRect(x: originX, y: originY, width: width, height: height),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        p.title = axis.title
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.delegate = self

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let hint = NSTextField(labelWithString: axis.rangeDescription)
        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 16, y: 94, width: width - 32, height: 18)
        content.addSubview(hint)

        let tf = NSTextField(string: String(format: "%.3f", currentValue))
        tf.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        tf.alignment = .left
        tf.frame = NSRect(x: 16, y: 60, width: width - 32, height: 26)
        tf.delegate = self
        content.addSubview(tf)

        let errLbl = NSTextField(labelWithString: "")
        errLbl.font = .systemFont(ofSize: 11)
        errLbl.textColor = .systemRed
        errLbl.frame = NSRect(x: 16, y: 38, width: width - 32, height: 16)
        content.addSubview(errLbl)

        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(cancelInput))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        cancelBtn.frame = NSRect(x: width - 146, y: 10, width: 62, height: 26)
        content.addSubview(cancelBtn)

        let okBtn = NSButton(title: "确定", target: self, action: #selector(confirmInput))
        okBtn.bezelStyle = .rounded
        okBtn.keyEquivalent = "\r"
        okBtn.frame = NSRect(x: width - 78, y: 10, width: 62, height: 26)
        content.addSubview(okBtn)

        p.contentView = content
        self.panel = p
        self.textField = tf
        self.errorLabel = errLbl

        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(tf)
        tf.selectText(nil)
    }

    @objc private func confirmInput() {
        guard let raw = textField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
              let parsed = Double(raw) else {
            errorLabel?.stringValue = "请输入有效数字"
            return
        }

        if parsed < activeAxis.minVal || parsed > activeAxis.maxVal {
            errorLabel?.stringValue = String(
                format: "当前范围限制为 %.3f ~ %.3f",
                activeAxis.minVal,
                activeAxis.maxVal
            )
            return
        }

        switch activeAxis {
        case .horizontal:
            AppSettings.shared.horizontalStep = SensitivityRange.clampHorizontal(parsed)
        case .vertical:
            AppSettings.shared.verticalStep = SensitivityRange.clampVertical(parsed)
        }

        panel?.close()
    }

    @objc private func cancelInput() {
        panel?.close()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            confirmInput()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelInput()
            return true
        }
        return false
    }
}
