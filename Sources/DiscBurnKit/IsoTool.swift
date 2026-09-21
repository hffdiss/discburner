import Foundation

/// mkisofs 系命令行工具的公共执行逻辑。
///
/// cdrtools 的 `mkisofs` 和 xorriso 的 `-as mkisofs` 用法一致：
/// `-M` 指旧段所在的盘、`-C 上段起始,下段起始` 决定新段的绝对地址、
/// `-print-size` 只算大小不落盘。这里只放两边共用的部分。
enum IsoTool {
    /// 生成映像文件。返回写入的文件 URL。
    @discardableResult
    static func buildImage(
        tool: String,
        arguments: [String],
        outputURL: URL,
        canceller: CommandCanceller? = nil,
        onProgress: ((Double) -> Void)? = nil,
        onLog: ((String) -> Void)? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputURL)
        try? fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var lastPercent = -1
        let result = try Shell.stream(tool, arguments, canceller: canceller) { line in
            let text = BurnOutputParser.sanitize(line)
            guard !text.isEmpty else { return }
            if let percent = BurnOutputParser.percentage(in: text) {
                let value = Int(percent.rounded())
                if value != lastPercent {
                    lastPercent = value
                    onProgress?(max(0, min(1, percent / 100)))
                }
                return
            }
            onLog?(text)
        }
        guard result.succeeded else {
            throw CommandFailure(command: result.command, exitCode: result.exitCode, output: result.output)
        }
        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw ImageBuilderError.imageMissing(outputURL)
        }
        return outputURL
    }

    /// 用已经带好 `-print-size` 的参数估算这一段映像的大小（字节）。
    ///
    /// 注意 `-print-size` 的位置两套工具有别：cdrtools 的 mkisofs 放最前面就行，
    /// xorriso 必须放在 `-as mkisofs` 之后，否则它会把整个映像真的生成一遍（白跑还拿不到数字）。
    static func estimatedBytes(tool: String, arguments: [String]) throws -> Int64 {
        let result = try Shell.run(tool, arguments)
        guard result.succeeded else {
            throw CommandFailure(command: result.command, exitCode: result.exitCode, output: result.output)
        }
        guard let sectors = parsePrintedSize(result.output), sectors > 0 else { return 0 }
        return sectors * Int64(RawDisc.sectorSize)
    }

    /// 从 `-print-size` 的输出里取最后一行的数字（扇区数）。
    static func parsePrintedSize(_ output: String) -> Int64? {
        var value: Int64?
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard let number = Int64(text), number > 0 else { continue }
            value = number
        }
        return value
    }

    /// 安装的版本（输出的第一行里有版本号的那一行）。
    static func version(tool: String, arguments: [String], keyword: String) -> String? {
        guard let result = try? Shell.run(tool, arguments) else { return nil }
        for line in result.output.split(separator: "\n") {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            if text.lowercased().contains(keyword.lowercased()) { return text }
        }
        return nil
    }
}
