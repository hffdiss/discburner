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
      discburn contents --export <目录>     把光盘里已有的内容（含全部区段）导出到目录
      discburn history [--limit N]          本机刻录记录
      discburn plan <路径…> [--name 卷标]    估算大小与所需介质，不写盘
      discburn check <路径…> [--json]       兼容性预检（Windows / Linux / 老设备）
      discburn image <路径…> -o <输出.iso>   只生成光盘映像文件
      discburn burn <路径…> [选项]           刻录到光盘
      discburn audio <路径…> [选项]          刻成音乐 CD（红皮书音轨，CD 机能放）
      discburn erase [--mode quick|full]    擦除可重写光盘
      discburn eject                        弹出光盘
      discburn --version                    显示版本号

    \(bold("音乐 CD"))
      音乐 CD 写的是红皮书音轨：把音频文件转成 44.1 kHz / 16 bit / 立体声，盘上没有文件系统，
      电脑看不到「文件」，CD 机 / 车载音响 / DVD 播放机才认。
      · 只收音频：MP3 / M4A / AAC / WAV / AIFF / ALAC / FLAC（Ogg / Opus 系统解不了，请先转换）
      · 只能刻在 CD-R / CD-RW 上，一张 80 分钟的盘大约放 80 分钟音频
      · 不能追加：盘上有内容时会先擦（只有 CD-RW 擦得掉），音轨按列表顺序写
      · 倍速默认 8x：老 CD 机对高倍速刻出来的音轨更挑

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
      --merge              可重写介质上追加时「整盘合并重刻」：先读盘上已有内容，
                           和这次要刻的合成一份，擦盘再单段刻完。
                           保证 Windows / macOS / Linux 看到的是同一份完整内容
      --append             追加新段（默认）：写得快，但 macOS / Linux 默认只看得到第一段
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
      discburn audio ~/Music/旅行歌单 --speed 8   # 刻成音乐 CD
      discburn audio ~/Downloads/专辑/            # 文件夹会自动找里面的音频文件
      discburn image ~/Pictures -o ~/Desktop/照片.iso
      discburn erase --mode full
    """)
}

// MARK: - 参数解析

struct Options {
    var command = ""
    var paths: [URL] = []
    var volumeName: String?
    /// 刻数据光盘还是音乐 CD。
    var mode: DiscMode = .data
    var driveIndex: Int?
    var verify = true
    var eject = true
    var test = false
    var eraseFirst = false
    var closeDisc = false
    /// 盘上已经有内容时：追加新段（默认）还是整盘合并重刻。
    var appendStrategy: AppendStrategy = .graft
    var keepJunk = false
    var force = false
    var keep = false
    var quiet = false
    var eraseMode: EraseMode = .quick
    /// 刻录倍速：默认「推荐」（按介质与驱动器能力取稳妥值）。
    var speedMode: SpeedMode = .recommended
    var outputURL: URL?
    /// `contents --export <目录>`：把盘上内容导出到这个目录。
    var exportURL: URL?
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
        case "audio", "music", "音乐":
            options.command = "audio"
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
        case "--export":
            let value = try nextValue(argument)
            options.exportURL = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
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
        case "--audio", "-a":
            options.mode = .audioCD
        case "--data":
            options.mode = .data
        case "--merge":
            options.appendStrategy = .rewriteMerged
        case "--append":
            options.appendStrategy = .graft
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
    // 音乐 CD 是另一条流水线（没有映像、没有文件系统、不能追加）。
    if options.mode == .audioCD {
        guard output == nil else { throw UsageError(message: "音乐 CD 没有映像文件可生成") }
        try runAudioJob(options)
        return
    }
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
            eraseFirst: options.eraseFirst,
            appendStrategy: options.appendStrategy
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
    let outcome = try execute(request, options: options)
    print("")
    if let image = outcome.imageURL {
        print(green("✔ 映像已生成：\(image.path)（\(ByteText.human(outcome.payloadBytes))）"))
    } else {
        print(green("✔ \(outcome.wasTestBurn ? "测试刻录完成" : "刻录完成")") + dim(" 用时 \(String(format: "%.1f", outcome.duration)) 秒"))
    }
}

/// 跑一个刻录任务，并按阶段把进度打到终端上。
func execute(_ request: BurnRequest, options: Options) throws -> BurnOutcome {
    let job = BurnJob(request: request)
    var lastPhase: JobPhase = .idle
    return try job.run { update in
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
}

/// 音乐 CD：先把音轨排出来给用户看一眼，再走写盘流程。
///
/// 这里的清单不是「仅供参考」——它按列表顺序编号，而 `drutil burn -audio` 是按
/// 文件名字母序写的，暂存时用两位序号前缀把两者对齐，所以看到的顺序就是盘上的顺序。
func runAudioJob(_ options: Options) throws {
    guard !options.paths.isEmpty else {
        throw UsageError(message: "audio 需要至少一个音频文件或文件夹路径")
    }
    print(bold("[音频清单] ") + "正在读取音频信息…")
    let plan = try AudioDisc.plan(items: options.paths) { done, total, url in
        guard !options.quiet, total > 0, done > 0, done % 10 == 0 else { return }
        print(dim("  …已读取 \(done)/\(total)：\(url.lastPathComponent)"))
    }
    guard !plan.tracks.isEmpty else { throw AudioDiscError.noAudioTracks }

    for track in plan.tracks {
        var line = String(format: "  %2d.  %@  %@", track.id, AudioDisc.timeText(track.duration), track.title)
        if !track.isCDQuality { line += yellow("（会转码）") }
        print(line)
        if !options.quiet {
            print(dim("        " + track.sourceURL.path))
        }
    }
    if !plan.skipped.isEmpty {
        print(yellow("  跳过 \(plan.skipped.count) 个不是音频的内容："))
        for skip in plan.skipped.prefix(10) {
            print(dim("    · \(skip.displayName)：\(skip.reason)"))
        }
        if plan.skipped.count > 10 {
            print(dim("    …还有 \(plan.skipped.count - 10) 个"))
        }
    }

    print(bold("[时长] ") + "\(plan.summary) · 加上每轨 2 秒间隔占 "
        + "\(AudioDisc.timeText(plan.requiredSeconds))，一张 CD 有 \(AudioDisc.timeText(plan.capacitySeconds))")
    try AudioDisc.validate(plan: plan, force: options.force)

    let speed = resolveAudioSpeed(options, plan: plan)
    if !options.quiet {
        print(bold("[刻录速度] ") + speed.note)
        if let caution = speed.caution { print(yellow("  ⚠︎ " + caution)) }
    }
    print("")

    let request = BurnRequest(
        items: options.paths,
        volumeName: "AUDIO",
        mode: .audioCD,
        burnOptions: BurnOptions(
            driveIndex: options.driveIndex,
            speed: speed.speed,
            verify: false,
            ejectWhenDone: options.eject,
            testBurn: options.test,
            closeDisc: true,
            eraseFirst: options.eraseFirst,
            appendStrategy: .graft
        ),
        force: options.force,
        keepWorkspace: options.keep
    )
    let outcome = try execute(request, options: options)
    print("")
    if outcome.wasTestBurn {
        print(green("✔ 测试刻录完成") + dim(" 用时 \(String(format: "%.1f", outcome.duration)) 秒"))
    } else {
        print(green("✔ 刻录完成：音乐 CD \(outcome.audioTrackCount) 轨")
            + " · 总时长 \(AudioDisc.timeText(outcome.audioDuration))")
        print(dim("  用时 \(String(format: "%.1f", outcome.duration)) 秒 · "
            + "盘上没有文件系统，用 CD 机 / 车载音响放；电脑上看不到「文件」"))
    }
}

/// 音乐 CD 的倍速：默认 8x，理由跟数据盘不同（老 CD 机对高倍速更挑）。
func resolveAudioSpeed(_ options: Options, plan: AudioDiscPlan) -> SpeedPlan {
    let drives = (try? DriveService.listDrives()) ?? []
    let drive = options.driveIndex.flatMap { index in drives.first { $0.index == index } } ?? drives.first
    let status = drive.flatMap { try? DriveService.status(driveIndex: $0.index) }
    let advice = SpeedAdvisor.audioAdvice(
        reportedSpeeds: status?.writeSpeeds ?? [],
        trackCount: plan.tracks.count
    )
    switch options.speedMode {
    case .automatic:
        return SpeedPlan(speed: nil, note: "自动（由驱动器选择，通常是它能跑的最高倍速）", caution: nil)
    case .fixed(let value):
        return SpeedPlan(speed: value, note: "\(value)x（手动指定）", caution: advice.caution(for: value))
    case .recommended:
        guard let speed = advice.recommended else {
            return SpeedPlan(speed: nil, note: "自动（\(advice.reason)）", caution: nil)
        }
        return SpeedPlan(speed: speed, note: "推荐 \(speed)x · \(advice.reason)", caution: nil)
    }
}

/// plan 命令：整理后只估算容量与所需介质。
func runPlanOnly(_ options: Options) throws {
    // 音乐 CD 的「预演」：只列音轨与时长，不转码、不写盘。
    if options.mode == .audioCD {
        let plan = try AudioDisc.plan(items: options.paths)
        guard !plan.tracks.isEmpty else { throw AudioDiscError.noAudioTracks }
        print(bold("[预演] ") + "音乐 CD：" + plan.summary)
        for track in plan.tracks {
            print(String(format: "  %2d.  %@  %@", track.id, AudioDisc.timeText(track.duration), track.title))
        }
        if !plan.skipped.isEmpty {
            print(yellow("  跳过 \(plan.skipped.count) 个不是音频的内容"))
        }
        let verdict = plan.isOverCapacity
            ? red("✘ 装不下，超了 \(AudioDisc.timeText(-plan.remainingSeconds))")
            : green("✔ 装得下，还剩 \(AudioDisc.timeText(plan.remainingSeconds))")
        print("  算上每轨 2 秒间隔占 \(AudioDisc.timeText(plan.requiredSeconds))，"
            + "一张 CD 有 \(AudioDisc.timeText(plan.capacitySeconds)) → \(verdict)")
        print(dim("  转成 CD 音轨大约需要 \(ByteText.human(plan.stagedBytes)) 临时空间。"))
        return
    }
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
    // 按扇区读出来的原始整盘内容 + 对应的读盘通道，导出时要用。
    var raw: DiscContentView?
    var reader: IsoImageReader?
    var source = "光盘"
    if let image = options.outputURL {
        print(bold("[读取映像] ") + image.path)
        source = image.path
        raw = IsoImageReader(fileURL: image).flatMap {
            DiscContentReader.read(reader: $0, layout: DiscLayout.singleSession)
        }
        if let whole = raw, let imageReader = IsoImageReader(fileURL: image) {
            reader = imageReader
            contents = whole.asDiscContents(source: source, sessionCount: 1)
        } else {
            contents = try DiscReader.readImage(image)
        }
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
        source = device
        // 优先按扇区读「整盘内容」：多区段盘系统只挂载其中一段，
        // 只看挂载结果会少显示内容——「追加刻录后看不到文件」最容易踩的就是这个坑。
        let layout = (try? Multisession.layout(driveIndex: drive.index)) ?? .empty
        if !layout.isEmpty,
           let whole = DiscContentReader.read(deviceNode: device, layout: layout) {
            raw = whole
            reader = IsoImageReader(deviceNode: device)
            contents = whole.asDiscContents(
                source: device,
                media: status.media,
                mediaID: status.mediaID,
                sessionCount: layout.recordedSessions
            )
            if layout.recordedSessions > 1 {
                contents.note = "这张盘是多区段盘：系统挂载只会显示其中一段，"
                    + "上面列的是按扇区读出来的全部 \(layout.recordedSessions) 个区段。"
            }
            // 卷标 / 文件系统名挂载着才拿得到，能补就补上。
            if let mounted = try? DiscReader.readDevice(
                device,
                media: status.media,
                mediaID: status.mediaID,
                sessionCount: status.sessions,
                allowMount: false
            ) {
                contents.volumeName = contents.volumeName ?? mounted.volumeName
                contents.fileSystem = contents.fileSystem ?? mounted.fileSystem
                contents.mountPoint = mounted.mountPoint
            }
        } else {
            contents = try DiscReader.readDevice(
                device,
                media: status.media,
                mediaID: status.mediaID,
                sessionCount: status.sessions
            )
        }
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

    // 访达 / 资源管理器里的那个卷是「系统挂载」的结果，多区段盘上系统只挂第一段，
    // 所以要把盘上真正的内容落到本机，只能自己按扇区读出来写一遍。
    if let exportURL = options.exportURL {
        guard let raw = raw, !raw.isEmpty, let reader = reader else {
            throw UsageError(message: "没读到可导出的内容（这张盘可能是空白的，或者区段读不出来）。")
        }
        print("")
        print(bold("[导出] ") + exportURL.path)
        var lastStep = -1
        let summary = try DiscContentReader.extract(
            raw,
            reader: reader,
            source: source,
            to: exportURL,
            conflict: .skipExisting
        ) { fraction in
            guard !options.quiet else { return }
            let step = Int(fraction * 10)
            if step != lastStep {
                lastStep = step
                print("  \(Int(fraction * 100))%")
            }
        }
        print("  \(summary.description)")
        print("  已导出到 \(exportURL.path)")
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
    var options = try parse(Array(CommandLine.arguments.dropFirst()))
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
    case "audio":
        options.mode = .audioCD
        try commandBurn(options: options)
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
