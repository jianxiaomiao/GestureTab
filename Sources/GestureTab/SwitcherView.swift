import AppKit
import SwiftUI

final class SwitcherViewModel: ObservableObject {
    @Published var items: [WindowItem] = []
    @Published var selectedIndex: Int = 0
    @Published var columns: Int = 6

    var selectedItem: WindowItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    func load(items: [WindowItem], columns: Int) {
        self.items = items
        self.columns = max(3, columns)
        // 默认选中第 2 个窗口（即上一个使用的窗口），只有一个窗口时选中第 0 个
        self.selectedIndex = items.count > 1 ? 1 : 0
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

        let totalRows = (count + columns - 1) / columns
        var curRow = selectedIndex / columns
        var curCol = selectedIndex % columns

        // 严格限制在网格上下左右边界内，不在边界处回卷到另一侧
        if deltaRow != 0 {
            curRow = max(0, min(totalRows - 1, curRow + deltaRow))
        }

        let rowStart = curRow * columns
        let rowEnd = min(rowStart + columns - 1, count - 1)
        let maxColInRow = rowEnd - rowStart
        curCol = min(curCol, maxColInRow)

        if deltaCol != 0 {
            curCol = max(0, min(maxColInRow, curCol + deltaCol))
        }

        let nextIndex = rowStart + curCol
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
        return Array(repeating: GridItem(.fixed(196), spacing: 12), count: colCount)
    }

    var body: some View {
        VStack(spacing: 12) {
            if viewModel.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("当前没有可切换的窗口")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 340, height: 140)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: viewModel.items.count > viewModel.columns * 3) {
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                                WindowCardView(
                                    item: item,
                                    isSelected: index == viewModel.selectedIndex
                                )
                                .id(item.id)
                                .onTapGesture {
                                    onSelectAndCommit(index)
                                }
                            }
                        }
                        .padding(18)
                    }
                    .frame(maxHeight: 540)
                    .onChange(of: viewModel.selectedIndex) { _, newIdx in
                        if viewModel.items.indices.contains(newIdx) {
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(viewModel.items[newIdx].id, anchor: .center)
                            }
                        }
                    }
                }

                // 底部轻量操作提示栏
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
}

private struct WindowCardView: View {
    let item: WindowItem
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 卡片顶部：App 图标 + 窗口标题 + 状态徽标
            HStack(spacing: 6) {
                if let icon = item.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "app.dashed")
                        .frame(width: 18, height: 18)
                }

                Text(item.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 2)

                if item.isFullScreen {
                    StatusBadge(text: "全屏")
                } else if item.isMinimized {
                    StatusBadge(text: "最小化")
                } else if !item.isOnScreen {
                    StatusBadge(text: "其他桌面")
                }
            }

            // 卡片主体：窗口实时/缓存缩略图，无缓存时使用 App 图标兜底
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.05))

                if let thumb = item.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .padding(3)
                } else if let icon = item.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 66, height: 66)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 112)
        }
        .padding(9)
        .frame(width: 196)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color(nsColor: .controlAccentColor).opacity(0.22) : Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSelected ? Color(nsColor: .controlAccentColor) : Color.primary.opacity(0.08),
                    lineWidth: isSelected ? 2.5 : 1
                )
        )
        .animation(.easeOut(duration: 0.08), value: isSelected)
    }
}

private struct StatusBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color.primary.opacity(0.08))
            .clipShape(Capsule())
    }
}
