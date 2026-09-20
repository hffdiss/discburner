import Foundation

/// 生成光盘映像时的文件系统选项。
public struct ImageOptions {
    /// 光盘卷标。
    public var volumeName: String
    /// ISO 9660：兼容性最好，任何系统都能读。
    public var includeISO9660: Bool
    /// Joliet：让 Windows 正确显示中文/长文件名。
    public var includeJoliet: Bool
    /// UDF：DVD/蓝光时代的标准，长文件名与中文支持最好。
    public var includeUDF: Bool
    /// UDF 版本，DVD 数据盘用 1.02 兼容性最好。
    public var udfVersion: String

    public init(
        volumeName: String,
        includeISO9660: Bool = true,
        includeJoliet: Bool = true,
        includeUDF: Bool = true,
        udfVersion: String = "1.02"
    ) {
        self.volumeName = volumeName
        self.includeISO9660 = includeISO9660
        self.includeJoliet = includeJoliet
        self.includeUDF = includeUDF
        self.udfVersion = udfVersion
    }

    public var localizedSummary: String {
        var parts: [String] = []
        if includeISO9660 { parts.append("ISO 9660") }
        if includeJoliet { parts.append("Joliet") }
        if includeUDF { parts.append("UDF \(udfVersion)") }
        return parts.isEmpty ? "无" : parts.joined(separator: " + ")
    }

    /// 这套文件系统选项对应的兼容性规则。
    ///
    /// Joliet 的 64 字符上限只在 Joliet 视图里成立：同时还带 UDF 时，
    /// Windows / macOS 会走 UDF 看到完整名字，所以「自动重命名」不必真的截断到 64 个字符。
    public var nameRules: NameRules {
        NameRules(
            maxBytes: 255,
            jolietMaxCharacters: includeJoliet ? 64 : nil,
            checkISO9660: includeISO9660,
            enforceWindows: true,
            sanitizeCharacterLimit: (includeJoliet && !includeUDF) ? 64 : nil
        )
    }
}

/// 调 `hdiutil makehybrid` 生成光盘映像（.iso / .cdr）。
public enum ImageBuilder {
    /// 卷标清洗：去掉路径分隔符和控制字符，并限制长度。
    public static func normalizeVolumeName(_ raw: String, fallback: String = "DATA") -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}")
        name = name.components(separatedBy: forbidden).joined(separator: "_")
        name = name.replacingOccurrences(of: "\n", with: "_")
        if name.isEmpty { name = fallback }
        if name.count > 16 {
            name = String(name.prefix(16))
        }
        return name
    }

    /// 用 `-print-size` 估算映像大小（扇区数 × 2048），不写任何文件。
    public static func estimateSize(
        source: URL,
        options: ImageOptions,
        canceller: CommandCanceller? = nil
    ) throws -> Int64 {
        var arguments = ["makehybrid", "-o", "/dev/null", source.path]
        arguments += filesystemArguments(options)
        arguments += ["-print-size"]
        let result = try Shell.run("hdiutil", arguments)
        guard result.succeeded else {
            throw CommandFailure(command: result.command, exitCode: result.exitCode, output: result.output)
        }
        return parseSectorCount(result.output).map { $0 * 2048 } ?? 0
    }

    public static func parseSectorCount(_ output: String) -> Int64? {
        guard let regex = try? NSRegularExpression(pattern: #"^\s*([0-9]+)\s*\("#, options: [.anchorsMatchLines]) else {
            return nil
        }
        let range = NSRange(output.startIndex..., in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              let swiftRange = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return Int64(output[swiftRange])
    }

    /// 生成映像文件。返回写入的文件 URL。
    @discardableResult
    public static func buildImage(
        source: URL,
        outputURL: URL,
        options: ImageOptions,
        canceller: CommandCanceller? = nil,
        onLine: ((String) -> Void)? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputURL)
        if let parent = outputURL.deletingLastPathComponent() as URL? {
            try? fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        var arguments = ["makehybrid", "-o", outputURL.path, source.path]
        arguments += filesystemArguments(options)
        arguments += ["-default-volume-name", normalizeVolumeName(options.volumeName)]
        if options.includeISO9660 {
            arguments += ["-iso-volume-name", normalizeVolumeName(options.volumeName)]
        }
        if options.includeJoliet {
            arguments += ["-joliet-volume-name", normalizeVolumeName(options.volumeName)]
        }
        if options.includeUDF {
            arguments += ["-udf-volume-name", normalizeVolumeName(options.volumeName)]
            arguments += ["-udf-version", options.udfVersion]
        }
        arguments.append("-ov")

        let result = try Shell.stream("hdiutil", arguments, canceller: canceller) { line in
            onLine?(line)
        }
        guard result.succeeded else {
            throw CommandFailure(command: result.command, exitCode: result.exitCode, output: result.output)
        }
        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw ImageBuilderError.imageMissing(outputURL)
        }
        return outputURL
    }

    private static func filesystemArguments(_ options: ImageOptions) -> [String] {
        var arguments: [String] = []
        if options.includeISO9660 { arguments.append("-iso") }
        if options.includeJoliet { arguments.append("-joliet") }
        if options.includeUDF { arguments.append("-udf") }
        if arguments.isEmpty {
            // makehybrid 至少要指定一种文件系统
            arguments = ["-iso", "-joliet"]
        }
        return arguments
    }
}

public enum ImageBuilderError: LocalizedError {
    case imageMissing(URL)

    public var errorDescription: String? {
        switch self {
        case .imageMissing(let url):
            return "映像生成结束，但没有找到输出文件：\(url.path)"
        }
    }
}
