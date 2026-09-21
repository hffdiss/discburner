import Foundation

public enum EraseMode: String {
    case quick
    case full

    public var localizedName: String {
        switch self {
        case .quick: return "快速擦除（约 1-2 分钟）"
        case .full: return "完全擦除（可能需要 30 分钟以上）"
        }
    }
}

public struct BurnOptions {
    /// 指定驱动器序号（`drutil list` 里的编号），nil 表示使用默认驱动器。
    public var driveIndex: Int?
    /// 刻录倍速，nil 表示由系统选择最高倍速。
    public var speed: Int?
    /// 刻录完成后校验数据。
    public var verify: Bool
    /// 完成后弹出光盘。
    public var ejectWhenDone: Bool
    /// 测试模式：不打开激光，只走一遍刻录流程（不会写入介质）。
    public var testBurn: Bool
    /// 是否关闭光盘（关闭后无法再追加数据）。
    public var closeDisc: Bool
    /// 刻录前先擦除介质（仅对可重写介质有效）。
    public var eraseFirst: Bool

    public init(
        driveIndex: Int? = nil,
        speed: Int? = nil,
        verify: Bool = true,
        ejectWhenDone: Bool = true,
        testBurn: Bool = false,
        closeDisc: Bool = false,
        eraseFirst: Bool = false
    ) {
        self.driveIndex = driveIndex
        self.speed = speed
        self.verify = verify
        self.ejectWhenDone = ejectWhenDone
        self.testBurn = testBurn
        self.closeDisc = closeDisc
        self.eraseFirst = eraseFirst
    }
}

public struct BurnProgress {
    public var phase: JobPhase
    public var fraction: Double?
    public var message: String
    public var rawLine: String?
}

/// 解析 drutil / hdiutil 的实时输出，转成阶段 + 百分比。
///
/// 不同 macOS 版本、不同驱动器打印的进度格式并不一致，
/// 因此这里做「尽力解析」：识别到百分比就用，识别不到就保持不确定进度。
public struct BurnOutputParser {
    public private(set) var phase: JobPhase
    public private(set) var fraction: Double?

    public init(phase: JobPhase = .preparing) {
        self.phase = phase
    }

    public mutating func consume(_ line: String) -> BurnProgress {
        let text = BurnOutputParser.sanitize(line)
        let lowered = text.lowercased()

        if lowered.contains("verif") {
            phase = .verifying
        } else if lowered.contains("eras") {
            phase = .erasing
        } else if lowered.contains("burn") || lowered.contains("writ") || lowered.contains("lead-in") || lowered.contains("lead-out") {
            if phase != .verifying { phase = .burning }
        } else if lowered.contains("prepar") || lowered.contains("cache") || lowered.contains("open session") {
            if phase == .preparing { phase = .preparing }
        }

        if let percent = BurnOutputParser.percentage(in: text) {
            fraction = max(0, min(1, percent / 100))
        }
        return BurnProgress(phase: phase, fraction: fraction, message: text, rawLine: text.isEmpty ? nil : text)
    }

    /// 清理 drutil 的进度动画。
    ///
    /// drutil 没有百分比，刻录期间只会吐一个「转圈」动画：一串内部指针字节 + 退格 + 回车。
    /// 原样显示会变成乱码（`pÂ¨·÷`），所以含退格/回车的行直接当成动画丢掉内容，
    /// 其余行也只保留可打印字符。
    public static func sanitize(_ line: String) -> String {
        if line.unicodeScalars.contains(where: { $0 == "\u{8}" || $0 == "\u{d}" }) {
            return ""
        }
        let printable = line.unicodeScalars.filter { scalar in
            scalar == "\u{9}" || scalar.value >= 0x20
        }
        return String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func percentage(in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"([0-9]{1,3}(?:\.[0-9]+)?)\s*%"#) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Double(text[swiftRange])
    }
}

/// 刻录期间按时间推进进度条的辅助计时器。
///
/// `drutil burn` 只会打印一个转圈动画，拿不到百分比，所以按
/// 「数据量 ÷ 1x 速率 ÷ 倍速」估一个时长，刻录期间按时间平滑推进。
/// 只是估算：真实耗时还受盘片、驱动器和校验影响，因此最多推到 90%。
final class BurnProgressTicker {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private let startedAt = Date()

    func start(estimatedSeconds: TimeInterval, onTick: @escaping (TimeInterval) -> Void) {
        lock.lock()
        guard timer == nil else {
            lock.unlock()
            return
        }
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        source.schedule(deadline: .now() + 1, repeating: 1)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let running = self.timer != nil
            self.lock.unlock()
            guard running else { return }
            onTick(Date().timeIntervalSince(self.startedAt))
        }
        timer = source
        lock.unlock()
        source.resume()
    }

    func stop() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }
}

/// 真正的写盘动作：`drutil burn`、`drutil erase`、`drutil eject`。
public enum Burner {

    /// 拼出写盘命令的参数。
    ///
    /// 写盘用 `drutil` 而不是 `hdiutil`，原因是「能不能追加」这一点上两者不等价：
    /// `hdiutil burn -noforceclose` 名义上是「刻完不关闭光盘」，但实测在
    /// PIONEER DVR-XU01C + DVD+R 上驱动器照样写了 final lead-out 把盘收尾
    /// （刻完 `discStatus` 从 0 变 2、`Space Free` 变 0），这张盘以后就再也追加不了。
    /// `drutil` 的 `-appendable` 才是真正对应的开关，实测刻完仍然是
    /// `Writability: appendable`、`discStatus: 1`，可以继续写下一段。
    public static func burnArguments(image: URL, options: BurnOptions) -> [String] {
        var arguments: [String] = []
        if let index = options.driveIndex {
            arguments += ["-drive", "\(index)"]
        }
        arguments.append("burn")
        if let speed = options.speed, speed > 0 {
            arguments += ["-speed", "\(speed)"]
        }
        // -appendable：刻完保留可追加（多区段）；-noappendable：关闭光盘，之后永远不能再写。
        arguments.append(options.closeDisc ? "-noappendable" : "-appendable")
        arguments.append(options.verify ? "-verify" : "-noverify")
        if options.testBurn {
            arguments.append("-test")
        }
        if options.ejectWhenDone {
            arguments.append("-eject")
        }
        arguments.append(image.path)
        return arguments
    }

    /// 把映像写入光盘。
    @discardableResult
    public static func burn(
        image: URL,
        options: BurnOptions,
        canceller: CommandCanceller? = nil,
        onProgress: @escaping (BurnProgress) -> Void
    ) throws -> CommandResult {
        var parser = BurnOutputParser(phase: .preparing)
        let arguments = burnArguments(image: image, options: options)
        var lastError: Error?
        var result: CommandResult?
        do {
            result = try Shell.stream("drutil", arguments, canceller: canceller) { line in
                let progress = parser.consume(line)
                onProgress(progress)
            }
        } catch {
            lastError = error
        }
        if let error = lastError { throw error }
        guard let commandResult = result else {
            throw BurnError.unexpected("刻录命令没有返回结果")
        }
        guard commandResult.succeeded else {
            throw CommandFailure(
                command: commandResult.command,
                exitCode: commandResult.exitCode,
                output: commandResult.output
            )
        }
        return commandResult
    }

    /// 擦除可重写介质。
    @discardableResult
    public static func erase(
        mode: EraseMode,
        driveIndex: Int? = nil,
        canceller: CommandCanceller? = nil,
        onProgress: @escaping (BurnProgress) -> Void
    ) throws -> CommandResult {
        var arguments: [String] = []
        if let index = driveIndex {
            arguments += ["-drive", "\(index)"]
        }
        arguments += ["erase", mode.rawValue]
        var parser = BurnOutputParser(phase: .erasing)
        let result = try Shell.stream("drutil", arguments, canceller: canceller) { line in
            onProgress(parser.consume(line))
        }
        guard result.succeeded else {
            throw CommandFailure(command: result.command, exitCode: result.exitCode, output: result.output)
        }
        return result
    }
}

public enum BurnError: LocalizedError {
    case noDrive
    case noMedia
    case mediaNotWritable(String)
    case mediaClosed(String)
    case capacityExceeded(required: Int64, available: Int64)
    case notRewritable(String)
    case noItems
    /// 盘上已经有内容、需要多区段嫁接，但机器上没有能做嫁接的映像工具。
    case appendNeedsIsoTool
    /// 盘是用旧版本刻的（每段各自独立寻址），接上去只会让旧内容消失。
    case appendIncompatibleDisc(sessions: Int)
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .noDrive:
            return "没有检测到可用的光盘驱动器，请确认外置光驱已连接。"
        case .noMedia:
            return "光驱里没有光盘，请放入空白光盘后重试。"
        case .mediaNotWritable(let media):
            return "当前介质（\(media)）不可写入，请放入 CD-R/RW、DVD±R/RW 或 BD-R/RE。"
        case .mediaClosed(let media):
            return "当前介质（\(media)）已经关闭，无法再写入。请更换光盘，或使用可重写介质擦除后重试。"
        case .capacityExceeded(let required, let available):
            return "待刻录内容 \(ByteText.human(required)) 超过光盘可用空间 \(ByteText.human(available))"
        case .notRewritable(let media):
            return "当前介质（\(media)）不支持擦除，只有 CD-RW / DVD-RW / DVD+RW / DVD-RAM / BD-RE 可以擦除。"
        case .noItems:
            return "还没有选择要刻录的文件。"
        case .appendNeedsIsoTool:
            return "追加刻录要把新内容嫁接在旧区段后面（系统自带的 hdiutil 做不到这件事）。\n"
                + "先在终端执行 `brew install xorriso`（已经装了 cdrtools 的话 `\(Mkisofs.recommendedTool)` 更好）再试；"
                + "或者换一张空盘，把内容一次刻完。"
        case .appendIncompatibleDisc(let sessions):
            return "这张盘上已有的 \(sessions) 段是用旧版本 DiscBurner 刻的：每段各自独立寻址，"
                + "Windows / Linux 本来就打不开旧内容。\n继续追加只会让旧段在新段里消失，所以先停下来了。"
                + "建议换一张空盘重刻；旧盘上的内容可以在 Mac 上读出来先备份。"
        case .unexpected(let message):
            return message
        }
    }
}
