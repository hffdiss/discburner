import Foundation
import AppKit

/// 菜单栏动作。菜单在 AppKit 侧，具体处理在 SwiftUI 视图里，
/// 通过通知总线转发，这样确认弹窗等界面状态仍然只有一份。
enum AppCommand: String {
    case addFiles
    case addFolder
    case makeImage
    case burn
    case erase
    case eject
    case showContents
    case checkCompatibility
    case settings
    case refresh
    case toggleLog
    case revealCLI
    case openHelp
}

extension Notification.Name {
    static let discBurnerCommand = Notification.Name("com.felix.discburner.command")
}

enum CommandBus {
    static func post(_ command: AppCommand) {
        NotificationCenter.default.post(name: .discBurnerCommand, object: command.rawValue)
    }
}

enum AppPaths {
    /// App 内置的命令行工具（和主程序一起放在 Contents/MacOS 下）。
    static var bundledCLI: URL? {
        if let executable = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("discburn"),
           FileManager.default.isExecutableFile(atPath: executable.path) {
            return executable
        }
        // 兼容旧布局
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("bin/discburn")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// 随 App 分发的说明文件。
    static var bundledHelp: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("命令行工具说明.txt")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
