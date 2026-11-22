import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class IgnoreListWindowController {
    static let shared = IgnoreListWindowController()
    private var window: NSWindow?

    private init() {}

    func show() {
        if window == nil {
            let rootView = IgnoreListManagerView()
            let hosting = NSHostingView(rootView: rootView)
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "GestureTab · 忽略应用名单配置"
            win.minSize = NSSize(width: 440, height: 420)
            win.isReleasedWhenClosed = false
            win.contentView = hosting
            win.center()
            self.window = win
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct IgnoreListManagerView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var installedApps: [InstalledAppInfo] = []
    @State private var searchText: String = ""
    @State private var customInput: String = ""
    @State private var showIgnoredOnly: Bool = false

    private var filteredApps: [InstalledAppInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return installedApps.filter { app in
            if showIgnoredOnly && !settings.isAppIgnored(key: app.id) {
                return false
            }
            guard !query.isEmpty else { return true }
            return app.name.lowercased().contains(query)
                || (app.bundleID?.lowercased().contains(query) ?? false)
        }
    }

    /// 手动添加或未在扫描列表中的已忽略条目
    private var customIgnoredEntries: [(key: String, name: String)] {
        let scannedIDs = Set(installedApps.map(\.id))
        return settings.ignoredApps
            .filter { !scannedIDs.contains($0.key) }
            .map { (key: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("忽略应用名单")
                        .font(.system(size: 16, weight: .semibold))
                    Text("勾选后，该软件的窗口将不再出现在多任务切换视图中（无需软件当前正在运行）")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !settings.ignoredApps.isEmpty {
                    Button("清空全部 (\(settings.ignoredApps.count))") {
                        settings.ignoredApps.removeAll()
                    }
                }
            }

            // 搜索 + 过滤 + 选择磁盘 .app
            HStack(spacing: 8) {
                TextField("搜索已安装应用名称或 Bundle ID...", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Toggle("仅看已忽略", isOn: $showIgnoredOnly)
                    .toggleStyle(.checkbox)

                Button("从磁盘选择 .app...") {
                    pickAppFromDisk()
                }
            }

            // 手动输入名称或 Bundle ID 添加
            HStack(spacing: 8) {
                TextField("手动输入应用名称或 Bundle ID（如 com.apple.TextEdit）", text: $customInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addCustomEntry() }

                Button("添加忽略") {
                    addCustomEntry()
                }
                .disabled(customInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Divider()

            List {
                if !customIgnoredEntries.isEmpty {
                    Section("自定义忽略条目") {
                        ForEach(customIgnoredEntries, id: \.key) { entry in
                            HStack {
                                Image(systemName: "app.badge")
                                    .frame(width: 24, height: 24)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.name)
                                        .font(.system(size: 13, weight: .medium))
                                    if entry.key != entry.name {
                                        Text(entry.key)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { settings.isAppIgnored(key: entry.key) },
                                    set: { _ in settings.toggleIgnoredApp(key: entry.key, name: entry.name) }
                                ))
                                .labelsHidden()
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("本机已安装应用（\(filteredApps.count)）") {
                    ForEach(filteredApps) { app in
                        HStack(spacing: 10) {
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: 26, height: 26)
                            } else {
                                Image(systemName: "app")
                                    .frame(width: 26, height: 26)
                            }

                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name)
                                    .font(.system(size: 13, weight: .medium))
                                Text(app.bundleID ?? app.url.path)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { settings.isAppIgnored(key: app.id) },
                                set: { _ in settings.toggleIgnoredApp(key: app.id, name: app.name) }
                            ))
                            .labelsHidden()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(16)
        .onAppear {
            refreshApps()
        }
    }

    private func refreshApps() {
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = InstalledAppScanner.scanInstalledApps()
            DispatchQueue.main.async {
                self.installedApps = apps
            }
        }
    }

    private func addCustomEntry() {
        let trimmed = customInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.ignoredApps[trimmed] = trimmed
        customInput = ""
    }

    private func pickAppFromDisk() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "加入忽略名单"

        if panel.runModal() == .OK {
            for url in panel.urls {
                let bundle = Bundle(url: url)
                let name = FileManager.default.displayName(atPath: url.path)
                    .replacingOccurrences(of: ".app", with: "")
                let key = bundle?.bundleIdentifier ?? name
                settings.ignoredApps[key] = name
            }
        }
    }
}
