import Foundation

/// 用 cdrtools 的 `mkisofs` 生成光盘映像（备用引擎）。
///
/// 它同样能做多区段嫁接（`-M` + `-C`），但有个已知缺陷：把文件名转成 Joliet（UCS-2）时
/// **只保留前 8 个字符**，再长的部分被写成 NUL。中文名一长，Windows 上就是残缺或乱码
/// （macOS / Linux 走 Rock Ridge 反而看不出来）。所以只有「装了 mkisofs、没装 xorriso」
/// 时才会选它，并且会提醒用户装 xorriso。
public enum Mkisofs {
    /// mkisofs 可执行文件路径（找不到就是没装）。
    public static var executablePath: String? {
        Shell.which("mkisofs")
    }

    public static var isAvailable: Bool { executablePath != nil }

    /// 给用户的安装提示。
    public static let installHint = "brew install cdrtools"

    /// 想写正确的 Joliet 中文名，应该装的工具。
    public static let recommendedTool = "brew install xorriso"

    /// 数据盘的通用参数：
    /// - `-input-charset UTF-8`：mkisofs 默认按 ISO-8859-1 解释文件名，
    ///   中文名会被「一个 UTF-8 字节 = 一个 UCS-2 码元」地写进 Joliet，
    ///   Windows 上就是一堆乱码（macOS 因为优先读 Rock Ridge 反而看不出来）。
    /// - `-J` Joliet（Windows 看中文名/长名）、`-joliet-long` Joliet 名字放宽到 103 个字符
    /// - `-R` Rock Ridge（Linux / macOS 保留名字、权限、符号链接）
    /// - `-l` ISO 9660 名字放宽到 31 个字符、`-iso-level 3` 允许单文件超过 4GB
    public static let baseArguments = ["-input-charset", "UTF-8", "-J", "-joliet-long", "-R", "-l", "-iso-level", "3"]

    /// cdrtools 的 Joliet 名字转换只保留前 8 个字符（自检里有对照实验）。
    public static let jolietCharacterLimit = 8

    /// 挑出会被 mkisofs 写坏的 Joliet 名字：含非 ASCII 而且超过 8 个字符。
    public static func namesBreakingJoliet(_ names: [String]) -> [String] {
        names.filter { name in
            name.count > jolietCharacterLimit && name.contains { !$0.isASCII }
        }
    }

    /// 组装 mkisofs 参数。`graft` 非空时生成的是「接在已有区段后面」的新段。
    public static func arguments(
        source: URL,
        outputURL: URL,
        volumeName: String,
        graft: AppendTarget?
    ) -> [String] {
        var arguments: [String] = []
        if let graft = graft {
            // -M：旧段所在的盘（mkisofs 自己从设备/映像里读旧段的目录树）
            // -C：上段起始扇区, 下段起始扇区（决定绝对地址）
            arguments += ["-M", graft.devicePath, "-C", "\(graft.lastSessionStart),\(graft.nextWritableAddress)"]
        }
        arguments += baseArguments
        arguments += ["-V", ImageBuilder.normalizeVolumeName(volumeName)]
        arguments += ["-o", outputURL.path]
        arguments.append(source.path)
        return arguments
    }

    /// 生成映像文件。返回写入的文件 URL。
    @discardableResult
    public static func buildImage(
        source: URL,
        outputURL: URL,
        volumeName: String,
        graft: AppendTarget?,
        canceller: CommandCanceller? = nil,
        onProgress: ((Double) -> Void)? = nil,
        onLog: ((String) -> Void)? = nil
    ) throws -> URL {
        try IsoTool.buildImage(
            tool: "mkisofs",
            arguments: arguments(source: source, outputURL: outputURL, volumeName: volumeName, graft: graft),
            outputURL: outputURL,
            canceller: canceller,
            onProgress: onProgress,
            onLog: onLog
        )
    }

    /// 估算这一段映像的大小（字节）。
    public static func estimatedBytes(
        source: URL,
        volumeName: String,
        graft: AppendTarget?,
        canceller: CommandCanceller? = nil
    ) throws -> Int64 {
        var arguments = arguments(
            source: source,
            outputURL: URL(fileURLWithPath: "/dev/null"),
            volumeName: volumeName,
            graft: graft
        )
        arguments.insert("-print-size", at: 0)
        return try IsoTool.estimatedBytes(tool: "mkisofs", arguments: arguments)
    }

    /// 从 `-print-size` 的输出里取最后一行的数字（扇区数）。
    public static func parsePrintedSize(_ output: String) -> Int64? {
        IsoTool.parsePrintedSize(output)
    }

    /// 安装的 mkisofs 版本（第一行）。
    public static func version() -> String? {
        guard let result = try? Shell.run("mkisofs", ["-version"]) else { return nil }
        for line in result.output.split(separator: "\n") {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            if text.lowercased().hasPrefix("mkisofs") { return text }
        }
        return nil
    }
}
