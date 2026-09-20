import AppKit
import SwiftUI
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
    host.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
    // SwiftUI 在离屏渲染时通常要两轮布局才能把文字画全，这里多走一圈。
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    host.layoutSubtreeIfNeeded()

    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        FileHandle.standardError.write("渲染失败：无法创建位图\n".data(using: .utf8)!)
        exit(2)
    }
    host.cacheDisplay(in: host.bounds, to: rep)
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "光盘刻录"
        window.minSize = NSSize(width: 900, height: 620)
        window.center()
        window.contentView = NSHostingView(rootView: ContentView().environmentObject(model))
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)

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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        // 「光盘刻录」菜单
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "光盘刻录")
        appMenu.addItem(withTitle: "关于光盘刻录", action: #selector(showAbout), keyEquivalent: "")
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
    @objc private func refreshDrives() { CommandBus.post(.refresh) }
    @objc private func toggleLog() { CommandBus.post(.toggleLog) }
    @objc private func revealCLI() { CommandBus.post(.revealCLI) }
    @objc private func openHelp() { CommandBus.post(.openHelp) }

    @objc private func showAbout() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        var credits = "把任意文件刻录到 CD / DVD / 蓝光光盘\n基于 macOS 自带的 drutil 与 hdiutil"
        if let cli = AppPaths.bundledCLI {
            credits += "\n内置命令行工具：\(cli.path)"
        }
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "光盘刻录",
            .applicationVersion: version,
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
/// `--render-compatibility <png> [路径…]`：渲染兼容性预检窗口。
if launchArguments.contains("--render-preview") || launchArguments.contains("--render-compatibility") {
    let compatibilityMode = launchArguments.contains("--render-compatibility")
    let flag = compatibilityMode ? "--render-compatibility" : "--render-preview"
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
    if compatibilityMode {
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
