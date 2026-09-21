import Foundation

/// `drutil trackinfo` 里的一条轨道。
public struct DiscTrack: Equatable {
    public var trackNumber: Int
    public var sessionNumber: Int
    /// 轨道起始的**光盘绝对扇区**。
    public var startAddress: Int
    /// 下一个可写地址；只有可追加的那条轨道才会给出有效值。
    public var nextWritableAddress: Int?
    public var trackSize: Int
    public var isBlank: Bool

    public init(
        trackNumber: Int,
        sessionNumber: Int,
        startAddress: Int,
        nextWritableAddress: Int? = nil,
        trackSize: Int = 0,
        isBlank: Bool = false
    ) {
        self.trackNumber = trackNumber
        self.sessionNumber = sessionNumber
        self.startAddress = startAddress
        self.nextWritableAddress = nextWritableAddress
        self.trackSize = trackSize
        self.isBlank = isBlank
    }
}

/// 一张盘的分段布局。
///
/// 多区段追加必须知道两件事：盘上最后一段从哪个绝对扇区开始（旧文件都在那之后），
/// 以及下一段会从哪个绝对扇区开始写（新文件的目标地址）。
public struct DiscLayout: Equatable {
    public var tracks: [DiscTrack]
    /// 每一段（已经写入内容的那一段）的起始绝对扇区，按段号升序。
    public var sessionStarts: [Int]
    /// 驱动器报告的下一个可写地址（扇区）。
    public var nextWritableAddress: Int?
    /// 盘上已经有内容的段数。
    public var recordedSessions: Int

    public init(tracks: [DiscTrack] = [], sessionStarts: [Int] = [], nextWritableAddress: Int? = nil, recordedSessions: Int = 0) {
        self.tracks = tracks
        self.sessionStarts = sessionStarts
        self.nextWritableAddress = nextWritableAddress
        self.recordedSessions = recordedSessions
    }

    public static let empty = DiscLayout()

    public var lastSessionStart: Int? { sessionStarts.last }
    public var isEmpty: Bool { recordedSessions == 0 }

    /// 解析 `drutil trackinfo` 的文本输出。
    ///
    /// ```
    ///   Track 12 info:
    ///                    blank: true
    ///        trackStartAddress: 546880
    ///      nextWritableAddress: 546880 (valid)
    ///                trackSize: 1748224
    /// ```
    public static func parse(trackInfo output: String) -> DiscLayout {
        var tracks: [DiscTrack] = []
        var fields: [String: String] = [:]

        func flush() {
            defer { fields = [:] }
            guard let numberText = fields["tracknumber"], let number = Int(numberText) else { return }
            let session = Int(fields["sessionnumber"] ?? "") ?? number
            let start = Int(fields["trackstartaddress"] ?? "") ?? 0
            let size = Int(fields["tracksize"] ?? "") ?? 0
            let blank = (fields["blank"] ?? "false").lowercased() == "true"
            var next: Int?
            if let raw = fields["nextwritableaddress"] {
                let text = raw.lowercased()
                let digits = text.prefix { $0.isNumber }
                if !text.contains("not valid"), !digits.isEmpty {
                    next = Int(digits)
                }
            }
            tracks.append(
                DiscTrack(
                    trackNumber: number,
                    sessionNumber: session,
                    startAddress: start,
                    nextWritableAddress: next,
                    trackSize: size,
                    isBlank: blank
                )
            )
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Track ") && line.hasSuffix("info:") {
                flush()
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { fields[key] = value }
        }
        flush()

        // 段起始：同一段里有多条轨道时取最小的那个地址。
        var startsBySession: [Int: Int] = [:]
        var sessionsWithData = Set<Int>()
        for track in tracks {
            let existing = startsBySession[track.sessionNumber]
            startsBySession[track.sessionNumber] = min(existing ?? track.startAddress, track.startAddress)
            if !track.isBlank { sessionsWithData.insert(track.sessionNumber) }
        }
        let recordedStarts = sessionsWithData.sorted().compactMap { startsBySession[$0] }
        let next = tracks.compactMap { $0.nextWritableAddress }.max()

        return DiscLayout(
            tracks: tracks,
            sessionStarts: recordedStarts,
            nextWritableAddress: next,
            recordedSessions: sessionsWithData.count
        )
    }
}

/// 追加到已有内容的盘上时需要的嫁接信息。
public struct AppendTarget: Equatable {
    /// 光盘设备节点（例如 `/dev/disk2`）。
    public var devicePath: String
    /// 最后一段的起始绝对扇区。
    public var lastSessionStart: Int
    /// 下一段的起始绝对扇区（驱动器报告的下一个可写地址）。
    public var nextWritableAddress: Int
    /// 旧段目录树里的文件数；嫁接完要能在新段里找到它们。
    public var oldFileCount: Int

    public init(
        devicePath: String,
        lastSessionStart: Int,
        nextWritableAddress: Int,
        oldFileCount: Int = 0
    ) {
        self.devicePath = devicePath
        self.lastSessionStart = lastSessionStart
        self.nextWritableAddress = nextWritableAddress
        self.oldFileCount = oldFileCount
    }

    /// 这个来源是不是光驱设备本身（否则就是我们自己造的稀疏映像文件）。
    public var isDevice: Bool { devicePath.hasPrefix("/dev/") }

    /// 换成「按扇区拷出来的稀疏映像」作为旧段来源。
    public func usingImage(at url: URL) -> AppendTarget {
        AppendTarget(
            devicePath: url.path,
            lastSessionStart: lastSessionStart,
            nextWritableAddress: nextWritableAddress,
            oldFileCount: oldFileCount
        )
    }
}

/// 盘上旧区段能不能被新段「接上」。
public enum DiscChainState: Equatable {
    /// 新段里能看到旧段的全部内容（标准多区段）。
    case complete
    /// 旧版本刻的盘：每段各自独立寻址，接上去会让旧内容在 Windows/Linux 上消失。
    case broken
    /// 读不到盘（没有权限等），无法判断。
    case unknown

    public var localizedDescription: String {
        switch self {
        case .complete: return "旧区段可合并"
        case .broken: return "旧区段不兼容（旧版本刻的盘）"
        case .unknown: return "无法读取旧区段"
        }
    }
}

/// 直接按扇区读光盘设备。
///
/// macOS 会把光驱设备节点交给当前登录用户（`/dev/rdisk2` 属主就是用户自己），
/// 所以不用 root 也能读出盘上的目录结构——多区段嫁接必须知道旧段里有什么。
public enum RawDisc {
    public static let sectorSize = 2048

    /// `/dev/disk2` → `/dev/rdisk2`（原始设备，读起来更快）。
    public static func rawPath(for deviceNode: String) -> String {
        guard deviceNode.hasPrefix("/dev/disk") else { return deviceNode }
        let raw = deviceNode.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
        return FileManager.default.fileExists(atPath: raw) ? raw : deviceNode
    }

    /// 读若干个扇区。失败时抛 `MultisessionError.deviceUnreadable`。
    public static func read(deviceNode: String, sector: Int, sectors: Int = 1) throws -> Data {
        let path = rawPath(for: deviceNode)
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw MultisessionError.deviceUnreadable(device: deviceNode)
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(0, sector) * sectorSize))
            guard let data = try handle.read(upToCount: sectors * sectorSize), data.count == sectors * sectorSize else {
                throw MultisessionError.deviceUnreadable(device: deviceNode)
            }
            return data
        } catch let error as MultisessionError {
            throw error
        } catch {
            throw MultisessionError.deviceUnreadable(device: deviceNode)
        }
    }

    /// 从一段光盘数据里取出 ISO 9660 的根目录地址（主卷描述符里的根目录记录）。
    public static func rootDirectorySector(inVolumeDescriptor descriptor: Data) -> Int? {
        guard descriptor.count >= 190 else { return nil }
        let id = descriptor.subdata(in: 1..<6)
        guard String(data: id, encoding: .ascii) == "CD001" else { return nil }
        let record = descriptor.subdata(in: 156..<190)
        guard record.count >= 14 else { return nil }
        return Int(littleEndian32(record.subdata(in: 2..<6)))
    }

    public static func littleEndian32(_ data: Data) -> UInt32 {
        guard data.count >= 4 else { return 0 }
        let bytes = [UInt8](data.prefix(4))
        return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
    }
}

public enum MultisessionError: LocalizedError {
    case noTrackInfo
    case deviceUnreadable(device: String)
    case appendUnsupported(reason: String)
    case graftNotAbsolute(sector: Int, sessionStart: Int)
    case graftMissingOldFiles(count: Int)
    case graftImageFailed(device: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .noTrackInfo:
            return "读不到光盘的区段信息（drutil trackinfo 没有输出）。"
        case .deviceUnreadable(let device):
            return "读不到光盘设备 \(device) 的原始数据，无法判断盘上旧区段的情况。"
        case .appendUnsupported(let reason):
            return reason
        case .graftNotAbsolute(let sector, let sessionStart):
            return "新段的目录树地址是 \(sector)，落在这段自己的范围（从 \(sessionStart) 起）之外，"
                + "说明这段又是「区段相对寻址」，Windows / Linux 上会读不到内容。"
        case .graftMissingOldFiles(let count):
            return "新段里没有引用到盘上原有的 \(count) 个文件——嫁接没生效，刻下去会让旧内容消失。"
        case .graftImageFailed(let device, let reason):
            return "没法从 \(device) 读出旧段内容来给映像工具用：\(reason)"
        }
    }
}

/// 多区段相关的查询。
public enum Multisession {
    /// 这次刻录要不要做多区段嫁接（把新段接到旧内容后面）。
    ///
    /// 判据是「驱动器说这盘可以追加写入」，**不是**段数：驱动器会把空白盘上那条
    /// 空白轨道也算成一段（实测空白 DVD+R 的 `discinfo` 就是 `Sessions: 1`），
    /// 只看段数会把空盘误判成需要嫁接，直接拒绝刻录。
    public static func needsGraft(status: DiscStatus, eraseFirst: Bool = false) -> Bool {
        guard !eraseFirst else { return false }
        return status.writability == .appendable
    }

    /// 读 `drutil trackinfo`。
    public static func layout(driveIndex: Int? = nil) throws -> DiscLayout {
        var arguments: [String] = []
        if let index = driveIndex {
            arguments += ["-drive", "\(index)"]
        }
        arguments.append("trackinfo")
        let result = try Shell.run("drutil", arguments)
        guard result.succeeded else { return .empty }
        return DiscLayout.parse(trackInfo: result.output)
    }

    /// 判断盘上已有的段能不能被新段接上。
    ///
    /// 标准多区段盘的每一段都是「绝对寻址 + 包含之前所有文件」，
    /// 所以最后一段的根目录一定落在这一段自己的范围内。
    /// 早期版本是「每段各自一个独立文件系统、用区段相对地址」，
    /// 根目录地址会小于本段起始扇区——这种盘接上去只会让旧内容消失。
    public static func chainState(deviceNode: String, layout: DiscLayout) -> DiscChainState {
        guard let start = layout.lastSessionStart else { return .unknown }
        guard let descriptor = try? RawDisc.read(deviceNode: deviceNode, sector: start + 16) else {
            return .unknown
        }
        guard let root = RawDisc.rootDirectorySector(inVolumeDescriptor: descriptor) else {
            return .unknown
        }
        return root >= start ? .complete : .broken
    }

    /// 组装追加所需的嫁接信息；不满足条件时返回 nil 或抛错。
    public static func appendTarget(
        status: DiscStatus,
        layout: DiscLayout,
        eraseFirst: Bool
    ) throws -> AppendTarget? {
        guard !eraseFirst else { return nil }
        guard !layout.isEmpty else { return nil }
        guard let devicePath = status.deviceNode, !devicePath.isEmpty else {
            throw MultisessionError.appendUnsupported(
                reason: "拿不到光盘设备节点，无法把新内容嫁接到已有区段上。"
            )
        }
        guard let lastStart = layout.lastSessionStart,
              let next = layout.nextWritableAddress,
              next > lastStart else {
            throw MultisessionError.appendUnsupported(
                reason: "驱动器没有报告下一个可写地址，这张盘现在不能追加。"
            )
        }
        return AppendTarget(devicePath: devicePath, lastSessionStart: lastStart, nextWritableAddress: next)
    }

    // MARK: - 让映像工具读到旧段

    /// 盘上的卷是不是被系统挂载着。
    ///
    /// 挂载状态下 xorriso 打不开块设备（`Failed to open device ... Resource busy`），
    /// 所以嫁接之前要先把卷卸下来独占读盘——写盘时本来也应该独占。
    ///
    /// 判据用 `/sbin/mount` 的输出：`diskutil info -plist` 无论有没有挂载都会给一个
    /// 空的 `MountPoint` 字段，靠它判断会一直误判成「已挂载」。
    public static func isMounted(deviceNode: String) -> Bool {
        guard let result = try? Shell.run("mount", []) else { return false }
        for line in result.output.split(separator: "\n") {
            guard let device = line.split(separator: " ").first.map(String.init) else { continue }
            if device == deviceNode || device.hasPrefix(deviceNode + "s") { return true }
        }
        return false
    }

    /// 卸载盘上的卷（没挂载时什么都不做）。返回是否已经不是挂载状态。
    @discardableResult
    public static func unmount(deviceNode: String) -> Bool {
        if !isMounted(deviceNode: deviceNode) { return true }
        _ = try? Shell.run("diskutil", ["unmount", deviceNode])
        return !isMounted(deviceNode: deviceNode)
    }

    /// 把卷重新挂回系统（刻录失败时把我们卸下来的卷放回去）。
    @discardableResult
    public static func mount(deviceNode: String) -> Bool {
        guard let result = try? Shell.run("diskutil", ["mount", deviceNode]) else { return false }
        return result.succeeded
    }

    /// 数一数某个段（绝对起始扇区 `sessionStart`）的目录树里有多少个文件。
    ///
    /// 嫁接之后必须能在新段里找到这些旧文件，所以刻之前先把数量记下来当验收标准。
    public static func fileCount(deviceNode: String, sessionStart: Int) -> Int? {
        guard let reader = IsoImageReader(deviceNode: deviceNode) else { return nil }
        // 只看主卷：Joliet 视图和主卷指向同一批文件，两边都数会翻倍。
        let entries = IsoTree.entries(in: reader, imageStart: sessionStart, includeJoliet: false)
        guard !entries.isEmpty else { return nil }
        return entries.filter { !$0.isDirectory }.count
    }

    /// 把旧盘上「嫁接要用到的扇区」按扇区读出来，拼成一张稀疏映像文件。
    ///
    /// 为什么需要它：映像工具得知道旧段的目录树长什么样，才能让新段去引用旧文件。
    /// 能直接读光驱时就不用这个；设备被占用（例如卷还挂载着、或权限不够）时用它兜底，
    /// 好处是完全不依赖挂载状态，读写都走我们自己的原始扇区读。
    ///
    /// 只抄两处：
    /// - 第 1 段的卷描述符（几个扇区）：让工具知道「这张盘上有内容」，否则它会当成空白介质，
    ///   拒绝按偏移量去查旧段（`Non-zero load offset given with blank input media`）。
    /// - 最后一段的全部扇区：新段要照着它的目录树做嫁接。
    @discardableResult
    public static func sparseGraftImage(
        deviceNode: String,
        layout: DiscLayout,
        outputURL: URL,
        onProgress: ((Double) -> Void)? = nil
    ) throws -> URL {
        guard let lastStart = layout.lastSessionStart,
              let next = layout.nextWritableAddress,
              next > lastStart else {
            throw MultisessionError.appendUnsupported(reason: "读不到旧段的起始扇区，没法准备嫁接。")
        }

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputURL)
        guard fileManager.createFile(atPath: outputURL.path, contents: nil),
              let handle = FileHandle(forWritingAtPath: outputURL.path) else {
            throw MultisessionError.graftImageFailed(device: deviceNode, reason: "写不了临时映像 \(outputURL.path)")
        }
        defer { try? handle.close() }

        let chunkSectors = 1024
        let descriptors = 4
        let total = descriptors + (next - lastStart)
        var done = 0

        func copy(sector: Int, sectors: Int) throws {
            var copied = 0
            while copied < sectors {
                let take = min(chunkSectors, sectors - copied)
                let data: Data
                do {
                    data = try RawDisc.read(deviceNode: deviceNode, sector: sector + copied, sectors: take)
                } catch {
                    throw MultisessionError.graftImageFailed(
                        device: deviceNode,
                        reason: "读第 \(sector + copied) 扇区失败"
                    )
                }
                try handle.seek(toOffset: UInt64(sector + copied) * UInt64(RawDisc.sectorSize))
                handle.write(data)
                copied += take
                done += take
                onProgress?(Double(done) / Double(max(total, 1)))
            }
        }

        // 第 1 段的卷描述符（PVD / Joliet / 结束符）：只当「介质非空」的标记用。
        try copy(sector: 16, sectors: descriptors)
        // 最后一段：新段嫁接时要照抄的目录树就在这一段里。
        try copy(sector: lastStart, sectors: next - lastStart)
        try handle.truncate(atOffset: UInt64(next) * UInt64(RawDisc.sectorSize))
        return outputURL
    }

    // MARK: - 验收

    /// 嫁接完的新段必须同时满足两条，否则刻下去只会让旧内容在 Windows / Linux 上消失。
    public static func verifyGraft(
        imageURL: URL,
        nextWritableAddress: Int,
        expectedOldFiles: Int
    ) throws {
        guard let reader = IsoImageReader(fileURL: imageURL, baseSector: nextWritableAddress) else {
            throw MultisessionError.graftImageFailed(device: imageURL.path, reason: "读不了刚生成的映像")
        }
        // 1. 根目录落在本段范围内 → 说明用的是光盘绝对地址（相对寻址会小于本段起始）。
        var descriptors = 0
        for joliet in [false, true] {
            guard let root = IsoTree.rootRecord(in: reader, imageStart: nextWritableAddress, joliet: joliet) else { continue }
            descriptors += 1
            guard root.extent >= nextWritableAddress else {
                throw MultisessionError.graftNotAbsolute(sector: root.extent, sessionStart: nextWritableAddress)
            }
        }
        guard descriptors > 0 else {
            throw MultisessionError.graftImageFailed(device: imageURL.path, reason: "映像里没有卷描述符")
        }
        // 2. 目录树里得真的引用到旧段的文件。
        let entries = IsoTree.entries(in: reader, imageStart: nextWritableAddress)
        let oldReferences = entries.filter { !$0.isDirectory && $0.extent < nextWritableAddress }.count
        if expectedOldFiles > 0, oldReferences == 0 {
            throw MultisessionError.graftMissingOldFiles(count: expectedOldFiles)
        }
    }
}
