import Foundation

/// 用 `xorriso -as mkisofs`（libisofs）生成光盘映像。
///
/// 为什么优先用它：
/// 1. 多区段嫁接只有 mkisofs 系工具能写（`-M` 旧段 + `-C 上段起始,下段起始`），
///    旧文件按**光盘绝对地址**被引用，不重写数据、不占新空间；
/// 2. cdrtools 的 `mkisofs` 把文件名转成 Joliet（UCS-2）时只保留前 8 个字符，
///    中文名一长就被补成 NUL，Windows 上看不到正确的名字；xorriso 没有这个毛病。
public enum Xorriso {
    /// xorriso 可执行文件路径（找不到就是没装）。
    public static var executablePath: String? {
        Shell.which("xorriso")
    }

    public static var isAvailable: Bool { executablePath != nil }

    /// 给用户的安装提示。
    public static let installHint = "brew install xorriso"

    /// 数据盘的通用参数，含义和 mkisofs 一致：
    /// - `-input-charset UTF-8`：显式声明文件名是 UTF-8（否则中文名会按 ISO-8859-1 处理成乱码）
    /// - `-J` Joliet（Windows 看中文名/长名）、`-joliet-long` Joliet 名字放宽到 103 个字符
    /// - `-R` Rock Ridge（Linux / macOS 保留名字、权限、符号链接）
    /// - `-l` ISO 9660 名字放宽到 31 个字符、`-iso-level 3` 允许单文件超过 4GB
    public static let baseArguments = ["-input-charset", "UTF-8", "-J", "-joliet-long", "-R", "-l", "-iso-level", "3"]

    /// 组装参数。`graft` 非空时生成的是「接在已有区段后面」的新段。
    public static func arguments(
        source: URL,
        outputURL: URL,
        volumeName: String,
        graft: AppendTarget?
    ) -> [String] {
        // `-as mkisofs` 让 xorriso 按 mkisofs 的命令行语义工作。
        var arguments = ["-as", "mkisofs"]
        if let graft = graft {
            // 光驱是块设备，xorriso 只把非 MMC 的路径当「文件」看，所以设备要写成 stdio: 前缀；
            // 我们自己造出来的稀疏映像本来就是文件，直接用路径。
            let mergePath = graft.isDevice ? "stdio:" + graft.devicePath : graft.devicePath
            arguments += ["-M", mergePath, "-C", "\(graft.lastSessionStart),\(graft.nextWritableAddress)"]
        }
        arguments += baseArguments
        arguments += ["-V", ImageBuilder.normalizeVolumeName(volumeName)]
        arguments += ["-o", outputURL.path]
        arguments.append(source.path)
        return arguments
    }

    /// 生成映像文件。
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
            tool: "xorriso",
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
        // 必须跟在 "-as mkisofs" 后面，否则 xorriso 不认这个参数。
        arguments.insert("-print-size", at: 2)
        return try IsoTool.estimatedBytes(tool: "xorriso", arguments: arguments)
    }

    /// 从 `-print-size` 的输出里取扇区数。
    public static func parsePrintedSize(_ output: String) -> Int64? {
        IsoTool.parsePrintedSize(output)
    }

    /// 安装的 xorriso 版本（第一行版本号）。
    public static func version() -> String? {
        guard let result = try? Shell.run("xorriso", ["-version"]) else { return nil }
        for line in result.output.split(separator: "\n") {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            if text.lowercased().hasPrefix("gnu xorriso") { return text }
        }
        return nil
    }
}
