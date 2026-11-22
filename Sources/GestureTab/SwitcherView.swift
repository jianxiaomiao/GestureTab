import AppKit
import SwiftUI

final class SwitcherViewModel: ObservableObject {
    @Published var items: [WindowItem] = []
    @Published var selectedIndex: Int = 0
    @Published var columns: Int = 6
    @Published var displayStyle: DisplayStyle = .compactPanel
    @Published var cardWidth: CGFloat = 196
    @Published var cardHeight: CGFloat = 146
    @Published var gridSpacing: CGFloat = 12

    var selectedItem: WindowItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    func load(items: [WindowItem], screenSize: CGSize, style: DisplayStyle, preferredColumns: Int) {
        self.items = items
        self.displayStyle = style
        computeLayout(for: items.count, screenSize: screenSize, style: style, preferredColumns: preferredColumns)
        // 默认选中第 2 个窗口（即上一个使用的窗口），只有一个窗口时选中第 0 个
        self.selectedIndex = items.count > 1 ? 1 : 0
    }

    private func computeLayout(for count: Int, screenSize: CGSize, style: DisplayStyle, preferredColumns: Int) {
        guard count > 0 else {
            self.columns = 1
            self.cardWidth = 300
            self.cardHeight = 140
            self.gridSpacing = 12
            return
        }

        switch style {
        case .compactPanel:
            let baseCols = max(3, preferredColumns)
            let cols = min(count, count > baseCols * 4 ? baseCols + 1 : baseCols)
            let rows = max(1, (count + cols - 1) / cols)
            let spacing: CGFloat = rows >= 4 ? 10 : 12

            let maxPanelW = max(640, screenSize.width * 0.88)
            let maxPanelH = max(420, screenSize.height * 0.80)
            let availW = maxPanelW - 36 - CGFloat(cols - 1) * spacing
            let availH = maxPanelH - 78 - CGFloat(rows - 1) * spacing

            let maxCardW = floor(availW / CGFloat(cols))
            let maxCardH = floor(availH / CGFloat(rows))
            let aspect: CGFloat = 0.74

            var w = min(204, maxCardW)
            var h = floor(w * aspect)
            if h > maxCardH {
                h = max(84, maxCardH)
                w = max(110, floor(h / aspect))
            } else {
                w = max(110, w)
                h = max(84, h)
            }

            self.columns = cols
            self.cardWidth = w
            self.cardHeight = h
            self.gridSpacing = spacing

        case .missionControl:
            let cols: Int
            switch count {
            case 1...3: cols = count
            case 4...8: cols = 4
            case 9...15: cols = 5
            case 16...24: cols = 6
            default: cols = 7
            }

            let rows = max(1, (count + cols - 1) / cols)
            let spacing: CGFloat = rows >= 4 ? 18 : 24
            let availW = max(720, screenSize.width * 0.90) - CGFloat(cols - 1) * spacing
            let availH = max(480, screenSize.height * 0.80) - CGFloat(rows - 1) * spacing

            let maxCardW = floor(availW / CGFloat(cols))
            let maxCardH = floor(availH / CGFloat(rows))
            let footerExtra: CGFloat = 44
            let thumbAspect: CGFloat = 0.64

            var w = min(340, maxCardW)
            var thumbH = floor(w * thumbAspect)
            if thumbH + footerExtra > maxCardH {
                thumbH = max(80, maxCardH - footerExtra)
                w = max(130, floor(thumbH / thumbAspect))
            }

            self.columns = cols
            self.cardWidth = w
            self.cardHeight = thumbH + footerExtra
            self.gridSpacing = spacing
        }
    }

    func updateThumbnail(windowID: CGWindowID, image: NSImage) {
        if let idx = items.firstIndex(where: { $0.id == windowID }) {
            items[idx].thumbnail = image
        }
    }

    @discardableResult
    func moveSelection(deltaCol: Int, deltaRow: Int) -> Bool {
        let count = items.count
        guard count > 1 else { return false }

        var nextIndex = selectedIndex

        // 上下移动：顶行不可上越到底行，底行不可下越到顶行
        if deltaRow != 0 {
            let totalRows = (count + columns - 1) / columns
            let curRow = nextIndex / columns
            let curCol = nextIndex % columns
            let nextRow = max(0, min(totalRows - 1, curRow + deltaRow))
            nextIndex = min(nextRow * columns + curCol, count - 1)
        }

        // 左右移动：行末右滑顺延至下一行首，行首左滑回上一行末；但左上角首项与末尾项边界均不循环
        if deltaCol != 0 {
            nextIndex = max(0, min(count - 1, nextIndex + deltaCol))
        }

        guard nextIndex != selectedIndex else { return false }
        selectedIndex = nextIndex
        return true
    }
}

struct VisualEffectBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct SwitcherView: View {
    @ObservedObject var viewModel: SwitcherViewModel
    let onSelectAndCommit: (Int) -> Void

    private var gridColumns: [GridItem] {
        let colCount = min(max(viewModel.items.count, 1), viewModel.columns)
        return Array(repeating: GridItem(.fixed(viewModel.cardWidth), spacing: viewModel.gridSpacing), count: colCount)
    }

    var body: some View {
        Group {
            switch viewModel.displayStyle {
            case .compactPanel:
                compactPanelBody
            case .missionControl:
                missionControlBody
            }
        }
    }

    // MARK: - 1. 紧凑悬浮面板（自动缩放，禁止滚动）

    private var compactPanelBody: some View {
        VStack(spacing: 10) {
            if viewModel.items.isEmpty {
                emptyStateView(darkText: false)
                    .frame(width: 340, height: 140)
            } else {
                LazyVGrid(columns: gridColumns, spacing: viewModel.gridSpacing) {
                    ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                        CompactWindowCardView(
                            item: item,
                            cardWidth: viewModel.cardWidth,
                            cardHeight: viewModel.cardHeight,
                            isSelected: index == viewModel.selectedIndex
                        )
                        .onTapGesture {
                            onSelectAndCommit(index)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)

                HStack(spacing: 16) {
                    if let selected = viewModel.selectedItem {
                        Text("\(selected.appName) — \(selected.displayTitle)")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    Text("滑动选窗口 · 松手切入 · Esc 取消")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
        .background(
            VisualEffectBackdrop(material: .hudWindow, blendingMode: .behindWindow)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .padding(14)
        .shadow(color: .black.opacity(0.28), radius: 22, x: 0, y: 10)
    }

    // MARK: - 2. 全屏调度视图（仿 macOS 调度中心，无滚动）

    private var missionControlBody: some View {
        ZStack {
            VisualEffectBackdrop(material: .fullScreenUI, blendingMode: .behindWindow)
                .ignoresSafeArea()
            Color.black.opacity(0.32)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                if let selected = viewModel.selectedItem {
                    Text("\(selected.appName)  ·  \(selected.displayTitle)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 22)
                }

                Spacer(minLength: 4)

                if viewModel.items.isEmpty {
                    emptyStateView(darkText: true)
                } else {
                    LazyVGrid(columns: gridColumns, spacing: viewModel.gridSpacing) {
                        ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                            MissionControlCardView(
                                item: item,
                                cardWidth: viewModel.cardWidth,
                                cardHeight: viewModel.cardHeight,
                                isSelected: index == viewModel.selectedIndex
                            )
                            .onTapGesture {
                                onSelectAndCommit(index)
                            }
                        }
                    }
                    .padding(.horizontal, 36)
                }

                Spacer(minLength: 4)

                Text("触控板滑动选择窗口 · 松手立即进入 · Esc 取消")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.bottom, 20)
            }
        }
    }

    private func emptyStateView(darkText: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 32))
                .foregroundStyle(darkText ? Color.white.opacity(0.8) : .secondary)
            Text("当前没有可切换的窗口")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(darkText ? Color.white.opacity(0.8) : .secondary)
        }
    }
}

// MARK: - Compact Card

private struct CompactWindowCardView: View {
    let item: WindowItem
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let isSelected: Bool

    var body: some View {
        let thumbHeight = max(52, cardHeight - 34)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let icon = item.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "app.dashed")
                        .frame(width: 16, height: 16)
                }

                Text(item.displayTitle)
                    .font(.system(size: max(10.5, min(12, cardWidth * 0.062)), weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 2)

                if item.isFullScreen {
                    StatusBadge(text: "全屏", lightStyle: false)
                } else if item.isMinimized {
                    StatusBadge(text: "最小化", lightStyle: false)
                } else if !item.isOnScreen {
                    StatusBadge(text: "其他桌面", lightStyle: false)
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))

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
                        .frame(width: min(62, thumbHeight * 0.62), height: min(62, thumbHeight * 0.62))
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: thumbHeight)
        }
        .padding(8)
        .frame(width: cardWidth, height: cardHeight)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(isSelected ? Color(nsColor: .controlAccentColor).opacity(0.22) : Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(
                    isSelected ? Color(nsColor: .controlAccentColor) : Color.primary.opacity(0.08),
                    lineWidth: isSelected ? 2.5 : 1
                )
        )
        .animation(.easeOut(duration: 0.08), value: isSelected)
    }
}

// MARK: - Mission Control Card

private struct MissionControlCardView: View {
    let item: WindowItem
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let isSelected: Bool

    var body: some View {
        let thumbHeight = max(72, cardHeight - 44)
        let iconSize = max(28, min(42, thumbHeight * 0.25))

        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.white.opacity(0.10))

                    if let thumb = item.thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .padding(3)
                    } else if let icon = item.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: min(72, thumbHeight * 0.55), height: min(72, thumbHeight * 0.55))
                    } else {
                        Image(systemName: "macwindow")
                            .font(.system(size: 32))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                .frame(width: cardWidth, height: thumbHeight)
                .overlay(alignment: .topTrailing) {
                    if item.isFullScreen {
                        StatusBadge(text: "全屏", lightStyle: true).padding(6)
                    } else if item.isMinimized {
                        StatusBadge(text: "最小化", lightStyle: true).padding(6)
                    } else if !item.isOnScreen {
                        StatusBadge(text: "其他桌面", lightStyle: true).padding(6)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(
                            isSelected ? Color(nsColor: .controlAccentColor) : Color.white.opacity(0.18),
                            lineWidth: isSelected ? 3.5 : 1
                        )
                )
                .shadow(
                    color: isSelected ? Color(nsColor: .controlAccentColor).opacity(0.65) : .black.opacity(0.42),
                    radius: isSelected ? 16 : 10,
                    x: 0,
                    y: 4
                )

                // 仿调度中心底部压边 App 图标
                if let icon = item.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: iconSize, height: iconSize)
                        .shadow(color: .black.opacity(0.45), radius: 4, x: 0, y: 2)
                        .offset(y: iconSize * 0.36)
                }
            }
            .padding(.bottom, iconSize * 0.42)

            Text(item.displayTitle)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: cardWidth)
        }
        .frame(width: cardWidth, height: cardHeight)
        .scaleEffect(isSelected ? 1.03 : 1.0)
        .animation(.easeOut(duration: 0.1), value: isSelected)
    }
}

private struct StatusBadge: View {
    let text: String
    let lightStyle: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(lightStyle ? Color.white.opacity(0.95) : .secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(lightStyle ? Color.black.opacity(0.55) : Color.primary.opacity(0.08))
            .clipShape(Capsule())
    }
}
