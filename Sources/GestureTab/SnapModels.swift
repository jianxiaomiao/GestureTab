import AppKit
import Foundation

/// 单个分屏区域（使用相对可用桌面 visibleFrame 的归一化左上角坐标 0...1）
struct SnapZone: Identifiable, Equatable {
    let id: Int
    let normalizedRect: CGRect

    func cocoaRect(in screen: NSScreen) -> CGRect {
        let vf = screen.visibleFrame
        let x = vf.minX + normalizedRect.minX * vf.width
        let w = normalizedRect.width * vf.width
        let h = normalizedRect.height * vf.height
        let y = vf.maxY - (normalizedRect.minY + normalizedRect.height) * vf.height
        return CGRect(x: round(x), y: round(y), width: round(w), height: round(h))
    }

    func axRect(in screen: NSScreen) -> CGRect {
        WindowService.cocoaRectToAXRect(cocoaRect(in: screen))
    }
}

/// 分屏布局模板
struct SnapLayout: Identifiable, Equatable {
    let id: String
    let name: String
    let zones: [SnapZone]

    static let maximize = SnapLayout(
        id: "maximize",
        name: "最大化",
        zones: [SnapZone(id: 0, normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))]
    )

    static let halves = SnapLayout(
        id: "halves",
        name: "左右均分",
        zones: [
            SnapZone(id: 0, normalizedRect: CGRect(x: 0, y: 0, width: 0.5, height: 1)),
            SnapZone(id: 1, normalizedRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        ]
    )

    static let mainAndSide = SnapLayout(
        id: "mainAndSide",
        name: "主副 65/35",
        zones: [
            SnapZone(id: 0, normalizedRect: CGRect(x: 0, y: 0, width: 0.65, height: 1)),
            SnapZone(id: 1, normalizedRect: CGRect(x: 0.65, y: 0, width: 0.35, height: 1))
        ]
    )

    static let thirds = SnapLayout(
        id: "thirds",
        name: "三栏并排",
        zones: [
            SnapZone(id: 0, normalizedRect: CGRect(x: 0, y: 0, width: 1.0 / 3.0, height: 1)),
            SnapZone(id: 1, normalizedRect: CGRect(x: 1.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1)),
            SnapZone(id: 2, normalizedRect: CGRect(x: 2.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1))
        ]
    )

    static let leftHalfRightQuarters = SnapLayout(
        id: "leftHalfRightQuarters",
        name: "左一右二",
        zones: [
            SnapZone(id: 0, normalizedRect: CGRect(x: 0, y: 0, width: 0.5, height: 1)),
            SnapZone(id: 1, normalizedRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)),
            SnapZone(id: 2, normalizedRect: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        ]
    )

    static let quarters = SnapLayout(
        id: "quarters",
        name: "四宫格 2×2",
        zones: [
            SnapZone(id: 0, normalizedRect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)),
            SnapZone(id: 1, normalizedRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)),
            SnapZone(id: 2, normalizedRect: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)),
            SnapZone(id: 3, normalizedRect: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        ]
    )

    static let topBottom = SnapLayout(
        id: "topBottom",
        name: "上下均分",
        zones: [
            SnapZone(id: 0, normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 0.5)),
            SnapZone(id: 1, normalizedRect: CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
        ]
    )

    /// 顶部悬浮分屏布局选择器展示的模板（含最大化 + 6 套经典分屏）
    static let barTemplates: [SnapLayout] = [
        .maximize,
        .halves,
        .mainAndSide,
        .thirds,
        .leftHalfRightQuarters,
        .quarters,
        .topBottom
    ]
}

/// 当前分屏锁定目标
struct SnapTarget: Equatable {
    let screen: NSScreen
    let layout: SnapLayout
    let zoneIndex: Int

    var targetZone: SnapZone {
        layout.zones[zoneIndex]
    }

    var cocoaRect: CGRect {
        targetZone.cocoaRect(in: screen)
    }

    var axRect: CGRect {
        targetZone.axRect(in: screen)
    }
}
