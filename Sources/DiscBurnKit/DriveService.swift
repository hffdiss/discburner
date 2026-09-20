import Foundation

/// 一台光学驱动器。
public struct OpticalDrive: Identifiable, Hashable {
    public let index: Int
    public let vendor: String
    public let product: String
    public let revision: String
    public let bus: String
    public let supportLevel: String

    public var id: Int { index }

    public var displayName: String {
        let combined = "\(vendor) \(product)".trimmingCharacters(in: .whitespaces)
        return combined.isEmpty ? "驱动器 #\(index)" : combined
    }

    /// Apple 的 DiscRecording 是否把这个型号标记为「官方支持」。
    /// 第三方 USB 光驱经常是 Unsupported，但依然能正常刻录。
    public var isAppleSupported: Bool {
        supportLevel.trimmingCharacters(in: .whitespaces).lowercased() != "unsupported"
    }
}

/// 当前插入介质的详细信息。
public struct DiscStatus {
    public var isPresent: Bool = false
    public var deviceNode: String?
    public var rawType: String?
    public var media: MediaKind = .unknown
    public var sessions: Int?
    public var tracks: Int?
    public var writeSpeeds: [Int] = []
    public var freeBytes: Int64?
    public var usedBytes: Int64?
    public var writability: Writability = .unknown
    public var bookType: String?
    public var mediaID: String?
    public var erasable: Bool = false
    /// MMC 的 Disc Status：0 空盘、1 未完成（可追加）、2 已完成（已关闭）。
    public var discStatus: Int?
    /// MMC 的 Session State。
    public var sessionState: Int?

    public init() {}

    /// 还能写入的字节数（优先用驱动器报告的空闲扇区）。
    public var writableBytes: Int64? {
        if let free = freeBytes, free > 0 { return free }
        if writability == .blank { return media.nominalCapacityBytes }
        return nil
    }

    /// 总容量估算。
    public var totalBytes: Int64? {
        guard let free = writableBytes else { return nil }
        let used = usedBytes ?? 0
        let total = free + used
        return max(total, media.nominalCapacityBytes)
    }

    public var canBurn: Bool {
        isPresent && media.isWritable && writability.canBurn
    }

    public var summary: String {
        guard isPresent else { return "未插入光盘" }
        var parts = [media.displayName, writability.localizedDescription]
        if let free = writableBytes {
            parts.append("可用空间 " + ByteText.human(free))
        } else if !canBurn {
            if let used = usedBytes, used > 0 {
                parts.append("已用 \(ByteText.human(used))，无法再写入")
            }
            parts.append("请更换新盘或使用可擦写介质")
        }
        if erasable { parts.append("可擦除") }
        return parts.joined(separator: " · ")
    }
}

/// 对 `drutil` 的封装：列出驱动器、查询介质、弹出。
public enum DriveService {

    // MARK: - 驱动器列表

    public static func listDrives() throws -> [OpticalDrive] {
        let result = try Shell.run("drutil", ["list"])
        return parseDriveList(result.output)
    }

    /// 解析 `drutil list` 的表格输出。
    ///
    /// ```
    ///    Vendor   Product           Rev   Bus       SupportLevel
    /// 1  PIONEER  DVD-RW DVR-XU01C  DL61  USB       Unsupported
    /// ```
    public static func parseDriveList(_ output: String) -> [OpticalDrive] {
        var drives: [OpticalDrive] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            guard let regex = try? NSRegularExpression(
                pattern: #"^\s*(\d+)\s+(\S+)\s+(.+?)\s+(\S+)\s+(\S+)\s+(\S+)\s*$"#
            ) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges == 7 else {
                continue
            }
            func group(_ index: Int) -> String {
                guard let swiftRange = Range(match.range(at: index), in: text) else { return "" }
                return String(text[swiftRange])
            }
            guard let index = Int(group(1)) else { continue }
            drives.append(
                OpticalDrive(
                    index: index,
                    vendor: group(2),
                    product: group(3),
                    revision: group(4),
                    bus: group(5),
                    supportLevel: group(6)
                )
            )
        }
        return drives
    }

    // MARK: - 介质状态

    public static func status(driveIndex: Int? = nil) throws -> DiscStatus {
        var arguments: [String] = []
        if let index = driveIndex {
            arguments += ["-drive", "\(index)"]
        }
        arguments.append("status")
        let result = try Shell.run("drutil", arguments)
        let status = parseStatus(result.output)
        guard status.isPresent else { return status }
        let info = discInfo(driveIndex: driveIndex, tolerateFailure: true)
        return apply(info, to: status)
    }

    /// 把 `drutil discinfo` 的信息合并进 `drutil status` 的结果。
    ///
    /// 需要这一步是因为：盘写满或被关闭后，`drutil status` 的
    /// `Writability:` 会输出空值，只看它会把「已关闭」误判成「状态未知」。
    /// `Disc Status: 2`（已完成）此时才是可靠的判据。
    public static func apply(_ info: DiscInfo?, to status: DiscStatus) -> DiscStatus {
        guard let info = info else { return status }
        var merged = status
        merged.erasable = info.erasable
        merged.discStatus = info.discStatus
        merged.sessionState = info.sessionState
        if merged.sessions == nil { merged.sessions = info.sessionCount }
        if merged.writability == .unknown || merged.writability == .notWritable {
            switch info.discStatus {
            case 0: merged.writability = .blank
            case 1: merged.writability = .appendable
            case 2: merged.writability = .closed
            default: break
            }
        }
        return merged
    }

    /// 解析 `drutil status` 的输出。
    public static func parseStatus(_ output: String) -> DiscStatus {
        var status = DiscStatus()
        let lowered = output.lowercased()
        if lowered.contains("no media inserted") || lowered.contains("no media") {
            return status
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            let fields = labelValues(in: text)
            if let type = fields["type"], !type.isEmpty {
                status.isPresent = true
                status.rawType = type
                status.media = MediaKind.parse(type) ?? .unknown
            }
            if let name = fields["name"], !name.isEmpty {
                status.deviceNode = name
            }
            if let sessions = fields["sessions"], let number = Int(sessions) {
                status.sessions = number
            }
            if let tracks = fields["tracks"], let number = Int(tracks) {
                status.tracks = number
            }
            if let speeds = fields["write speeds"], !speeds.isEmpty {
                status.writeSpeeds = parseSpeeds(speeds)
            }
            if let writability = fields["writability"], !writability.isEmpty {
                status.writability = Writability(statusText: writability)
            }
            if let book = fields["book type"], !book.isEmpty {
                status.bookType = book
            }
            if let mediaID = fields["media id"], !mediaID.isEmpty {
                status.mediaID = mediaID
            }
            if text.contains("Space Free") {
                status.freeBytes = parseSpace(text)
            }
            if text.contains("Space Used") {
                status.usedBytes = parseSpace(text)
            }
        }

        // 有些时候「Type」字段缺失，但仍然插着盘。
        if !status.isPresent, output.contains("Space Free") || output.contains("Writability") {
            status.isPresent = true
        }
        return status
    }

    private static func parseSpeeds(_ text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)\s*x"#) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
            guard let value = Double(text[swiftRange]) else { return nil }
            return Int(value)
        }
    }

    /// 从 `Space Free:  337:27:35  blocks: 1518560 / 3.11GB / 2.90GiB` 里取字节数。
    private static func parseSpace(_ line: String) -> Int64? {
        if let regex = try? NSRegularExpression(pattern: #"blocks:\s*(\d+)\s*/"#),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: line),
           let blocks = Int64(line[range]) {
            return blocks * 2048
        }
        if let regex = try? NSRegularExpression(pattern: #"/\s*([0-9.]+)\s*([KMGT]?B)\s*/\s*([0-9.]+)\s*([KMGT]?iB)"#),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let numberRange = Range(match.range(at: 1), in: line),
           let unitRange = Range(match.range(at: 2), in: line),
           let number = Double(line[numberRange]) {
            return Int64(number * unitMultiplier(String(line[unitRange])))
        }
        return nil
    }

    private static func unitMultiplier(_ unit: String) -> Double {
        switch unit.uppercased() {
        case "KB": return 1_000
        case "MB": return 1_000_000
        case "GB": return 1_000_000_000
        case "TB": return 1_000_000_000_000
        case "KIB": return 1024
        case "MIB": return 1_048_576
        case "GIB": return 1_073_741_824
        case "TIB": return 1_099_511_627_776
        default: return 1
        }
    }

    /// 把一行里的 `标签: 值` 全部抽出来。
    ///
    /// drutil 的一行里可能有两组字段（`Type: DVD+R    Name: /dev/disk4`），
    /// 而且标签本身可能带空格（`Book Type`）。这里先找出所有标签的位置，
    /// 每个标签的值就是它到下一个标签之间的内容。
    static func labelValues(in line: String) -> [String: String] {
        // 标签本身可以带一个空格（`Book Type`），但标签内部不允许出现连续空格，
        // 否则 `DVD+R            Name:` 里的 `R … Name` 会被误当成一个标签。
        let pattern = #"([A-Za-z][A-Za-z0-9\-]*(?: [A-Za-z0-9\-]+)*)[ \t]*:"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [:]
        }
        let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
        guard !matches.isEmpty, let nsLine = line as NSString? else { return [:] }

        var fields: [String: String] = [:]
        for (index, match) in matches.enumerated() {
            let label = nsLine.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let valueStart = match.range.location + match.range.length
            let valueEnd = index + 1 < matches.count ? matches[index + 1].range.location : nsLine.length
            guard valueEnd > valueStart else { continue }
            let value = nsLine.substring(with: NSRange(location: valueStart, length: valueEnd - valueStart))
                .trimmingCharacters(in: .whitespaces)
            if fields[label] == nil, !label.isEmpty {
                fields[label] = value
            }
        }
        return fields
    }

    // MARK: - 底层硬件信息

    public struct DiscInfo {
        public var erasable: Bool
        public var sessionCount: Int?
        public var discStatus: Int?
        public var sessionState: Int?

        public init(erasable: Bool, sessionCount: Int?, discStatus: Int?, sessionState: Int?) {
            self.erasable = erasable
            self.sessionCount = sessionCount
            self.discStatus = discStatus
            self.sessionState = sessionState
        }
    }

    public static func discInfo(driveIndex: Int? = nil, tolerateFailure: Bool = false) -> DiscInfo? {
        var arguments: [String] = []
        if let index = driveIndex {
            arguments += ["-drive", "\(index)"]
        }
        arguments.append("discinfo")
        let result = Shell.tryRun("drutil", arguments)
        guard result.succeeded else { return nil }
        return parseDiscInfo(result.output)
    }

    public static func parseDiscInfo(_ output: String) -> DiscInfo? {
        func number(after label: String) -> Int? {
            guard let range = output.range(of: label) else { return nil }
            let rest = output[range.upperBound...]
            let digits = rest.drop { !$0.isNumber }.prefix { $0.isNumber }
            return Int(digits)
        }
        guard output.contains(":") else { return nil }
        return DiscInfo(
            erasable: (number(after: "erasable:") ?? 0) != 0,
            sessionCount: number(after: "sessionCount:"),
            discStatus: number(after: "discStatus:"),
            sessionState: number(after: "sessionState:")
        )
    }

    // MARK: - 弹出

    public static func eject(driveIndex: Int? = nil) throws {
        // drutil 在没有驱动器时也会返回成功，所以先确认确实有光驱。
        guard let drives = try? listDrives(), !drives.isEmpty else {
            throw BurnError.noDrive
        }
        if let index = driveIndex, !drives.contains(where: { $0.index == index }) {
            throw BurnError.noDrive
        }
        var arguments: [String] = []
        if let index = driveIndex {
            arguments += ["-drive", "\(index)"]
        }
        arguments.append("eject")
        let result = try Shell.run("drutil", arguments)
        guard result.succeeded else {
            throw CommandFailure(command: result.command, exitCode: result.exitCode, output: result.output)
        }
    }
}
