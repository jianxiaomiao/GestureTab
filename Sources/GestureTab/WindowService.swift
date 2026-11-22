import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> AXUIElement?

private typealias CGSConnectionID = Int32
private typealias CGSMainConnectionIDFn = @convention(c) () -> CGSConnectionID
private typealias CGSHWCaptureWindowListFn = @convention(c) (
    CGSConnectionID,
    UnsafeMutablePointer<CGWindowID>,
    Int32,
    UInt32
) -> Unmanaged<CFArray>?

/// SkyLight 私有高速抓图接口（可尝试直接抓取后台/其他 Space 已渲染窗口）
private enum SkyLightCapture {
    private static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
            ?? dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
    }()

    private static let fnMainConnection: CGSMainConnectionIDFn? = {
        guard let handle, let sym = dlsym(handle, "CGSMainConnectionID") else { return nil }
        return unsafeBitCast(sym, to: CGSMainConnectionIDFn.self)
    }()

    private static let fnHWCaptureList: CGSHWCaptureWindowListFn? = {
        guard let handle, let sym = dlsym(handle, "CGSHWCaptureWindowList") else { return nil }
        return unsafeBitCast(sym, to: CGSHWCaptureWindowListFn.self)
    }()

    static func capture(windowID: CGWindowID) -> CGImage? {
        guard let fnMainConnection, let fnHWCaptureList else { return nil }
        let cid = fnMainConnection()
        var wid = windowID

        // 0x0200 = kCGSWindowCaptureNominalResolution
        if let arr = fnHWCaptureList(cid, &wid, 1, 0x0200)?.takeRetainedValue() as? [CGImage],
           let img = arr.first {
            return img
        }
        if let arr = fnHWCaptureList(cid, &wid, 1, 0x0000)?.takeRetainedValue() as? [CGImage],
           let img = arr.first {
            return img
        }
        return nil
    }
}

/// 负责枚举全桌面/全屏/最小化窗口、维护 MRU 排序、后台缓存缩略图及精准前置窗口
final class WindowService {
    static let shared = WindowService()

    private let thumbnailLock = NSLock()
    private var thumbnailCache: [CGWindowID: NSImage] = [:]

    private let axCacheLock = NSLock()
    private var axElementCache: [CGWindowID: AXUIElement] = [:]

    private let mruLock = NSLock()
    private var mruOrder: [CGWindowID] = []

    private var appActivateObserver: NSObjectProtocol?
    private var spaceChangeObserver: NSObjectProtocol?
    private var backgroundTimer: Timer?
    private var isCapturingBackground = false

    private lazy var diskCacheDir: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = caches.appendingPathComponent("GestureTab/thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {}

    func startMonitoring() {
        loadDiskThumbnailCache()
        updateFrontmostWindowMRU()
        captureVisibleThumbnailsInBackground()

        appActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 稍延迟等待目标 App 更新焦点窗口并缓存其最新画面
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.updateFrontmostWindowMRU()
                self?.captureVisibleThumbnailsInBackground()
            }
        }

        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 切换到任意其他桌面/全屏后立即抓取该桌面全部窗口缓存
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                self?.captureVisibleThumbnailsInBackground()
            }
        }

        // 每 2.5 秒低开销缓存一次当前可见窗口画面，以便最小化或切到其他桌面后仍保留缩略图
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.captureVisibleThumbnailsInBackground()
        }
    }

    func stopMonitoring() {
        if let appActivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivateObserver)
            self.appActivateObserver = nil
        }
        if let spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeObserver)
            self.spaceChangeObserver = nil
        }
        backgroundTimer?.invalidate()
        backgroundTimer = nil
    }

    /// 检查权限状态
    static func hasAccessibilityPermission(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - MRU Tracking

    private func updateFrontmostWindowMRU() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }

        let appAX = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appAX, kAXFocusedWindowAttribute as CFString, &focusedRef)
        if err == .success, let winRef = focusedRef {
            let winAX = winRef as! AXUIElement
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(winAX, &wid) == .success, wid != 0 {
                bumpMRU(windowID: wid)
                return
            }
        }

        // 兜底：取 CGWindowList 中该 App 最靠前的 layer-0 窗口
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid == frontApp.processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let wid = info[kCGWindowNumber as String] as? CGWindowID else {
                continue
            }
            bumpMRU(windowID: wid)
            break
        }
    }

    func bumpMRU(windowID: CGWindowID) {
        mruLock.lock()
        mruOrder.removeAll { $0 == windowID }
        mruOrder.insert(windowID, at: 0)
        if mruOrder.count > 120 {
            mruOrder.removeLast(mruOrder.count - 120)
        }
        mruLock.unlock()
    }

    // MARK: - Window Enumeration (All Spaces, FullScreen, Minimized)

    func fetchAllSwitchableWindows() -> [WindowItem] {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let cgList = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []

        // 按 CGWindowID 索引系统底层窗口属性
        struct CGInfo {
            let pid: pid_t
            let ownerName: String
            let title: String
            let layer: Int
            let bounds: CGRect
            let isOnScreen: Bool
            let zIndex: Int
        }

        var cgByID: [CGWindowID: CGInfo] = [:]
        for (idx, dict) in cgList.enumerated() {
            guard let wid = dict[kCGWindowNumber as String] as? CGWindowID,
                  let pid = dict[kCGWindowOwnerPID as String] as? pid_t,
                  pid != selfPID else {
                continue
            }
            let layer = (dict[kCGWindowLayer as String] as? Int) ?? -1
            let ownerName = (dict[kCGWindowOwnerName as String] as? String) ?? ""
            let title = (dict[kCGWindowName as String] as? String) ?? ""
            let isOnScreen = (dict[kCGWindowIsOnscreen as String] as? Bool) ?? false

            var bounds = CGRect.zero
            if let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary {
                CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds)
            }

            cgByID[wid] = CGInfo(
                pid: pid,
                ownerName: ownerName,
                title: title,
                layer: layer,
                bounds: bounds,
                isOnScreen: isOnScreen,
                zIndex: idx
            )
        }

        let regularApps = NSWorkspace.shared.runningApplications.filter {
            guard $0.activationPolicy == .regular,
                  $0.processIdentifier != selfPID,
                  !$0.isTerminated else {
                return false
            }
            let name = $0.localizedName ?? "App"
            return !AppSettings.shared.isAppIgnored(bundleID: $0.bundleIdentifier, appName: name)
        }

        var itemsByID: [CGWindowID: WindowItem] = [:]
        var zOrderByID: [CGWindowID: Int] = [:]

        // 1) 通过 AXUIElement 遍历每个常规 App 的全部窗口（包含最小化、全屏、跨桌面）
        for app in regularApps {
            let pid = app.processIdentifier
            let appAX = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            let axResult = AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &windowsRef)
            guard axResult == .success, let axWindows = windowsRef as? [AXUIElement] else {
                continue
            }

            let appName = app.localizedName ?? "App"
            let appIcon = app.icon

            for axWin in axWindows {
                var subroleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWin, kAXSubroleAttribute as CFString, &subroleRef)
                let subrole = subroleRef as? String
                if let subrole, subrole != "AXStandardWindow" && subrole != "AXDialog" {
                    continue
                }

                var wid: CGWindowID = 0
                guard _AXUIElementGetWindow(axWin, &wid) == .success, wid != 0 else {
                    continue
                }

                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &titleRef)
                let axTitle = (titleRef as? String) ?? ""

                var minRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWin, kAXMinimizedAttribute as CFString, &minRef)
                let isMinimized = (minRef as? Bool) ?? false

                var fsRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWin, "AXFullScreen" as CFString, &fsRef)
                var isFullScreen = (fsRef as? Bool) ?? false

                // 过滤极小的隐藏辅助窗口
                let cgInfo = cgByID[wid]
                if let bounds = cgInfo?.bounds, (bounds.width < 80 || bounds.height < 60), !isMinimized {
                    continue
                }

                // 若尺寸几乎等于屏幕大小且无边框特征，补充识别全屏
                if !isFullScreen, let bounds = cgInfo?.bounds, let mainScreen = NSScreen.main {
                    if abs(bounds.width - mainScreen.frame.width) <= 2 &&
                       abs(bounds.height - mainScreen.frame.height) <= 2 &&
                       app.bundleIdentifier != "com.apple.finder" {
                        isFullScreen = true
                    }
                }

                let resolvedTitle = !axTitle.isEmpty ? axTitle : (cgInfo?.title ?? "")
                let cachedThumb = getCachedThumbnail(for: wid)
                setCachedAXElement(axWin, for: wid)

                itemsByID[wid] = WindowItem(
                    id: wid,
                    pid: pid,
                    appName: appName,
                    title: resolvedTitle,
                    appIcon: appIcon,
                    axElement: axWin,
                    runningApp: app,
                    isMinimized: isMinimized,
                    isFullScreen: isFullScreen,
                    isOnScreen: cgInfo?.isOnScreen ?? false,
                    thumbnail: cachedThumb
                )
                zOrderByID[wid] = cgInfo?.zIndex ?? Int.max
            }
        }

        // 2) 补充 CGWindowList 中属于常规 App、在其他 Space 未被 AX 返回的窗口
        let appsByPID = Dictionary(uniqueKeysWithValues: regularApps.map { ($0.processIdentifier, $0) })
        for (wid, cgInfo) in cgByID {
            guard itemsByID[wid] == nil,
                  cgInfo.layer == 0,
                  cgInfo.bounds.width >= 100,
                  cgInfo.bounds.height >= 80,
                  let app = appsByPID[cgInfo.pid] else {
                continue
            }

            // 跳过 Finder 桌面底层窗口
            if app.bundleIdentifier == "com.apple.finder" && cgInfo.title.isEmpty {
                continue
            }
            // 跳过无标题的隐形后台渲染窗
            if cgInfo.title.isEmpty && !cgInfo.isOnScreen {
                continue
            }

            let isFS: Bool = {
                guard let screen = NSScreen.main else { return false }
                return abs(cgInfo.bounds.width - screen.frame.width) <= 2 &&
                       abs(cgInfo.bounds.height - screen.frame.height) <= 2
            }()

            itemsByID[wid] = WindowItem(
                id: wid,
                pid: cgInfo.pid,
                appName: app.localizedName ?? cgInfo.ownerName,
                title: cgInfo.title,
                appIcon: app.icon,
                axElement: getCachedAXElement(for: wid),
                runningApp: app,
                isMinimized: false,
                isFullScreen: isFS,
                isOnScreen: cgInfo.isOnScreen,
                thumbnail: getCachedThumbnail(for: wid)
            )
            zOrderByID[wid] = cgInfo.zIndex
        }

        // 3) 按 MRU 排序，未在 MRU 中的按 WindowServer zOrder 排在后面
        mruLock.lock()
        let mruSnapshot = mruOrder
        mruLock.unlock()

        let mruRank = Dictionary(uniqueKeysWithValues: mruSnapshot.enumerated().map { ($0.element, $0.offset) })

        return itemsByID.values.sorted { a, b in
            let rankA = mruRank[a.id]
            let rankB = mruRank[b.id]
            switch (rankA, rankB) {
            case let (ra?, rb?):
                return ra < rb
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                let za = zOrderByID[a.id] ?? Int.max
                let zb = zOrderByID[b.id] ?? Int.max
                if za != zb { return za < zb }
                return a.appName < b.appName
            }
        }
    }

    // MARK: - Thumbnail Caching & Refresh (SkyLight + ScreenCaptureKit + Disk Cache)

    private func getCachedThumbnail(for windowID: CGWindowID) -> NSImage? {
        thumbnailLock.lock()
        defer { thumbnailLock.unlock() }
        return thumbnailCache[windowID]
    }

    private func setCachedThumbnail(_ image: NSImage, for windowID: CGWindowID, saveToDisk: Bool = true) {
        thumbnailLock.lock()
        thumbnailCache[windowID] = image
        thumbnailLock.unlock()

        if saveToDisk, let dir = diskCacheDir {
            let fileURL = dir.appendingPathComponent("\(windowID).jpg")
            DispatchQueue.global(qos: .background).async {
                guard let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else {
                    return
                }
                try? jpeg.write(to: fileURL, options: .atomic)
            }
        }
    }

    private func loadDiskThumbnailCache() {
        guard let dir = diskCacheDir,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
              ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for url in files where url.pathExtension == "jpg" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let mod = values?.contentModificationDate, mod < cutoff {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if let wid = UInt32(url.deletingPathExtension().lastPathComponent),
               let img = NSImage(contentsOf: url) {
                thumbnailLock.lock()
                thumbnailCache[wid] = img
                thumbnailLock.unlock()
            }
        }
    }

    private func scaledThumbnail(from cgImage: CGImage) -> NSImage {
        let origW = CGFloat(cgImage.width)
        let origH = CGFloat(cgImage.height)
        let maxW: CGFloat = 480
        let targetW = Int(min(max(origW, 160), maxW))
        let targetH = max(Int(CGFloat(targetW) * (origH / max(origW, 1))), 90)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        if let ctx = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) {
            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
            if let resized = ctx.makeImage() {
                return NSImage(cgImage: resized, size: NSSize(width: targetW, height: targetH))
            }
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: targetW, height: targetH))
    }

    private func captureVisibleThumbnailsInBackground() {
        guard !isCapturingBackground, Self.hasScreenRecordingPermission() else { return }
        isCapturingBackground = true

        Task.detached(priority: .utility) { [weak self] in
            defer { self?.isCapturingBackground = false }
            await self?.refreshThumbnails(for: nil, onScreenOnly: true, limit: 40, onUpdate: nil)
        }
    }

    func refreshThumbnailsAsync(
        for windowIDs: Set<CGWindowID>,
        onUpdate: @escaping (_ windowID: CGWindowID, _ image: NSImage) -> Void
    ) {
        guard Self.hasScreenRecordingPermission() else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            // 1) 先用 SkyLight CGSHWCaptureWindowList 尝试抓取全量窗口（含跨 Space/遮挡窗口）
            var capturedIDs = Set<CGWindowID>()
            for wid in windowIDs {
                if let cgImg = SkyLightCapture.capture(windowID: wid),
                   cgImg.width >= 40, cgImg.height >= 40 {
                    let nsImg = self.scaledThumbnail(from: cgImg)
                    self.setCachedThumbnail(nsImg, for: wid)
                    capturedIDs.insert(wid)
                    await MainActor.run {
                        onUpdate(wid, nsImg)
                    }
                }
            }

            // 2) 对 SkyLight 未拿到的窗口，再用 ScreenCaptureKit 补充抓取
            let remaining = windowIDs.subtracting(capturedIDs)
            if !remaining.isEmpty {
                await self.refreshThumbnails(for: remaining, onScreenOnly: false, limit: 40, onUpdate: onUpdate)
            }
        }
    }

    private func refreshThumbnails(
        for targetIDs: Set<CGWindowID>?,
        onScreenOnly: Bool,
        limit: Int,
        onUpdate: ((_ windowID: CGWindowID, _ image: NSImage) -> Void)?
    ) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: onScreenOnly)
            var captured = 0

            for scWin in content.windows {
                if captured >= limit { break }
                let wid = scWin.windowID
                if let targetIDs, !targetIDs.contains(wid) { continue }
                if scWin.frame.width < 80 || scWin.frame.height < 60 { continue }

                // 优先尝试 SkyLight（极速且支持后台/遮挡窗口）
                if let cgImg = SkyLightCapture.capture(windowID: wid),
                   cgImg.width >= 40, cgImg.height >= 40 {
                    let nsImg = scaledThumbnail(from: cgImg)
                    setCachedThumbnail(nsImg, for: wid)
                    captured += 1
                    if let onUpdate {
                        await MainActor.run { onUpdate(wid, nsImg) }
                    }
                    continue
                }

                let filter = SCContentFilter(desktopIndependentWindow: scWin)
                let config = SCStreamConfiguration()

                // 高清缩略图（限制最大宽 480px，保持宽高比）
                let aspect = scWin.frame.height / max(scWin.frame.width, 1)
                let targetWidth = min(max(Int(scWin.frame.width), 160), 480)
                let targetHeight = max(Int(Double(targetWidth) * Double(aspect)), 90)
                config.width = targetWidth
                config.height = targetHeight
                config.showsCursor = false

                do {
                    let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: targetWidth, height: targetHeight))
                    setCachedThumbnail(nsImage, for: wid)
                    captured += 1

                    if let onUpdate {
                        await MainActor.run {
                            onUpdate(wid, nsImage)
                        }
                    }
                } catch {
                    // 最小化或未渲染 Space 窗口截不到时保留旧缓存或交由 UI 显示 App 图标
                    continue
                }
            }
        } catch {
            // 忽略无权限或系统瞬态错误
        }
    }

    // MARK: - Window Activation

    func activateWindow(_ item: WindowItem) {
        bumpMRU(windowID: item.id)

        // 若目标窗口在 Dock 最小化，先取消最小化
        if item.isMinimized, let ax = item.axElement {
            AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        // 先尝试通过 AX 精确聚焦特定窗口（不带 activateAllWindows，避免把同 App 其他窗口一起抬起来）
        if let ax = item.axElement {
            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
        }

        item.runningApp?.activate(options: [])

        // 跨 Space / 全屏切换时系统会有动画延迟，稍后补一次 Raise 确保选中子窗口置顶
        if let ax = item.axElement {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
        } else if item.axElement == nil, let app = item.runningApp {
            // 若初始枚举时没有拿到 axElement（例如刚从其他桌面切过来），激活后再次查找匹配 wid 并 Raise
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                let appAX = AXUIElementCreateApplication(app.processIdentifier)
                var windowsRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                   let wins = windowsRef as? [AXUIElement] {
                    for w in wins {
                        var wid: CGWindowID = 0
                        if _AXUIElementGetWindow(w, &wid) == .success, wid == item.id {
                            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
                            break
                        }
                    }
                }
            }
        }
    }

    /// 关闭指定单个窗口（通过 AXCloseButton 触发原生关闭，保留未保存提示保护）
    @discardableResult
    func closeWindow(_ item: WindowItem) -> Bool {
        let targetAX: AXUIElement? = item.axElement ?? findAXWindow(pid: item.pid, windowID: item.id)
        guard let ax = targetAX else { return false }

        var closeBtnRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXCloseButtonAttribute as CFString, &closeBtnRef) == .success,
              let closeBtn = closeBtnRef else {
            return false
        }

        let err = AXUIElementPerformAction(closeBtn as! AXUIElement, kAXPressAction as CFString)
        if err == .success {
            removeCachedAXElement(for: item.id)
            return true
        }
        return false
    }

    /// 退出目标窗口所属的整个应用程序（等效 Cmd+Q 优雅退出）
    @discardableResult
    func quitApp(_ item: WindowItem) -> Bool {
        if let app = item.runningApp {
            return app.terminate()
        }
        if let app = NSRunningApplication(processIdentifier: item.pid) {
            return app.terminate()
        }
        return false
    }

    /// 切换指定窗口的最小化状态，返回操作后的最新 isMinimized 值；失败返回 nil
    func toggleMinimizeWindow(_ item: WindowItem) -> Bool? {
        guard !item.isFullScreen else { return nil }
        let targetAX: AXUIElement? = item.axElement ?? findAXWindow(pid: item.pid, windowID: item.id)
        guard let ax = targetAX else { return nil }

        var minRef: CFTypeRef?
        let currentMin: Bool
        if AXUIElementCopyAttributeValue(ax, kAXMinimizedAttribute as CFString, &minRef) == .success {
            currentMin = (minRef as? Bool) ?? item.isMinimized
        } else {
            currentMin = item.isMinimized
        }

        let nextMin = !currentMin
        let err = AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, nextMin as CFBoolean)
        return err == .success ? nextMin : nil
    }

    private func getCachedAXElement(for windowID: CGWindowID) -> AXUIElement? {
        axCacheLock.lock()
        defer { axCacheLock.unlock() }
        return axElementCache[windowID]
    }

    private func setCachedAXElement(_ element: AXUIElement, for windowID: CGWindowID) {
        axCacheLock.lock()
        axElementCache[windowID] = element
        axCacheLock.unlock()
    }

    private func removeCachedAXElement(for windowID: CGWindowID) {
        axCacheLock.lock()
        axElementCache.removeValue(forKey: windowID)
        axCacheLock.unlock()
    }

    private func findAXWindow(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        // 1) 当前桌面直接查询 kAXWindowsAttribute
        let appAX = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let wins = windowsRef as? [AXUIElement] {
            for w in wins {
                var wid: CGWindowID = 0
                if _AXUIElementGetWindow(w, &wid) == .success, wid == windowID {
                    setCachedAXElement(w, for: windowID)
                    return w
                }
            }
        }

        // 2) 检查此前切过该桌面时缓存下来的 AXUIElement
        if let cached = getCachedAXElement(for: windowID) {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(cached, &wid) == .success, wid == windowID {
                return cached
            }
            removeCachedAXElement(for: windowID)
        }

        // 3) 跨桌面（其他 Space）兜底：通过 _AXUIElementCreateWithRemoteToken 探测远端窗口句柄
        for idx: Int64 in 0..<1000 {
            var targetPID = pid
            var magic: Int32 = 0x636f636f // "coco"
            var elementID = idx

            var token = Data(count: 20)
            token.replaceSubrange(0..<4, with: withUnsafeBytes(of: &targetPID) { Data($0) })
            token.replaceSubrange(8..<12, with: withUnsafeBytes(of: &magic) { Data($0) })
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: &elementID) { Data($0) })

            guard let el = _AXUIElementCreateWithRemoteToken(token as CFData) else { continue }

            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(el, &wid) == .success, wid == windowID else { continue }

            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
               (roleRef as? String) == (kAXWindowRole as String) {
                setCachedAXElement(el, for: windowID)
                return el
            }
        }

        return nil
    }
}
