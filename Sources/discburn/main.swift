import Foundation
import DiscBurnKit

#if canImport(Darwin)
import Darwin
#endif

// MARK: - 输出小工具

let useColor = isatty(STDOUT_FILENO) == 1

func style(_ text: String, _ code: String) -> String {
    useColor ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
}

func bold(_ text: String) -> String { style(text, "1") }
func green(_ text: String) -> String { style(text, "32") }
func yellow(_ text: String) -> String { style(text, "33") }
func red(_ text: String) -> String { style(text, "31") }
func dim(_ text: String) -> String { style(text, "2") }

func printError(_ message: String) {
    FileHandle.standardError.write((red("错误：") + message + "\n").data(using: .utf8)!)
}

/// 命令行工具的版本号。
///
/// 随 App 一起分发时（`DiscBurner.app/Contents/MacOS/discburn`）能读到 App 的 Info.plist
/// 里的版本；单独跑 `.build-manual/universal/discburn` 时读不到，就照实说，
/// 免得编一个假版本号出来。
let discburnVersionText: String = {
    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
        return version
    }
    return "未知（未随 App 打包，版本号见仓库根的 VERSION 文件）"
}()

func usage() {
    print("""
    \(bold("discburn")) — 在 macOS 上把任意文件刻录到光盘（含外置 USB 光驱）

    \(bold("用法"))
      discburn list                         列出光驱与介质状态
      discburn status [--drive N]           查看当前介质详情
      discburn contents [--drive N]         读取光盘里已有的内容
      discburn contents --image <映像>      读取光盘映像里的内容
      discburn history [--limit N]          本机刻录记录
      discburn plan <路径…> [--name 卷标]    估算大小与所需介质，不写盘
      discburn check <路径…> [--json]       兼容性预检（Windows / Linux / 老设备）
      discburn image <路径…> -o <输出.iso>   只生成光盘映像文件
      discburn burn <路径…> [选项]           刻录到光盘
      discburn erase [--mode quick|full]    擦除可重写光盘
      discburn eject                        弹出光盘
      discburn --version                    显示版本号

    \(bold("刻录选项"))
      --name <卷标>        光盘卷标（默认 DiscBurn_日期）
      --speed <N|auto|recommended>
                           刻录倍速。默认 recommended（按介质给稳妥值）
                           也可以写 auto（驱动器自己选）或具体数字，
                           常用 1 / 2 / 3 / 4 / 6 / 8 / 16 / 24 / 48
      --drive <N>          指定驱动器编号（见 list）
      --no-verify          刻录后不做数据校验
      --no-eject           刻录完成后不弹出
      --test               测试模式（不打开激光，不写入介质）
      --erase-first        刻录前先快速擦除（仅可重写介质）
      --close              关闭光盘，之后无法再追加
      --keep-junk          保留 .DS_Store 等 macOS 垃圾文件
      --fix-names          自动重命名不兼容的文件名（只改光盘里的副本）
      --strict             有兼容性问题就中止，不开始刻录
      --force              忽略容量不足的警告，强行尝试
      --keep               保留临时目录（排错用）
      --quiet              只输出关键信息

    \(bold("示例"))
      discburn list
      discburn burn ~/Movies/婚礼视频 ~/Documents/合同.pdf --name 婚礼存档
      discburn burn ~/Desktop/report.iso          # 直接刻录已有 ISO
      discburn check ~/Documents                  # 先看看有没有不兼容的文件名
      discburn burn ~/Documents --fix-names       # 自动改名后再刻
      discburn image ~/Pictures -o ~/Desktop/照片.iso
      discburn erase --mode full
    """)
}

// MARK: - 参数解析

struct Options {
    var command = ""
    var paths: [URL] = []
    var volumeName: String?
    var driveIndex: Int?
    var verify = true
    var eject = true
    var test = false
    var eraseFirst = false
    var closeDisc = false
    var keepJunk = false
    var force = false
    var keep = false
    var quiet = false
    var eraseMode: EraseMode = .quick
    /// 刻录倍速：默认「推荐」（按介质与驱动器能力取稳妥值）。
    var speedMode: SpeedMode = .recommended
    var outputURL: URL?
    var assumeYes = false
    var limit = 10
    /// 自动重命名不兼容的文件名后再刻。
    var fixNames = false
    /// 有兼容性问题就中止（默认只是提示）。
    var strict = false
    var json = false
}

enum SpeedMode {
    case recommended
    case automatic
    case fixed(Int)

    var isRecommended: Bool {
        if case .recommended = self { return true }
        return false
    }
}

struct UsageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func parse(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0
    var pendingPaths: [String] = []

    func nextValue(_ flag: String) throws -> String {
        index += 1
        guard index < arguments.count else { throw UsageError(message: "\(flag) 缺少参数") }
        return arguments[index]
    }

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "-h", "--help", "help":
            options.command = "help"
        case "-v", "--version", "version":
            options.command = "version"
        case "list", "drives":
            options.command = "list"
        case "status":
            options.command = "status"
        case "contents", "ls":
            options.command = "contents"
        case "check", "precheck":
            options.command = "check"
        case "history":
            options.command = "history"
        case "plan":
            options.command = "plan"
        case "image":
            options.command = "image"
        case "burn":
            options.command = "burn"
        case "erase":
            options.command = "erase"
        case "eject":
            options.command = "eject"
        case "--name", "-n":
            options.volumeName = try nextValue(argument)
        case "--speed", "-s":
            let value = try nextValue(argument)
            switch value.lowercased() {
            case "auto", "automatic", "自动":
                options.speedMode = .automatic
            case "recommended", "rec", "recommend", "推荐":
                options.speedMode = .recommended
            default:
                guard let speed = Int(value), speed > 0 else {
                    throw UsageError(message: "--speed 需要正整数，或 auto / recommended")
                }
                options.speedMode = .fixed(speed)
            }
        case "--drive", "-d":
            let value = try nextValue(argument)
            guard let drive = Int(value), drive > 0 else { throw UsageError(message: "--drive 需要正整数") }
            options.driveIndex = drive
        case "--mode", "-m":
            let value = try nextValue(argument)
            guard let mode = EraseMode(rawValue: value) else { throw UsageError(message: "--mode 只能是 quick 或 full") }
            options.eraseMode = mode
        case "--limit":
            let value = try nextValue(argument)
            guard let limit = Int(value), limit > 0 else { throw UsageError(message: "--limit 需要正整数") }
            options.limit = limit
        case "-o", "--output", "--image":
            let value = try nextValue(argument)
            options.outputURL = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        case "--no-verify":
            options.verify = false
        case "--verify":
            options.verify = true
        case "--no-eject":
            options.eject = false
        case "--eject":
            options.eject = true
        case "--test":
            options.test = true
        case "--erase-first":
            options.eraseFirst = true
        case "--close":
            options.closeDisc = true
        case "--keep-junk":
            options.keepJunk = true
        case "--force", "-f":
            options.force = true
        case "--keep":
            options.keep = true
        case "--quiet", "-q":
            options.quiet = true
        case "--yes", "-y":
            options.assumeYes = true
        case "--fix-names":
            options.fixNames = true
        case "--strict":
            options.strict = true
        case "--json":
            options.json = true
        default:
            if argument.hasPrefix("-"), argument.count > 1 {
                throw UsageError(message: "未知选项 \(argument)")
            }
            pendingPaths.append(argument)
        }
        index += 1
    }

    options.paths = pendingPaths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    return options
}

// MARK: - 命令实现

func commandList(quiet: Bool) throws {
    let drives = try DriveService.listDrives()
    guard !drives.isEmpty else {
        print(yellow("没有检测到光驱。请确认外置光驱已连接并已通电。"))
        return
    }
    for drive in drives {
        print(bold("光驱 #\(drive.index)  \(drive.displayName)"))
        if !quiet {
            print(dim("    固件 \(drive.revision) · 接口 \(drive.bus) · Apple 支持级别 \(drive.supportLevel)"))
            if !drive.isAppleSupported {
                print(dim("    （第三方光驱常显示 Unsupported，通常仍可正常刻录）"))
            }
        }
        let status = (try? DriveService.status(driveIndex: drive.index)) ?? DiscStatus()
        print("    介质：\(status.isPresent ? status.summary : "未插入光盘")")
        if status.isPresent {
            var details: [String] = []
            if let total = status.totalBytes { details.append("总容量 \(ByteText.human(total))") }
            if let sessions = status.sessions { details.append("区段 \(sessions)") }
            if !status.writeSpeeds.isEmpty {
                details.append("可用倍速 " + status.writeSpeeds.map { "\($0)x" }.joined(separator: "/"))
            }
            if let book = status.bookType { details.append("Book Type \(book)") }
            if let mediaID = status.mediaID { details.append("Media ID \(mediaID)") }
            if !details.isEmpty, !quiet {
                print(dim("    " + details.joined(separator: " · ")))
            }
        }
    }
}

func commandStatus(options: Options) throws {
    let drives = try DriveService.listDrives()
    guard let drive = options.driveIndex.flatMap({ index in drives.first { $0.index == index } }) ?? drives.first else {
        throw BurnError.noDrive
    }
    let status = try DriveService.status(driveIndex: drive.index)
    print(bold("光驱 #\(drive.index)  \(drive.displayName)"))
    guard status.isPresent else {
        print(yellow("未插入光盘。"))
        return
    }
    print("  介质类型：\(status.media.displayName)\(status.rawType.map { " (\($0))" } ?? "")")
    print("  写入状态：\(status.writability.localizedDescription)")
    if let free = status.writableBytes { print("  可用空间：\(ByteText.human(free))（\(ByteText.decimal(free))）") }
    if let used = status.usedBytes { print("  已用空间：\(ByteText.human(used))") }
    if let total = status.totalBytes { print("  总容量：  \(ByteText.human(total))") }
    if let sessions = status.sessions { print("  已有区段：\(sessions)") }
    if let device = status.deviceNode { print("  设备节点：\(device)") }
    if let book = status.bookType { print("  Book Type：\(book)") }
    if let mediaID = status.mediaID { print("  Media ID：\(mediaID)") }
    if !status.writeSpeeds.isEmpty {
        print("  可用倍速：\(status.writeSpeeds.map { "\($0)x" }.joined(separator: ", "))")
    }
    print("  可擦除：  \(status.erasable || status.media.isRewritable ? "是" : "否")")
    // 多区段盘：把段起始和「下一个可写地址」也打出来，方便核对追加会不会写对地方。
    if (status.sessions ?? 0) > 0, let layout = try? Multisession.layout(driveIndex: drive.index), !layout.isEmpty {
        let starts = layout.sessionStarts.prefix(6).map(String.init).joined(separator: ", ")
        let more = layout.sessionStarts.count > 6 ? " …" : ""
        print("  段起始扇区：\(starts)\(more)（共 \(layout.recordedSessions) 段）")
        if let next = layout.nextWritableAddress {
            print("  下一段起始：\(next)（扇区）")
        }
        if let device = status.deviceNode {
            let chain = Multisession.chainState(deviceNode: device, layout: layout)
            print("  旧段可合并：\(chain.localizedDescription)")
            // 最后一段的 Joliet 视图就是 Windows 会看到的那一套（macOS 自己读的是 Rock Ridge）。
            if let start = layout.lastSessionStart,
               let reader = IsoImageReader(deviceNode: device),
               IsoTree.rootRecord(in: reader, imageStart: start, joliet: true) != nil {
                let entries = IsoTree.entries(in: reader, imageStart: start).filter { $0.isJoliet }
                let files = entries.filter { !$0.isDirectory }
                let folders = entries.filter { $0.isDirectory }
                let sample = files.prefix(3).map { $0.name }.joined(separator: "、")
                print("  最后一段目录树：\(files.count) 个文件、\(folders.count) 个文件夹"
                    + (sample.isEmpty ? "" : "（Windows 视角，如 \(sample)）"))
            }
        }
    }
    // 追加刻录要靠 xorriso（首选）或 mkisofs 把新段嫁接给旧段，这里把能不能用得说清楚。
    let appendEngine = DataImageEngine.preferred(for: makeImageOptions(options))
    if appendEngine.supportsMultisessionAppend {
        let version = (appendEngine == .xorriso ? Xorriso.version() : Mkisofs.version())?
            .components(separatedBy: " : ").first
        print("  多区段追加：可用（\(appendEngine.toolName)\(version.map { " · \($0)" } ?? "")）")
        if appendEngine == .mkisofs {
            print("  ⚠︎ mkisofs 写 Joliet 中文长名只保留前 8 个字符，建议 \(Mkisofs.recommendedTool)")
        }
    } else {
        print("  多区段追加：不可用，需要 \(Xorriso.installHint)")
    }
}

func makeImageOptions(_ options: Options) -> ImageOptions {
    let name = options.volumeName ?? defaultVolumeName()
    return ImageOptions(volumeName: ImageBuilder.normalizeVolumeName(name))
}

func defaultVolumeName() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd"
    return "DISC_\(formatter.string(from: Date()))"
}

func commandPlan(options: Options) throws {
    guard !options.paths.isEmpty else { throw UsageError(message: "plan 需要至少一个文件或文件夹路径") }
    try runPlanOnly(options)
}

// MARK: - 兼容性预检

struct PrecheckError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 打印预检结果（逐条列出「警告」及以上，提示类只列一行）。
func printCompatibilityReport(_ report: CompatibilityReport, detailLimit: Int = 30) {
    let issues = report.issues(atLeast: .warning)
    for issue in issues.prefix(detailLimit) {
        let mark = issue.severity == .error ? red("✘") : yellow("⚠")
        let location = issue.relativePath.map { $0.isEmpty ? "光盘根目录" : $0 } ?? "整张盘"
        print("  \(mark) [\(issue.category.localizedName)] \(location)")
        print("      \(issue.message)")
        print(dim("      → \(issue.advice)"))
    }
    if issues.count > detailLimit {
        print(dim("  …还有 \(issues.count - detailLimit) 项，见 discburn check --json"))
    }
    for issue in report.issues(atLeast: .info).filter({ $0.severity == .info }).prefix(6) {
        print(dim("  · \(issue.message)"))
    }
}

func printRenamePlan(_ report: CompatibilityReport, limit: Int = 8) {
    guard !report.renamePlan.isEmpty else { return }
    print("")
    print("  自动重命名会改掉 \(report.renamePlan.count) 个名字（只改光盘里的副本，源文件不动）：")
    for rename in report.renamePlan.prefix(limit) {
        print("    「\(rename.oldRelativePath)」→「\(rename.newRelativePath)」")
        if let reason = rename.reasons.first {
            print(dim("      原因：\(reason)"))
        }
    }
    if report.renamePlan.count > limit {
        print(dim("    …还有 \(report.renamePlan.count - limit) 个"))
    }
}

func compatibilityJSON(_ report: CompatibilityReport) -> String {
    let issues: [[String: Any]] = report.sortedIssues().map { issue in
        [
            "severity": issue.severity.localizedName,
            "category": issue.category.rawValue,
            "path": issue.relativePath ?? "",
            "message": issue.message,
            "advice": issue.advice,
        ]
    }
    let renames: [[String: Any]] = report.renamePlan.map { rename in
        [
            "from": rename.oldRelativePath,
            "to": rename.newRelativePath,
            "reasons": rename.reasons,
        ]
    }
    let payload: [String: Any] = [
        "headline": report.headline,
        "errors": report.errorCount,
        "warnings": report.warningCount,
        "infos": report.infoCount,
        "files": report.fileCount,
        "directories": report.directoryCount,
        "maxDepth": report.maxDepth,
        "issues": issues,
        "renames": renames,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return text
}

func commandCheck(options: Options) throws {
    guard !options.paths.isEmpty else { throw UsageError(message: "check 需要至少一个文件或文件夹路径") }
    for path in options.paths where !FileManager.default.fileExists(atPath: path.path) {
        throw UsageError(message: "找不到路径：\(path.path)")
    }
    let imageOptions = makeImageOptions(options)
    let report = CompatibilityChecker.scan(items: options.paths, rules: imageOptions.nameRules)

    if options.json {
        print(compatibilityJSON(report))
        if report.hasErrors { exit(1) }
        return
    }

    let headline = report.hasErrors
        ? red("✘ \(report.headline)")
        : (report.hasWarningsOrErrors ? yellow("⚠ \(report.headline)") : green("✔ \(report.headline)"))
    print(bold("[兼容性预检] ") + headline)
    print("  \(report.fileCount) 个文件 / \(report.directoryCount) 个目录，最深 \(report.maxDepth) 层")
    print("  目标文件系统：\(DataImageEngine.preferred(for: imageOptions).localizedSummary)")
    printCompatibilityReport(report)
    printRenamePlan(report)
    if report.renamePlan.isEmpty {
        print(dim("\n  名字本身没有问题，直接刻录即可。"))
    } else {
        print(dim("\n  刻录时加 --fix-names 会自动按上面的方案改名（只改光盘里的副本）。"))
    }
    if report.hasErrors {
        exit(1)
    }
}

func commandImage(options: Options) throws {
    guard !options.paths.isEmpty else { throw UsageError(message: "image 需要至少一个文件或文件夹路径") }
    guard let output = options.outputURL else { throw UsageError(message: "image 需要 -o <输出文件>") }
    try runJob(options, output: output)
}

func commandBurn(options: Options) throws {
    guard !options.paths.isEmpty else { throw UsageError(message: "burn 需要至少一个文件或文件夹路径") }
    try runJob(options, output: nil)
}

func runJob(_ options: Options, output: URL?) throws {
    let imageOptions = makeImageOptions(options)

    // 先做兼容性预检：默认只提示，--strict 时有「需处理」的问题就中止。
    let report = CompatibilityChecker.scan(items: options.paths, rules: imageOptions.nameRules)
    if !options.quiet || report.hasErrors {
        let headline = report.hasErrors
            ? red("✘ \(report.headline)")
            : (report.hasWarningsOrErrors ? yellow("⚠ \(report.headline)") : green("✔ \(report.headline)"))
        print(bold("[兼容性预检] ") + headline)
        if !options.quiet {
            printCompatibilityReport(report, detailLimit: 10)
        }
        if report.hasErrors, !options.fixNames {
            print(dim("  提示：加 --fix-names 可自动重命名；大小写冲突还会让整理文件这一步失败。"))
        }
    }
    if options.strict, report.hasErrors {
        throw PrecheckError(message: "兼容性预检发现 \(report.errorCount) 项需要处理的问题，已按 --strict 中止。")
    }
    if options.fixNames, !options.quiet {
        printRenamePlan(report)
    }

    let speed = resolveSpeed(options)
    if !options.quiet {
        print(bold("[刻录速度] ") + speed.note)
        if let caution = speed.caution { print(yellow("  ⚠︎ " + caution)) }
        if let hint = currentSpeedAdvice(options, payloadBytes: 0).hint, options.speedMode.isRecommended {
            print(dim("  " + hint))
        }
    }
    print("")

    let request = BurnRequest(
        items: options.paths,
        volumeName: imageOptions.volumeName,
        imageOptions: imageOptions,
        burnOptions: BurnOptions(
            driveIndex: options.driveIndex,
            speed: speed.speed,
            verify: options.verify,
            ejectWhenDone: options.eject,
            testBurn: options.test,
            closeDisc: options.closeDisc,
            eraseFirst: options.eraseFirst
        ),
        imageOnlyURL: output,
        stageOptions: StageOptions(
            excludeJunkFiles: !options.keepJunk,
            namePolicy: options.fixNames ? .sanitize : .keep,
            nameRules: imageOptions.nameRules
        ),
        force: options.force,
        keepWorkspace: options.keep
    )
    let job = BurnJob(request: request)
    var lastPhase: JobPhase = .idle
    let outcome = try job.run { update in
        if options.quiet, update.log != nil { return }
        if update.phase != lastPhase {
            lastPhase = update.phase
            print(bold("[\(update.phase.localizedName)]"))
        }
        if let log = update.log {
            // 日志可能是多行（例如自动重命名的清单），逐行缩进一下更好读。
            for line in log.split(separator: "\n", omittingEmptySubsequences: false) {
                print("  " + dim(String(line)))
            }
        } else if !update.message.isEmpty {
            print("  " + update.message)
        }
    }
    print("")
    if let image = outcome.imageURL {
        print(green("✔ 映像已生成：\(image.path)（\(ByteText.human(outcome.payloadBytes))）"))
    } else {
        print(green("✔ \(outcome.wasTestBurn ? "测试刻录完成" : "刻录完成")") + dim(" 用时 \(String(format: "%.1f", outcome.duration)) 秒"))
    }
}

/// plan 命令：整理后只估算容量与所需介质。
func runPlanOnly(_ options: Options) throws {
    // 直接刻录现成映像文件时不用再打包，直接报文件大小
    if let direct = BurnJob.directImageURL(for: options.paths) {
        let bytes = Workspace.fileSize(of: direct)
        print(bold("[预演] ") + "直接刻录现成映像文件：\(direct.lastPathComponent)")
        print("  映像大小：\(ByteText.human(bytes))（\(ByteText.decimal(bytes))）")
        if let drive = (try? DriveService.listDrives())?.first,
           let status = try? DriveService.status(driveIndex: drive.index),
           let free = status.writableBytes {
            let verdict = bytes <= free
                ? green("✔ 可以刻录，剩余 \(ByteText.human(free - bytes))")
                : red("✘ 空间不足，还差 \(ByteText.human(bytes - free))")
            print("  当前介质 \(status.media.displayName) 可用 \(ByteText.human(free)) → \(verdict)")
        }
        print(dim("  卷标与文件系统由映像本身决定。"))
        return
    }

    let workspace = try Workspace()
    defer { workspace.cleanup() }
    let drives = (try? DriveService.listDrives()) ?? []
    let drive = options.driveIndex.flatMap { index in drives.first { $0.index == index } } ?? drives.first
    let status = drive.flatMap { try? DriveService.status(driveIndex: $0.index) }
    let imageOptions = makeImageOptions(options)

    print(bold("[预演] ") + "正在整理文件…")
    let entries = try workspace.stage(
        items: options.paths,
        options: StageOptions(excludeJunkFiles: !options.keepJunk)
    )
    let payload = entries.reduce(Int64(0)) { $0 + $1.byteCount }
    let engine = DataImageEngine.preferred(for: imageOptions)
    var estimated = payload
    if let printed = try? engine.estimatedBytes(source: workspace.staging, options: imageOptions, graft: nil), printed > 0 {
        estimated = printed
    }

    print("")
    print(bold("待刻录内容"))
    for entry in entries {
        print("  \(entry.name)\(entry.isDirectory ? "/" : "")  \(ByteText.human(entry.byteCount))")
    }
    print("  合计：\(ByteText.human(payload))（\(ByteText.decimal(payload))）")
    print("  光盘映像预计：\(ByteText.human(estimated))")
    print("  卷标：\(imageOptions.volumeName)   文件系统：\(engine.localizedSummary)（\(engine.toolName)）")
    let speed = resolveSpeed(options)
    var speedLine = speed.note
    if let value = speed.speed {
        let seconds = SpeedAdvisor.estimateDuration(payloadBytes: payload, speed: value, media: status?.media ?? .unknown)
        if seconds > 0 { speedLine += "，预计约 \(SpeedAdvisor.durationText(seconds))" }
    }
    if let caution = speed.caution { speedLine += " · ⚠︎ " + caution }
    print("  刻录速度：\(speedLine)")
    let compatibility = CompatibilityChecker.scan(items: options.paths, rules: imageOptions.nameRules)
    if compatibility.isPerfect {
        print("  兼容性：\(green("✔ 未发现兼容性问题"))")
    } else {
        print("  兼容性：\(compatibility.hasErrors ? red("✘ ") : yellow("⚠ "))\(compatibility.headline)"
            + dim("（用 discburn check 查看详情，--fix-names 可自动改名）"))
    }
    print("")
    if let status = status, status.isPresent {
        print(bold("当前介质"))
        print("  \(status.media.displayName) · \(status.writability.localizedDescription)")
        if let free = status.writableBytes {
            let verdict = estimated <= free
                ? green("✔ 可以刻录，剩余 \(ByteText.human(free - estimated))")
                : red("✘ 空间不足，还差 \(ByteText.human(estimated - free))")
            print("  可用 \(ByteText.human(free)) → \(verdict)")
        }
    } else {
        let suggestion = suggestMedia(for: estimated)
        print(bold("未检测到可用介质"))
        print("  需要容量 ≥ \(ByteText.human(estimated))，建议使用：\(suggestion)")
    }
}

func suggestMedia(for bytes: Int64) -> String {
    let candidates: [MediaKind] = [.cdR, .dvdR, .dvdRDL, .bdR, .bdRDL, .bdRTriple]
    for media in candidates where media.nominalCapacityBytes >= bytes {
        return "\(media.displayName)（标称 \(ByteText.human(media.nominalCapacityBytes))）"
    }
    return "内容过大，需要分割成多张光盘"
}

func commandErase(options: Options) throws {
    let drives = (try? DriveService.listDrives()) ?? []
    guard let drive = options.driveIndex.flatMap({ index in drives.first { $0.index == index } }) ?? drives.first else {
        throw BurnError.noDrive
    }
    let status = try DriveService.status(driveIndex: drive.index)
    guard status.isPresent else { throw BurnError.noMedia }
    guard status.erasable || status.media.isRewritable else {
        throw BurnError.notRewritable(status.media.displayName)
    }
    if !options.assumeYes {
        print(yellow("即将\(options.eraseMode.localizedName)光驱 #\(drive.index)（\(drive.displayName)）中的 \(status.media.displayName)。"))
        print(yellow("光盘上的所有数据都会被清除，且无法恢复。"))
        print("确认请输入 yes：", terminator: "")
        guard let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              answer == "yes" || answer == "y" else {
            print("已取消。")
            return
        }
    }
    print(bold("[擦除] ") + options.eraseMode.localizedName)
    try Burner.erase(mode: options.eraseMode, driveIndex: drive.index) { progress in
        if !options.quiet, let line = progress.rawLine, !line.isEmpty {
            print("  " + dim(line))
        }
    }
    print(green("✔ 擦除完成"))
}

func commandEject(options: Options) throws {
    try DriveService.eject(driveIndex: options.driveIndex)
    print(green("✔ 光盘已弹出"))
}

/// 解析出来的刻录倍速：数值（nil = 交给驱动器）+ 说明 + 风险提示。
struct SpeedPlan {
    var speed: Int?
    var note: String
    var caution: String?
}

/// 按当前介质与驱动器能力解析刻录倍速。
func resolveSpeed(_ options: Options) -> SpeedPlan {
    switch options.speedMode {
    case .automatic:
        return SpeedPlan(speed: nil, note: "自动（由驱动器选择，通常是它能跑的最高倍速）", caution: nil)
    case .fixed(let value):
        let advice = currentSpeedAdvice(options)
        return SpeedPlan(speed: value, note: "\(value)x（手动指定）", caution: advice.caution(for: value))
    case .recommended:
        let advice = currentSpeedAdvice(options)
        guard let speed = advice.recommended else {
            return SpeedPlan(speed: nil, note: "自动（\(advice.reason)）", caution: nil)
        }
        return SpeedPlan(speed: speed, note: "推荐 \(speed)x · \(advice.reason)", caution: nil)
    }
}

func currentSpeedAdvice(_ options: Options, payloadBytes: Int64 = 0) -> SpeedAdvice {
    let drives = (try? DriveService.listDrives()) ?? []
    let drive = options.driveIndex.flatMap { index in drives.first { $0.index == index } } ?? drives.first
    let status = drive.flatMap { try? DriveService.status(driveIndex: $0.index) }
    return SpeedAdvisor.advise(
        media: status?.media ?? .unknown,
        reportedSpeeds: status?.writeSpeeds ?? [],
        payloadBytes: payloadBytes
    )
}

/// 读取光盘（或映像文件）里已有的内容。
func commandContents(options: Options) throws {
    var contents: DiscContents
    if let image = options.outputURL {
        print(bold("[读取映像] ") + image.path)
        contents = try DiscReader.readImage(image)
    } else {
        let drives = try DriveService.listDrives()
        guard let drive = options.driveIndex.flatMap({ index in drives.first { $0.index == index } }) ?? drives.first else {
            throw BurnError.noDrive
        }
        let status = try DriveService.status(driveIndex: drive.index)
        guard status.isPresent else { throw BurnError.noMedia }
        guard let device = status.deviceNode else {
            throw BurnError.unexpected("系统没有报告光盘设备节点")
        }
        print(bold("[读取光盘] ") + "\(device)  \(status.media.displayName)")
        contents = try DiscReader.readDevice(
            device,
            media: status.media,
            mediaID: status.mediaID,
            sessionCount: status.sessions
        )
    }

    print("")
    if let volumeName = contents.volumeName ?? contents.fileSystem {
        print("卷标：\(volumeName)")
    }
    print("内容：\(contents.summary)")
    if let note = contents.note {
        print(yellow(note))
    }
    if contents.entries.isEmpty {
        return
    }
    print("")
    for entry in contents.entries {
        for (depth, item) in entry.flatten() {
            let indent = String(repeating: "  ", count: depth)
            var line = "  \(indent)\(item.name)\(item.isDirectory ? "/" : "")"
            if let target = item.linkTarget {
                line += "  → \(target)"
            } else if !item.isDirectory {
                line += "  " + ByteText.human(item.byteCount)
            }
            print(line)
        }
    }
}

/// 本机刻录记录。
func commandHistory(options: Options) throws {
    let records = BurnHistory.records(mediaID: nil, limit: options.limit)
    guard !records.isEmpty else {
        print(yellow("还没有刻录记录。"))
        if let url = BurnHistory.fileURL { print(dim("记录文件：\(url.path)")) }
        return
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    print(bold("本机刻录记录（最近 \(records.count) 条）"))
    for record in records {
        let when = formatter.string(from: record.date)
        let size = ByteText.human(record.payloadBytes)
        var line = "  \(when)  「\(record.volumeName)」  \(record.mediaKind)"
        if let session = record.sessionIndex { line += " 第 \(session) 区段" }
        line += "  \(record.fileCount) 个文件 / \(size)"
        print(line)
        if !record.topLevelItems.isEmpty {
            print(dim("      " + record.topLevelItems.prefix(6).joined(separator: "、")))
        }
    }
    if let url = BurnHistory.fileURL {
        print(dim("\n记录文件：\(url.path)"))
    }
}

// MARK: - 入口

do {
    Workspace.purgeStale()
    let options = try parse(Array(CommandLine.arguments.dropFirst()))
    switch options.command {
    case "": usage()
    case "help": usage()
    case "version": print("discburn \(discburnVersionText)")
    case "list": try commandList(quiet: options.quiet)
    case "status": try commandStatus(options: options)
    case "contents": try commandContents(options: options)
    case "check": try commandCheck(options: options)
    case "history": try commandHistory(options: options)
    case "plan": try commandPlan(options: options)
    case "image": try commandImage(options: options)
    case "burn": try commandBurn(options: options)
    case "erase": try commandErase(options: options)
    case "eject": try commandEject(options: options)
    default:
        usage()
        throw UsageError(message: "未知命令 \(options.command)")
    }
} catch {
    printError(error.localizedDescription)
    if error is UsageError {
        print(dim("运行 discburn --help 查看用法。"))
    }
    exit(1)
}
