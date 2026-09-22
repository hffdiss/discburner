import Foundation

/// DVD-Video 的画面制式。
///
/// DVD-Video 只有两种标准分辨率：PAL 720×576（25 帧）、NTSC 720×480（29.97 帧）。
/// 别的尺寸（1080p、720p、竖屏手机视频……）都得先转成这两种之一。
public enum VideoStandard: String, CaseIterable, Identifiable, Hashable {
    case pal
    case ntsc

    public var id: String { rawValue }

    public var localizedName: String { self == .pal ? "PAL" : "NTSC" }

    public var detail: String {
        switch self {
        case .pal:
            return "25 帧 / 576 行：中国大陆、香港、欧洲、澳洲的电视制式"
        case .ntsc:
            return "29.97 帧 / 480 行：美国、日本、台湾地区用的制式"
        }
    }

    /// 720×576（PAL）还是 720×480（NTSC）。
    public var width: Int { 720 }
    public var height: Int { self == .pal ? 576 : 480 }

    /// 交给 ffmpeg 的帧率参数。
    public var frameRateArgument: String { self == .pal ? "25" : "30000/1001" }

    public var frameRateText: String { self == .pal ? "25 fps" : "29.97 fps" }

    /// GOP 长度。DVD 规范允许 PAL 最多 15 帧、NTSC 最多 18 帧一个 GOP。
    public var gopSize: Int { self == .pal ? 15 : 18 }

    /// 16:9 时每个像素的长宽比（PAL 64:45、NTSC 40:33）。
    public var widescreenSampleAspect: String { self == .pal ? "64/45" : "40/33" }

    /// 4:3 时每个像素的长宽比（PAL 16:15、NTSC 10:11）。
    public var standardSampleAspect: String { self == .pal ? "16/15" : "10/11" }

    public func sampleAspect(widescreen: Bool) -> String {
        widescreen ? widescreenSampleAspect : standardSampleAspect
    }

    /// 换算成「方形像素」后这一档画布有多宽：16:9 的 PAL 是 1024×576，4:3 是 768×576。
    ///
    /// 转码时先把原始画面按这个画布等比缩放 + 补黑边（保比例、不裁切），
    /// 再压成 720×576 并标上像素长宽比，播放机就会把它拉回正确的形状。
    public func squarePixelWidth(widescreen: Bool) -> Int {
        let ratio: Double
        switch (self, widescreen) {
        case (.pal, true): ratio = 64.0 / 45
        case (.pal, false): ratio = 16.0 / 15
        case (.ntsc, true): ratio = 40.0 / 33
        case (.ntsc, false): ratio = 10.0 / 11
        }
        return Int((Double(width) * ratio).rounded())
    }
}

/// 一个视频源文件的探测结果（来自 `ffprobe`）。
public struct VideoFileInfo: Hashable {
    public let duration: TimeInterval
    public let width: Int
    public let height: Int
    public let hasAudio: Bool
    /// 显示宽高比（`display_aspect_ratio`，已经算上旋转与像素长宽比）。
    public let displayAspect: Double
    /// 隔行扫描的话是 `tt` / `bb` 这类标记，逐行一般是 `progressive` 或 `unknown`。
    public let fieldOrder: String?

    public init(
        duration: TimeInterval,
        width: Int,
        height: Int,
        hasAudio: Bool,
        displayAspect: Double,
        fieldOrder: String? = nil
    ) {
        self.duration = duration
        self.width = width
        self.height = height
        self.hasAudio = hasAudio
        self.displayAspect = displayAspect
        self.fieldOrder = fieldOrder
    }

    /// 需不需要先反交错。逐行素材硬套反交错只会变糊，所以先看 `ffprobe` 怎么说。
    public var isInterlaced: Bool {
        guard let field = fieldOrder?.lowercased() else { return false }
        return ["tt", "bb", "tb", "bt"].contains(field)
    }

    /// 宽屏（16:9）还是标准（4:3）。1.5 是个经验分界：1.66 / 1.78 都算宽屏。
    public var isWidescreen: Bool { displayAspect >= 1.5 }
}

/// 一条准备写进 DVD-Video 的节目。
public struct VideoSource: Identifiable, Hashable {
    /// 节目号，从 1 开始（也就是 DVD 的 title 号）。
    public let id: Int
    public let sourceURL: URL
    /// 显示名（文件名去掉扩展名，清理过控制字符）。
    public let title: String
    public let duration: TimeInterval
    public let width: Int
    public let height: Int
    public let hasAudio: Bool
    public let isWidescreen: Bool
    public let isInterlaced: Bool
    /// 源文件字节数（界面里显示用）。
    public let sourceBytes: Int64

    public init(
        id: Int,
        sourceURL: URL,
        title: String,
        duration: TimeInterval,
        width: Int,
        height: Int,
        hasAudio: Bool,
        isWidescreen: Bool,
        isInterlaced: Bool = false,
        sourceBytes: Int64
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.title = title
        self.duration = duration
        self.width = width
        self.height = height
        self.hasAudio = hasAudio
        self.isWidescreen = isWidescreen
        self.isInterlaced = isInterlaced
        self.sourceBytes = sourceBytes
    }

    /// 暂存目录里的文件名。两位序号前缀让 `--keep` 留下来的临时目录一眼能看懂顺序。
    public var stagedName: String {
        String(format: "%02d - %@.mpg", id, VideoDVD.safeFileName(title))
    }

    public var durationText: String { AudioDisc.timeText(duration) }
    public var resolutionText: String { "\(width)×\(height)" }
    public var sourceSizeText: String { ByteText.human(sourceBytes) }
    /// 「1280×720 · 16:9 · 有声音」这种一句话说明。
    public var formatSummary: String {
        var parts = [resolutionText, isWidescreen ? "16:9" : "4:3"]
        parts.append(hasAudio ? "有声音" : "无音轨（会补静音）")
        if isInterlaced { parts.append("隔行，会反交错") }
        return parts.joined(separator: " · ")
    }
}

/// 被跳过的文件（不是视频、读不出信息等）。
public struct VideoSkip: Hashable {
    public let url: URL
    public let reason: String

    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }

    public var displayName: String { url.lastPathComponent }
}

/// 一张 DVD-Video 的排布计划。
public struct VideoDVDPlan {
    public var sources: [VideoSource]
    public var skipped: [VideoSkip]
    public var standard: VideoStandard
    /// 这张盘能用的字节数。
    public var capacityBytes: Int64
    /// 整张盘统一的画面比例（一个 VTS 只能有一种比例）。
    public var widescreen: Bool
    /// 视频码率（kbps）；0 表示连最低码率都塞不下。
    public var videoBitrateKbps: Int

    public init(
        sources: [VideoSource],
        skipped: [VideoSkip] = [],
        standard: VideoStandard = .pal,
        capacityBytes: Int64 = VideoDVD.defaultCapacityBytes,
        widescreen: Bool,
        videoBitrateKbps: Int
    ) {
        self.sources = sources
        self.skipped = skipped
        self.standard = standard
        self.capacityBytes = capacityBytes
        self.widescreen = widescreen
        self.videoBitrateKbps = videoBitrateKbps
    }

    public var totalDuration: TimeInterval {
        sources.reduce(0) { $0 + $1.duration }
    }

    public var titleCount: Int { sources.count }

    public var audioBitrateKbps: Int { VideoDVD.audioBitrateKbps }

    /// 转码 + 打包后预计占用的字节数。
    public var estimatedBytes: Int64 {
        VideoDVD.estimatedBytes(
            totalDuration: totalDuration,
            videoBitrateKbps: videoBitrateKbps,
            audioBitrateKbps: VideoDVD.audioBitrateKbps
        )
    }

    /// 本机临时目录要留的空间：编码产物 + IFO/BUP + 一点余量。
    public var stagedBytes: Int64 { estimatedBytes + VideoDVD.workspaceMarginBytes }

    public var remainingBytes: Int64 { capacityBytes - estimatedBytes }
    public var isOverCapacity: Bool {
        videoBitrateKbps <= 0 || estimatedBytes > capacityBytes
    }

    public var usageFraction: Double {
        guard capacityBytes > 0 else { return 0 }
        return min(1, Double(estimatedBytes) / Double(capacityBytes))
    }

    public var aspectText: String { widescreen ? "16:9" : "4:3" }

    /// 界面上那一行摘要。
    public var summary: String {
        "\(sources.count) 个节目 · 合计 \(AudioDisc.timeText(totalDuration)) · "
            + "\(standard.localizedName) \(standard.width)×\(standard.height) \(aspectText)"
    }

    /// 「码率 4.0 Mbps · 预计占 3.1 GiB / 4.38 GiB」。
    public var bitrateText: String {
        guard videoBitrateKbps > 0 else { return "装不下" }
        return String(format: "%.1f Mbps", Double(videoBitrateKbps) / 1000)
    }
}

public enum VideoDVDError: LocalizedError {
    case missingTool(name: String, hint: String)
    case noVideoFiles
    case requiresDVDMedia(String)
    case needsBlankDisc(sessions: Int, media: String)
    case overCapacity(required: Int64, available: Int64)
    case notEnoughSpace(required: Int64, available: Int64)
    case tooManyTitles(Int)
    case readFailed(name: String, detail: String)
    case encodeFailed(name: String, detail: String)
    case authorFailed(detail: String)
    case imageFailed(detail: String)

    public var errorDescription: String? {
        switch self {
        case .missingTool(let name, let hint):
            return "视频 DVD 要用 \(name) 把片子转成 DVD 格式，但找不到它。\n\(hint)"
        case .noVideoFiles:
            return "没有找到能刻成 DVD 的视频文件。支持的格式：MP4 / MOV / MKV / AVI / M4V / "
                + "MPEG / TS / M2TS / WMV / FLV / WebM / 3GP 等（能不能解码取决于 ffmpeg）。"
        case .requiresDVDMedia(let media):
            return "视频 DVD 要刻在 DVD 上，而现在这张是 \(media)：一张 CD 只装得下 700 MB，"
                + "放不下一部片子的 MPEG-2。请换一张 DVD±R / DVD±RW 空白盘。"
        case .needsBlankDisc(let sessions, let media):
            return "这张 \(media) 上已经有 \(sessions) 段内容，而视频 DVD 不能追加："
                + "播放机只认盘开头的 VIDEO_TS 目录，追加出来的分段它读不到。"
                + "\n请换一张空白 DVD±R，或用可重写的 DVD±RW / DVD-RAM 擦除后再刻。"
        case .overCapacity(let required, let available):
            return "按最低码率算也要 \(ByteText.human(required))，超过这张盘的 \(ByteText.human(available))。"
                + "\n请去掉几段视频，或者降低视频码率 / 分成两张盘刻。"
        case .notEnoughSpace(let required, let available):
            return "本机磁盘空间不足：转码需要一个约 \(ByteText.human(required)) 的临时目录，"
                + "当前可用 \(ByteText.human(available))。"
        case .tooManyTitles(let count):
            return "一张 DVD-Video 最多 99 个节目，现在有 \(count) 个。请合并成几段长一点的视频，或分成两张盘。"
        case .readFailed(let name, let detail):
            return "读不出 \(name) 的视频信息：\(detail)"
        case .encodeFailed(let name, let detail):
            return "把 \(name) 转成 DVD 格式失败：\(detail)"
        case .authorFailed(let detail):
            return "生成 VIDEO_TS 目录失败：\(detail)"
        case .imageFailed(let detail):
            return "生成 DVD 映像失败：\(detail)"
        }
    }
}

/// DVD-Video（VIDEO_TS）相关的常量、探测、排布与 XML 生成。
///
/// 一条完整的流水线是：
/// `ffprobe` 探测 → `ffmpeg` 转成 DVD 兼容的 MPEG-PS → `dvdauthor` 排成 VIDEO_TS →
/// `mkisofs -dvd-video`（或系统自带 `hdiutil makehybrid`）做成 UDF 1.02 映像 → `drutil` 写盘。
public enum VideoDVD {
    /// 单层 DVD 的扇区数（4.38 GiB）。
    public static let defaultCapacityBytes: Int64 = 2_298_496 * 2048
    /// 双层 DVD。
    public static let dualLayerCapacityBytes: Int64 = 4_171_712 * 2048

    /// 音频固定 MPEG-1 Layer II 192 kbps / 48 kHz / 立体声：DVD-Video 的老规格，
    /// 所有播放机都认，兼容性比 AC-3 好（AC-3 编码器不是每台机器的 ffmpeg 都带）。
    public static let audioBitrateKbps = 192

    /// 视频码率的上下限。低于 1.5 Mbps 的画面在大电视上没法看；
    /// 高于 8 Mbps 加上音频就顶到 DVD 的 10.08 Mbps 上限了。
    public static let minimumVideoBitrateKbps = 1500
    public static let maximumVideoBitrateKbps = 8000
    public static let defaultVideoBitrateKbps = 4000

    /// 算容量时留 6% 给 MPEG-PS 容器开销与文件系统。
    public static let capacitySafetyFraction = 0.94
    /// IFO / BUP / 文件系统这些零碎开销，固定按 1 MiB 算。
    public static let overheadBytes: Int64 = 1024 * 1024
    /// 临时目录额外多留一点（转码中会有中间文件）。
    public static let workspaceMarginBytes: Int64 = 256 * 1024 * 1024

    /// 每个节目隔多久打一个章节（秒）。5 分钟一个，遥控器上就能跳段了。
    public static let chapterSeconds: Double = 300

    /// 能当视频源收进来的扩展名。
    ///
    /// 这里不做「能不能解码」的判断——那由 ffmpeg 说了算；收进来但 ffmpeg 解不了的，
    /// 会出现在「已跳过」里并带上 ffmpeg 的原话。
    public static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "mkv", "avi", "mpg", "mpeg", "mpe", "m2v", "mpv",
        "vob", "ts", "m2ts", "mts", "trp", "wmv", "asf", "flv", "f4v", "webm",
        "3gp", "3g2", "ogv", "rm", "rmvb", "dv", "mxf", "y4m", "divx", "dat",
    ]

    // MARK: - 外部工具

    /// `ffprobe`：读时长与分辨率。
    public static var ffprobePath: String? { Shell.which("ffprobe") }
    /// `ffmpeg`：转码。
    public static var ffmpegPath: String? { Shell.which("ffmpeg") }
    /// `dvdauthor`：把 MPEG-PS 排成 VIDEO_TS。
    public static var dvdauthorPath: String? { Shell.which("dvdauthor") }

    /// 这套流水线能不能跑；缺工具时 `missing` 里是要装的东西。
    public static var missingTools: [String] {
        var missing: [String] = []
        if ffprobePath == nil { missing.append("ffprobe") }
        if ffmpegPath == nil { missing.append("ffmpeg") }
        if dvdauthorPath == nil { missing.append("dvdauthor") }
        return missing
    }

    public static var isReady: Bool { missingTools.isEmpty }

    /// 装齐这套工具的建议。
    ///
    /// Intel Mac 上有个坑：Homebrew 已经不再为 x86_64 的 macOS 编译 ffmpeg（`brew install ffmpeg`
    /// 会报 `no bottle available` 然后开始从头编译，动辄一两个小时），所以 Intel 机器上
    /// 建议直接下 evermeet.cx 的静态版，Apple 芯片上 `brew install` 是好的。
    public static let installHint = """
    · ffmpeg / ffprobe：Apple 芯片执行 brew install ffmpeg；Intel Mac 上 Homebrew 已经不提供\
    现成的二进制包，建议到 https://evermeet.cx/ffmpeg/ 下载静态版，解压后把 ffmpeg、ffprobe \
    放到 /usr/local/bin/（首次运行可能要执行 xattr -dr com.apple.quarantine /usr/local/bin/ffmpeg）
    · dvdauthor：brew install dvdauthor
    """

    /// 生成映像用哪个工具：优先 cdrtools 的 `mkisofs -dvd-video`（它会按 DVD-Video 规范
    /// 排好 UDF 1.02 + ISO 9660），没装就用系统自带的 `hdiutil makehybrid`。
    public static var imagerIsMkisofs: Bool { Mkisofs.isAvailable }

    // MARK: - 收集视频文件

    public static func isVideoFile(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// 把用户选的文件/文件夹摊平成视频文件列表，并记下跳过了什么、为什么。
    public static func collectVideoFiles(from items: [URL]) -> (videos: [URL], skipped: [VideoSkip]) {
        var videos: [URL] = []
        var skipped: [VideoSkip] = []
        let fileManager = FileManager.default

        for item in items {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory) else {
                skipped.append(VideoSkip(url: item, reason: "找不到这个文件"))
                continue
            }
            if isDirectory.boolValue {
                let found = videoFiles(inDirectory: item)
                if found.isEmpty {
                    skipped.append(VideoSkip(url: item, reason: "这个文件夹里没有视频文件"))
                } else {
                    videos.append(contentsOf: found)
                }
            } else if isVideoFile(item) {
                videos.append(item)
            } else {
                let ext = item.pathExtension
                skipped.append(VideoSkip(
                    url: item,
                    reason: ext.isEmpty ? "不是视频文件（没有扩展名）" : "不是视频文件（.\(ext)）"
                ))
            }
        }
        return (videos, skipped)
    }

    /// 递归找一个文件夹里的视频文件（按路径自然排序）。
    public static func videoFiles(inDirectory directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var found: [URL] = []
        for case let url as URL in enumerator {
            if NameSanitizer.isJunk(url.lastPathComponent) { continue }
            let isRegular = (try? url.resourceValues(forKeys: Set(keys)))?.isRegularFile ?? false
            guard isRegular, isVideoFile(url) else { continue }
            found.append(url)
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: - 名字与卷标

    /// 文件名里不能出现 `/`（会变成目录），顺便收拾控制字符。
    public static func safeFileName(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "/", with: "-")
        text = text.replacingOccurrences(of: ":", with: "-")
        text = text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        if text.isEmpty { text = "节目" }
        if text.count > 120 { text = String(text.prefix(120)) }
        return text
    }

    /// 显示用的标题：文件名去掉扩展名，顺手去掉「01 - 」这种序号前缀。
    public static func videoTitle(from url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        let digits = name.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let rest = name.dropFirst(digits.count)
            if rest.hasPrefix("-") || rest.hasPrefix(".") || rest.hasPrefix("_") || rest.hasPrefix(" ") {
                var trimmed = rest[...]
                let separators: Set<Character> = ["-", ".", "_", " "]
                while let first = trimmed.first, separators.contains(first) {
                    trimmed = trimmed.dropFirst()
                }
                if !trimmed.isEmpty { name = String(trimmed) }
            }
        }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? url.deletingPathExtension().lastPathComponent : cleaned
    }

    /// DVD-Video 的卷标。
    ///
    /// 卷标会写进 ISO 9660 的主目录区（那是 ASCII 字段），中文进去会变成乱码，
    /// 播放机的「碟片信息」里就是一堆问号。所以这里只留 A–Z、0–9、下划线，最多 32 个字符。
    public static func volumeLabel(_ raw: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        var text = raw.uppercased().map { allowed.contains($0) ? $0 : "_" }
        // 连续下划线压成一个，首尾的去掉，别出来「___」这种名字。
        var collapsed: [Character] = []
        for character in text {
            if character == "_", collapsed.last == "_" { continue }
            collapsed.append(character)
        }
        text = collapsed
        while text.first == "_" { text.removeFirst() }
        while text.last == "_" { text.removeLast() }
        var label = String(text)
        if label.isEmpty { label = "VIDEO_DVD" }
        if label.count > 32 { label = String(label.prefix(32)) }
        return label
    }

    // MARK: - 容量与码率

    /// 这种介质能放多少字节的 DVD-Video。
    public static func capacityBytes(for media: MediaKind) -> Int64 {
        switch media {
        case .dvdRDL, .dvdPlusRDL, .dvdRWDual:
            return dualLayerCapacityBytes
        case .unknown, .cdROM, .dvdROM, .bdROM:
            return defaultCapacityBytes
        default:
            return media.nominalCapacityBytes > 0 ? media.nominalCapacityBytes : defaultCapacityBytes
        }
    }

    /// 按总时长和盘的容量倒推一个「装得下、画质也还行」的视频码率（kbps）。
    ///
    /// 装不下时返回 0，调用方据此报「超容量」而不是硬刻一张刻不完的盘。
    public static func recommendedVideoBitrate(
        totalDuration: TimeInterval,
        capacityBytes: Int64
    ) -> Int {
        guard totalDuration > 0, capacityBytes > 0 else { return defaultVideoBitrateKbps }
        let usable = Double(capacityBytes) * capacitySafetyFraction - Double(overheadBytes)
        guard usable > 0 else { return 0 }
        let totalBits = usable * 8
        let audioBits = Double(audioBitrateKbps) * 1000 * totalDuration
        let videoKbps = (totalBits - audioBits) / totalDuration / 1000
        guard videoKbps >= Double(minimumVideoBitrateKbps) else { return 0 }
        let capped = min(Double(maximumVideoBitrateKbps), videoKbps)
        // 往下取整到 100 kbps，宁可少算一点也别刻到一半发现超了。
        return Int(capped / 100) * 100
    }

    /// 转码 + 打包后要占多少字节。
    public static func estimatedBytes(
        totalDuration: TimeInterval,
        videoBitrateKbps: Int,
        audioBitrateKbps: Int = VideoDVD.audioBitrateKbps
    ) -> Int64 {
        guard totalDuration > 0, videoBitrateKbps > 0 else { return 0 }
        let bitsPerSecond = Double(videoBitrateKbps + audioBitrateKbps) * 1000
        let payload = bitsPerSecond * totalDuration / 8
        return Int64((payload / capacitySafetyFraction).rounded(.up)) + overheadBytes
    }

    // MARK: - 探测

    /// 用 `ffprobe` 读一个视频文件的时长、分辨率、有没有音轨。
    public static func info(for url: URL) throws -> VideoFileInfo {
        guard let probe = ffprobePath else {
            throw VideoDVDError.missingTool(name: "ffprobe", hint: installHint)
        }
        let result = try Shell.run(probe, [
            "-v", "error",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            url.path,
        ])
        guard result.succeeded else {
            throw VideoDVDError.readFailed(
                name: url.lastPathComponent,
                detail: result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return try parseFFProbe(result.output, name: url.lastPathComponent)
    }

    /// 解析 `ffprobe -print_format json` 的输出。
    public static func parseFFProbe(_ text: String, name: String = "视频文件") throws -> VideoFileInfo {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw VideoDVDError.readFailed(name: name, detail: "ffprobe 的输出不是合法 JSON")
        }
        let streams = (root["streams"] as? [[String: Any]]) ?? []
        guard let video = streams.first(where: { ($0["codec_type"] as? String) == "video" }) else {
            throw VideoDVDError.readFailed(name: name, detail: "这个文件里没有视频轨道")
        }
        let rawWidth = (video["width"] as? NSNumber)?.intValue ?? 0
        let rawHeight = (video["height"] as? NSNumber)?.intValue ?? 0
        guard rawWidth > 0, rawHeight > 0 else {
            throw VideoDVDError.readFailed(name: name, detail: "读不出画面尺寸")
        }

        let format = (root["format"] as? [String: Any]) ?? [:]
        // 时长优先取 format（它算的是容器总时长），没有再用视频轨的。
        let duration = decimal(format["duration"]) ?? decimal(video["duration"]) ?? 0
        guard duration > 0 else {
            throw VideoDVDError.readFailed(name: name, detail: "读不出时长")
        }

        let hasAudio = streams.contains { ($0["codec_type"] as? String) == "audio" }

        // 手机竖着拍的片子会带 rotate 元数据：ffmpeg 转码时会自动转正，
        // 所以算宽高比之前得先跟着转，不然竖屏片子会被当成宽屏塞进 16:9。
        let rotation = rotationDegrees(in: video)
        let isQuarterTurned = rotation == 90 || rotation == 270 || rotation == -90 || rotation == -270
        var width = rawWidth
        var height = rawHeight
        if isQuarterTurned {
            swap(&width, &height)
        }
        // `display_aspect_ratio` 是**转正之前**的比例，转过 90 度之后要取倒数。
        var aspect = displayAspect(video: video, width: rawWidth, height: rawHeight)
        if isQuarterTurned, aspect > 0 { aspect = 1 / aspect }

        return VideoFileInfo(
            duration: duration,
            width: width,
            height: height,
            hasAudio: hasAudio,
            displayAspect: aspect,
            fieldOrder: video["field_order"] as? String
        )
    }

    /// 从 `side_data_list` 里取旋转角度。
    static func rotationDegrees(in video: [String: Any]) -> Int {
        if let tags = video["tags"] as? [String: Any], let text = tags["rotate"] as? String,
           let value = Int(text) {
            return value
        }
        guard let sides = video["side_data_list"] as? [[String: Any]] else { return 0 }
        for side in sides {
            if let number = side["rotation"] as? NSNumber { return number.intValue }
            if let text = side["rotation"] as? String, let value = Int(text) { return value }
        }
        return 0
    }

    /// 显示宽高比：优先用 ffprobe 给的 `display_aspect_ratio`，
    /// 没有再按「宽 × 像素长宽比 ÷ 高」自己算，最后兜底用宽 ÷ 高。
    static func displayAspect(video: [String: Any], width: Int, height: Int) -> Double {
        guard height > 0 else { return 16.0 / 9 }
        if let text = video["display_aspect_ratio"] as? String, let value = ratioValue(text) {
            return value
        }
        if let text = video["sample_aspect_ratio"] as? String, let sar = ratioValue(text) {
            return Double(width) * sar / Double(height)
        }
        return Double(width) / Double(height)
    }

    /// 把 `16:9` / `64/45` 这种写法的比值算出来。
    static func ratioValue(_ text: String) -> Double? {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == "/" })
        guard parts.count == 2,
              let numerator = Double(parts[0]), let denominator = Double(parts[1]),
              denominator != 0, numerator > 0 else { return nil }
        return numerator / denominator
    }

    static func decimal(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    // MARK: - 计划

    /// 生成 DVD-Video 的排布计划：摊平视频文件、探测、算码率与容量。
    public static func plan(
        items: [URL],
        standard: VideoStandard = .pal,
        capacityBytes: Int64 = VideoDVD.defaultCapacityBytes,
        onProgress: ((Int, Int, URL) -> Void)? = nil
    ) throws -> VideoDVDPlan {
        let collected = collectVideoFiles(from: items)
        var sources: [VideoSource] = []
        var skipped = collected.skipped
        let total = collected.videos.count
        for (index, url) in collected.videos.enumerated() {
            onProgress?(index, total, url)
            do {
                let info = try info(for: url)
                sources.append(VideoSource(
                    id: sources.count + 1,
                    sourceURL: url,
                    title: videoTitle(from: url),
                    duration: info.duration,
                    width: info.width,
                    height: info.height,
                    hasAudio: info.hasAudio,
                    isWidescreen: info.isWidescreen,
                    isInterlaced: info.isInterlaced,
                    sourceBytes: Workspace.fileSize(of: url)
                ))
            } catch {
                skipped.append(VideoSkip(url: url, reason: error.localizedDescription))
            }
        }
        onProgress?(total, total, collected.videos.last ?? items.first ?? URL(fileURLWithPath: "/"))

        // 一个 VTS 只能有一种画面比例，所以整张盘统一：只要有一部是宽屏，就按 16:9 做，
        // 4:3 的素材左右补黑边（电视上看起来仍然是对的）。
        let widescreen = sources.contains { $0.isWidescreen }
        let duration = sources.reduce(0) { $0 + $1.duration }
        let bitrate = recommendedVideoBitrate(totalDuration: duration, capacityBytes: capacityBytes)
        return VideoDVDPlan(
            sources: sources,
            skipped: skipped,
            standard: standard,
            capacityBytes: capacityBytes,
            widescreen: widescreen,
            videoBitrateKbps: bitrate
        )
    }

    /// 检查这张盘装不装得下。
    public static func validate(plan: VideoDVDPlan, force: Bool = false) throws {
        guard !plan.sources.isEmpty else { throw VideoDVDError.noVideoFiles }
        guard plan.sources.count <= 99 else { throw VideoDVDError.tooManyTitles(plan.sources.count) }
        guard !plan.isOverCapacity || force else {
            // 报错时报「最低码率下要多大」，比报 0 有用。
            let minimum = estimatedBytes(
                totalDuration: plan.totalDuration,
                videoBitrateKbps: minimumVideoBitrateKbps
            )
            throw VideoDVDError.overCapacity(required: minimum, available: plan.capacityBytes)
        }
    }

    // MARK: - dvdauthor XML

    /// 生成 `dvdauthor` 的 XML 控制文件。
    ///
    /// 几个必须遵守的规矩（都是实测撞出来的）：
    /// - `<vmgm>` 必须带一段 `<menus><video format=... /></menus>`，否则 dvdauthor 会报
    ///   「no default video format, must explicitly specify NTSC or PAL」并且**不生成 VIDEO_TS.IFO**，
    ///   刻出来是一张放不了的盘；
    /// - `jump title N` 只在**同一个 VTS 内**编号，跨 titleset 不成立，所以所有节目都放一个
    ///   titleset，按 `<pgc>` 顺序排，最后一个 `exit`；
    /// - 文件路径要转义，否则路径里一个 `&` 就会让 XML 解析失败。
    public static func dvdauthorXML(
        destination: URL,
        standard: VideoStandard,
        widescreen: Bool,
        titles: [URL],
        chapters: [[TimeInterval]] = []
    ) -> String {
        let aspect = widescreen ? "16:9" : "4:3"
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<dvdauthor dest=\"\(xmlEscape(destination.path))\">")
        lines.append("  <vmgm>")
        lines.append("    <menus>")
        lines.append("      <video format=\"\(standard.rawValue)\" aspect=\"\(aspect)\" />")
        lines.append("    </menus>")
        lines.append("  </vmgm>")
        lines.append("  <titleset>")
        lines.append("    <titles>")
        lines.append("      <video format=\"\(standard.rawValue)\" aspect=\"\(aspect)\" />")
        for (index, title) in titles.enumerated() {
            let marks = chapters.indices.contains(index) ? chapters[index] : []
            lines.append("      <pgc>")
            if let list = chapterList(seconds: marks) {
                lines.append("        <vob file=\"\(xmlEscape(title.path))\" chapters=\"\(list)\" />")
            } else {
                lines.append("        <vob file=\"\(xmlEscape(title.path))\" />")
            }
            if index < titles.count - 1 {
                lines.append("        <post> jump title \(index + 2); </post>")
            } else {
                lines.append("        <post> exit; </post>")
            }
            lines.append("      </pgc>")
        }
        lines.append("    </titles>")
        lines.append("  </titleset>")
        lines.append("</dvdauthor>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// 一个节目要打的章节点（秒）。第一个永远是 0。
    public static func chapterMarks(duration: TimeInterval, every: Double) -> [TimeInterval] {
        guard duration > 0, every > 0 else { return [0] }
        // 太短的片子打章节没有意义（遥控器上按一下就到头了）。
        guard duration > every * 1.2 else { return [0] }
        var marks: [TimeInterval] = [0]
        var position = every
        while position < duration - 5 {
            marks.append(position)
            position += every
        }
        return marks
    }

    /// 章节点写成 dvdauthor 要的 `[[h:]mm:]ss`。
    static func chapterList(seconds: [TimeInterval]) -> String? {
        guard !seconds.isEmpty else { return nil }
        let parts = seconds.map { value -> String in
            let total = Int(value.rounded())
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            let secs = total % 60
            if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
            return String(format: "%d:%02d:%02d", 0, minutes, secs)
        }
        return parts.joined(separator: ",")
    }

    /// XML 转义。文件路径里一个 `&` 就能让 dvdauthor 的 XML 解析直接失败。
    public static func xmlEscape(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }
}
/// 把视频源转成 DVD 格式、排成 VIDEO_TS、打成 UDF 映像。
///
/// 每一步都用现成的系统 / Homebrew 工具，不自己造 MPEG 编码器：
/// `ffmpeg` 转码 → `dvdauthor` 排结构 → `mkisofs` / `hdiutil` 做映像。
public enum VideoDVDStager {

    // MARK: - 转码

    /// 转码滤镜链：等比缩放 → 补黑边 → 压成 DVD 的标准分辨率 → 标上像素长宽比。
    ///
    /// 关键在于最后那个 `setsar`：DVD 的 720×576 不是方形像素，
    /// 16:9 的内容要靠 64:45 的像素长宽比才能在播放机上还原成正确形状，
    /// 缺了它画面会被横向拉扁。
    public static func encodeFilters(
        standard: VideoStandard,
        widescreen: Bool,
        isInterlaced: Bool
    ) -> String {
        let height = standard.height
        let squareWidth = standard.squarePixelWidth(widescreen: widescreen)
        var filters: [String] = []
        if isInterlaced { filters.append("yadif=0") }
        filters.append("scale=\(squareWidth):\(height):force_original_aspect_ratio=decrease")
        filters.append("pad=\(squareWidth):\(height):(ow-iw)/2:(oh-ih)/2")
        filters.append("setsar=1")
        filters.append("scale=\(standard.width):\(height)")
        filters.append("setsar=\(standard.sampleAspect(widescreen: widescreen))")
        return filters.joined(separator: ",")
    }

    /// 一条节目的 ffmpeg 参数。
    public static func encodeArguments(
        source: URL,
        destination: URL,
        standard: VideoStandard,
        widescreen: Bool,
        videoBitrateKbps: Int,
        hasAudio: Bool,
        isInterlaced: Bool
    ) -> [String] {
        var arguments = ["-y", "-hide_banner", "-nostdin"]
        if hasAudio {
            arguments += ["-i", source.path, "-map", "0:v:0", "-map", "0:a:0"]
        } else {
            // DVD-Video 要求每条节目至少有一条音频流，没有音轨的素材补一条静音。
            arguments += [
                "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
                "-i", source.path,
                "-map", "1:v:0", "-map", "0:a:0", "-shortest",
            ]
        }
        // 峰值码率留一倍余量，但顶在 DVD 的 10.08 Mbps 总码率上限以内。
        let maxRate = max(videoBitrateKbps, min(videoBitrateKbps * 2, 8000))
        arguments += [
            "-vf", encodeFilters(standard: standard, widescreen: widescreen, isInterlaced: isInterlaced),
            "-c:v", "mpeg2video",
            "-b:v", "\(videoBitrateKbps)k",
            "-maxrate", "\(maxRate)k",
            "-bufsize", "1835008",
            "-pix_fmt", "yuv420p",
            "-aspect", widescreen ? "16:9" : "4:3",
            "-r", standard.frameRateArgument,
            "-g", "\(standard.gopSize)",
            "-c:a", "mp2",
            "-b:a", "\(VideoDVD.audioBitrateKbps)k",
            "-ac", "2",
            "-ar", "48000",
            "-f", "dvd",
            destination.path,
        ]
        return arguments
    }

    /// 逐条转码，返回真正写进暂存目录的 MPEG-PS 文件（顺序与节目一致）。
    ///
    /// `onProgress` 的参数是（已完成数、总数、正在处理的节目标题）。
    @discardableResult
    public static func encode(
        sources: [VideoSource],
        into directory: URL,
        standard: VideoStandard,
        widescreen: Bool,
        videoBitrateKbps: Int,
        canceller: CommandCanceller? = nil,
        onProgress: ((Int, Int, String) -> Void)? = nil,
        onLog: ((String) -> Void)? = nil
    ) throws -> [URL] {
        guard let ffmpeg = VideoDVD.ffmpegPath else {
            throw VideoDVDError.missingTool(name: "ffmpeg", hint: VideoDVD.installHint)
        }
        var encoded: [URL] = []
        let total = sources.count
        for (index, source) in sources.enumerated() {
            if let canceller = canceller, canceller.isCancelled { throw ShellError.cancelled }
            onProgress?(index, total, source.title)
            let destination = directory.appendingPathComponent(source.stagedName)
            try? FileManager.default.removeItem(at: destination)
            let arguments = encodeArguments(
                source: source.sourceURL,
                destination: destination,
                standard: standard,
                widescreen: widescreen,
                videoBitrateKbps: videoBitrateKbps,
                hasAudio: source.hasAudio,
                isInterlaced: source.isInterlaced
            )
            let result = try Shell.stream(ffmpeg, arguments, canceller: canceller) { line in
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                onLog?(text)
            }
            guard result.succeeded else {
                throw VideoDVDError.encodeFailed(
                    name: source.sourceURL.lastPathComponent,
                    detail: lastMeaningfulLines(result.output)
                )
            }
            guard Workspace.fileSize(of: destination) > 0 else {
                throw VideoDVDError.encodeFailed(
                    name: source.sourceURL.lastPathComponent,
                    detail: "转码后没有生成文件"
                )
            }
            encoded.append(destination)
        }
        onProgress?(total, total, sources.last?.title ?? "")
        return encoded
    }

    /// 从命令输出里挑几行有信息量的，别把整屏进度都塞进错误提示。
    static func lastMeaningfulLines(_ output: String, limit: Int = 5) -> String {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let text = lines.suffix(limit).joined(separator: "\n")
        return text.isEmpty ? "命令没有输出错误信息" : text
    }

    // MARK: - 排 VIDEO_TS

    /// 用 `dvdauthor` 把 MPEG-PS 排成 DVD-Video 的目录结构。
    ///
    /// 返回的 URL 是**包含 VIDEO_TS 的那一层目录**（也就是要拿去做映像的那棵树）。
    @discardableResult
    public static func author(
        rootDirectory: URL,
        titles: [URL],
        standard: VideoStandard,
        widescreen: Bool,
        chapters: [[TimeInterval]] = [],
        canceller: CommandCanceller? = nil,
        onLog: ((String) -> Void)? = nil
    ) throws -> URL {
        guard let tool = VideoDVD.dvdauthorPath else {
            throw VideoDVDError.missingTool(name: "dvdauthor", hint: VideoDVD.installHint)
        }
        try? FileManager.default.removeItem(at: rootDirectory)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let xml = VideoDVD.dvdauthorXML(
            destination: rootDirectory,
            standard: standard,
            widescreen: widescreen,
            titles: titles,
            chapters: chapters
        )
        // XML 放在**上一级**：这一层目录接下来会被整个做成映像，留在里面的话
        // 光盘根目录就会多出一个 dvdauthor.xml，不再是干净的 DVD-Video 结构。
        let xmlURL = rootDirectory.deletingLastPathComponent().appendingPathComponent("dvdauthor.xml")
        try xml.write(to: xmlURL, atomically: true, encoding: .utf8)

        let result = try Shell.stream(tool, ["-x", xmlURL.path], canceller: canceller) { line in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            onLog?(text)
        }
        guard result.succeeded else {
            throw VideoDVDError.authorFailed(detail: lastMeaningfulLines(result.output, limit: 8))
        }

        let fileManager = FileManager.default
        let videoTS = rootDirectory.appendingPathComponent("VIDEO_TS", isDirectory: true)
        for name in ["VIDEO_TS.IFO", "VTS_01_0.IFO"] {
            guard fileManager.fileExists(atPath: videoTS.appendingPathComponent(name).path) else {
                throw VideoDVDError.authorFailed(detail: "VIDEO_TS 里缺少 \(name)")
            }
        }
        let hasVOB = ((try? fileManager.contentsOfDirectory(atPath: videoTS.path)) ?? [])
            .contains { $0.uppercased().hasSuffix(".VOB") }
        guard hasVOB else {
            throw VideoDVDError.authorFailed(detail: "VIDEO_TS 里没有生成 .VOB 数据文件")
        }
        // DVD-Video 规范要求根目录有 AUDIO_TS（空的也算），挂载时才会被认成一张正规的 DVD。
        let audioTS = rootDirectory.appendingPathComponent("AUDIO_TS", isDirectory: true)
        if !fileManager.fileExists(atPath: audioTS.path) {
            try? fileManager.createDirectory(at: audioTS, withIntermediateDirectories: true)
        }
        return rootDirectory
    }

    // MARK: - 做成映像

    /// 生成 DVD-Video 映像。
    ///
    /// 优先用 cdrtools 的 `mkisofs -dvd-video`：它会按 DVD-Video 规范把 UDF 1.02 与
    /// ISO 9660 两层文件系统都建好，并把 VIDEO_TS 里的文件排到规范要求的位置。没装 mkisofs
    /// 就退回系统自带的 `hdiutil makehybrid`（同样是 UDF 1.02 + ISO 9660）。
    @discardableResult
    public static func buildImage(
        source: URL,
        outputURL: URL,
        volumeName: String,
        canceller: CommandCanceller? = nil,
        onProgress: ((Double) -> Void)? = nil,
        onLog: ((String) -> Void)? = nil
    ) throws -> URL {
        let label = VideoDVD.volumeLabel(volumeName)
        if let mkisofs = Mkisofs.executablePath {
            let arguments = ["-dvd-video", "-V", label, "-o", outputURL.path, source.path]
            return try IsoTool.buildImage(
                tool: mkisofs,
                arguments: arguments,
                outputURL: outputURL,
                canceller: canceller,
                onProgress: onProgress,
                onLog: onLog
            )
        }
        return try buildImageWithMakeHybrid(
            source: source,
            outputURL: outputURL,
            label: label,
            canceller: canceller,
            onLog: onLog
        )
    }

    /// 系统自带工具这条路：`hdiutil makehybrid -udf -udf-version 1.02 -iso`。
    @discardableResult
    static func buildImageWithMakeHybrid(
        source: URL,
        outputURL: URL,
        label: String,
        canceller: CommandCanceller? = nil,
        onLog: ((String) -> Void)? = nil
    ) throws -> URL {
        try? FileManager.default.removeItem(at: outputURL)
        let arguments = [
            "makehybrid",
            "-udf", "-udf-version", "1.02",
            "-iso",
            "-default-volume-name", label,
            "-iso-volume-name", label,
            "-udf-volume-name", label,
            "-o", outputURL.path,
            source.path,
        ]
        let result = try Shell.stream("hdiutil", arguments, canceller: canceller) { line in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            onLog?(text)
        }
        guard result.succeeded else {
            throw VideoDVDError.imageFailed(detail: lastMeaningfulLines(result.output, limit: 8))
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw VideoDVDError.imageFailed(detail: "没有生成映像文件")
        }
        return outputURL
    }
}
