import Foundation

/// 光盘类型：数据光盘（ISO/UDF 文件系统）还是音乐 CD（CD-DA 红皮书音轨）。
///
/// 两者的写盘方式完全不同：
/// - 数据光盘：先把文件整理成 ISO 映像，再整块写进盘，盘上有文件系统，电脑能读；
/// - 音乐 CD：把音频文件转成 44.1 kHz / 16 bit / 立体声 PCM，交给 `drutil burn -audio`
///   直接写成音轨（红皮书），**盘上没有文件系统**——电脑看不到「文件」，
///   CD 机、车载音响、DVD 播放机才认这张盘。
public enum DiscMode: String, CaseIterable, Identifiable, Hashable {
    case data
    case audioCD
    case videoDVD

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .data: return "数据光盘"
        case .audioCD: return "音乐 CD"
        case .videoDVD: return "视频 DVD"
        }
    }

    public var detail: String {
        switch self {
        case .data:
            return "把任意文件、文件夹写进 ISO 9660 + Joliet + UDF 文件系统：电脑、手机、车机插上就能看到文件。"
        case .audioCD:
            return "把音频文件转成红皮书音轨：CD 机、车载音响、DVD 播放机都能直接放。"
                + "盘上没有文件系统，电脑看不到「文件」；一张 80 分钟的 CD-R 大约能放 80 分钟音频。"
        case .videoDVD:
            return "把视频转成 DVD-Video（MPEG-2），排成标准的 VIDEO_TS 目录：DVD 播放机、"
                + "蓝光机、电脑都能放，遥控器上还能跳章节。一张单层 DVD 大约放 2 小时。"
        }
    }

    /// 音乐 CD 用不上「卷标 / 文件系统 / 多区段追加」这些设置。
    public var usesFileSystemOptions: Bool { self == .data }

    /// 盘上有没有用户能直接读到的文件（音乐 CD 没有；视频 DVD 有 VIDEO_TS，但那不是「文件列表」）。
    public var hasVisibleFiles: Bool { self == .data }
}

/// 一条准备写进音乐 CD 的音轨。
public struct AudioTrack: Identifiable, Hashable {
    /// 音轨号，从 1 开始。
    public let id: Int
    public let sourceURL: URL
    /// 显示名（文件名去掉扩展名，清理过控制字符）。
    public let title: String
    /// 时长（秒），来自 `afinfo`。
    public let duration: TimeInterval
    /// 源文件字节数（用于界面显示「原始大小」）。
    public let sourceBytes: Int64
    /// 源文件本来就是 CD 音质（44.1 kHz / 16 bit / 立体声 PCM），刻录时不用重采样。
    public let isCDQuality: Bool

    public init(
        id: Int,
        sourceURL: URL,
        title: String,
        duration: TimeInterval,
        sourceBytes: Int64,
        isCDQuality: Bool
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.title = title
        self.duration = duration
        self.sourceBytes = sourceBytes
        self.isCDQuality = isCDQuality
    }

    /// 暂存目录里的文件名。
    ///
    /// 两位数字前缀是必须的：`drutil burn -audio` 按**文件名字母序**决定音轨顺序，
    /// 不加前缀的话「10 某首歌」会排到「2 某首歌」前面，用户排的顺序就乱了。
    public var stagedName: String {
        String(format: "%02d - %@.aiff", id, AudioDisc.safeFileName(title))
    }

    public var durationText: String { AudioDisc.timeText(duration) }
    public var sourceSizeText: String { ByteText.human(sourceBytes) }
}

/// 被跳过的文件（不是音频、读不出音频信息等）。
public struct AudioSkip: Hashable {
    public let url: URL
    public let reason: String

    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }

    public var displayName: String { url.lastPathComponent }
}

/// 一张音乐 CD 的排布计划。
public struct AudioDiscPlan {
    public var tracks: [AudioTrack]
    public var skipped: [AudioSkip]
    /// 每轨前后的标准间隔（秒）。红皮书规定音轨之间至少 2 秒静音。
    public var gapSeconds: Double
    /// 一张 80 分钟 CD-R 的可用时间（秒）。
    public var capacitySeconds: Double

    public init(
        tracks: [AudioTrack],
        skipped: [AudioSkip] = [],
        gapSeconds: Double = AudioDisc.gapSeconds,
        capacitySeconds: Double = AudioDisc.capacitySeconds
    ) {
        self.tracks = tracks
        self.skipped = skipped
        self.gapSeconds = gapSeconds
        self.capacitySeconds = capacitySeconds
    }

    /// 纯音频时长。
    public var totalDuration: TimeInterval {
        tracks.reduce(0) { $0 + $1.duration }
    }

    /// 算上每轨前后的间隔后，这张盘实际要占用的时间。
    public var requiredSeconds: Double {
        guard !tracks.isEmpty else { return 0 }
        return totalDuration + gapSeconds * Double(tracks.count + 1)
    }

    public var remainingSeconds: Double { capacitySeconds - requiredSeconds }
    public var isOverCapacity: Bool { requiredSeconds > capacitySeconds }

    public var usageFraction: Double {
        guard capacitySeconds > 0 else { return 0 }
        return min(1, requiredSeconds / capacitySeconds)
    }

    /// 暂存成 AIFF 后要占的本机磁盘空间（16 bit / 44.1 kHz / 立体声）。
    public var stagedBytes: Int64 {
        tracks.reduce(Int64(0)) { $0 + AudioDisc.pcmBytes(duration: $1.duration) }
    }

    /// 已经是 CD 音质、不用重采样的音轨数。
    public var cdQualityCount: Int { tracks.filter { $0.isCDQuality }.count }

    public var summary: String {
        guard !tracks.isEmpty else { return "还没有音轨" }
        return "\(tracks.count) 轨 · 总时长 \(AudioDisc.timeText(totalDuration))"
    }
}

/// `afinfo` 报出来的一条音频信息。
public struct AudioFileInfo {
    public let duration: TimeInterval
    public let channels: Int?
    public let sampleRate: Double?
    public let bitsPerSample: Int?
    public let isPCM: Bool

    public init(
        duration: TimeInterval,
        channels: Int?,
        sampleRate: Double?,
        bitsPerSample: Int?,
        isPCM: Bool
    ) {
        self.duration = duration
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitsPerSample = bitsPerSample
        self.isPCM = isPCM
    }

    /// 是否已经是红皮书音轨的格式（44.1 kHz / 16 bit / 双声道未压缩）。
    public var isCDQuality: Bool {
        isPCM && channels == 2 && bitsPerSample == 16 && (sampleRate ?? 0) >= 44099 && (sampleRate ?? 0) <= 44101
    }

    public var formatSummary: String {
        let channelText = channels.map { "\($0) 声道" } ?? "声道未知"
        let rateText = sampleRate.map { $0 >= 1000 ? "\(Int($0 / 1000)) kHz" : "\(Int($0)) Hz" } ?? "采样率未知"
        let bitText = bitsPerSample.map { "\($0) bit" } ?? (isPCM ? "位深未知" : "压缩格式")
        return "\(channelText) · \(rateText) · \(bitText)"
    }
}

public enum AudioDiscError: LocalizedError {
    case noAudioTracks
    /// 介质不是 CD（音乐 CD 只能刻在 CD-R / CD-RW 上）。
    case requiresCDMedia(String)
    /// 盘上已经有内容，而音乐 CD 不能追加。
    case needsBlankDisc(sessions: Int, media: String)
    case overCapacity(required: Double, available: Double)
    case notEnoughSpace(required: Int64, available: Int64)
    case readFailed(name: String, detail: String)
    case convertFailed(name: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .noAudioTracks:
            return "列表里没有能刻进音乐 CD 的音频文件。"
                + "\n音乐 CD 只收音频：MP3 / M4A / AAC / WAV / AIFF / ALAC / FLAC 都可以，视频文件请改用「数据光盘」。"
        case .requiresCDMedia(let media):
            return "音乐 CD 只能刻在 CD-R / CD-RW 上，当前介质是 \(media)。"
                + "\nDVD / 蓝光的坑距和反射率跟 CD 不一样，刻出来的音轨 CD 机放不了。"
                + "想刻 DVD 请改用「数据光盘」，并换一张 DVD 空盘。"
        case .needsBlankDisc(let sessions, let media):
            return "这张 \(media) 上已经有 \(sessions) 段内容，而音乐 CD 不能追加刻录："
                + "音频盘是多区段里最尴尬的一种，绝大多数 CD 机只认第一段。"
                + "\n请换一张空白 CD-R，或用可重写的 CD-RW 擦除后再刻。"
        case .overCapacity(let required, let available):
            return "音频总时长 \(AudioDisc.timeText(required)) 超过一张 CD 的容量"
                + "（\(AudioDisc.timeText(available))，已算上每轨 2 秒间隔）。"
                + "\n请去掉几首歌，或换一张 90 分钟的 CD-R。"
        case .notEnoughSpace(let required, let available):
            return "本机磁盘空间不足：转成 CD 音轨需要 \(ByteText.human(required)) 临时空间，"
                + "当前可用 \(ByteText.human(available))。"
        case .readFailed(let name, let detail):
            return "读不出 \(name) 的音频信息：\(detail)"
        case .convertFailed(let name, let detail):
            return "把 \(name) 转成 CD 音轨失败：\(detail)"
        }
    }
}

/// 音乐 CD（CD-DA）相关的计算与音频信息读取。
public enum AudioDisc {
    /// 一张 80 分钟 CD-R 的可用时间。
    public static let capacitySeconds: Double = 80 * 60
    /// 红皮书音轨之间/前后的标准间隔。
    public static let gapSeconds: Double = 2
    /// CD-DA 的采样率与位深。
    public static let sampleRate: Double = 44100
    public static let bitsPerSample: Int = 16
    /// 1 秒 CD 音轨的字节数（44.1 kHz × 2 声道 × 2 字节）。
    public static let pcmBytesPerSecond: Double = 44100 * 2 * 2

    /// 能被 CoreAudio 解码、因而能转成音轨的扩展名。
    ///
    /// 这里不收 Ogg / Opus：macOS 的 CoreAudio 解不了，列进来只会让用户
    /// 以为能刻，最后还是失败。想刻这两种格式得先用别处转成 MP3 / WAV。
    public static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "adts", "wav", "wave", "aif", "aiff", "aifc",
        "caf", "alac", "flac", "au", "snd", "mp2", "mpga",
    ]

    public static let afinfoPath = "/usr/bin/afinfo"
    public static let afconvertPath = "/usr/bin/afconvert"

    public static func isAudioFile(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    /// 把秒数写成 `3:45` / `1:02:03`。
    public static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// 一条音轨的 PCM 字节数。
    public static func pcmBytes(duration: TimeInterval) -> Int64 {
        guard duration > 0 else { return 0 }
        return Int64((duration * pcmBytesPerSecond).rounded(.up))
    }

    /// 音频占用的红皮书扇区数（一个音频扇区 2352 字节 = 1/75 秒）。
    public static func audioSectors(duration: TimeInterval) -> Int {
        guard duration > 0 else { return 0 }
        let frames = Int((duration * 44100).rounded(.up))
        return (frames + 587) / 588
    }

    /// 文件名里不能出现 `/`（会变成目录），顺便收拾控制字符。
    public static func safeFileName(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "/", with: "-")
        text = text.replacingOccurrences(of: ":", with: "-")
        text = text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        if text.isEmpty { text = "音轨" }
        if text.count > 120 { text = String(text.prefix(120)) }
        return text
    }

    /// 显示用的标题：文件名去掉扩展名，顺手把常见的「01 - 」「01. 」这种序号去掉。
    public static func trackTitle(from url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        // 只在前缀确实是「1~3 位数字 + 分隔符」时才去掉，别把「2001 太空漫游」这种名字切坏。
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

    // MARK: - 收集音频文件

    /// 把用户选的文件/文件夹摊平成音频文件列表，并记下跳过了什么、为什么。
    ///
    /// 文件夹是递归找的（按名字自然排序，让「第 2 首」排在「第 10 首」前面），
    /// 隐藏文件和 `.DS_Store` 这类垃圾直接忽略，不占用「已跳过」的说明名额。
    public static func collectAudioFiles(from items: [URL]) -> (audio: [URL], skipped: [AudioSkip]) {
        var audio: [URL] = []
        var skipped: [AudioSkip] = []
        let fileManager = FileManager.default

        for item in items {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory) else {
                skipped.append(AudioSkip(url: item, reason: "找不到这个文件"))
                continue
            }
            if isDirectory.boolValue {
                let found = audioFiles(inDirectory: item)
                if found.isEmpty {
                    skipped.append(AudioSkip(url: item, reason: "这个文件夹里没有音频文件"))
                } else {
                    audio.append(contentsOf: found)
                }
            } else if isAudioFile(item) {
                audio.append(item)
            } else {
                let ext = item.pathExtension
                skipped.append(AudioSkip(
                    url: item,
                    reason: ext.isEmpty ? "不是音频文件（没有扩展名）" : "不是音频文件（.\(ext)）"
                ))
            }
        }
        return (audio, skipped)
    }

    /// 递归找出一个文件夹里的音频文件（按路径自然排序）。
    public static func audioFiles(inDirectory directory: URL) -> [URL] {
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
            let name = url.lastPathComponent
            if NameSanitizer.isJunk(name) { continue }
            let isRegular = (try? url.resourceValues(forKeys: Set(keys)))?.isRegularFile ?? false
            guard isRegular else { continue }
            guard isAudioFile(url) else { continue }
            found.append(url)
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: - 音频信息

    /// 读一条音频文件的时长与格式（调用系统的 `afinfo`）。
    public static func info(for url: URL) throws -> AudioFileInfo {
        let result = try Shell.run(afinfoPath, [url.path])
        guard result.succeeded else {
            throw AudioDiscError.readFailed(
                name: url.lastPathComponent,
                detail: result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return try parseAFInfo(result.output, name: url.lastPathComponent)
    }

    /// 解析 `afinfo` 的输出。
    public static func parseAFInfo(_ text: String, name: String = "音频文件") throws -> AudioFileInfo {
        guard let duration = parseDuration(fromAFInfo: text), duration > 0 else {
            throw AudioDiscError.readFailed(name: name, detail: "没有读到时长，可能不是音频文件")
        }
        let format = parseFormat(fromAFInfo: text)
        return AudioFileInfo(
            duration: duration,
            channels: format.channels,
            sampleRate: format.sampleRate,
            bitsPerSample: format.bits,
            isPCM: format.isPCM
        )
    }

    /// 从 `afinfo` 输出里取时长，例如 `estimated duration: 213.184 sec`。
    public static func parseDuration(fromAFInfo text: String) -> TimeInterval? {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lowered = line.lowercased()
            guard lowered.hasPrefix("estimated duration:") || lowered.hasPrefix("duration:") else { continue }
            guard let colon = line.firstIndex(of: ":"),
                  let secRange = line.range(of: "sec") else { continue }
            let numberPart = line[line.index(after: colon)..<secRange.lowerBound]
            let trimmed = numberPart.trimmingCharacters(in: .whitespaces)
            if let value = Double(trimmed), value > 0 { return value }
        }
        return nil
    }

    /// 从 `afinfo` 输出里取格式，例如
    /// `Data format: 2 ch, 44100 Hz, lpcm (0x0000000E) 16-bit big-endian signed integer`。
    public static func parseFormat(
        fromAFInfo text: String
    ) -> (channels: Int?, sampleRate: Double?, bits: Int?, isPCM: Bool) {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lowered = line.lowercased()
            guard lowered.hasPrefix("data format:") else { continue }
            let body = String(line.dropFirst("Data format:".count))
            var channels: Int?
            var sampleRate: Double?
            var bits: Int?
            var isPCM = false
            for token in body.split(separator: ",") {
                let piece = token.trimmingCharacters(in: .whitespaces)
                let lower = piece.lowercased()
                if lower.hasSuffix(" ch"), let value = Int(lower.dropLast(3).trimmingCharacters(in: .whitespaces)) {
                    channels = value
                } else if lower.hasSuffix(" hz"), let value = Double(lower.dropLast(3).trimmingCharacters(in: .whitespaces)) {
                    sampleRate = value
                }
                if lower.contains("lpcm") || lower.contains("integer") { isPCM = true }
            }
            // 位深在最后一段里，写法不止一种：`Int16`、`16-bit big-endian signed integer`、
            // `Float32`（AAC 解出来就是浮点，不是 CD 音质）。
            bits = sampleBitDepth(inFormat: body)
            // WAV 报的是 `Int16`（不是 lpcm），也是未压缩 PCM，要认。
            if !isPCM, body.range(of: "(?:int|float)[0-9]+", options: [.regularExpression, .caseInsensitive]) != nil {
                isPCM = true
            }
            return (channels, sampleRate, bits, isPCM)
        }
        return (nil, nil, nil, false)
    }

    /// 从格式说明里取位深。
    ///
    /// 两种写法都要认：`Int16` / `Float32`（数字在后），以及 `16-bit ...`（数字在前）。
    /// 注意别被 `interleaved` 骗了——它中间的 `int` 后面跟的是字母，不是数字。
    static func sampleBitDepth(inFormat text: String) -> Int? {
        let patterns = ["([0-9]+)\\s*-\\s*bit", "(?:int|float)([0-9]+)"]
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            guard let match = regex.firstMatch(in: text, options: [], range: fullRange),
                  match.numberOfRanges > 1,
                  let captured = Range(match.range(at: 1), in: text),
                  let value = Int(text[captured]), value > 0 else { continue }
            return value
        }
        return nil
    }

    // MARK: - 计划

    /// 生成音乐 CD 的排布计划：摊平音频文件、读时长、算容量。
    public static func plan(
        items: [URL],
        onProgress: ((Int, Int, URL) -> Void)? = nil
    ) throws -> AudioDiscPlan {
        let collected = collectAudioFiles(from: items)
        var tracks: [AudioTrack] = []
        var skipped = collected.skipped
        let total = collected.audio.count
        for (index, url) in collected.audio.enumerated() {
            onProgress?(index, total, url)
            do {
                let info = try info(for: url)
                tracks.append(AudioTrack(
                    id: tracks.count + 1,
                    sourceURL: url,
                    title: trackTitle(from: url),
                    duration: info.duration,
                    sourceBytes: Workspace.fileSize(of: url),
                    isCDQuality: info.isCDQuality
                ))
            } catch {
                skipped.append(AudioSkip(url: url, reason: error.localizedDescription))
            }
        }
        onProgress?(total, total, collected.audio.last ?? items.first ?? URL(fileURLWithPath: "/"))
        return AudioDiscPlan(tracks: tracks, skipped: skipped)
    }

    /// 检查这张盘装不装得下这个计划。
    public static func validate(plan: AudioDiscPlan, force: Bool = false) throws {
        guard !plan.tracks.isEmpty else { throw AudioDiscError.noAudioTracks }
        guard !plan.isOverCapacity || force else {
            throw AudioDiscError.overCapacity(required: plan.requiredSeconds, available: plan.capacitySeconds)
        }
    }
}

/// 把音轨转成 CD-DA 规范（44.1 kHz / 16 bit / 立体声）的 AIFF，放进暂存目录。
///
/// 用系统自带的 `afconvert`：它跟 `afinfo` 一样基于 CoreAudio，MP3 / M4A / AAC /
/// WAV / AIFF / ALAC / FLAC 都能解，不用另外装 ffmpeg。
public enum AudioDiscStager {
    /// 暂停/继续用的转码选项：`-f AIFF` + `-d BEI16@44100` + `-c 2` 就是红皮书音轨。
    public static func convertArguments(source: URL, destination: URL) -> [String] {
        ["-f", "AIFF", "-d", "BEI16@44100", "-c", "2", source.path, destination.path]
    }

    /// 逐条转换，返回真正写进暂存目录的音轨。
    ///
    /// `onProgress` 的参数是（已完成数、总数、正在处理的音轨标题）。
    @discardableResult
    public static func stage(
        tracks: [AudioTrack],
        into directory: URL,
        canceller: CommandCanceller? = nil,
        onProgress: ((Int, Int, String) -> Void)? = nil
    ) throws -> [AudioTrack] {
        var staged: [AudioTrack] = []
        let total = tracks.count
        for (index, track) in tracks.enumerated() {
            if let canceller = canceller, canceller.isCancelled { throw ShellError.cancelled }
            onProgress?(index, total, track.title)
            let destination = directory.appendingPathComponent(track.stagedName)
            try? FileManager.default.removeItem(at: destination)
            let result = try Shell.run(
                AudioDisc.afconvertPath,
                convertArguments(source: track.sourceURL, destination: destination)
            )
            guard result.succeeded else {
                throw AudioDiscError.convertFailed(
                    name: track.sourceURL.lastPathComponent,
                    detail: result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            guard FileManager.default.fileExists(atPath: destination.path),
                  Workspace.fileSize(of: destination) > 0 else {
                throw AudioDiscError.convertFailed(
                    name: track.sourceURL.lastPathComponent,
                    detail: "转换后没有生成音轨文件"
                )
            }
            staged.append(track)
        }
        onProgress?(total, total, tracks.last?.title ?? "")
        return staged
    }
}
