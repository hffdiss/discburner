import Foundation

/// 盘上「一整份内容」里的一条记录（带相对路径）。
///
/// `extent` 已经是**光盘绝对扇区**：旧版本刻的盘把地址写成了「本段内的相对地址」，
/// 这里在读取阶段就把段起始补回去，后面导出内容时不用再关心寻址方式。
public struct DiscContentFile: Equatable {
    /// 相对路径，例如 `第一段/子目录/嵌套.txt`。
    public var relativePath: String
    /// 内容所在的绝对扇区。
    public var extent: Int
    /// 内容字节数。
    public var size: Int

    public init(relativePath: String, extent: Int, size: Int) {
        self.relativePath = relativePath
        self.extent = extent
        self.size = size
    }
}

/// 整张盘的完整内容。
///
/// 多区段盘上每一段都是「一份完整卷」：正常嫁接出来的最后一段，目录树里本来就
/// 包含之前所有段的文件，所以只读最后一段就够了；旧版本刻的盘（每段各自寻址）
/// 读不出来时，退化成逐段合并——后面的段覆盖前面同名的文件。
public struct DiscContentView {
    public init() {}

    public var files: [DiscContentFile] = []
    /// 空目录的相对路径（ISO 里一般没有，留着了兼容）。
    public var directories: [String] = []
    public var totalBytes: Int64 = 0
    /// 这份内容用到了哪些段（绝对起始扇区，升序）。
    public var sessions: [Int] = []
    /// 只读最后一段就拿到了完整内容（正常情况）。
    public var fromLastSessionOnly = true
    /// 需要说明的特殊情况（例如旧盘只能逐段合并）。
    public var note: String?

    public var fileCount: Int { files.count }
    public var isEmpty: Bool { files.isEmpty }

    public var summary: String {
        var text = "\(files.count) 个文件"
        if !directories.isEmpty { text += "、\(directories.count) 个文件夹" }
        text += " · " + ByteText.human(totalBytes)
        if sessions.count > 1 {
            text += fromLastSessionOnly
                ? " · 来自第 \(sessions.count) 段（已含前面各段）"
                : " · 由 \(sessions.count) 段合并"
        }
        return text
    }
}

/// 导出盘上内容时怎么处理同名文件。
public enum DiscContentConflict {
    /// 覆盖已存在的文件（导出到空目录时用）。
    case replace
    /// 保留已存在的文件（把盘上内容并进待刻目录时用：新加的文件优先）。
    case skipExisting
}

public extension DiscContentView {
    /// 转成界面用的树（左上「光盘里已有的内容」栏直接渲染这个）。
    ///
    /// 系统只挂载多区段盘的其中一段，而这一份是按扇区读出来的**整盘**内容，
    /// 所以界面显示的和盘上真实的能对上——追加刻录最容易踩的就是这个坑。
    func asDiscContents(
        source: String,
        media: MediaKind = .unknown,
        mediaID: String? = nil,
        volumeName: String? = nil,
        fileSystem: String? = nil
    ) -> DiscContents {
        var isDirectory: [String: Bool] = [:]
        for directory in directories { isDirectory[directory] = true }
        for file in files {
            isDirectory[file.relativePath] = false
            for parent in DiscContentView.parentPaths(of: file.relativePath) where isDirectory[parent] == nil {
                isDirectory[parent] = true
            }
        }
        var sizes: [String: Int64] = [:]
        for file in files { sizes[file.relativePath] = Int64(file.size) }

        func name(of path: String) -> String {
            path.split(separator: "/").last.map(String.init) ?? path
        }

        func entries(under prefix: String) -> [DiscEntry] {
            let head = prefix.isEmpty ? "" : prefix + "/"
            let children = isDirectory.keys.filter { path in
                guard path.hasPrefix(head) else { return false }
                let rest = path.dropFirst(head.count)
                return !rest.isEmpty && !rest.contains("/")
            }
            return children
                .sorted { left, right in
                    let leftIsDir = isDirectory[left] ?? false
                    let rightIsDir = isDirectory[right] ?? false
                    if leftIsDir != rightIsDir { return leftIsDir }
                    return left.localizedStandardCompare(right) == .orderedAscending
                }
                .map { path in
                    let directory = isDirectory[path] ?? false
                    return DiscEntry(
                        id: path,
                        name: name(of: path),
                        relativePath: path,
                        isDirectory: directory,
                        isSymlink: false,
                        linkTarget: nil,
                        byteCount: directory ? 0 : (sizes[path] ?? 0),
                        children: directory ? entries(under: path) : []
                    )
                }
        }

        var contents = DiscContents()
        contents.source = source
        contents.media = media
        contents.mediaID = mediaID
        contents.volumeName = volumeName
        contents.fileSystem = fileSystem
        contents.sessionCount = sessions.count
        contents.entries = entries(under: "")
        contents.fileCount = files.count
        contents.directoryCount = isDirectory.values.filter { $0 }.count
        contents.totalBytes = totalBytes
        contents.note = note
        return contents
    }

    /// `a/b/c.txt` → `["a/b", "a"]`（从下往上）。
    static func parentPaths(of path: String) -> [String] {
        var parts = path.split(separator: "/").dropLast()
        var result: [String] = []
        while !parts.isEmpty {
            result.append(parts.joined(separator: "/"))
            parts = parts.dropLast()
        }
        return result
    }
}

public struct DiscExtractSummary {
    public var files: Int = 0
    public var skipped: Int = 0
    public var bytes: Int64 = 0

    public var description: String {
        var text = "导出 \(files) 个文件 · " + ByteText.human(bytes)
        if skipped > 0 { text += " · 跳过 \(skipped) 个同名文件（保留现有内容）" }
        return text
    }
}

public enum DiscContentError: LocalizedError {
    case noSessions
    case unreadable(device: String, sector: Int)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noSessions:
            return "这张盘上还没有任何区段，没有内容可以导出。"
        case .unreadable(let device, let sector):
            return "读 \(device) 的第 \(sector) 扇区失败：盘上这一段读不出来（可能有划伤，或者旧版本刻的盘）。"
        case .cancelled:
            return "已取消。"
        }
    }
}

/// 读「整张盘的内容」。
///
/// 为什么不能用系统挂载：macOS 的 cd9660 驱动根本不认多区段，永远只挂第一段；
/// Linux 的 isofs 也只在光驱能把「最后一段起始」告诉内核时才读最后一段。
/// 所以要让用户看到「盘上真正有什么」，必须自己按段读原始扇区。
public enum DiscContentReader {
    /// 从设备读一份完整内容；读不到（空盘、没介质）返回 nil。
    public static func read(deviceNode: String, layout: DiscLayout, includeJoliet: Bool = true) -> DiscContentView? {
        guard let reader = IsoImageReader(deviceNode: deviceNode) else { return nil }
        return read(reader: reader, layout: layout, includeJoliet: includeJoliet)
    }

    /// 从映像（文件 / 设备）读一份完整内容。
    public static func read(reader: IsoImageReader, layout: DiscLayout, includeJoliet: Bool = true) -> DiscContentView? {
        let starts = layout.sessionStarts
        guard let last = starts.last else { return nil }

        if let only = session(reader: reader, sessionStart: last, includeJoliet: includeJoliet),
           only.referencesOlderFiles(sessionStart: last) || starts.count == 1 {
            return view(files: only.files, directories: only.directories, sessions: [last], fromLastSessionOnly: true)
        }

        // 旧盘（每段各自从本段开头算地址）或者最后一段没嫁接：逐段读、后面的段覆盖前面。
        var merged: [String: DiscContentFile] = [:]
        var directories = Set<String>()
        var used: [Int] = []
        for start in starts {
            guard let part = session(reader: reader, sessionStart: start, includeJoliet: includeJoliet) else { continue }
            used.append(start)
            for file in part.files { merged[file.relativePath] = file }
            directories.formUnion(part.directories)
        }
        guard !used.isEmpty else {
            return view(files: [], directories: [], sessions: starts, fromLastSessionOnly: false)
        }
        var result = view(
            files: merged.values.sorted { $0.relativePath < $1.relativePath },
            directories: directories.sorted(),
            sessions: used,
            fromLastSessionOnly: false
        )
        if used.count > 1 {
            result.note = "这张盘是多区段盘，系统只会挂载其中一段；下面是按段合并出来的完整内容。"
        }
        return result
    }

    /// 把内容导出到目录（保持原来的目录结构）。
    public static func extract(
        _ view: DiscContentView,
        deviceNode: String,
        to destination: URL,
        conflict: DiscContentConflict = .replace,
        canceller: CommandCanceller? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) throws -> DiscExtractSummary {
        guard let reader = IsoImageReader(deviceNode: deviceNode) else {
            throw DiscContentError.unreadable(device: deviceNode, sector: 0)
        }
        return try extract(
            view,
            reader: reader,
            source: deviceNode,
            to: destination,
            conflict: conflict,
            canceller: canceller,
            onProgress: onProgress
        )
    }

    /// 把内容导出到目录；`reader` 可以是设备，也可以是映像文件。
    public static func extract(
        _ view: DiscContentView,
        reader: IsoImageReader,
        source: String = "光盘",
        to destination: URL,
        conflict: DiscContentConflict = .replace,
        canceller: CommandCanceller? = nil,
        onProgress: ((Double) -> Void)? = nil
    ) throws -> DiscExtractSummary {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        var summary = DiscExtractSummary()
        let total = max(view.totalBytes, 1)
        var copied: Int64 = 0
        let chunk = 1 << 20

        for file in view.files {
            if let canceller = canceller, canceller.isCancelled { throw DiscContentError.cancelled }
            guard let relative = sanitize(relativePath: file.relativePath) else { continue }
            let target = destination.appendingPathComponent(relative)
            if conflict == .skipExisting, fileManager.fileExists(atPath: target.path) {
                summary.skipped += 1
                copied += Int64(file.size)
                onProgress?(Double(copied) / Double(total))
                continue
            }
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            fileManager.createFile(atPath: target.path, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: target.path) else {
                throw DiscContentError.unreadable(device: source, sector: file.extent)
            }
            defer { try? handle.close() }

            var written = 0
            while written < file.size {
                let take = min(chunk, file.size - written)
                guard let data = reader.read(extent: file.extent + written / IsoImageReader.sectorSize, size: take),
                      data.count == take else {
                    throw DiscContentError.unreadable(
                        device: source,
                        sector: file.extent + written / IsoImageReader.sectorSize
                    )
                }
                handle.write(data)
                written += take
                copied += Int64(take)
                onProgress?(Double(copied) / Double(total))
            }
            summary.files += 1
            summary.bytes += Int64(file.size)
        }
        return summary
    }

    // MARK: - 内部

    struct SessionContent {
        var files: [DiscContentFile]
        var directories: [String]

        /// 目录树里有没有引用到本段之前就写好的文件（= 这一段是嫁接出来的，含旧内容）。
        func referencesOlderFiles(sessionStart: Int) -> Bool {
            files.contains { $0.extent < sessionStart }
        }
    }

    static func session(reader: IsoImageReader, sessionStart: Int, includeJoliet: Bool) -> SessionContent? {
        // 主卷决定寻址方式：根目录落在本段起始之前，说明这一段是「本段相对地址」写的。
        guard let primary = IsoTree.rootRecord(in: reader, imageStart: sessionStart, joliet: false) else {
            return nil
        }
        let shift = primary.extent >= sessionStart ? 0 : sessionStart
        var jolietRoot: (extent: Int, size: Int)?
        if includeJoliet {
            jolietRoot = IsoTree.rootRecord(in: reader, imageStart: sessionStart, joliet: true)
        }
        let root = jolietRoot ?? primary
        var files: [DiscContentFile] = []
        var directories: [String] = []
        var visited = Set<Int>()
        walk(
            reader: reader,
            directoryExtent: root.extent + shift,
            directorySize: root.size,
            addressShift: shift,
            joliet: jolietRoot != nil,
            prefix: "",
            visited: &visited,
            files: &files,
            directories: &directories
        )
        guard !files.isEmpty || !directories.isEmpty else { return nil }
        return SessionContent(files: files, directories: directories)
    }

    static func walk(
        reader: IsoImageReader,
        directoryExtent: Int,
        directorySize: Int,
        addressShift: Int,
        joliet: Bool,
        prefix: String,
        visited: inout Set<Int>,
        files: inout [DiscContentFile],
        directories: inout [String]
    ) {
        guard directoryExtent >= 0, directorySize > 0 else { return }
        guard visited.insert(directoryExtent).inserted else { return }
        guard let block = reader.read(extent: directoryExtent, size: directorySize) else { return }
        let bytes = [UInt8](block)
        var offset = 0
        while offset < bytes.count {
            let length = Int(bytes[offset])
            if length == 0 {
                offset = ((offset / IsoImageReader.sectorSize) + 1) * IsoImageReader.sectorSize
                continue
            }
            guard length >= 34, offset + length <= bytes.count else { break }
            let nameLength = Int(bytes[offset + 32])
            let nameStart = offset + 33
            let isDirectory = (bytes[offset + 25] & 2) != 0
            let isDot = nameLength == 1 && (bytes[nameStart] == 0 || bytes[nameStart] == 1)
            if !isDot, nameStart + nameLength <= bytes.count {
                let rawExtent = Int(IsoTree.littleEndian32(bytes, offset + 2))
                let size = Int(IsoTree.littleEndian32(bytes, offset + 10))
                let name = decode(Data(bytes[nameStart..<(nameStart + nameLength)]), joliet: joliet)
                let path = prefix.isEmpty ? name : prefix + "/" + name
                if isDirectory {
                    directories.append(path)
                    walk(
                        reader: reader,
                        directoryExtent: rawExtent + addressShift,
                        directorySize: size,
                        addressShift: addressShift,
                        joliet: joliet,
                        prefix: path,
                        visited: &visited,
                        files: &files,
                        directories: &directories
                    )
                } else {
                    files.append(
                        DiscContentFile(relativePath: path, extent: rawExtent + addressShift, size: size)
                    )
                }
            }
            offset += length
        }
    }

    static func decode(_ bytes: Data, joliet: Bool) -> String {
        if joliet {
            var units: [UInt16] = []
            let raw = [UInt8](bytes)
            var index = 0
            while index + 1 < raw.count {
                units.append(UInt16(raw[index]) << 8 | UInt16(raw[index + 1]))
                index += 2
            }
            return String(decoding: units, as: UTF16.self)
        }
        var name = String(decoding: [UInt8](bytes), as: UTF8.self)
        if let semicolon = name.firstIndex(of: ";") { name = String(name[name.startIndex..<semicolon]) }
        return name
    }

    static func view(
        files: [DiscContentFile],
        directories: [String],
        sessions: [Int],
        fromLastSessionOnly: Bool
    ) -> DiscContentView {
        var content = DiscContentView()
        content.files = files
        content.directories = directories
        content.sessions = sessions
        content.fromLastSessionOnly = fromLastSessionOnly
        content.totalBytes = files.reduce(Int64(0)) { $0 + Int64($1.size) }
        return content
    }

    /// 把目录树里的相对路径收干净：挡掉 `..`、绝对路径和空名字，防止导出时跑到目标目录外面。
    public static func sanitize(relativePath: String) -> String? {
        let parts = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "/")
    }
}
