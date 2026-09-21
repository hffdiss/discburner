import SwiftUI
import AppKit

/// 外观：跟随系统 / 浅色 / 深色。
///
/// 存进 `UserDefaults`，启动时由 `AppDelegate` 应用一次，之后在「设置」面板里随时改，
/// 改完立刻作用到所有窗口（包括已经打开的那些）。
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var detail: String {
        switch self {
        case .system: return "跟着「系统设置 → 外观」走，白天黑夜自动切换"
        case .light: return "这个 App 一直用浅色，不受系统设置影响"
        case .dark: return "这个 App 一直用深色，不受系统设置影响"
        }
    }

    /// `nil` 表示交回给系统决定。
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    func apply() {
        // 「跟随系统」时千万别去写 NSApp.appearance —— 显式写过一次（哪怕写的是 nil），
        // AppKit 就会把这个 App 的外观钉死在当时的系统外观上：之后系统在深色/浅色之间
        // 自动切换它不再跟，而新开的 sheet 仍按当前系统外观画，一个窗口深、一个窗口浅。
        // 所以只在明确选了浅色/深色时才写，选回「系统」时再把它清干净。
        guard let appearance = nsAppearance else {
            if NSApp.appearance != nil {
                NSApp.appearance = nil
                for window in NSApp.windows { window.appearance = nil }
            }
            return
        }
        NSApp.appearance = appearance
    }

    static func stored() -> AppAppearance {
        let raw = UserDefaults.standard.string(forKey: AppModel.appearanceKey) ?? ""
        return AppAppearance(rawValue: raw) ?? .system
    }
}

/// 「设置」面板。默认不占地方：底栏的小齿轮或者菜单「光盘刻录 → 设置…」（⌘,）打开。
struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    appearanceSection
                    Divider()
                    versionSection
                }
                .padding(18)
            }
        }
        .frame(width: 520, height: 430)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape")
                .foregroundColor(.secondary)
            Text("设置")
                .font(.headline)
            Spacer()
            Button("完成") { model.showSettings = false }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("外观")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            HStack(alignment: .top, spacing: 14) {
                ForEach(AppAppearance.allCases) { option in
                    AppearanceOptionCard(
                        option: option,
                        selected: model.appearance == option
                    ) {
                        model.appearance = option
                    }
                }
            }
            Text(model.appearance.detail)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 版本号

    private var versionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("版本")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            HStack {
                Text("光盘刻录")
                Spacer()
                Text(AppVersion.display)
                    .foregroundColor(.secondary)
            }
            Text("版本号来自仓库根的 VERSION 文件，构建时写进 App；发版流程会自动打上对应的 tag 和版本目录。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 外观选项卡片：上面一张缩略图，下面一行名字。照着 macOS「外观」设置里那三张图画的。
private struct AppearanceOptionCard: View {
    let option: AppAppearance
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    thumbnail
                        .frame(width: 140, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            selected ? Color.accentColor : Color.primary.opacity(0.14),
                            lineWidth: selected ? 3 : 1
                        )
                }
                Text(option.title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? Color.primary : Color(NSColor.secondaryLabelColor))
            }
        }
        .buttonStyle(PlainButtonStyle())
        .help(option.detail)
        .accessibilityLabel(option.title)
    }

    /// 「系统」那张是左浅右深拼起来的，和系统设置里一样。
    @ViewBuilder
    private var thumbnail: some View {
        if option == .system {
            HStack(spacing: 0) {
                AppearancePreview(dark: false)
                AppearancePreview(dark: true)
            }
        } else {
            AppearancePreview(dark: option == .dark)
        }
    }
}

/// 缩略图里的那个「小窗口」。
private struct AppearancePreview: View {
    let dark: Bool

    var body: some View {
        let windowBG = dark ? Color(white: 0.20) : Color(white: 0.95)
        let barBG = dark ? Color(white: 0.16) : Color(white: 0.90)
        let cardBG = dark ? Color(white: 0.32) : Color.white
        let line = dark ? Color(white: 0.52) : Color(white: 0.80)

        return VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                barBG
                HStack(spacing: 3) {
                    ForEach(0..<3) { _ in
                        Circle().fill(line).frame(width: 3.5, height: 3.5)
                    }
                }
                .padding(.leading, 6)
            }
            .frame(height: 12)

            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(cardBG)
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().fill(line).frame(width: 34, height: 4)
                        Capsule().fill(line).frame(width: 52, height: 4)
                        Capsule().fill(line).frame(width: 44, height: 4)
                    }
                    .padding(7)
                }
                Capsule().fill(line).frame(width: 26, height: 4)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(windowBG)
    }
}
