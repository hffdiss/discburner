import Foundation
import SwiftUI
import DiscBurnKit

struct FileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let isDirectory: Bool
    let byteCount: Int64

    var name: String { url.lastPathComponent }
    var sizeText: String { isDirectory ? ByteText.human(byteCount) + "/" : ByteText.human(byteCount) }
}

enum FileSystemPreset: Int, CaseIterable, Identifiable {
    case universal
    case isoOnly
    case udfOnly

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .universal: return "通用数据光盘（推荐）"
        case .isoOnly: return "ISO 9660 + Joliet"
        case .udfOnly: return "纯 UDF"
        }
    }

    var detail: String {
        switch self {
        case .universal: return "ISO 9660 + Joliet + UDF 1.02，Windows / macOS / Linux / 车机都能读"
        case .isoOnly: return "最老式兼容，适合老设备和部分车载音响"
        case .udfOnly: return "适合大文件与超长中文名，部分老设备无法识别"
        }
    }

    var options: (includeISO: Bool, includeJoliet: Bool, includeUDF: Bool) {
        switch self {
        case .universal: return (true, true, true)
        case .isoOnly: return (true, true, false)
        case .udfOnly: return (false, false, true)
        }
    }
}

/// 点「开始刻录」之后先算出来的确认信息：待刻内容摘要 + 兼容性预检结果。
struct BurnPrep: Identifiable {
    let id = UUID()
    let report: CompatibilityReport
    let summary: String

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
    /// 刻录时是否自动重命名不兼容的文件名（记住上次选择）。
    @Published var sanitizeNames: Bool = UserDefaults.standard.bool(forKey: AppModel.sanitizeNamesKey) {
        didSet { UserDefaults.standard.set(sanitizeNames, forKey: AppModel.sanitizeNamesKey) }
    }

    static let sanitizeNamesKey = "DiscBurner.sanitizeNames"
    static let showDiscBrowserKey = "DiscBurner.showDiscBrowser"
    static let speedChoiceKey = "DiscBurner.speedChoice"

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
        status.writableBytes
    }

    var isOverCapacity: Bool {
        guard let capacity = capacityBytes, capacity > 0 else { return false }
        return totalBytes > capacity
    }

    var usageFraction: Double {
        guard let capacity = capacityBytes, capacity > 0 else { return 0 }
        return min(1, Double(totalBytes) / Double(capacity))
    }

    func add(urls: [URL]) {
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
        scheduleCompatibilityScan()
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

    var nameRules: NameRules { imageOptions.nameRules }

    /// 当前介质 + 驱动器能力 + 内容大小给出的速度建议。
    var speedAdvice: SpeedAdvice {
        SpeedAdvisor.advise(
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
            if totalBytes > 0, status.isPresent {
                let seconds = SpeedAdvisor.estimateDuration(
                    payloadBytes: totalBytes,
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
            if totalBytes > 0, status.isPresent {
                let seconds = SpeedAdvisor.estimateDuration(
                    payloadBytes: totalBytes,
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
        let size = ByteText.human(totalBytes)
        let media = status.isPresent ? status.media.displayName : "未知介质"
        let extra = testBurn ? "\n测试模式不会写入介质，只验证流程。" : ""
        return "把 \(items.count) 个项目（\(size)）刻录到 \(media)，卷标「\(volumeName)」。\n刻录速度：\(speedSummaryLine)\(extra)"
    }

    /// 确认单里的速度一行。
    var speedSummaryLine: String {
        guard let speed = effectiveSpeed else { return "自动（由驱动器选择）" }
        let estimated = status.isPresent
            ? SpeedAdvisor.estimateDuration(payloadBytes: totalBytes, speed: speed, media: status.media)
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
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var drives: [OpticalDrive] = []
            var status = DiscStatus()
            var failure: String?
            var effectiveIndex: Int?
            do {
                drives = try DriveService.listDrives()
                let index = drives.contains(where: { $0.index == preferred }) ? preferred : drives.first?.index
                effectiveIndex = index
                if let index = index {
                    status = try DriveService.status(driveIndex: index)
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
                self.statusError = failure
                self.autoRefreshDiscContentsIfNeeded()
            }
        }
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
        discContentsError = nil
        burnHistory = BurnHistory.records(mediaID: status.mediaID, limit: 10)
        guard status.isPresent else { return }
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
            verify: verify,
            ejectWhenDone: ejectWhenDone,
            testBurn: testBurn,
            closeDisc: closeDisc,
            eraseFirst: false
        )
        return BurnRequest(
            items: items.map { $0.url },
            volumeName: name,
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
                    if let image = outcome.imageURL {
                        self.taskMessage = "映像已生成"
                        self.finishedMessage = "已生成光盘映像：\n\(image.path)\n大小 \(ByteText.human(outcome.payloadBytes))"
                    } else {
                        self.taskMessage = detail
                        self.finishedMessage = detail + "。\n用时 " +
                            String(format: "%.0f", outcome.duration) + " 秒。"
                    }
                }
                self.refresh()
            }
        }
    }

    func cancel() {
        job?.cancel()
        taskMessage = "正在取消…"
    }

    // MARK: - 擦除 / 弹出

    func eraseDisc(mode: EraseMode) {
        guard let index = selectedDriveIndex, !isBusy else { return }
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
