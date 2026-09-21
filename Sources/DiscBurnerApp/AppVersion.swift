import Foundation

/// App 的版本号。
///
/// 唯一出处是仓库根的 `VERSION` 文件：`build.sh` 构建时把它写进 `Info.plist`，
/// 运行时从这里读出来显示（「关于」面板和「设置」面板都用它）。
enum AppVersion {
    /// 例如 `1.1.0`。直接跑未打包的可执行文件时读不到，显示「开发版」。
    static var short: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "开发版"
    }

    /// 构建号。同一个版本号重新打包时会加一，没设置过就不显示。
    static var build: String? {
        guard let value = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
              !value.isEmpty, value != "1" else { return nil }
        return value
    }

    /// 给人看的一行，例如 `1.1.0`。
    static var display: String {
        if let build = build { return "\(short)（构建 \(build)）" }
        return short
    }
}
