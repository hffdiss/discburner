import Foundation

/// 一次命令执行的结果。
public struct CommandResult {
    public let command: String
    public let exitCode: Int32
    public let output: String

    public var succeeded: Bool { exitCode == 0 }

    public init(command: String, exitCode: Int32, output: String) {
        self.command = command
        self.exitCode = exitCode
        self.output = output
    }
}

/// 命令执行失败（退出码非 0）。
public struct CommandFailure: LocalizedError {
    public let command: String
    public let exitCode: Int32
    public let output: String

    public init(command: String, exitCode: Int32, output: String) {
        self.command = command
        self.exitCode = exitCode
        self.output = output
    }

    public var errorDescription: String? {
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            return "\(command) 失败（退出码 \(exitCode)）"
        }
        return "\(command) 失败（退出码 \(exitCode)）：\n\(detail)"
    }
}

/// 允许外部取消正在运行的系统命令（例如用户点了「取消刻录」）。
public final class CommandCanceller {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if let running = running, running.isRunning {
            running.terminate()
        }
    }

    /// 返回 false 表示任务在启动前就已被取消。
    fileprivate func attach(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        self.process = process
        return true
    }

    fileprivate func detach() {
        lock.lock()
        process = nil
        lock.unlock()
    }
}

public enum ShellError: LocalizedError {
    case cancelled
    case toolNotFound(String)
    case launchFailed(String, Error)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "操作已取消"
        case .toolNotFound(let tool):
            return "找不到系统命令 \(tool)"
        case .launchFailed(let tool, let error):
            return "无法运行 \(tool)：\(error.localizedDescription)"
        }
    }
}

/// 对系统命令（drutil / hdiutil / diskutil）的薄封装。
///
/// 所有刻录动作最终都交给 macOS 自带的 DiscRecording 命令行工具完成，
/// 这样既不需要额外驱动，也不需要 root 权限。
public enum Shell {
    /// 优先使用绝对路径，避免 GUI 从 Finder 启动时 PATH 过窄的问题。
    private static let knownPaths: [String: String] = [
        "drutil": "/usr/bin/drutil",
        "hdiutil": "/usr/bin/hdiutil",
        "diskutil": "/usr/sbin/diskutil",
        "diskutil-usr": "/usr/bin/diskutil",
        "screencapture": "/usr/sbin/screencapture",
    ]

    public static func resolve(_ tool: String) -> String {
        if tool.hasPrefix("/") { return tool }
        if let known = knownPaths[tool], FileManager.default.isExecutableFile(atPath: known) {
            return known
        }
        if let found = which(tool) {
            return found
        }
        return tool
    }

    /// 在 PATH 里查找可执行文件（例如 Homebrew 安装的 xorriso）。
    public static func which(_ tool: String) -> String? {
        if tool.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil
        }
        let searchPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init) + ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for directory in searchPaths {
            let candidate = directory.hasSuffix("/") ? directory + tool : directory + "/" + tool
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func makeProcess(_ tool: String, _ arguments: [String]) throws -> (Process, Pipe) {
        let path = resolve(tool)
        guard FileManager.default.isExecutableFile(atPath: path) || path.contains("/") else {
            throw ShellError.toolNotFound(tool)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        return (process, pipe)
    }

    /// 同步执行命令，返回合并后的 stdout + stderr。
    @discardableResult
    public static func run(_ tool: String, _ arguments: [String]) throws -> CommandResult {
        let (process, pipe) = try makeProcess(tool, arguments)
        let display = ([tool] + arguments).joined(separator: " ")

        var collected = Data()
        let collectLock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collectLock.lock()
            collected.append(data)
            collectLock.unlock()
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw ShellError.launchFailed(tool, error)
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil

        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        collectLock.lock()
        collected.append(tail)
        let data = collected
        collectLock.unlock()

        return CommandResult(command: display, exitCode: process.terminationStatus, output: decode(data))
    }

    /// 执行命令但不检查退出码，把成功与否交给调用方判断。
    public static func tryRun(_ tool: String, _ arguments: [String]) -> CommandResult {
        do {
            return try run(tool, arguments)
        } catch {
            return CommandResult(
                command: ([tool] + arguments).joined(separator: " "),
                exitCode: -1,
                output: error.localizedDescription
            )
        }
    }

    /// 逐行流式执行命令，用于刻录/擦除这类耗时操作。
    ///
    /// - Parameter onLine: 在后台线程逐行回调（不含换行符），调用方需要自行切换线程。
    /// - Returns: 命令的完整输出与退出码。
    @discardableResult
    public static func stream(
        _ tool: String,
        _ arguments: [String],
        canceller: CommandCanceller? = nil,
        onLine: @escaping (String) -> Void
    ) throws -> CommandResult {
        let (process, pipe) = try makeProcess(tool, arguments)
        let display = ([tool] + arguments).joined(separator: " ")

        var pending = Data()
        var allLines: [String] = []
        let stateLock = NSLock()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            var completed: [String] = []
            stateLock.lock()
            pending.append(data)
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending.subdata(in: pending.startIndex..<newline)
                pending.removeSubrange(pending.startIndex...newline)
                completed.append(decode(lineData))
            }
            allLines.append(contentsOf: completed)
            stateLock.unlock()
            for line in completed { onLine(line) }
        }

        if let canceller = canceller, !canceller.attach(process) {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw ShellError.cancelled
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            canceller?.detach()
            throw ShellError.launchFailed(tool, error)
        }

        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        canceller?.detach()

        let tail = pipe.fileHandleForReading.readDataToEndOfFile()
        stateLock.lock()
        pending.append(tail)
        let leftover = decode(pending).trimmingCharacters(in: .whitespacesAndNewlines)
        if !leftover.isEmpty {
            allLines.append(leftover)
        }
        let lines = allLines
        stateLock.unlock()

        if !leftover.isEmpty { onLine(leftover) }

        if let canceller = canceller, canceller.isCancelled {
            throw ShellError.cancelled
        }

        return CommandResult(
            command: display,
            exitCode: process.terminationStatus,
            output: lines.joined(separator: "\n")
        )
    }

    private static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        return ""
    }
}
