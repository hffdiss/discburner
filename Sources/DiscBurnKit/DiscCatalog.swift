import Foundation

/// 光盘上的一个文件或文件夹。
public struct DiscEntry: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let relativePath: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let linkTarget: String?
    public let byteCount: Int64
    public let children: [DiscEntry]

    public var childCount: Int { children.count }

    public var kindSymbol: String {
        if isSymlink { return "→" }
        return isDirectory ? "📁" : "📄"
    }
}

/// 光盘当前区段的内容清单。
public struct DiscContents {
    public var source: String = ""
    public var volumeName: String?
    public var fileSystem: String?
    public var mountPoint: String?
    public var sessionCount: Int?
    public var media: MediaKind = .unknown
    public var mediaID: String?
    public var entries: [DiscEntry] = []
    public var fileCount: Int = 0
    public var directoryCount: Int = 0
    public var totalBytes: Int64 = 0
    /// 无法读取时的解释（例如空白盘、音频 CD、未关闭区段）。
    public var note: String?
    /// 读取时临时挂载过（读取完已弹出）。
    public var mountedTemporarily: Bool = false

    public var isEmpty: Bool { entries.isEmpty }

    /// 简短摘要（用于主界面面板，不重复区段信息）。
    public var shortSummary: String {
        if let note = note, entries.isEmpty { return note }
        var text = "\(fileCount) 个文件"
        if directoryCount > 0 { text += "、\(directoryCount) 个文件夹" }
        text += " · " + ByteText.human(totalBytes)
        return text
    }

    public var summary: String {
        if let note = note, entries.isEmpty { return note }
        let size = ByteText.human(totalBytes)
        var text = "\(fileCount) 个文件"
        if directoryCount > 0 { text += "、\(directoryCount) 个文件夹" }
        text += " · \(size)"
        if let sessions = sessionCount, sessions > 1 {
            text += " · 共 \(sessions) 个区段（此处为系统挂载的那一段）"
        }
        return text
    }
}

public enum DiscReadSource {
    case device(String)
    case image(URL)

    public var displayPath: String {
        switch self {
        case .device(let node): return node
        case .image(let url): return url.path
        }
    }
}

public enum DiscReaderError: LocalizedError {
    case blank
    case audioCD
    case notMountable(String)
    case mountFailed(String)

    public var errorDescription: String? {
        switch self {
        case .blank:
            return "这是一张空白盘，暂时没有内容。"
        case .audioCD:
            return "这是音频 CD，没有文件系统可读取（可以用 drutil toc 查看曲目）。"
        case .notMountable(let detail):
            return "系统无法挂载这张光盘的内容：\(detail)"
        case .mountFailed(let detail):
            return "挂载光盘失败：\(detail)"
        }
    }
}

/// 读取光盘内容。
///
/// 注意：多区段光盘上 macOS 每次只会挂载**其中一段**（Finder 里看到的那一份），
/// 其余区段在系统层面不可见，所以这里读到的就是「系统当前挂载的那一层」。
public enum DiscReader {

    /// 读取已插入光盘的内容。
    ///
    /// - Parameters:
    ///   - deviceNode: 例如 `/dev/disk4`
    ///   - media: 介质类型（用于给出更准确的提示）
    ///   - sessionCount: 区段数
    ///   - allowMount: 未挂载时是否临时挂载读取（读完自动弹出）
    public static func readDevice(
        _ deviceNode: String,
        media: MediaKind = .unknown,
        mediaID: String? = nil,
        sessionCount: Int? = nil,
        allowMount: Bool = true
    ) throws -> DiscContents {
        var contents = DiscContents()
        contents.source = deviceNode
        contents.media = media
        contents.mediaID = mediaID
        contents.sessionCount = sessionCount

        // 1. 系统已经自动挂载了就直接读；否则按需临时挂载
        if let info = diskInfo(deviceNode), let mountPoint = info.mountPoint {
            contents.mountPoint = mountPoint
            var read = try readContents(at: URL(fileURLWithPath: mountPoint))
            read.source = deviceNode
            read.media = media
            read.mediaID = mediaID
            read.sessionCount = sessionCount
            read.fileSystem = info.fileSystem ?? read.fileSystem
            read.volumeName = read.volumeName ?? info.volumeName
            read.note = sessionNote(sessionCount)
            return read
        }

        guard allowMount else {
            if let sessions = sessionCount, sessions == 0 {
                contents.note = "这张盘还没有区段，看起来是空白的。"
            } else {
                contents.note = "系统还没有挂载这张盘，点「临时挂载并读取」可以直接读一遍。"
            }
            return contents
        }

        return try withTemporaryMount(of: .device(deviceNode), media: media, mediaID: mediaID, sessionCount: sessionCount)
    }

    /// 读取磁盘映像（.iso/.dmg/.cdr）的内容，用来核对准备刻录的映像。
    public static func readImage(_ url: URL) throws -> DiscContents {
        var contents = DiscContents()
        contents.source = url.path
        contents.fileSystem = "光盘映像"
        if let info = diskInfo(url.path), let mountPoint = info.mountPoint {
            var read = try readContents(at: URL(fileURLWithPath: mountPoint))
            read.source = url.path
            read.note = nil
            return read
        }
        contents = try withTemporaryMount(of: .image(url), media: .unknown, mediaID: nil, sessionCount: nil)
        return contents
    }

    /// 挂载 → 读取 → 卸载。
    private static func withTemporaryMount(
        of source: DiscReadSource,
        media: MediaKind,
        mediaID: String?,
        sessionCount: Int?
    ) throws -> DiscContents {
        switch source {
        case .device(let node):
            return try readByAttachingDevice(node, media: media, mediaID: mediaID, sessionCount: sessionCount)
        case .image(let url):
            let mountPoint = FileManager.default.temporaryDirectory
                .appendingPathComponent("DiscBurner-mount-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: mountPoint) }

            let attach = Shell.tryRun(
                "hdiutil",
                ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mountPoint.path, url.path]
            )
            try checkAttach(attach, media: media)
            defer { _ = Shell.tryRun("hdiutil", ["detach", mountPoint.path]) }

            var contents = try readContents(at: mountPoint)
            contents.source = source.displayPath
            contents.media = media
            contents.mediaID = mediaID
            contents.sessionCount = sessionCount
            contents.mountPoint = mountPoint.path
            contents.mountedTemporarily = true
            contents.note = sessionNote(sessionCount)
            return contents
        }
    }

    /// 物理光驱不允许调用方指定挂载点：`hdiutil attach -mountpoint … /dev/diskN`
    /// 在 macOS 上会直接报「attach failed - 权限被拒绝」，所以只能让系统挂到
    /// `/Volumes` 下，读完再按整盘设备节点卸载。
    private static func readByAttachingDevice(
        _ deviceNode: String,
        media: MediaKind,
        mediaID: String?,
        sessionCount: Int?
    ) throws -> DiscContents {
        let attach = Shell.tryRun("hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", deviceNode])
        try checkAttach(attach, media: media)

        let report = AttachReport(output: attach.output)
        defer {
            if let node = report.baseDevice {
                detachTrying(node)
            } else if let mountPoint = report.mountPoint {
                detachTrying(mountPoint)
            }
        }

        guard let mountPoint = report.mountPoint ?? diskInfo(deviceNode)?.mountPoint else {
            throw DiscReaderError.mountFailed("系统挂载了这张盘，但没有找到挂载点")
        }

        var contents = try readContents(at: URL(fileURLWithPath: mountPoint))
        contents.source = deviceNode
        contents.media = media
        contents.mediaID = mediaID
        contents.sessionCount = sessionCount
        contents.mountPoint = mountPoint
        contents.mountedTemporarily = true
        contents.note = sessionNote(sessionCount)
        return contents
    }

    /// 卸载临时挂载的光盘。
    ///
    /// 刚读完盘时卷可能还被 Spotlight / Finder 抓着，第一次 detach 会失败，
    /// 这时等一下再试，最后用 -force 兜底，别把卷留在 /Volumes 里。
    @discardableResult
    static func detachTrying(_ target: String) -> Bool {
        if Shell.tryRun("hdiutil", ["detach", target]).succeeded { return true }
        Thread.sleep(forTimeInterval: 0.6)
        if Shell.tryRun("hdiutil", ["detach", target]).succeeded { return true }
        Thread.sleep(forTimeInterval: 0.6)
        return Shell.tryRun("hdiutil", ["detach", "-force", target]).succeeded
    }

    /// 解析 `hdiutil attach` 的输出。
    ///
    /// 每行形如 `/dev/disk6s1\tApple_HFS\tDISC\t123\t/Volumes/DISC`，
    /// 首列是设备节点、最后一列（如果有）是挂载点。
    public struct AttachReport {
        public var baseDevice: String?
        public var mountPoint: String?

        public init(output: String) {
            for line in output.split(separator: "\n") {
                let fields = line
                    .split(separator: "\t", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if baseDevice == nil, let first = fields.first, first.hasPrefix("/dev/disk") {
                    baseDevice = first
                }
                if let last = fields.last, last.hasPrefix("/Volumes/") {
                    mountPoint = last
                }
            }
        }
    }

    private static func checkAttach(_ attach: CommandResult, media: MediaKind) throws {
        guard !attach.succeeded else { return }
        let detail = attach.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.lowercased().contains("no mountable file systems") {
            if !media.isWritable || media == .unknown {
                throw DiscReaderError.notMountable("介质上没有系统可识别的文件系统（可能是音频 CD 或未格式化）")
            }
            throw DiscReaderError.blank
        }
        throw DiscReaderError.mountFailed(detail)
    }

    private static func sessionNote(_ sessionCount: Int?) -> String? {
        guard let sessions = sessionCount, sessions > 1 else { return nil }
        return "这张盘有 \(sessions) 个区段，macOS 每次只会挂载其中一段（不一定是最后刻的那段），这里显示的就是系统当前挂载的这一段。"
    }

    // MARK: - 目录遍历

    public static func readContents(at url: URL) throws -> DiscContents {
        var contents = DiscContents()
        contents.mountPoint = url.path

        // 卷名：ISO9660 / Rock Ridge 挂载时 URL 资源里的卷名可能是挂载点目录名，
        // 所以优先用 diskutil 报告的名字。
        if let info = diskInfo(url.path), let name = info.volumeName, !isTemporaryMountName(name) {
            contents.volumeName = name
        } else if let values = try? url.resourceValues(forKeys: [.volumeNameKey]) {
            contents.volumeName = values.volumeName
        }

        var fileCount = 0
        var directoryCount = 0
        var totalBytes: Int64 = 0

        func scan(_ directory: URL, depth: Int) -> [DiscEntry] {
            guard depth <= 32 else { return [] }
            var result: [DiscEntry] = []
            for child in FileTree.children(of: directory.path) {
                let relative = child.path
                    .replacingOccurrences(of: url.path, with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

                if child.kind == .directory {
                    let nested = scan(URL(fileURLWithPath: child.path), depth: depth + 1)
                    directoryCount += 1
                    let nestedSize = nested.reduce(Int64(0)) { $0 + $1.byteCount }
                    totalBytes += nestedSize
                    result.append(
                        DiscEntry(
                            id: relative,
                            name: child.name,
                            relativePath: relative,
                            isDirectory: true,
                            isSymlink: false,
                            linkTarget: nil,
                            byteCount: nestedSize,
                            children: nested
                        )
                    )
                } else {
                    fileCount += 1
                    totalBytes += child.size
                    result.append(
                        DiscEntry(
                            id: relative,
                            name: child.name,
                            relativePath: relative,
                            isDirectory: false,
                            isSymlink: child.kind == .symlink,
                            linkTarget: child.linkTarget,
                            byteCount: child.size,
                            children: []
                        )
                    )
                }
                if fileCount > 20000 { break }
            }
            return result
        }

        contents.entries = scan(url, depth: 0)
        contents.fileCount = fileCount
        contents.directoryCount = directoryCount
        contents.totalBytes = totalBytes
        return contents
    }

    static func isTemporaryMountName(_ name: String) -> Bool {
        name.hasPrefix("DiscBurner-mount-")
    }

    // MARK: - diskutil 信息

    struct DiskInfo {
        var mountPoint: String?
        var volumeName: String?
        var fileSystem: String?
    }

    static func diskInfo(_ target: String) -> DiskInfo? {
        let result = Shell.tryRun("diskutil", ["info", "-plist", target])
        guard result.succeeded,
              let data = result.output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            return nil
        }
        func string(_ key: String) -> String? {
            guard let value = dictionary[key] as? String, !value.isEmpty, value != "Not applicable" else { return nil }
            return value
        }
        return DiskInfo(
            mountPoint: string("MountPoint"),
            volumeName: string("VolumeName"),
            fileSystem: string("FilesystemName") ?? string("FilesystemType")
        )
    }
}

public extension DiscEntry {
    /// 把树拍平成「层级 + 名称」的列表，方便命令行输出和列表控件展示。
    func flatten(depth: Int = 0) -> [(depth: Int, entry: DiscEntry)] {
        var result: [(Int, DiscEntry)] = [(depth, self)]
        for child in children {
            result.append(contentsOf: child.flatten(depth: depth + 1))
        }
        return result
    }
}
