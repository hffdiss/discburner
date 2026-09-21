import Foundation

/// 生成数据光盘映像的三套引擎。
///
/// - `xorriso`：ISO 9660 + Joliet + Rock Ridge，**首选**。多区段追加要靠它把新段接在旧段后面
///   （旧文件按光盘绝对地址引用，不重写数据），而且它写出来的 Joliet 中文名是正确的。
/// - `mkisofs`：cdrtools 的老工具，也能嫁接，但 Joliet 名字转换只保留前 8 个字符，
///   长中文名在 Windows 上会残缺，只在没装 xorriso 时兜底。
/// - `makehybrid`：系统自带，ISO 9660 + Joliet + UDF。适合「一次刻完」的盘，
///   但它不会做多区段嫁接，所以这种盘之后不能安全追加。
public enum DataImageEngine: Equatable {
    case xorriso
    case mkisofs
    case makehybrid

    /// 当前机器默认用哪套。
    ///
    /// 「纯 UDF」这个预设是 makehybrid 独有的，选它就只能用 makehybrid。
    public static func preferred(for options: ImageOptions) -> DataImageEngine {
        if options.includeUDF, !options.includeISO9660, !options.includeJoliet {
            return .makehybrid
        }
        if Xorriso.isAvailable { return .xorriso }
        if Mkisofs.isAvailable { return .mkisofs }
        return .makehybrid
    }

    /// 界面上显示的文件系统。
    public var localizedSummary: String {
        switch self {
        case .xorriso, .mkisofs: return "ISO 9660 + Joliet + Rock Ridge"
        case .makehybrid: return "ISO 9660 + Joliet + UDF"
        }
    }

    /// 「实际写入」后面跟的工具名。
    public var toolName: String {
        switch self {
        case .xorriso: return "xorriso"
        case .mkisofs: return "mkisofs"
        case .makehybrid: return "系统自带工具"
        }
    }

    /// 能不能接在已有区段后面继续写。
    public var supportsMultisessionAppend: Bool {
        self != .makehybrid
    }

    /// 追加刻录需要的映像工具；装了就返回安装提示用不到。
    public static var appendToolHint: String? {
        if Xorriso.isAvailable { return nil }
        if Mkisofs.isAvailable { return Mkisofs.recommendedTool }
        return Xorriso.installHint
    }

    /// 这套引擎对应的命名规则：预检、自动重命名、真正刻进去的名字共用这一份。
    ///
    /// mkisofs 系工具用 `-joliet-long`，Joliet 视图最多 103 个字符（Windows 能正常显示），
    /// Rock Ridge 视图则没有实际长度限制。
    public func nameRules(for options: ImageOptions) -> NameRules {
        switch self {
        case .xorriso, .mkisofs:
            return NameRules(
                maxBytes: 255,
                jolietMaxCharacters: 103,
                checkISO9660: options.includeISO9660,
                enforceWindows: true,
                sanitizeCharacterLimit: 103
            )
        case .makehybrid:
            return options.nameRules
        }
    }

    /// 生成映像：三套引擎的差异只收在这一处，界面流程和自检都走同一条路。
    @discardableResult
    public func buildImage(
        source: URL,
        outputURL: URL,
        options: ImageOptions,
        graft: AppendTarget?,
        canceller: CommandCanceller? = nil,
        onProgress: ((Double) -> Void)? = nil,
        onLog: ((String) -> Void)? = nil
    ) throws -> URL {
        switch self {
        case .xorriso:
            return try Xorriso.buildImage(
                source: source,
                outputURL: outputURL,
                volumeName: options.volumeName,
                graft: graft,
                canceller: canceller,
                onProgress: onProgress,
                onLog: onLog
            )
        case .mkisofs:
            return try Mkisofs.buildImage(
                source: source,
                outputURL: outputURL,
                volumeName: options.volumeName,
                graft: graft,
                canceller: canceller,
                onProgress: onProgress,
                onLog: onLog
            )
        case .makehybrid:
            return try ImageBuilder.buildImage(
                source: source,
                outputURL: outputURL,
                options: options,
                canceller: canceller
            ) { line in
                onLog?(line)
            }
        }
    }

    /// 估算这一段映像的大小；估不出来时抛错（调用方自己决定要不要退回按内容大小估）。
    public func estimatedBytes(
        source: URL,
        options: ImageOptions,
        graft: AppendTarget?,
        canceller: CommandCanceller? = nil
    ) throws -> Int64 {
        switch self {
        case .xorriso:
            return try Xorriso.estimatedBytes(
                source: source,
                volumeName: options.volumeName,
                graft: graft,
                canceller: canceller
            )
        case .mkisofs:
            return try Mkisofs.estimatedBytes(
                source: source,
                volumeName: options.volumeName,
                graft: graft,
                canceller: canceller
            )
        case .makehybrid:
            return try ImageBuilder.estimateSize(source: source, options: options, canceller: canceller)
        }
    }
}
