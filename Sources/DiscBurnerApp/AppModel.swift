import Foundation
import SwiftUI
import DiscBurnKit

struct FileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let isDirectory: Bool
    let byteCount: Int64
    /// 音乐 CD 模式下这条音轨的时长（秒）；数据光盘模式不用。
    var duration: TimeInterval = 0

    var name: String { url.lastPathComponent }
    var sizeText: String { isDirectory ? ByteText.human(byteCount) + "/" : ByteText.human(byteCount) }
    var durationText: String { duration > 0 ? AudioDisc.timeText(duration) : "—" }
}

enum FileSystemPreset: Int, CaseIterable, Identifiable {
    case universal
    case udfOnly

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .universal: return "通用数据光盘（推荐）"
        case .udfOnly: return "纯 UDF"
        }
    }

    var detail: String {
        switch self {
        case .universal: return "ISO 9660 + Joliet + Rock Ridge：Windows / macOS / Linux / 车机都能读，支持追加"
        case .udfOnly: return "UDF 1.02：适合超大文件与超长中文名，但不能追加（每次都得一次刻完）"
        }
    }

    var options: (includeISO: Bool, includeJoliet: Bool, includeUDF: Bool) {
        switch self {
        case .universal: return (true, true, true)
        case .udfOnly: return (false, false, true)
        }
    }
}

/// 点「开始刻录」之后先算出来的确认信息：待刻内容摘要 + 兼容性预检结果。
struct BurnPrep: Identifiable {
    let id = UUID()
    let report: CompatibilityReport
    let summary: String
    /// 音乐 CD 的确认单：不展示文件名兼容性（盘上没有文件名）。
    var isAudio: Bool = false

    var hasIssues: Bool { !report.isPerfect }
    var hasErrors: Bool { report.hasErrors }
}

/// 刻录速度的选择。默认「推荐」：按介质类型与驱动器上报的能力给一个稳妥值。
enum SpeedChoice: Hashable {
    case recommended
    case automatic
    case fixed(Int)

    /// 存 UserDefaults 用的整数：-1 推荐，0 自动，正数表示固定倍速。
    var storedValue: Int {
        switch self {
        case .recommended: return -1
        case .automatic: return 0
        case .fixed(let value): return value
        }
    }

    init(storedValue: Int) {
        switch storedValue {
        case -1: self = .recommended
        case 0: self = .automatic
        case let value: self = .fixed(value)
        }
    }
}

/// GUI 的全部状态与动作。
final class AppModel: ObservableObject {
    @Published var items: [FileItem] = []
    @Published var volumeName: String = AppModel.defaultVolumeName()
    /// 音乐 CD 模式下「刚才加了什么、跳过了什么」的一句话提示。
    @Published var audioSkipNotice: String?
    /// 刻数据光盘还是音乐 CD。两种盘的写盘方式完全不同，界面也跟着换一套说法。
    @Published var mode: DiscMode =
        DiscMode(rawValue: UserDefaults.standard.string(forKey: AppModel.discModeKey) ?? "") ?? .data {
        didSet {
            guard oldValue != mode else { return }
            if persistModeChanges {
                UserDefaults.standard.set(mode.rawValue, forKey: AppModel.discModeKey)
            }
            if mode == .audioCD {
                filterItemsToAudio()
            }
            scheduleCompatibilityScan()
        }
    }

    /// 截屏参数（`--demo-audio`）切模式时不写 UserDefaults，免得改掉用户真实的选择。
    var persistModeChanges = true
    @Published var preset: FileSystemPreset = .universal {
        didSet { scheduleCompatibilityScan() }
    }
    @Published var verify = true
    @Published var ejectWhenDone = true
    @Published var testBurn = false
    @Published var closeDisc = false
    @Published var excludeJunk = true
    /// 刻录速度：默认「推荐」（按介质给稳妥值），可以改成自动或指定倍速。
    @Published var speedChoice: SpeedChoice =
        SpeedChoice(storedValue: UserDefaults.standard.object(forKey: AppModel.speedChoiceKey) as? Int ?? -1) {
        didSet { UserDefaults.standard.set(speedChoice.storedValue, forKey: AppModel.speedChoiceKey) }
    }

    @Published var drives: [OpticalDrive] = []
    @Published var selectedDriveIndex: Int?
    @Published var status: DiscStatus = DiscStatus()
    @Published var statusError: String?
    /// 盘上已有区段的布局（追加刻录要靠它决定新段从哪开始写）。
    @Published var discLayout: DiscLayout = .empty
    /// 已有区段能不能被新段接上（旧版本刻的盘接不上）。
    @Published var discChainState: DiscChainState = .unknown

    @Published var phase: JobPhase = .idle
    @Published var taskFraction: Double?
    @Published var taskMessage: String = "准备就绪"
    @Published var logLines: [String] = []
    @Published var isBusy = false
    @Published var lastError: String?
    @Published var finishedMessage: String?

    /// BurnJob 最后一次上报的收尾说明（例如「刻录完成 · 光盘仍可继续追加，还剩 4.3 GiB」）。
    private var jobFinishMessage: String?

    @Published var showLog = false
    @Published var discContents: DiscContents?
    /// 按扇区读出来的「整盘内容」（多区段盘的每一段都在里面）。
    ///
    /// 系统只挂载多区段盘的其中一段，所以「光盘里已有的内容」栏优先显示这一份，
    /// 免得界面显示的内容和盘上真正有的内容对不上。读的是目录结构，不是文件内容，很快。
    @Published var discWholeContent: DiscContents?
    @Published var discWholeContentLoading = false
    /// 导出盘上内容到文件夹的进度（0...1，nil 表示没在导出）。
    @Published var discExportProgress: Double?
    @Published var discExportMessage: String?
    @Published var discContentsLoading = false
    @Published var discContentsError: String?
    @Published var showDiscContents = false
    /// 左栏顶部的「光盘里已有的内容」是否展开（记住上次的状态）。
    @Published var showDiscBrowser: Bool =
        (UserDefaults.standard.object(forKey: AppModel.showDiscBrowserKey) as? Bool) ?? true {
        didSet { UserDefaults.standard.set(showDiscBrowser, forKey: AppModel.showDiscBrowserKey) }
    }
    @Published var burnHistory: [BurnRecord] = []

    /// 兼容性预检结果（后台算，随文件列表变化自动更新）。
    @Published var compatibility: CompatibilityReport?
    @Published var compatibilityScanning = false
    @Published var showCompatibility = false
    @Published var burnPrep: BurnPrep?
    /// 设置面板（外观、版本号）是否打开。
    @Published var showSettings = false
    /// 外观：跟随系统 / 浅色 / 深色。选了就立刻生效，并且记住下次启动照旧。
    @Published var appearance: AppAppearance = AppAppearance.stored() {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: AppModel.appearanceKey)
            appearance.apply()
        }
    }
    /// 刻录时是否自动重命名不兼容的文件名（记住上次选择）。
    @Published var sanitizeNames: Bool = UserDefaults.standard.bool(forKey: AppModel.sanitizeNamesKey) {
        didSet { UserDefaults.standard.set(sanitizeNames, forKey: AppModel.sanitizeNamesKey) }
    }

    /// 往「已经有内容的盘」上刻的时候，是不是「整盘合并重刻」。
    ///
    /// 默认打开：追加刻录出来的盘，macOS / Linux 默认只看得到第一段（Windows 反而正常），
    /// 合并重刻才能保证三边看到的都是同一份完整内容。只对可重写介质有意义。
    @Published var mergeBeforeBurn: Bool =
        (UserDefaults.standard.object(forKey: AppModel.mergeBeforeBurnKey) as? Bool) ?? true {
        didSet { UserDefaults.standard.set(mergeBeforeBurn, forKey: AppModel.mergeBeforeBurnKey) }
    }

    static let sanitizeNamesKey = "DiscBurner.sanitizeNames"
    static let showDiscBrowserKey = "DiscBurner.showDiscBrowser"
    static let speedChoiceKey = "DiscBurner.speedChoice"
    static let appearanceKey = "DiscBurner.appearance"
    static let mergeBeforeBurnKey = "DiscBurner.mergeBeforeBurn"
    static let discModeKey = "DiscBurner.discMode"

    private var job: BurnJob?
    private var pollTimer: Timer?
    private var isRefreshing = false
    private var lastMediaFingerprint: String?
    private var compatibilityWorkItem: DispatchWorkItem?
    private var compatibilityGeneration = 0

    init() {
        // 清掉上次异常退出留下的暂存目录
        Workspace.purgeStale()
        startPolling()
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    deinit {
        pollTimer?.invalidate()
    }

    static func defaultVolumeName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return "DISC_\(formatter.string(from: Date()))"
    }

    // MARK: - 文件列表

    var totalBytes: Int64 {
        items.reduce(Int64(0)) { $0 + $1.byteCount }
    }

    var capacityBytes: Int64? {
        // 音乐 CD 按时间算容量，不按字节。
        mode == .audioCD ? nil : status.writableBytes
    }

    var isOverCapacity: Bool {
        if mode == .audioCD { return isAudioOverCapacity }
        guard let capacity = capacityBytes, capacity > 0 else { return false }
        return totalBytes > capacity
    }

    var usageFraction: Double {
        if mode == .audioCD { return audioUsageFraction }
        guard let capacity = capacityBytes, capacity > 0 else { return 0 }
        return min(1, Double(totalBytes) / Double(capacity))
    }

    // MARK: - 音乐 CD 的时长

    /// 所有音轨的时长合计。
    var audioTotalDuration: TimeInterval {
        items.reduce(0) { $0 + $1.duration }
    }

    /// 算上每轨前后 2 秒间隔后，这张盘要占用的时间。
    var audioRequiredSeconds: Double {
        guard !items.isEmpty else { return 0 }
        return audioTotalDuration + AudioDisc.gapSeconds * Double(items.count + 1)
    }

    var audioCapacitySeconds: Double { AudioDisc.capacitySeconds }
    var audioRemainingSeconds: Double { audioCapacitySeconds - audioRequiredSeconds }
    var isAudioOverCapacity: Bool {
        !items.isEmpty && audioRequiredSeconds > audioCapacitySeconds
    }

    var audioUsageFraction: Double {
        guard items.count > 0 else { return 0 }
        return min(1, audioRequiredSeconds / audioCapacitySeconds)
    }

    /// 转成 CD 音轨后的大致字节数（估刻录耗时、显示「要多少临时空间」用）。
    var audioPayloadBytes: Int64 {
        items.reduce(Int64(0)) { $0 + AudioDisc.pcmBytes(duration: $1.duration) }
    }

    /// 估算刻录耗时用的字节数：数据盘是文件大小，音乐 CD 是转码后的音轨大小。
    var payloadBytesForEstimate: Int64 {
        mode == .audioCD ? audioPayloadBytes : totalBytes
    }

    /// 还有音轨的时长没读出来（`afinfo` 正在后台跑）。
    var audioDurationsPending: Bool {
        mode == .audioCD && items.contains { $0.duration <= 0 }
    }

    func add(urls: [URL]) {
        if mode == .audioCD {
            addAudio(urls: urls)
            return
        }
        var known = Set(items.map { $0.url.standardizedFileURL.path })
        var added: [FileItem] = []
        for url in urls {
            let standardized = url.standardizedFileURL
            guard !known.contains(standardized.path) else { continue }
            guard FileManager.default.fileExists(atPath: standardized.path) else { continue }
            let isDirectory = (try? standardized.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            known.insert(standardized.path)
            // 尺寸可能很耗时（大文件夹），先占位，随后在后台算。
            added.append(FileItem(url: standardized, isDirectory: isDirectory, byteCount: 0))
        }
        guard !added.isEmpty else { return }
        items.append(contentsOf: added)
        measureSizes(of: added)
        scheduleCompatibilityScan()
    }

    private func measureSizes(of added: [FileItem]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var measured: [UUID: Int64] = [:]
            for item in added {
                measured[item.id] = item.isDirectory
                    ? Workspace.size(of: item.url)
                    : Workspace.fileSize(of: item.url)
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.items = self.items.map { item in
                    guard let size = measured[item.id] else { return item }
                    return FileItem(url: item.url, isDirectory: item.isDirectory, byteCount: size)
                }
            }
        }
    }

    func remove(_ item: FileItem) {
        items.removeAll { $0.id == item.id }
        scheduleCompatibilityScan()
    }

    func clearItems() {
        items.removeAll()
        audioSkipNotice = nil
        scheduleCompatibilityScan()
    }

    // MARK: - 音乐 CD 的列表

    /// 音乐 CD 模式下的「添加」：文件夹摊平成音轨，非音频内容根本不进列表。
    ///
    /// 数据光盘是把文件夹原样刻进去，音乐 CD 没有「文件夹」这个东西——一张盘就是一条条音轨。
    /// 所以这里先把文件夹递归摊平，用户看到的列表顺序就是盘上的音轨顺序
    /// （暂存时按这个顺序加两位序号前缀，因为 `drutil burn -audio` 是按文件名字母序写的）。
    private func addAudio(urls: [URL]) {
        var known = Set(items.map { $0.url.standardizedFileURL.path })
        var added: [FileItem] = []
        var skipped: [String] = []
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let candidates: [URL]
            if isDirectory {
                candidates = AudioDisc.audioFiles(inDirectory: url)
                if candidates.isEmpty { skipped.append("\(url.lastPathComponent)（文件夹里没有音频）") }
            } else if AudioDisc.isAudioFile(url) {
                candidates = [url]
            } else {
                skipped.append(url.lastPathComponent)
                continue
            }
            for candidate in candidates {
                let standardized = candidate.standardizedFileURL
                guard !known.contains(standardized.path) else { continue }
                known.insert(standardized.path)
                added.append(FileItem(
                    url: standardized,
                    isDirectory: false,
                    byteCount: Workspace.fileSize(of: standardized)
                ))
            }
        }
        audioSkipNotice = skipped.isEmpty ? nil : audioSkipSummary(skipped)
        guard !added.isEmpty else { return }
        items.append(contentsOf: added)
        measureDurations(of: added)
    }

    private func audioSkipSummary(_ skipped: [String]) -> String {
        let head = skipped.prefix(3).joined(separator: "、")
        let tail = skipped.count > 3 ? " 等 \(skipped.count) 个" : ""
        return "音乐 CD 只收音频文件，已跳过：\(head)\(tail)"
    }

    /// 读每条音轨的时长（`afinfo` 很轻，一条几十毫秒）。
    private func measureDurations(of added: [FileItem]) {
        guard !added.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var measured: [UUID: TimeInterval] = [:]
            for item in added {
                measured[item.id] = (try? AudioDisc.info(for: item.url))?.duration ?? 0
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.items = self.items.map { item in
                    guard let duration = measured[item.id] else { return item }
                    var updated = item
                    updated.duration = duration
                    return updated
                }
            }
        }
    }

    /// 从数据光盘切到音乐 CD 时，把列表里不是音频的内容摊平/去掉。
    private func filterItemsToAudio() {
        var known = Set<String>()
        var result: [FileItem] = []
        for item in items {
            let candidates = item.isDirectory ? AudioDisc.audioFiles(inDirectory: item.url) : [item.url]
            for candidate in candidates {
                let standardized = candidate.standardizedFileURL
                guard AudioDisc.isAudioFile(standardized) else { continue }
                guard !known.contains(standardized.path) else { continue }
                known.insert(standardized.path)
                result.append(FileItem(
                    url: standardized,
                    isDirectory: false,
                    byteCount: Workspace.fileSize(of: standardized)
                ))
            }
        }
        let removed = items.count - result.count
        items = result
        measureDurations(of: result)
        if removed > 0 {
            audioSkipNotice = "切到音乐 CD 后去掉了 \(removed) 个不是音频的项目"
        }
    }

    // MARK: - 兼容性预检

    private var imageOptions: ImageOptions {
        let fs = preset.options
        return ImageOptions(
            volumeName: ImageBuilder.normalizeVolumeName(volumeName),
            includeISO9660: fs.includeISO,
            includeJoliet: fs.includeJoliet,
            includeUDF: fs.includeUDF,
            udfVersion: "1.02"
        )
    }

    /// 这次会用哪套引擎：优先 xorriso（多区段嫁接 + 正确的 Joliet 中文名），
    /// 没装就退到 mkisofs，「纯 UDF」预设只能用系统自带工具。
    var imageEngine: DataImageEngine { DataImageEngine.preferred(for: imageOptions) }

    /// 命名规则必须和真正用的引擎一致（预检、自动重命名、刻进去的名字）。
    var nameRules: NameRules { imageEngine.nameRules(for: imageOptions) }

    /// 「刻录选项」里显示的文件系统。
    var filesystemSummary: String {
        "\(imageEngine.localizedSummary)（\(imageEngine.toolName)）"
    }

    enum BurnNoticeLevel { case info, warning, error }

    /// 「整盘合并重刻」这次用不用得上：盘上已经有内容，而且这张盘擦得掉。
    ///
    /// 「盘上已经有内容」必须用 `Multisession.needsGraft` 判断，不能看段数——
    /// 空白盘的 `discinfo` 也会写 `Sessions: 1`（那条空白轨道）。
    var canMergeBeforeBurn: Bool {
        guard mode == .data else { return false }
        guard status.isPresent, Multisession.needsGraft(status: status) else { return false }
        return demoRewritable || status.erasable || status.media.isRewritable
    }

    /// 截屏 / 排错用：把「这张盘可重写」当成真的（`--demo-rewritable`）。
    /// 只影响界面上的判断，不会去擦任何盘。
    var demoRewritable = false

    /// 这次刻录会不会走「整盘合并重刻」。
    var willMergeWholeDisc: Bool { mergeBeforeBurn && canMergeBeforeBurn }

    /// Linux 上要读「第一段以外」的区段，只能自己指定段起始扇区。
    ///
    /// Linux 内核的 isofs 靠光驱回应的 TOC 判断「最后一段从哪开始」，很多 USB 光驱对
    /// DVD+R 这类介质只回一条轨道，内核就退回第一段——盘上数据没坏，是读的一方挑错了段。
    var linuxMountCommand: String? {
        guard let start = discLayout.lastSessionStart else { return nil }
        return "sudo mount -t iso9660 -o ro,sbsector=\(start) /dev/sr0 /mnt"
    }

    /// 追加刻录这一行的说明：会不会合并旧内容、缺不缺工具、旧盘兼不兼容。
    var appendNotice: (text: String, level: BurnNoticeLevel)? {
        // 音乐 CD 不能追加：盘上有内容时，这条提示取代「追加 / 合并」那一套说法。
        if mode == .audioCD {
            guard status.isPresent, Multisession.needsGraft(status: status) else { return nil }
            if status.erasable || status.media.isRewritable {
                return ("音乐 CD 不能追加刻录：刻录前会先擦除这张盘，然后再写音轨。", .warning)
            }
            return ("这张 \(status.media.displayName) 上已经有内容，而音乐 CD 不能追加刻录。"
                + "请换一张空白 CD-R，或用可重写的 CD-RW 擦除后再刻。", .error)
        }
        // 只有「盘上已经有内容、还能接着写」才有追加这回事：空白盘（哪怕是可重写盘）段数是 1，
        // 但那是空白轨道，不是已有内容。
        guard status.isPresent, Multisession.needsGraft(status: status) else { return nil }
        let sessions = status.sessions ?? discLayout.recordedSessions
        if closeDisc {
            return ("这次会关闭光盘：刻完之后不能再往这张盘里加内容。", .info)
        }
        // 合并重刻不嫁接，所以「读不到区段」「工具不支持嫁接」这些限制都不适用。
        if willMergeWholeDisc {
            let sizeHint = discWholeContent.map { "（盘上约 \(ByteText.human($0.totalBytes))）" } ?? ""
            return (
                "整盘合并重刻：先把盘上已有的 \(sessions) 段内容\(sizeHint)读出来，和这次要刻的合成一份，"
                    + "擦掉盘再单段刻完。Windows / macOS / Linux 看到的都是这一份完整内容。"
                    + "\n代价是慢：盘上内容要先整个读一遍，再整盘写一遍。",
                .info
            )
        }
        if discLayout.isEmpty {
            return ("盘上已经有 \(sessions) 段内容，但读不到区段信息，现在无法追加。", .warning)
        }
        if discChainState == .broken {
            return (
                "这张盘是用旧版本刻的（每段各自独立寻址），追加后旧段内容在 Windows / Linux 上看不到；建议换一张空盘。",
                .error
            )
        }
        if imageEngine == .makehybrid {
            return ("追加刻录需要 xorriso（终端执行 \(Xorriso.installHint)）：系统自带的工具不会把新段嫁接给旧段。", .warning)
        }
        if imageEngine == .mkisofs {
            return (
                "能追加，但 mkisofs 的 Joliet 名字转换只保留前 8 个字符，长中文名在 Windows 上会缺字；"
                    + "执行 \(Mkisofs.recommendedTool) 换成 xorriso 就好了。",
                .warning
            )
        }
        var appendText =
            "追加模式：新内容接在第 \(discLayout.recordedSessions + 1) 段，合并盘上已有 "
            + "\(discLayout.recordedSessions) 段内容。"
        appendText += "\n⚠︎ 追加出来的盘 Windows 上正常，但 macOS / Linux 默认只看得到第一段（旧内容还在盘上，"
            + "只是读的一方挑了旧的那一段）。"
        if canMergeBeforeBurn {
            appendText += "\n勾上「整盘合并重刻」就能让三边都看到全部内容。"
        } else {
            appendText += "一次性介质擦不掉，只能换可重写介质（DVD±RW / BD-RE）合并重刻。"
        }
        if let command = linuxMountCommand {
            appendText += "\n在 Linux 上临时读全部内容：\(command)"
        }
        return (
            appendText,
            .warning
        )
    }

    /// 当前介质 + 驱动器能力 + 内容大小给出的速度建议。
    var speedAdvice: SpeedAdvice {
        // 音乐 CD 的建议跟数据盘不一样：老 CD 机对高倍速刻出来的音轨更挑，宁可慢一点。
        if mode == .audioCD {
            return SpeedAdvisor.audioAdvice(
                reportedSpeeds: status.writeSpeeds,
                trackCount: items.count
            )
        }
        return SpeedAdvisor.advise(
            media: status.media,
            reportedSpeeds: status.writeSpeeds,
            payloadBytes: totalBytes
        )
    }

    /// 真正传给刻录命令的倍速；nil 表示交给系统自动选。
    var effectiveSpeed: Int? {
        switch speedChoice {
        case .recommended:
            // 没插盘时没有介质信息，这时交给系统自动选。
            return status.isPresent ? speedAdvice.recommended : nil
        case .automatic:
            return nil
        case .fixed(let value):
            return value > 0 ? value : nil
        }
    }

    /// 速度选择下面那行说明。
    var speedExplanation: String {
        let advice = speedAdvice
        switch speedChoice {
        case .recommended:
            guard let recommended = advice.recommended else { return advice.reason }
            var text = "推荐 \(recommended)x · \(advice.reason)"
            if payloadBytesForEstimate > 0, status.isPresent {
                let seconds = SpeedAdvisor.estimateDuration(
                    payloadBytes: payloadBytesForEstimate,
                    speed: recommended,
                    media: status.media
                )
                text += "，约 \(SpeedAdvisor.durationText(seconds))（不含校验）"
            }
            if let hint = advice.hint { text += "\n" + hint }
            return text
        case .automatic:
            var text = "由驱动器自己选（通常是它能跑的最高倍速）。\(advice.reason)"
            if let recommended = advice.recommended {
                text += " 保守起见推荐 \(recommended)x。"
            }
            return text
        case .fixed(let value):
            var text = "手动指定 \(value)x"
            if payloadBytesForEstimate > 0, status.isPresent {
                let seconds = SpeedAdvisor.estimateDuration(
                    payloadBytes: payloadBytesForEstimate,
                    speed: value,
                    media: status.media
                )
                text += "，约 \(SpeedAdvisor.durationText(seconds))（不含校验）"
            }
            if let caution = advice.caution(for: value) { text += "\n⚠︎ " + caution }
            return text
        }
    }

    var speedExplanationIsWarning: Bool {
        if case .fixed(let value) = speedChoice {
            return speedAdvice.caution(for: value) != nil
        }
        return false
    }

    /// 文件列表改动后延迟一小会儿再扫，避免连续拖入时反复扫描。
    func scheduleCompatibilityScan(delay: TimeInterval = 0.6) {
        compatibilityWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runCompatibilityScan() }
        compatibilityWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func runCompatibilityScan(reveal: Bool = false) {
        // 音乐 CD 的盘上没有文件名，这一步对它没有意义：清掉旧结果就行。
        guard mode == .data else {
            compatibility = nil
            compatibilityScanning = false
            if reveal { showCompatibility = false }
            return
        }
        let urls = items.map { $0.url }
        guard !urls.isEmpty else {
            compatibility = nil
            compatibilityScanning = false
            if reveal { showCompatibility = false }
            return
        }
        let rules = nameRules
        compatibilityScanning = true
        compatibilityGeneration += 1
        let generation = compatibilityGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = CompatibilityChecker.scan(items: urls, rules: rules)
            DispatchQueue.main.async {
                guard let self = self, self.compatibilityGeneration == generation else { return }
                self.compatibilityScanning = false
                self.compatibility = report
                if reveal { self.showCompatibility = true }
            }
        }
    }

    /// 「开始刻录」第一步：先扫一遍兼容性，再把确认单交给界面。
    func prepareBurn() {
        guard !items.isEmpty else { return }
        // 音乐 CD 的盘上没有文件名，兼容性预检（Windows 非法字符 / 大小写冲突 / 超长名）
        // 跟它没关系，直接给确认单。
        if mode == .audioCD {
            var report = CompatibilityReport()
            report.fileCount = items.count
            report.totalBytes = audioPayloadBytes
            burnPrep = BurnPrep(report: report, summary: burnSummary(), isAudio: true)
            return
        }
        let urls = items.map { $0.url }
        let rules = nameRules
        let summary = burnSummary()
        compatibilityScanning = true
        compatibilityGeneration += 1
        let generation = compatibilityGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = CompatibilityChecker.scan(items: urls, rules: rules)
            DispatchQueue.main.async {
                guard let self = self, self.compatibilityGeneration == generation else { return }
                self.compatibilityScanning = false
                self.compatibility = report
                self.burnPrep = BurnPrep(report: report, summary: summary)
            }
        }
    }

    func burnSummary() -> String {
        if mode == .audioCD {
            return audioBurnSummary()
        }
        let size = ByteText.human(totalBytes)
        let media = status.isPresent ? status.media.displayName : "未知介质"
        var text = "把 \(items.count) 个项目（\(size)）刻录到 \(media)，卷标「\(volumeName)」。"
        if willMergeWholeDisc {
            text += "\n追加方式：整盘合并重刻——先读盘上已有内容，擦除后单段刻完（Windows / macOS / Linux 都能看到全部内容）。"
        } else if status.isPresent, Multisession.needsGraft(status: status) {
            let sessions = status.sessions ?? discLayout.recordedSessions
            text += "\n追加方式：追加写入第 \(sessions + 1) 段（macOS / Linux 默认只看得到第一段）。"
        }
        text += "\n刻录速度：\(speedSummaryLine)"
        if testBurn { text += "\n测试模式不会写入介质，只验证流程。" }
        return text
    }

    /// 音乐 CD 的确认单：按时间说话，不按字节。
    private func audioBurnSummary() -> String {
        let media = status.isPresent ? status.media.displayName : "未知介质"
        var text = "把 \(items.count) 条音轨（合计 \(AudioDisc.timeText(audioTotalDuration))）"
            + "刻成音乐 CD，写到 \(media)。"
        text += "\n算上每轨 2 秒间隔占 \(AudioDisc.timeText(audioRequiredSeconds))，"
            + "一张 CD 有 \(AudioDisc.timeText(audioCapacitySeconds))。"
        text += "\n盘上没有文件系统：电脑看不到「文件」，用 CD 机 / 车载音响 / DVD 播放机放。"
        if status.isPresent, Multisession.needsGraft(status: status) {
            text += "\n⚠︎ 这张盘上已经有内容，而音乐 CD 不能追加：刻录前会先擦除这张盘。"
        }
        text += "\n刻录速度：\(speedSummaryLine)"
        if testBurn { text += "\n测试模式不会写入介质，只验证流程。" }
        return text
    }

    /// 确认单里的速度一行。
    var speedSummaryLine: String {
        guard let speed = effectiveSpeed else { return "自动（由驱动器选择）" }
        let estimated = status.isPresent
            ? SpeedAdvisor.estimateDuration(payloadBytes: payloadBytesForEstimate, speed: speed, media: status.media)
            : 0
        var text = "\(speed)x"
        if case .recommended = speedChoice { text += "（推荐）" }
        if estimated > 0 { text += "，预计约 \(SpeedAdvisor.durationText(estimated))（不含校验）" }
        if let caution = speedAdvice.caution(for: speed) { text += "\n⚠︎ " + caution }
        return text
    }

    // MARK: - 驱动器状态

    func refresh() {
        // drutil 要启动进程、访问光驱，放到后台线程做，避免界面卡顿。
        guard !isRefreshing else { return }
        isRefreshing = true
        let preferred = selectedDriveIndex
        // 判断旧段兼不兼容要读原始扇区，很费光驱；区段布局没变就沿用上次的结论。
        let previousChainKey = chainKey
        let previousChain = discChainState
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var drives: [OpticalDrive] = []
            var status = DiscStatus()
            var failure: String?
            var effectiveIndex: Int?
            var layout = DiscLayout.empty
            var chain = DiscChainState.unknown
            var newChainKey: String?
            do {
                drives = try DriveService.listDrives()
                let index = drives.contains(where: { $0.index == preferred }) ? preferred : drives.first?.index
                effectiveIndex = index
                if let index = index {
                    status = try DriveService.status(driveIndex: index)
                    if status.isPresent, (status.sessions ?? 0) > 0 {
                        layout = (try? Multisession.layout(driveIndex: index)) ?? .empty
                        if let device = status.deviceNode, !layout.isEmpty {
                            let key = Self.chainKey(for: device, layout: layout)
                            if key == previousChainKey {
                                chain = previousChain
                            } else {
                                chain = Multisession.chainState(deviceNode: device, layout: layout)
                                newChainKey = key
                            }
                        }
                    }
                }
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isRefreshing = false
                self.drives = drives
                self.selectedDriveIndex = effectiveIndex
                self.status = status
                self.discLayout = layout
                self.discChainState = chain
                if let key = newChainKey { self.chainKey = key }
                self.statusError = failure
                self.autoRefreshDiscContentsIfNeeded()
            }
        }
    }

    /// 「旧段可合并性」判据的缓存键：设备 + 区段布局，都没变就不用再读一次盘。
    private var chainKey: String?

    private static func chainKey(for device: String, layout: DiscLayout) -> String {
        "\(device)|\(layout.lastSessionStart ?? -1)|\(layout.nextWritableAddress ?? -1)|\(layout.recordedSessions)"
    }

    /// 换盘后自动读取内容——但只在系统已经挂载的情况下做，
    /// 免得每次轮询都去挂载/卸载光驱。
    private func autoRefreshDiscContentsIfNeeded() {
        let fingerprint = [
            status.deviceNode ?? "-",
            status.mediaID ?? "-",
            String(status.sessions ?? -1),
            status.media.rawValue,
        ].joined(separator: "|")
        guard fingerprint != lastMediaFingerprint else { return }
        lastMediaFingerprint = fingerprint
        discContents = nil
        discWholeContent = nil
        discContentsError = nil
        burnHistory = BurnHistory.records(mediaID: status.mediaID, limit: 10)
        guard status.isPresent else { return }
        loadDiscWholeContent()
        loadDiscContents(allowMount: false)
    }

    /// 按扇区读「整盘内容」（多区段盘的每一段都在里面）。
    ///
    /// 只在**换盘 / 刻完之后**读，不跟着 6 秒轮询走：原始设备读要光驱真去转盘，
    /// 这台 USB 光驱在这种持续读盘下容易掉总线，而且内容只有刻完才会变。
    func loadDiscWholeContent() {
        guard status.isPresent, discWholeContentLoading == false else { return }
        guard let device = status.deviceNode, !device.isEmpty, !discLayout.isEmpty else {
            discWholeContent = nil
            discWholeRaw = nil
            return
        }
        let media = status.media
        let mediaID = status.mediaID
        let layout = discLayout
        discWholeContentLoading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let raw = DiscContentReader.read(deviceNode: device, layout: layout)
            let whole = raw?.asDiscContents(
                source: device,
                media: media,
                mediaID: mediaID,
                sessionCount: layout.recordedSessions
            )
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.discWholeContentLoading = false
                self.discWholeRaw = raw
                self.discWholeContent = (whole?.entries.isEmpty == false) ? whole : nil
            }
        }
    }

    /// 导出时用的原始整盘内容（包含每个文件在盘上的扇区地址）。
    private var discWholeRaw: DiscContentView?

    /// 盘上内容能不能导出（读到了内容、而且没在刻录 / 导出）。
    var canExportDiscContents: Bool {
        discWholeRaw?.isEmpty == false && !isBusy && discExportProgress == nil
    }

    /// 弹「选择文件夹」，然后导出盘上内容。
    func chooseFolderAndExportDiscContents() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "导出到这里"
        panel.message = "会新建一个以卷标命名的文件夹，把盘上全部区段的内容放进去（访达里的那个卷只有第一段）。"
        if panel.runModal() == .OK, let url = panel.url {
            exportDiscContents(to: url)
        }
    }

    /// 把盘上已有的内容导出到一个文件夹，导出完在访达里选中它。
    ///
    /// 为什么需要这个：访达里的那个卷是**系统挂载**的结果，多区段盘上系统只挂第一段，
    /// 所以「应用里看得到、访达里看不到」是必然的——要拿到文件就得自己按扇区读出来再落盘。
    func exportDiscContents(to folder: URL) {
        guard !isBusy else {
            lastError = "正在刻录，等这一轮结束再导出。"
            return
        }
        guard let device = status.deviceNode, !device.isEmpty else {
            lastError = "没有可以读取的光盘设备。"
            return
        }
        guard let content = discWholeRaw, !content.isEmpty else {
            lastError = "还没读到盘上的内容，先点「重新读取」。"
            return
        }
        guard discExportProgress == nil else { return }

        // 导出到「以卷标命名的新文件夹」，别把用户选的位置弄乱。
        let rawName = discContents?.volumeName ?? status.media.displayName
        let base = ImageBuilder.normalizeVolumeName(rawName, fallback: "光盘内容")
        var destination = folder.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(base) \(suffix)", isDirectory: true)
            suffix += 1
        }

        discExportProgress = 0
        discExportMessage = "正在导出 \(content.fileCount) 个文件…"
        logLines.append("↓ 导出盘上内容到 \(destination.path)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: String?
            var summary: DiscExtractSummary?
            do {
                summary = try DiscContentReader.extract(
                    content,
                    deviceNode: device,
                    to: destination,
                    conflict: .replace
                ) { fraction in
                    DispatchQueue.main.async { self?.discExportProgress = fraction }
                }
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.discExportProgress = nil
                self.discExportMessage = nil
                if let failure = failure {
                    self.lastError = "导出失败：\(failure)"
                } else if let summary = summary {
                    self.finishedMessage = "已把盘上内容导出到：\n\(destination.path)\n"
                        + "\(summary.description)（含全部区段）"
                    // 直接在访达里选中刚导出的文件夹——盘上那些文件在访达里本来就不显示。
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            }
        }
    }

    /// 两个来源一起重读：按扇区读的整盘内容 + 系统挂载的那一段（拿卷标 / 文件系统名）。
    func reloadDiscContents() {
        loadDiscWholeContent()
        loadDiscContents(allowMount: false)
    }

    /// 读取光盘内容。
    ///
    /// - Parameter allowMount: 为 true 时，若系统没有自动挂载就临时挂载（读完自动弹出）。
    func loadDiscContents(allowMount: Bool) {
        guard let device = status.deviceNode, !discContentsLoading else { return }
        let media = status.media
        let mediaID = status.mediaID
        let sessions = status.sessions
        discContentsLoading = true
        if allowMount { discContentsError = nil }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var contents: DiscContents?
            var failure: String?
            do {
                contents = try DiscReader.readDevice(
                    device,
                    media: media,
                    mediaID: mediaID,
                    sessionCount: sessions,
                    allowMount: allowMount
                )
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.discContentsLoading = false
                if let contents = contents {
                    self.discContents = contents
                    self.discContentsError = nil
                } else if allowMount {
                    self.discContentsError = failure
                }
            }
        }
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !self.isBusy { self.refresh() }
        }
    }

    // MARK: - 刻录动作

    func buildRequest(imageOnlyURL: URL?) -> BurnRequest {
        let name = ImageBuilder.normalizeVolumeName(volumeName)
        let imageOptions = self.imageOptions
       let burnOptions = BurnOptions(
            driveIndex: selectedDriveIndex,
            speed: effectiveSpeed,
            verify: mode == .audioCD ? false : verify,
            ejectWhenDone: ejectWhenDone,
            testBurn: testBurn,
            closeDisc: mode == .audioCD ? true : closeDisc,
            eraseFirst: false,
            appendStrategy: mode == .data && willMergeWholeDisc ? .rewriteMerged : .graft
        )
        return BurnRequest(
            items: items.map { $0.url },
            volumeName: name,
            mode: mode,
            imageOptions: imageOptions,
            burnOptions: burnOptions,
            imageOnlyURL: imageOnlyURL,
            stageOptions: StageOptions(
                excludeJunkFiles: excludeJunk,
                namePolicy: sanitizeNames ? .sanitize : .keep,
                nameRules: imageOptions.nameRules
            ),
            force: false,
            keepWorkspace: false
        )
    }

    /// 开始刻录。`sanitize` 决定是否在刻录前自动重命名不兼容的文件名。
    func startBurn(sanitize: Bool) {
        guard !items.isEmpty else {
            lastError = BurnError.noItems.localizedDescription
            return
        }
        sanitizeNames = sanitize
        burnPrep = nil
        run(request: buildRequest(imageOnlyURL: nil))
    }

    func startMakeImage(at url: URL) {
        guard !items.isEmpty else {
            lastError = BurnError.noItems.localizedDescription
            return
        }
        run(request: buildRequest(imageOnlyURL: url))
    }

    func run(request: BurnRequest) {
        guard !isBusy else { return }
        // 导出和刻录都要独占读盘，别让两边同时动光驱。
        guard discExportProgress == nil else {
            lastError = "正在导出盘上内容，等导出结束再刻录。"
            return
        }
        isBusy = true
        phase = .checking
        taskFraction = 0
        taskMessage = "开始…"
        logLines.removeAll()
        lastError = nil
        finishedMessage = nil
        jobFinishMessage = nil
        let job = BurnJob(request: request)
        self.job = job

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var outcome: BurnOutcome?
            var failure: Error?
            do {
                outcome = try job.run { update in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.phase = update.phase
                        if let fraction = update.fraction { self.taskFraction = fraction }
                        if !update.message.isEmpty { self.taskMessage = update.message }
                        // 收尾那句话由 BurnJob 给出（「光盘仍可继续追加，还剩 X」之类），
                        // 先记下来，免得下面用笼统的「刻录完成」把它盖掉。
                        if update.phase == .finished, !update.message.isEmpty {
                            self.jobFinishMessage = update.message
                        }
                        if let log = update.log, !log.isEmpty {
                            self.logLines.append(log)
                            if self.logLines.count > 500 {
                                self.logLines.removeFirst(self.logLines.count - 500)
                            }
                        }
                    }
                }
            } catch {
                failure = error
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isBusy = false
                self.job = nil
                if let failure = failure {
                    if let shellError = failure as? ShellError, case .cancelled = shellError {
                        self.phase = .cancelled
                        self.taskMessage = "已取消"
                    } else {
                        self.phase = .failed
                        self.taskMessage = "失败"
                        self.lastError = failure.localizedDescription
                    }
                } else if let outcome = outcome {
                    self.phase = .finished
                    self.taskFraction = 1
                    let detail = self.jobFinishMessage
                        ?? (outcome.wasTestBurn ? "测试刻录完成" : "刻录完成")
                    // 耗时用 durationText，别写成「86 秒」这种要自己换算的说法。
                    let spent = SpeedAdvisor.durationText(outcome.duration)
                    if let image = outcome.imageURL {
                        self.taskMessage = "映像已生成 · 用时 \(spent)"
                        self.finishedMessage = "已生成光盘映像：\n\(image.path)\n"
                            + "大小 \(ByteText.human(outcome.payloadBytes))，用时 \(spent)。"
                    } else {
                        self.taskMessage = detail + " · 用时 \(spent)"
                        self.finishedMessage = detail + "。\n用时 \(spent)。"
                    }
                }
                self.refresh()
                // 刻完盘上内容就变了，等状态刷回来再按扇区重读一遍整盘内容。
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.loadDiscWholeContent()
                }
            }
        }
    }

    func cancel() {
        job?.cancel()
        taskMessage = "正在取消…"
    }

    // MARK: - 擦除 / 弹出

    func eraseDisc(mode: EraseMode) {
        guard let index = selectedDriveIndex, !isBusy, discExportProgress == nil else { return }
        isBusy = true
        phase = .erasing
        taskFraction = nil
        taskMessage = "正在擦除…"
        logLines.removeAll()
        lastError = nil
        finishedMessage = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: Error?
            do {
                try Burner.erase(mode: mode, driveIndex: index) { progress in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if let line = progress.rawLine, !line.isEmpty {
                            self.taskMessage = line
                            self.logLines.append(line)
                        }
                        self.taskFraction = progress.fraction
                    }
                }
            } catch {
                failure = error
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isBusy = false
                if let failure = failure {
                    self.phase = .failed
                    self.lastError = failure.localizedDescription
                } else {
                    self.phase = .finished
                    self.taskFraction = 1
                    self.taskMessage = "擦除完成"
                    self.finishedMessage = "光盘已擦除，可以重新刻录。"
                }
                self.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.loadDiscWholeContent()
                }
            }
        }
    }

    func eject() {
        guard let index = selectedDriveIndex else { return }
        do {
            try DriveService.eject(driveIndex: index)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
