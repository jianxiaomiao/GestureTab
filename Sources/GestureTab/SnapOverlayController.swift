import AppKit
import SwiftUI

// MARK: - 1. 分屏半透明蓝色预览框

final class SnapPreviewOverlayController {
    private var panel: NSPanel?

    func showPreview(cocoaRect: CGRect) {
        let insetRect = cocoaRect.insetBy(dx: 6, dy: 6)
        if panel == nil {
            let p = NSPanel(
                contentRect: insetRect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
            p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: SnapPreviewBoxView())
            self.panel = p
        }

        guard let panel else { return }
        if !panel.isVisible {
            panel.setFrame(insetRect, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        } else if panel.frame != insetRect {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(insetRect, display: true)
            }
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

private struct SnapPreviewBoxView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: .controlAccentColor).opacity(0.20))
            .background(
                VisualEffectBackdrop(material: .hudWindow, blendingMode: .behindWindow)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .opacity(0.65)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(nsColor: .controlAccentColor), lineWidth: 2.5)
            )
    }
}

// MARK: - 2. 顶部悬浮分屏布局选择器（Snap Layouts Bar）

final class SnapLayoutBarViewModel: ObservableObject {
    @Published var hoveredLayoutID: String? = nil
    @Published var hoveredZoneIndex: Int? = nil
}

final class SnapLayoutBarController {
    private var panel: NSPanel?
    private let viewModel = SnapLayoutBarViewModel()
    private(set) var currentScreen: NSScreen?

    private let templates = SnapLayout.barTemplates
    private let thumbWidth: CGFloat = 78
    private let thumbHeight: CGFloat = 50
    private let itemSpacing: CGFloat = 12
    private let hPadding: CGFloat = 16
    private let vPadding: CGFloat = 12
    private let titleHeight: CGFloat = 20

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    var panelFrame: CGRect {
        panel?.frame ?? .zero
    }

    func show(on screen: NSScreen) {
        currentScreen = screen
        let totalW = hPadding * 2
            + CGFloat(templates.count) * thumbWidth
            + CGFloat(templates.count - 1) * itemSpacing
        let totalH = vPadding * 2 + thumbHeight + titleHeight + 8

        let vf = screen.visibleFrame
        let originX = round(vf.midX - totalW / 2)
        let originY = round(vf.maxY - totalH - 10)
        let frame = CGRect(x: originX, y: originY, width: totalW, height: totalH)

        if panel == nil {
            let p = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
            p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: SnapLayoutBarView(
                viewModel: viewModel,
                templates: templates,
                thumbWidth: thumbWidth,
                thumbHeight: thumbHeight,
                itemSpacing: itemSpacing,
                hPadding: hPadding,
                vPadding: vPadding,
                titleHeight: titleHeight
            ))
            self.panel = p
        }

        panel?.setFrame(frame, display: true)
        panel?.orderFrontRegardless()
    }

    func hide() {
        viewModel.hoveredLayoutID = nil
        viewModel.hoveredZoneIndex = nil
        panel?.orderOut(nil)
    }

    /// 根据当前鼠标 Cocoa 坐标精确命中模板内的某个分屏区域
    func hitTest(cocoaMouse: CGPoint) -> SnapTarget? {
        guard isVisible, let panel, let screen = currentScreen else { return nil }
        let pf = panel.frame
        // 向上延伸到屏幕最顶边，向下留出 14pt 容差，保证从顶边拖入布局栏全程不断触
        let hitMaxY = max(pf.maxY + 24, screen.frame.maxY)
        let hitBounds = CGRect(x: pf.minX, y: pf.minY - 14, width: pf.width, height: hitMaxY - (pf.minY - 14))
        guard hitBounds.contains(cocoaMouse) else {
            viewModel.hoveredLayoutID = nil
            viewModel.hoveredZoneIndex = nil
            return nil
        }

        // 计算在模板列表内的横向索引
        let localX = cocoaMouse.x - pf.minX - hPadding
        let strideX = thumbWidth + itemSpacing
        guard localX >= 0 else {
            viewModel.hoveredLayoutID = nil
            viewModel.hoveredZoneIndex = nil
            return nil
        }

        let idx = Int(localX / strideX)
        guard idx >= 0, idx < templates.count else {
            viewModel.hoveredLayoutID = nil
            viewModel.hoveredZoneIndex = nil
            return nil
        }

        let offsetInSlot = localX - CGFloat(idx) * strideX
        let clampedX = min(max(offsetInSlot / thumbWidth, 0), 0.999)

        // 布局缩略图在面板上方（Cocoa 中 maxY 往下偏移 vPadding）
        let thumbTopCocoa = pf.maxY - vPadding
        let thumbBottomCocoa = thumbTopCocoa - thumbHeight
        let clampedY = min(max((thumbTopCocoa - cocoaMouse.y) / thumbHeight, 0), 0.999)

        let layout = templates[idx]
        for (zIdx, zone) in layout.zones.enumerated() {
            if zone.normalizedRect.contains(CGPoint(x: clampedX, y: clampedY)) {
                viewModel.hoveredLayoutID = layout.id
                viewModel.hoveredZoneIndex = zIdx
                return SnapTarget(screen: screen, layout: layout, zoneIndex: zIdx)
            }
        }

        // 若落在缝隙中且处于面板高度内，回退到距离最近区域
        if cocoaMouse.y >= thumbBottomCocoa - 16 {
            viewModel.hoveredLayoutID = layout.id
            viewModel.hoveredZoneIndex = 0
            return SnapTarget(screen: screen, layout: layout, zoneIndex: 0)
        }
        return nil
    }
}

private struct SnapLayoutBarView: View {
    @ObservedObject var viewModel: SnapLayoutBarViewModel
    let templates: [SnapLayout]
    let thumbWidth: CGFloat
    let thumbHeight: CGFloat
    let itemSpacing: CGFloat
    let hPadding: CGFloat
    let vPadding: CGFloat
    let titleHeight: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: itemSpacing) {
                ForEach(templates) { layout in
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .frame(width: thumbWidth, height: thumbHeight)

                        ForEach(Array(layout.zones.enumerated()), id: \.element.id) { zIdx, zone in
                            let nr = zone.normalizedRect
                            let isHovered = (viewModel.hoveredLayoutID == layout.id && viewModel.hoveredZoneIndex == zIdx)
                            let gap: CGFloat = 3
                            let zw = max(8, nr.width * thumbWidth - gap)
                            let zh = max(8, nr.height * thumbHeight - gap)
                            let zx = nr.minX * thumbWidth + gap / 2
                            let zy = nr.minY * thumbHeight + gap / 2

                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .fill(isHovered ? Color(nsColor: .controlAccentColor) : Color.primary.opacity(0.16))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                        .stroke(
                                            isHovered ? Color.white.opacity(0.85) : Color.primary.opacity(0.22),
                                            lineWidth: isHovered ? 1.5 : 0.8
                                        )
                                )
                                .frame(width: zw, height: zh)
                                .offset(x: zx, y: zy)
                        }
                    }
                    .frame(width: thumbWidth, height: thumbHeight, alignment: .topLeading)
                    .clipped()
                }
            }

            HStack {
                if let lid = viewModel.hoveredLayoutID,
                   let layout = templates.first(where: { $0.id == lid }) {
                    Text("松手吸附到：\(layout.name)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .controlAccentColor))
                } else {
                    Text("将窗口拖到上方任意分屏区域内松手")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: titleHeight)
        }
        .padding(.horizontal, hPadding)
        .padding(.vertical, vPadding)
        .background(
            VisualEffectBackdrop(material: .hudWindow, blendingMode: .behindWindow)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)
    }
}

// MARK: - 3. 分屏后空闲区域窗口缩略图选择器（Snap Assist）

final class SnapAssistViewModel: ObservableObject {
    @Published var candidates: [WindowItem] = []
    @Published var remainingCount: Int = 0
}

final class SnapAssistController {
    static let shared = SnapAssistController()

    private let viewModel = SnapAssistViewModel()
    private var panel: NSPanel?
    private let previewOverlay = SnapPreviewOverlayController()

    private var screen: NSScreen?
    private var layout: SnapLayout?
    private var pendingZoneIndices: [Int] = []
    private var placedWindowIDs: Set<CGWindowID> = []
    private var keyMonitor: Any?
    private var clickMonitor: Any?

    var onWindowSnapped: ((_ windowID: CGWindowID, _ originalFrame: CGRect, _ axWindow: AXUIElement) -> Void)?

    private init() {}

    func begin(on screen: NSScreen, layout: SnapLayout, filledZoneIndex: Int, primaryWindowID: CGWindowID?) {
        let remaining = (0..<layout.zones.count).filter { $0 != filledZoneIndex }
        guard !remaining.isEmpty else {
            dismiss()
            return
        }

        self.screen = screen
        self.layout = layout
        self.pendingZoneIndices = remaining
        self.placedWindowIDs = primaryWindowID.map { [$0] } ?? []

        reloadCandidates()
        if viewModel.candidates.isEmpty {
            dismiss()
            return
        }

        presentNextEmptyZone()
    }

    private func reloadCandidates() {
        let all = WindowService.shared.fetchAllSwitchableWindows()
        // 仅展示当前桌面窗口与 Dock 最小化窗口（避免点击全屏或其他桌面窗口导致突然跳离当前分屏桌面）
        viewModel.candidates = all.filter {
            !$0.isWindowlessApp && !$0.isFullScreen && ($0.isOnScreen || $0.isMinimized) && !placedWindowIDs.contains($0.id)
        }
    }

    private func presentNextEmptyZone() {
        guard let screen, let layout, let nextZoneIndex = pendingZoneIndices.first,
              !viewModel.candidates.isEmpty else {
            dismiss()
            return
        }

        viewModel.remainingCount = pendingZoneIndices.count
        let zoneRect = layout.zones[nextZoneIndex].cocoaRect(in: screen)
        previewOverlay.showPreview(cocoaRect: zoneRect)

        // 限制面板宽度适应空闲区域大小
        let maxW = max(320, min(zoneRect.width - 32, 640))
        let maxH = max(240, min(zoneRect.height - 32, 460))
        let originX = round(zoneRect.midX - maxW / 2)
        let originY = round(zoneRect.midY - maxH / 2)
        let panelRect = CGRect(x: originX, y: originY, width: maxW, height: maxH)

        if panel == nil {
            let p = NSPanel(
                contentRect: panelRect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
            p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: SnapAssistView(
                viewModel: viewModel,
                onPick: { [weak self] item in
                    self?.fillCurrentZone(with: item)
                },
                onSkip: { [weak self] in
                    self?.skipCurrentZone()
                },
                onDismiss: { [weak self] in
                    self?.dismiss()
                }
            ))
            self.panel = p
        }

        panel?.setFrame(panelRect, display: true)
        panel?.orderFrontRegardless()
        installMonitors()

        // 异步补抓最新缩略图
        let ids = Set(viewModel.candidates.map(\.id))
        WindowService.shared.refreshThumbnailsAsync(for: ids) { [weak self] wid, img in
            guard let self, self.panel?.isVisible == true else { return }
            if let idx = self.viewModel.candidates.firstIndex(where: { $0.id == wid }) {
                self.viewModel.candidates[idx].thumbnail = img
            }
        }
    }

    private func fillCurrentZone(with item: WindowItem) {
        guard let screen, let layout, let zoneIndex = pendingZoneIndices.first else {
            dismiss()
            return
        }

        let targetAXRect = layout.zones[zoneIndex].axRect(in: screen)
        placedWindowIDs.insert(item.id)

        // 记录原始尺寸以支持之后拖离还原
        let resolvedAX = item.axElement ?? WindowService.shared.findAXWindow(pid: item.pid, windowID: item.id)
        if let ax = resolvedAX, let orig = WindowService.shared.getWindowFrame(ax) {
            onWindowSnapped?(item.id, orig, ax)
        }

        WindowService.shared.activateWindow(item)

        if let ax = resolvedAX {
            WindowService.shared.setWindowFrame(ax, axFrame: targetAXRect)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                WindowService.shared.setWindowFrame(ax, axFrame: targetAXRect)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                if let ax = WindowService.shared.findAXWindow(pid: item.pid, windowID: item.id) {
                    if let orig = WindowService.shared.getWindowFrame(ax) {
                        self?.onWindowSnapped?(item.id, orig, ax)
                    }
                    WindowService.shared.setWindowFrame(ax, axFrame: targetAXRect)
                }
            }
        }

        if AppSettings.shared.hapticEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }

        pendingZoneIndices.removeFirst()
        viewModel.candidates.removeAll { $0.id == item.id }
        presentNextEmptyZone()
    }

    private func skipCurrentZone() {
        guard !pendingZoneIndices.isEmpty else {
            dismiss()
            return
        }
        pendingZoneIndices.removeFirst()
        presentNextEmptyZone()
    }

    func dismiss() {
        removeMonitors()
        previewOverlay.hide()
        panel?.orderOut(nil)
        pendingZoneIndices.removeAll()
        placedWindowIDs.removeAll()
    }

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc 关闭 Snap Assist
                DispatchQueue.main.async {
                    self?.dismiss()
                }
            }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            let loc = NSEvent.mouseLocation
            if !panel.frame.contains(loc) {
                DispatchQueue.main.async {
                    self.dismiss()
                }
            }
        }
    }

    private func removeMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }
}

private struct SnapAssistView: View {
    @ObservedObject var viewModel: SnapAssistViewModel
    let onPick: (WindowItem) -> Void
    let onSkip: () -> Void
    let onDismiss: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 10)]

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("选择填入此区域的窗口（还剩 \(viewModel.remainingCount) 格）")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if viewModel.remainingCount > 1 {
                    Button("跳过此格") {
                        onSkip()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button("完成 (Esc)") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(viewModel.candidates) { item in
                        Button {
                            onPick(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 5) {
                                    if let icon = item.appIcon {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .interpolation(.high)
                                            .frame(width: 15, height: 15)
                                    }
                                    Text(item.displayTitle)
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }

                                ZStack {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                    if let thumb = item.thumbnail {
                                        Image(nsImage: thumb)
                                            .resizable()
                                            .interpolation(.high)
                                            .aspectRatio(contentMode: .fit)
                                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                            .padding(2)
                                    } else if let icon = item.appIcon {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .interpolation(.high)
                                            .frame(width: 44, height: 44)
                                    }
                                }
                                .frame(height: 82)
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.primary.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .background(
            VisualEffectBackdrop(material: .hudWindow, blendingMode: .behindWindow)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 8)
    }
}
