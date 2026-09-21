import Foundation

public enum JobPhase: String {
    case idle
    case checking
    case staging
    case buildingImage
    case erasing
    case preparing
    case burning
    case verifying
    case ejecting
    case finished
    case failed
    case cancelled

    public var localizedName: String {
        switch self {
        case .idle: return "空闲"
        case .checking: return "检查介质"
        case .staging: return "整理文件"
        case .buildingImage: return "生成光盘映像"
        case .erasing: return "擦除光盘"
        case .preparing: return "准备刻录"
        case .burning: return "写入光盘"
        case .verifying: return "校验数据"
        case .ejecting: return "弹出光盘"
        case .finished: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

public struct JobUpdate {
    public var phase: JobPhase
    /// 0...1 的总体进度；nil 表示正在进行但无法确定进度。
    public var fraction: Double?
    public var message: String
    public var log: String?
}

public struct BurnRequest {
    /// 要刻录的文件/文件夹（可来自任意位置）。
    public var items: [URL]
    public var volumeName: String
    public var imageOptions: ImageOptions
    public var burnOptions: BurnOptions
    /// 只生成映像文件而不刻录时设置（此时不写盘）。
    public var imageOnlyURL: URL?
    public var stageOptions: StageOptions
    /// 跳过容量检查（谨慎使用）。
    public var force: Bool
    /// 完成后保留临时目录（用于排查问题）。
    public var keepWorkspace: Bool

    public init(
        items: [URL],
        volumeName: String,
        imageOptions: ImageOptions? = nil,
        burnOptions: BurnOptions = BurnOptions(),
        imageOnlyURL: URL? = nil,
        stageOptions: StageOptions = StageOptions(),
        force: Bool = false,
        keepWorkspace: Bool = false
    ) {
        self.items = items
        self.volumeName = volumeName
        self.imageOptions = imageOptions ?? ImageOptions(volumeName: volumeName)
        self.burnOptions = burnOptions
        self.imageOnlyURL = imageOnlyURL
        self.stageOptions = stageOptions
        self.force = force
        self.keepWorkspace = keepWorkspace
    }
}

public struct BurnOutcome {
    public var imageURL: URL?
    public var payloadBytes: Int64
    public var mediaBefore: DiscStatus?
    public var mediaAfter: DiscStatus?
    public var duration: TimeInterval
    public var wasTestBurn: Bool
}

/// 端到端任务：整理文件 → 生成映像 → 检查容量 →（可选）擦除 → 写入 → 校验 → 弹出。
public final class BurnJob {
    public let request: BurnRequest
    private let canceller = CommandCanceller()
    private var workspace: Workspace?
    /// 为了独占读盘而卸下来的光驱设备（刻录失败时要把卷挂回去）。
    private var unmountedDeviceNode: String?
    private let startedAt = Date()

    public init(request: BurnRequest) {
        self.request = request
    }

    public var isCancelled: Bool { canceller.isCancelled }

    public func cancel() {
        canceller.cancel()
    }

    public func run(onUpdate: @escaping (JobUpdate) -> Void) throws -> BurnOutcome {
        do {
            return try runInternal(onUpdate: onUpdate)
        } catch {
            // 失败时也要把暂存目录清掉，否则会在缓存里留下一份完整拷贝
            if !request.keepWorkspace {
                workspace?.cleanup()
            }
            // 嫁接前为了独占读盘卸下来的卷，失败时挂回去，别让用户以为盘出了问题。
            if let device = unmountedDeviceNode {
                _ = Multisession.mount(deviceNode: device)
            }
            throw error
        }
    }

    private func runInternal(onUpdate: @escaping (JobUpdate) -> Void) throws -> BurnOutcome {
        guard !request.items.isEmpty else { throw BurnError.noItems }

        // 1. 检查驱动器与介质
        report(onUpdate, .checking, 0.0, "正在检测光驱…")
        let drives = try DriveService.listDrives()
        let selectedDrive = selectDrive(from: drives)
        var status = DiscStatus()
        if let selected = selectedDrive {
            status = try DriveService.status(driveIndex: selected.index)
        }

        // 只生成映像时不需要光驱和介质
        if request.imageOnlyURL != nil {
            let prepared = try prepareImage(status: status, onUpdate: onUpdate)
            report(onUpdate, .finished, 1.0, "映像已生成：\(prepared.imageURL.path)", log: prepared.imageURL.path)
            cleanup()
            return BurnOutcome(
                imageURL: prepared.imageURL,
                payloadBytes: prepared.payloadBytes,
                mediaBefore: nil,
                mediaAfter: nil,
                duration: Date().timeIntervalSince(startedAt),
                wasTestBurn: false
            )
        }

        guard let drive = selectedDrive else { throw BurnError.noDrive }
        guard status.isPresent else { throw BurnError.noMedia }

        if !request.burnOptions.testBurn {
            guard status.media.isWritable else {
                throw BurnError.mediaNotWritable(status.media.displayName)
            }
            if !status.writability.canBurn {
                throw BurnError.mediaClosed(status.media.displayName)
            }
        }
        if request.burnOptions.eraseFirst, !(status.erasable || status.media.isRewritable) {
            throw BurnError.notRewritable(status.media.displayName)
        }
        report(
            onUpdate,
            .checking,
            0.0,
            "光驱：\(drive.displayName) · 介质：\(status.summary)"
        )

        // 2. 拿到要写入的光盘映像
        let prepared = try prepareImage(status: status, onUpdate: onUpdate)
        try checkCancelled()

        // 5. 需要时先擦除
        if request.burnOptions.eraseFirst {
            report(onUpdate, .erasing, 0.45, "正在擦除光盘…")
            try Burner.erase(
                mode: .quick,
                driveIndex: drive.index,
                canceller: canceller
            ) { progress in
                self.report(
                    onUpdate,
                    .erasing,
                    self.scale(progress.fraction, 0.45, 0.55),
                    progress.message.isEmpty ? "正在擦除光盘…" : progress.message,
                    log: progress.rawLine
                )
            }
            status = try DriveService.status(driveIndex: drive.index)
            report(onUpdate, .erasing, 0.55, "擦除完成 · \(status.summary)")
        }

        // 6. 写盘
        let action = request.burnOptions.testBurn ? "测试刻录（不会写入介质）" : "刻录"
        report(onUpdate, .preparing, 0.58, "\(action)：\(prepared.imageURL.lastPathComponent)")
        var progressParser = BurnOutputParser(phase: .preparing)
        var sawWritePhase = false
        // drutil 不像 hdiutil 那样打印百分比，只能按「数据量 ÷ 倍速」估个时长，
        // 在刻录期间按时间推进进度条，免得进度条长时间停在原地。
        let ticker = BurnProgressTicker()
        let estimated = SpeedAdvisor.estimateDuration(
            payloadBytes: prepared.payloadBytes,
            speed: request.burnOptions.speed ?? 0,
            media: status.media
        )
        if estimated > 0, !request.burnOptions.testBurn {
            ticker.start(estimatedSeconds: estimated) { elapsed in
                let fraction = min(0.9, 0.6 + 0.3 * (elapsed / estimated))
                // 剩余时间要传原值：估完变负数时 progressText 会改成「正在收尾…」，
                // 掐到 0 再格式化只会得到「预计还要 —」。
                let remaining = estimated - elapsed
                self.report(
                    onUpdate,
                    .burning,
                    fraction,
                    "正在刻录… " + SpeedAdvisor.progressText(elapsed: elapsed, remaining: remaining),
                    log: nil
                )
            }
        }
        defer { ticker.stop() }
        let writeStartedAt = Date()
        _ = try Burner.burn(
            image: prepared.imageURL,
            options: request.burnOptions,
            canceller: canceller
        ) { line in
            var update = progressParser.consume(line.rawLine ?? line.message)
            if update.phase == .burning || update.phase == .verifying {
                sawWritePhase = true
            }
            if update.phase == .verifying { ticker.stop() }
            let low: Double = update.phase == .verifying ? 0.9 : 0.6
            let high: Double = update.phase == .verifying ? 0.98 : 0.9
            let fraction = self.scale(update.fraction, low, high)
            update.message = line.message.isEmpty ? update.phase.localizedName : line.message
            if update.phase == .verifying {
                // 校验阶段 drutil 也不给百分比，至少把已经花掉的时间写出来，
                // 别让状态栏一直停在「正在校验…」上不动。
                update.message = "正在校验数据… 已用 "
                    + SpeedAdvisor.durationText(Date().timeIntervalSince(writeStartedAt))
            }
            self.report(onUpdate, update.phase, fraction ?? 0.6, update.message, log: line.rawLine)
        }
        if !sawWritePhase {
            report(onUpdate, .burning, 0.9, "刻录命令已结束")
        }

        // 7. 弹出（--no-eject 时兜底）
        if request.burnOptions.ejectWhenDone {
            report(onUpdate, .ejecting, 0.99, "正在弹出光盘…")
            try? DriveService.eject(driveIndex: drive.index)
        }

        // 刻完立刻读状态：部分驱动器（实测 PIONEER DVR-XU01C）刚写完会短暂「认不到盘」，
        // 所以失败时等一会儿再读一次，免得把「光盘已关闭/还能追加」这句话丢掉。
        var finalStatus = try? DriveService.status(driveIndex: drive.index)
        var attempt = 0
        while finalStatus?.isPresent != true, attempt < 3 {
            attempt += 1
            Thread.sleep(forTimeInterval: 1.5)
            finalStatus = (try? DriveService.status(driveIndex: drive.index)) ?? finalStatus
        }
        report(onUpdate, .finished, 1.0, finishedMessage(status: finalStatus), log: nil)

        // 记一笔账：macOS 看不到多区段光盘里更早的区段，
        // 本机保留刻录记录便于回头核对每张盘刻过什么。
        if !request.burnOptions.testBurn {
            // 区段号 = 这次刻的是这张盘的第几段。
            // 刻完立刻读到的区段数常常还差一段（驱动器要过几秒才把这一段算进
            // TOC），所以取「刻之前的段数 + 1」与「刻完读到的新值」里较大的那个。
            let sessionIndex = max((status.sessions ?? 0) + 1, finalStatus?.sessions ?? 0)
            BurnHistory.record(
                BurnRecord(
                    volumeName: ImageBuilder.normalizeVolumeName(request.volumeName),
                    mediaKind: status.media.displayName,
                    mediaID: status.mediaID,
                    sessionIndex: sessionIndex,
                    payloadBytes: prepared.payloadBytes,
                    fileCount: prepared.fileCount,
                    topLevelItems: request.items.map { $0.lastPathComponent },
                    wasTestBurn: false,
                    filesystem: prepared.filesystem
                )
            )
        }

        cleanup()
        return BurnOutcome(
            imageURL: prepared.keepImage ? prepared.imageURL : nil,
            payloadBytes: prepared.payloadBytes,
            mediaBefore: status,
            mediaAfter: finalStatus,
            duration: Date().timeIntervalSince(startedAt),
            wasTestBurn: request.burnOptions.testBurn
        )
    }

    struct PreparedImage {
        var imageURL: URL
        var payloadBytes: Int64
        /// true 表示这个映像文件是用户自己的，不要删。
        var keepImage: Bool
        var fileCount: Int
        /// 这次用的文件系统（用于记录与提示）。
        var filesystem: String
    }

    /// 直接刻录现成映像文件时返回它的 URL（.iso / .dmg / .cdr / .toast / .cue / .toc）。
    public static func directImageURL(for items: [URL]) -> URL? {
        guard items.count == 1, let url = items.first else { return nil }
        let extensions = ["iso", "dmg", "cdr", "toast", "img", "cue", "toc"]
        guard extensions.contains(url.pathExtension.lowercased()) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return url
    }

    /// 准备光盘映像：用户直接给了映像文件就用它，否则整理文件后现场生成。
    private func prepareImage(status: DiscStatus, onUpdate: @escaping (JobUpdate) -> Void) throws -> PreparedImage {
        if request.imageOnlyURL == nil, let direct = BurnJob.directImageURL(for: request.items) {
            let bytes = Workspace.fileSize(of: direct)
            report(onUpdate, .checking, 0.1, "直接刻录映像文件 \(direct.lastPathComponent)（\(ByteText.human(bytes))）")
            if let capacity = status.writableBytes, bytes > capacity, !request.force {
                throw BurnError.capacityExceeded(required: bytes, available: capacity)
            }
            // 现成映像文件是按「自己就是从第 0 扇区开始」做的，落到第 N 段上时地址会错位，
            // 所以这种刻法不会把旧区段合并进来——盘上已经有内容时提醒一句。
            if (status.sessions ?? 0) > 0 {
                report(
                    onUpdate,
                    .checking,
                    0.12,
                    "⚠︎ 直接刻映像文件不会合并盘上旧区段：Windows / Linux 只会看到新段里的内容。要合并旧内容请改用「文件 / 文件夹」。",
                    log: "⚠︎ 直接刻映像文件：不会做多区段嫁接"
                )
            }
            return PreparedImage(imageURL: direct, payloadBytes: bytes, keepImage: true, fileCount: 1, filesystem: "现成映像")
        }

        // 用哪套引擎、要不要接在已有区段后面写，先定下来（还会顺便检查旧盘兼不兼容）。
        let engine = DataImageEngine.preferred(for: request.imageOptions)
        let appendPlan = try resolveAppendPlan(status: status, engine: engine, onUpdate: onUpdate)
        let mergedSessions = appendPlan == nil ? 0 : (status.sessions ?? 0)

        let workspace = try Workspace()
        self.workspace = workspace
        if request.keepWorkspace {
            report(onUpdate, .staging, 0.02, "临时目录：\(workspace.root.path)")
        }
        report(onUpdate, .staging, 0.02, "正在整理 \(request.items.count) 个项目…")

        // 兼容性规则跟着实际用的引擎走：预检、自动重命名、最终映像三者用同一份规则。
        var stageOptions = request.stageOptions
        stageOptions.nameRules = engine.nameRules(for: request.imageOptions)
        let entries = try workspace.stage(items: request.items, options: stageOptions) { done, total, name in
            let fraction = total == 0 ? 0 : Double(done) / Double(total)
            self.report(
                onUpdate,
                .staging,
                0.02 + 0.10 * fraction,
                "已整理 \(done)/\(total)：\(name)",
                log: "+ \(name)"
            )
        }
        let renames = entries.flatMap { $0.renames }
        if !renames.isEmpty {
            var logText = ""
            for rename in renames.prefix(100) {
                logText += "✎ \(rename.oldRelativePath) → \(rename.newRelativePath)\n"
            }
            if renames.count > 100 {
                logText += "…（还有 \(renames.count - 100) 个改名未列出）\n"
            }
            report(
                onUpdate,
                .staging,
                0.12,
                "已自动重命名 \(renames.count) 个名字以兼容 Windows / Linux（源文件未改动）",
                log: logText.trimmingCharacters(in: .newlines)
            )
        }
        let payloadBytes = entries.reduce(Int64(0)) { $0 + $1.byteCount }
        report(onUpdate, .staging, 0.12, "内容大小 \(ByteText.human(payloadBytes))")
        try checkCancelled()

        // 再查一遍真正要刻的那些名字（自动重命名后这里通常已经干净了）。
        let stagedCheck = CompatibilityChecker.scan(
            items: entries.map { $0.destination },
            rules: stageOptions.nameRules
        )
        if !stagedCheck.isPerfect {
            report(onUpdate, .staging, 0.13, stagedCheck.logSummary)
            for issue in stagedCheck.issues(atLeast: .warning).prefix(20) {
                self.report(
                    onUpdate,
                    .staging,
                    0.13,
                    stagedCheck.logSummary,
                    log: "· [\(issue.category.localizedName)] \(issue.relativePath ?? "整张盘")：\(issue.message)"
                )
            }
        }

        // 估算映像大小并检查光盘容量
        var imageOptions = request.imageOptions
        imageOptions.volumeName = ImageBuilder.normalizeVolumeName(request.volumeName)
        var estimated = payloadBytes
        if let printed = try? engine.estimatedBytes(
            source: workspace.staging,
            options: imageOptions,
            graft: appendPlan?.target,
            canceller: canceller
        ), printed > 0 {
            estimated = printed
        }
        if let capacity = status.writableBytes, estimated > capacity, !request.force {
            throw BurnError.capacityExceeded(required: estimated, available: capacity)
        }

        let imageURL: URL
        let temporaryImage = request.imageOnlyURL == nil
        if let output = request.imageOnlyURL {
            imageURL = output
        } else {
            let name = ImageBuilder.normalizeVolumeName(request.volumeName).replacingOccurrences(of: " ", with: "_")
            imageURL = workspace.root.appendingPathComponent("\(name).iso")
        }
        let localSpace = Workspace.availableSpace(at: workspace.root) ?? Int64.max
        if localSpace < estimated + 64 * 1024 * 1024 {
            throw WorkspaceError.notEnoughDiskSpace(required: estimated, available: localSpace)
        }

        let mergeNote = mergedSessions > 0 ? "，合并盘上已有 \(mergedSessions) 段内容" : ""
        report(
            onUpdate,
            .buildingImage,
            0.15,
            "正在生成光盘映像（\(engine.localizedSummary)\(mergeNote)，卷标 \(imageOptions.volumeName)）…"
        )
        try buildImage(
            engine: engine,
            staging: workspace.staging,
            imageURL: imageURL,
            imageOptions: imageOptions,
            plan: appendPlan,
            workspace: workspace,
            canceller: canceller,
            onUpdate: onUpdate
        )
        return PreparedImage(
            imageURL: imageURL,
            payloadBytes: payloadBytes,
            keepImage: !temporaryImage,
            fileCount: Workspace.fileCount(of: workspace.staging),
            filesystem: engine.localizedSummary
        )
    }

    /// 一次追加刻录需要知道的两件事：盘的区段布局，以及把新段嫁接到哪儿。
    struct AppendPlan {
        var layout: DiscLayout
        var target: AppendTarget
    }

    /// 这次要不要「接在已有区段后面写」；需要嫁接时返回旧段信息。
    ///
    /// 只有盘上确实已经有内容时才需要：空盘（或先擦盘）就是普通的单段刻录。
    private func resolveAppendPlan(
        status: DiscStatus,
        engine: DataImageEngine,
        onUpdate: @escaping (JobUpdate) -> Void
    ) throws -> AppendPlan? {
        // 只生成映像、或者这次会先擦盘，都按「从零开始」处理。
        guard request.imageOnlyURL == nil, !request.burnOptions.eraseFirst else { return nil }
        // 只有「可追加写入」的盘才需要嫁接：空白盘、刚擦过的盘都属于从零开始。
        guard Multisession.needsGraft(status: status, eraseFirst: request.burnOptions.eraseFirst) else { return nil }
        let reported = status.sessions ?? 0

        let layout = (try? Multisession.layout(driveIndex: request.burnOptions.driveIndex)) ?? .empty
        guard !layout.isEmpty,
              let lastStart = layout.lastSessionStart,
              let next = layout.nextWritableAddress,
              next > lastStart else {
            throw MultisessionError.appendUnsupported(
                reason: "这张盘上已经有 \(reported) 段内容，但读不到区段起始 / 下一个可写地址，"
                    + "无法安全地把新内容接上去。请换一张空盘重试。"
            )
        }
        guard engine.supportsMultisessionAppend else { throw BurnError.appendNeedsIsoTool }
        if let device = status.deviceNode,
           Multisession.chainState(deviceNode: device, layout: layout) == .broken {
            throw BurnError.appendIncompatibleDisc(sessions: layout.recordedSessions)
        }
        guard let device = status.deviceNode, !device.isEmpty else {
            throw MultisessionError.appendUnsupported(reason: "拿不到光盘设备节点，无法把新内容嫁接到已有区段上。")
        }
        report(
            onUpdate,
            .checking,
            0.1,
            "追加刻录：新内容会接在第 \(layout.recordedSessions + 1) 段（合并盘上已有 "
                + "\(layout.recordedSessions) 段内容，从扇区 \(next) 开始写）"
        )
        // 记下旧段里有多少文件：嫁接完要能在新段里找到它们，否则等于白刻。
        let oldFiles = Multisession.fileCount(deviceNode: device, sessionStart: lastStart) ?? 0
        if oldFiles > 0 {
            report(onUpdate, .checking, 0.11, "盘上旧段里有 \(oldFiles) 个文件，刻完会一起出现在新段的目录树里")
        }
        return AppendPlan(
            layout: layout,
            target: AppendTarget(
                devicePath: device,
                lastSessionStart: lastStart,
                nextWritableAddress: next,
                oldFileCount: oldFiles
            )
        )
    }

    /// 生成映像：没有旧段就普通生成；有旧段就嫁接，并且刻之前先验一遍。
    private func buildImage(
        engine: DataImageEngine,
        staging: URL,
        imageURL: URL,
        imageOptions: ImageOptions,
        plan: AppendPlan?,
        workspace: Workspace,
        canceller: CommandCanceller?,
        onUpdate: @escaping (JobUpdate) -> Void
    ) throws {
        func run(_ target: AppendTarget?) throws {
            try engine.buildImage(
                source: staging,
                outputURL: imageURL,
                options: imageOptions,
                graft: target,
                canceller: canceller
            ) { fraction in
                let percent = Int((fraction * 100).rounded())
                self.report(onUpdate, .buildingImage, self.scale(fraction, 0.15, 0.5), "正在生成光盘映像… \(percent)%")
            } onLog: { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                self.report(onUpdate, .buildingImage, 0.4, trimmed, log: trimmed)
            }
        }

        /// 嫁接完必须自己验一遍：根目录要用绝对地址，而且得真的引用到旧文件。
        func verify(_ target: AppendTarget?) throws {
            guard let target = target else { return }
            try Multisession.verifyGraft(
                imageURL: imageURL,
                nextWritableAddress: target.nextWritableAddress,
                expectedOldFiles: target.oldFileCount
            )
        }

        /// mkisofs 写 Joliet 名字只保留前 8 个字符，写坏的名字会带 NUL，这里顺手报出来。
        func reportBrokenJolietNames() {
            guard engine == .mkisofs, let reader = IsoImageReader(fileURL: imageURL) else { return }
            let broken = IsoTree.entries(in: reader).filter { $0.isJoliet && $0.name.contains("\0") }
            guard !broken.isEmpty else { return }
            let sample = broken.prefix(3).map { $0.name.replacingOccurrences(of: "\0", with: "") }.joined(separator: "、")
            report(
                onUpdate,
                .buildingImage,
                0.5,
                "⚠︎ mkisofs 把 \(broken.count) 个名字写坏了（例如 \(sample)），Windows 上会缺字；"
                    + "装 xorriso 就能修：\(Mkisofs.recommendedTool)",
                log: "⚠︎ mkisofs 的 Joliet 名字转换只保留前 8 个字符：\n" + broken.prefix(20).map { "· \($0.name)" }.joined(separator: "\n")
            )
        }

        guard let plan = plan else {
            try run(nil)
            reportBrokenJolietNames()
            return
        }

        var target = plan.target
        if target.isDevice {
            // 卷挂载着的话 xorriso 打不开块设备，先卸下来独占读盘（写盘本来也该独占）。
            if Multisession.unmount(deviceNode: target.devicePath) {
                self.unmountedDeviceNode = target.devicePath
                do {
                    try run(target)
                    try verify(target)
                    reportBrokenJolietNames()
                    return
                } catch {
                    report(
                        onUpdate,
                        .buildingImage,
                        0.16,
                        "直接读光驱失败，改成先把旧段按扇区拷成临时映像再嫁接…",
                        log: "· 直接读光驱失败：\(error.localizedDescription)"
                    )
                }
            }
        }

        // 兜底路线：自己做一张「只含旧段」的稀疏映像，让映像工具照着它嫁接。
        let graftImageURL = workspace.root.appendingPathComponent("旧段映像.iso")
        let layout = plan.layout
        try Multisession.sparseGraftImage(
            deviceNode: plan.target.devicePath,
            layout: layout,
            outputURL: graftImageURL
        ) { fraction in
            let percent = Int((fraction * 100).rounded())
            self.report(onUpdate, .buildingImage, self.scale(fraction, 0.15, 0.25), "正在读取盘上旧段… \(percent)%")
        }
        target = plan.target.usingImage(at: graftImageURL)
        try run(target)
        try verify(target)
        reportBrokenJolietNames()
    }

    private func cleanup() {
        guard !request.keepWorkspace else { return }
        workspace?.cleanup()
    }

    private func selectDrive(from drives: [OpticalDrive]) -> OpticalDrive? {
        if let index = request.burnOptions.driveIndex {
            return drives.first { $0.index == index } ?? drives.first
        }
        return drives.first
    }

    private func checkCancelled() throws {
        if canceller.isCancelled { throw ShellError.cancelled }
    }

    private func scale(_ value: Double?, _ low: Double, _ high: Double) -> Double? {
        guard let value = value else { return nil }
        return low + (high - low) * max(0, min(1, value))
    }

    private func report(
        _ handler: (JobUpdate) -> Void,
        _ phase: JobPhase,
        _ fraction: Double?,
        _ message: String,
        log: String? = nil
    ) {
        handler(JobUpdate(phase: phase, fraction: fraction, message: message, log: log))
    }

    /// 收尾时那句话：把「这张盘刻完还能不能继续追加」直接讲出来。
    ///
    /// 一次性介质（CD-R / DVD±R / BD-R）收尾是不可逆的，用户最需要知道的
    /// 就是这一次刻录有没有把盘关掉。
    private func finishedMessage(status: DiscStatus?) -> String {
        if request.burnOptions.testBurn { return "测试刻录完成" }
        guard let status = status, status.isPresent else {
            // 刻完读不到盘时，至少按这次用的参数说清楚有没有关盘。
            return request.burnOptions.closeDisc
                ? "刻录完成 · 已关闭光盘（之后无法再追加）"
                : "刻录完成 · 未关闭光盘，可继续追加"
        }
        if status.writability.canBurn {
            let free = status.writableBytes.map { "，还剩 \(ByteText.human($0))" } ?? ""
            return "刻录完成 · 光盘仍可继续追加\(free)"
        }
        if status.erasable || status.media.isRewritable {
            return "刻录完成 · 光盘已关闭，擦除后可重新使用"
        }
        return "刻录完成 · 光盘已关闭，之后无法再追加"
    }
}
