import AppKit
import SwiftUI
import Combine
import DiscBurnKit

/// 离屏渲染整个界面并写成 PNG，用来在无窗口环境下自检：
/// `DiscBurner --render-preview /tmp/preview.png`
func renderPreview(
    to url: URL,
    items: [URL] = [],
    size: NSSize = NSSize(width: 1020, height: 700),
    makeView: (AppModel) -> AnyView = { AnyView(ContentView().environmentObject($0)) }
) {
    let model = AppModel()
    if !items.isEmpty {
        model.add(urls: items)
    }
    // 留点时间让驱动器状态刷新、兼容性预检跑完
    RunLoop.main.run(until: Date().addingTimeInterval(items.isEmpty ? 1.5 : 4.0))

    let host = NSHostingView(rootView: makeView(model))
    // 离屏渲染没有窗口，SwiftUI 默认按「浅色」画，而 NSColor 这类动态颜色
    // 是按 App 当前外观解析的，两边对不上就会出现「黑字画在黑底上」。
    // 明确把渲染视图的外观对齐成 App 当前外观，出来才和真窗口一致。
    host.appearance = NSApp.effectiveAppearance
    host.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
    // 离屏渲染没有窗口时 `NSAppearance.current` 还是「浅色」，而分栏视图里的面板
    // 是各自独立的视图，会照 current 解析动态颜色 —— 不设的话左半边会画成浅色。
    let savedAppearance = NSAppearance.current
    NSAppearance.current = host.appearance
    // SwiftUI 在离屏渲染时通常要两轮布局才能把文字画全，这里多走一圈。
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    host.layoutSubtreeIfNeeded()

    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        FileHandle.standardError.write("渲染失败：无法创建位图\n".data(using: .utf8)!)
        exit(2)
    }
    host.cacheDisplay(in: host.bounds, to: rep)
    NSAppearance.current = savedAppearance
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("渲染失败：无法生成 PNG\n".data(using: .utf8)!)
        exit(2)
    }
    do {
        try data.write(to: url)
    } catch {
        FileHandle.standardError.write("写入失败：\(error)\n".data(using: .utf8)!)
        exit(2)
    }

    // 简单像素统计，确认界面不是一整块空白
    var distinct = Set<UInt32>()
    var total = 0.0
    var samples = 0
    if let cgImage = rep.cgImage, let provider = cgImage.dataProvider, let cfData = provider.data,
       let bytes = CFDataGetBytePtr(cfData) {
        let length = CFDataGetLength(cfData)
        let bytesPerRow = cgImage.bytesPerRow
        let bytesPerPixel = max(1, cgImage.bitsPerPixel / 8)
        var y = 0
        while y < cgImage.height {
            var x = 0
            while x < cgImage.width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                if offset + 2 < length {
                    let r = UInt32(bytes[offset])
                    let g = UInt32(bytes[offset + 1])
                    let b = UInt32(bytes[offset + 2])
                    total += Double(r + g + b) / 3.0
                    samples += 1
                    distinct.insert(r << 16 | g << 8 | b)
                }
                x += 4
            }
            y += 4
        }
    }
    let mean = samples > 0 ? total / Double(samples) : 0
    print("预览图：\(url.path)")
    print("  尺寸：\(rep.pixelsWide)x\(rep.pixelsHigh)")
    print("  采样点：\(samples)，不同颜色数：\(distinct.count)，平均亮度：\(String(format: "%.1f", mean))")
    print("  驱动器检测：\(model.drives.count) 台，介质：\(model.status.summary)")
    if let report = model.compatibility {
        print("  兼容性预检：\(report.headline)，改名方案 \(report.renamePlan.count) 条")
    }
}

/// 应用入口。使用 NSApplication + NSHostingView 而不是 SwiftUI 的 `App` 协议，
/// 这样既能在 SwiftPM 下直接编译出可执行文件，也不依赖 Xcode 工程。
final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate, NSToolbarItemValidation {
    private var window: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 先定外观，再建窗口，免得窗口先按系统外观画一遍再跳变。
        AppAppearance.stored().apply()
        buildMenu()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "光盘刻录"
        window.minSize = NSSize(width: 940, height: 560)
        window.tabbingMode = .disallowed
        window.contentView = NSHostingView(rootView: ContentView().environmentObject(model))
        // 工具栏 + 统一标题栏：动作都在标题栏里，窗口内不再重复一条「标题 + 刷新」的头栏。
        window.toolbar = makeToolbar()
        window.toolbarStyle = .unified
        // 窗口大小/位置按 macOS 惯例记住；第一次打开再居中。
        if !window.setFrameAutosaveName("DiscBurnerMain") {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        self.window = window

        // 标题栏副标题跟着光驱与介质状态走，随时能看出当前这张盘的情况。
        model.$status
            .combineLatest(model.$drives, model.$selectedDriveIndex, model.$statusError)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in self?.updateSubtitle() }
            .store(in: &cancellables)

        NSApp.activate(ignoringOtherApps: true)

        // 截屏用：把「这张盘可重写」当成真的，好看到「整盘合并重刻」那一行（不改任何盘）。
        if launchArguments.contains("--demo-rewritable") {
            model.demoRewritable = true
        }

        // 截屏用：`--demo-audio` 直接以「音乐 CD」模式启动（配合 `--demo-items` 看音轨列表）。
        // 只改这一次运行的模式，不写进 UserDefaults。
        if launchArguments.contains("--demo-audio") {
            model.persistModeChanges = false
            model.mode = .audioCD
        }

        // 截屏用：`--demo-video` 直接以「视频 DVD」模式启动（配合 `--demo-items` 看节目列表）。
        if launchArguments.contains("--demo-video") {
            model.persistModeChanges = false
            model.mode = .videoDVD
        }

        // 排错/截屏用：`--demo-items <路径…>` 只把内容加进列表，
        // `--demo-compatibility <路径…>` 再加完内容后打开预检窗口，
        // `--demo-burnprep` 直接摆出「开始刻录？」确认单（光驱里没有可写盘时也能看）。
        if !launchDemoItems.isEmpty {
            model.add(urls: launchDemoItems)
            if launchArguments.contains("--demo-compatibility") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.model.runCompatibilityScan(reveal: true)
                }
            } else if launchArguments.contains("--demo-burnprep") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.model.prepareBurn()
                }
            }
        }

        // 截屏用：把「刻录完成」弹窗直接摆出来，不必真的刻一张盘。
        if launchArguments.contains("--demo-notice") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self else { return }
                let free = self.model.status.writableBytes.map { "，还剩 \(ByteText.human($0))" } ?? ""
                let detail = "刻录完成 · 光盘仍可继续追加\(free)"
                let spent = SpeedAdvisor.durationText(86)
                self.model.phase = .finished
                self.model.taskFraction = 1
                self.model.taskMessage = detail + " · 用时 \(spent)"
                self.model.finishedMessage = detail + "。\n用时 \(spent)。"
            }
        }

        // 截屏用：摆出「正在刻录」的状态栏（同样不真刻盘）。
        if launchArguments.contains("--demo-progress") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self else { return }
                self.model.phase = .burning
                self.model.taskFraction = 0.72
                self.model.taskMessage = "正在刻录… "
                    + SpeedAdvisor.progressText(elapsed: 151, remaining: 65)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - 工具栏

    private enum ToolbarID {
        static let addFiles = NSToolbarItem.Identifier("discburn.addFiles")
        static let addFolder = NSToolbarItem.Identifier("discburn.addFolder")
        static let discContents = NSToolbarItem.Identifier("discburn.discContents")
        static let refresh = NSToolbarItem.Identifier("discburn.refresh")
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "discburn.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.addFiles, ToolbarID.addFolder, .flexibleSpace, ToolbarID.discContents, ToolbarID.refresh]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case ToolbarID.addFiles:
            item.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: "添加文件")
            item.label = "添加文件"
            item.paletteLabel = "添加文件"
            item.toolTip = "把文件加入要刻录的内容（⌘O）"
            item.target = self
            item.action = #selector(addFiles)
        case ToolbarID.addFolder:
            item.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "添加文件夹")
            item.label = "添加文件夹"
            item.paletteLabel = "添加文件夹"
            item.toolTip = "把整个文件夹加入要刻录的内容（⇧⌘O）"
            item.target = self
            item.action = #selector(addFolder)
        case ToolbarID.discContents:
            item.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: "光盘内容")
            item.label = "光盘内容"
            item.paletteLabel = "光盘内容"
            item.toolTip = "查看光盘里已有的内容（⌘I）"
            item.target = self
            item.action = #selector(showContents)
        case ToolbarID.refresh:
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")
            item.label = "刷新"
            item.paletteLabel = "刷新"
            item.toolTip = "重新读取光驱与介质状态（⌘R）"
            item.target = self
            item.action = #selector(refreshDrives)
        default:
            return nil
        }
        return item
    }

    /// 正在刻录时把工具栏动作一并禁掉，避免中途改列表。
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        !model.isBusy
    }

    /// 标题栏副标题：当前光驱 + 介质摘要。
    private func updateSubtitle() {
        if let drive = model.drives.first(where: { $0.index == model.selectedDriveIndex }) {
            window?.subtitle = "\(drive.displayName) · \(model.status.summary)"
        } else if let error = model.statusError {
            window?.subtitle = "光驱不可用：\(error)"
        } else {
            window?.subtitle = "未检测到光驱，请连接外置光驱"
        }
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        // 「光盘刻录」菜单
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "光盘刻录")
        appMenu.addItem(withTitle: "关于光盘刻录", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "隐藏光盘刻录", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "隐藏其他",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "显示全部",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出光盘刻录", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 「文件」菜单
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        add(to: fileMenu, "添加文件…", #selector(addFiles), "o")
        add(to: fileMenu, "添加文件夹…", #selector(addFolder), "o", modifiers: [.command, .shift])
        fileMenu.addItem(NSMenuItem.separator())
        add(to: fileMenu, "开始刻录", #selector(burn), "\r")
        add(to: fileMenu, "生成 ISO 映像…", #selector(makeImage), "s", modifiers: [.command, .shift])
        fileMenu.addItem(NSMenuItem.separator())
        add(to: fileMenu, "擦除光盘…", #selector(eraseDisc), "")
        add(to: fileMenu, "弹出光盘", #selector(ejectDisc), "e")
        fileMenu.addItem(NSMenuItem.separator())
        add(to: fileMenu, "查看光盘内容…", #selector(showContents), "i")
        add(to: fileMenu, "兼容性预检…", #selector(checkCompatibility), "k")
        fileMenu.addItem(NSMenuItem.separator())
        add(to: fileMenu, "关闭窗口", #selector(NSWindow.performClose(_:)), "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // 「编辑」菜单
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // 「显示」菜单
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        add(to: viewMenu, "刷新光驱状态", #selector(refreshDrives), "r")
        add(to: viewMenu, "显示/隐藏日志", #selector(toggleLog), "l")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // 「窗口」菜单
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(
            withTitle: "前置全部窗口",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        // 「帮助」菜单
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "帮助")
        add(to: helpMenu, "在访达中显示命令行工具", #selector(revealCLI), "")
        add(to: helpMenu, "打开使用说明", #selector(openHelp), "?")
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    @discardableResult
    private func add(
        to menu: NSMenu,
        _ title: String,
        _ action: Selector,
        _ key: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: - 菜单动作转发

    @objc private func addFiles() { CommandBus.post(.addFiles) }
    @objc private func addFolder() { CommandBus.post(.addFolder) }
    @objc private func makeImage() { CommandBus.post(.makeImage) }
    @objc private func burn() { CommandBus.post(.burn) }
    @objc private func eraseDisc() { CommandBus.post(.erase) }
    @objc private func ejectDisc() { CommandBus.post(.eject) }
    @objc private func showContents() { CommandBus.post(.showContents) }
    @objc private func checkCompatibility() { CommandBus.post(.checkCompatibility) }
    @objc private func openSettings() { CommandBus.post(.settings) }
    @objc private func refreshDrives() { CommandBus.post(.refresh) }
    @objc private func toggleLog() { CommandBus.post(.toggleLog) }
    @objc private func revealCLI() { CommandBus.post(.revealCLI) }
    @objc private func openHelp() { CommandBus.post(.openHelp) }

    @objc private func showAbout() {
        var credits = "版本 \(AppVersion.display)\n把任意文件刻录到 CD / DVD / 蓝光光盘\n基于 macOS 自带的 drutil 与 hdiutil"
        if let cli = AppPaths.bundledCLI {
            credits += "\n内置命令行工具：\(cli.path)"
        }
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "光盘刻录",
            .applicationVersion: AppVersion.short,
            .credits: NSAttributedString(string: credits),
        ])
    }
}

let launchArguments = Array(CommandLine.arguments.dropFirst())

/// `--demo-items <路径…>` / `--demo-compatibility <路径…>`：启动后自动加入这些内容。
let launchDemoItems: [URL] = {
    let flag = ["--demo-compatibility", "--demo-items"].first { launchArguments.contains($0) }
    guard let flag = flag, let index = launchArguments.firstIndex(of: flag) else { return [] }
    return launchArguments
        .dropFirst(index + 1)
        .filter { !$0.hasPrefix("-") }
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
}()

/// `--render-preview <png> [路径…]`：渲染主窗口；
/// `--render-compatibility <png> [路径…]`：渲染兼容性预检窗口；
/// `--render-settings <png>`：渲染设置面板。
if launchArguments.contains("--render-preview")
    || launchArguments.contains("--render-compatibility")
    || launchArguments.contains("--render-settings") {
    let compatibilityMode = launchArguments.contains("--render-compatibility")
    let settingsMode = launchArguments.contains("--render-settings")
    let flag = settingsMode ? "--render-settings"
        : (compatibilityMode ? "--render-compatibility" : "--render-preview")
    let index = launchArguments.firstIndex(of: flag)!
    let path = index + 1 < launchArguments.count && !launchArguments[index + 1].hasPrefix("-")
        ? launchArguments[index + 1]
        : "/tmp/discburner-preview.png"
    let previewItems = launchArguments
        .dropFirst(index + 2)
        .filter { !$0.hasPrefix("-") }
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    let previewApplication = NSApplication.shared
    previewApplication.setActivationPolicy(.accessory)
    // 预览也要跟用户选的外观一致，否则看到的深浅色跟 App 里不一样。
    AppAppearance.stored().apply()
    if settingsMode {
        renderPreview(
            to: URL(fileURLWithPath: path),
            items: [],
            size: NSSize(width: 520, height: 430),
            makeView: { AnyView(SettingsView().environmentObject($0)) }
        )
    } else if compatibilityMode {
        renderPreview(
            to: URL(fileURLWithPath: path),
            items: previewItems,
            size: NSSize(width: 760, height: 580),
            makeView: { AnyView(CompatibilityView().environmentObject($0)) }
        )
    } else {
        renderPreview(to: URL(fileURLWithPath: path), items: previewItems)
    }
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
