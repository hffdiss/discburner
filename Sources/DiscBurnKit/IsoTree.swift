import Foundation

/// ISO 9660 目录树里的一条记录。
public struct IsoDirectoryEntry: Equatable {
    /// 名字（Joliet 视图是 UTF-16 解出来的真名；主卷视图是 ISO 9660 名字，去掉了 `;1` 版本号）。
    public var name: String
    /// 内容所在的**绝对扇区**（嫁接段里旧文件的地址落在旧段范围内）。
    public var extent: Int
    /// 内容字节数。
    public var size: Int
    public var isDirectory: Bool
    /// 这条记录来自 Joliet 扩展（否则来自主卷）。
    public var isJoliet: Bool

    public init(name: String, extent: Int, size: Int, isDirectory: Bool, isJoliet: Bool) {
        self.name = name
        self.extent = extent
        self.size = size
        self.isDirectory = isDirectory
        self.isJoliet = isJoliet
    }
}

/// 按扇区随机读一个光盘映像：既可以是磁盘上的文件，也可以是内存里的字节。
///
/// 读盘上的旧段、校验刚生成的嫁接段都靠它——只需要目录结构那几个扇区，
/// 不必把整个映像读进内存。
public final class IsoImageReader {
    public static let sectorSize = RawDisc.sectorSize

    private let handle: FileHandle?
    private let data: Data?
    /// 映像里第 0 个扇区对应盘上的哪个绝对扇区（嫁接段映像传这一段的起始扇区）。
    public let baseSector: Int
    /// 映像字节数；设备等拿不到长度的场合是 nil。
    public let byteCount: Int?

    public init(data: Data, baseSector: Int = 0) {
        self.data = data
        self.handle = nil
        self.baseSector = baseSector
        self.byteCount = data.count
    }

    public init?(fileURL: URL, baseSector: Int = 0) {
        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else { return nil }
        self.handle = handle
        self.data = nil
        self.baseSector = baseSector
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        self.byteCount = size > 0 ? size : nil
    }

    public convenience init?(deviceNode: String, baseSector: Int = 0) {
        self.init(fileURL: URL(fileURLWithPath: RawDisc.rawPath(for: deviceNode)), baseSector: baseSector)
    }

    deinit {
        try? handle?.close()
    }

    public var sectorCount: Int? { byteCount.map { $0 / Self.sectorSize } }

    /// 读第 `index` 个扇区（相对映像起点）。越界或读不到返回 nil。
    public func sector(_ index: Int) -> Data? {
        read(extent: index, size: Self.sectorSize)
    }

    /// 从第 `extent` 个扇区开始读 `size` 个字节。
    ///
    /// 光驱对应的 `/dev/rdiskN` 只接受**扇区整数倍**的读取长度：实测要 18 个字节、
    /// 1000 个字节都直接报错（`read` 返回 EINVAL），2048 / 1 MiB 就正常。
    /// 所以读盘时一律把长度向上取整到扇区边界，读完再截断。
    /// 文件映像走同一条路也不会读坏：末尾不足一个扇区时拿到多少算多少。
    public func read(extent: Int, size: Int) -> Data? {
        guard extent >= 0, size > 0 else { return nil }
        let offset = (extent - baseSector) * Self.sectorSize
        guard offset >= 0 else { return nil }
        if let limit = byteCount, offset + size > limit { return nil }
        if let data = data {
            return data.subdata(in: offset..<(offset + size))
        }
        guard let handle = handle else { return nil }
        let aligned = ((size + Self.sectorSize - 1) / Self.sectorSize) * Self.sectorSize
        var collected = Data()
        var remaining = aligned
        do {
            try handle.seek(toOffset: UInt64(offset))
            // 设备短读是正常现象，攒够为止；读到 0 字节说明到底了。
            while remaining > 0 {
                guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else { break }
                collected.append(chunk)
                remaining -= chunk.count
            }
        } catch {
            return nil
        }
        guard collected.count >= size else { return nil }
        return collected.prefix(size)
    }
}

/// 走 ISO 9660 / Joliet 目录树。
///
/// 多区段嫁接的正确性完全写在目录树里：新段的根目录必须是**光盘绝对地址**，
/// 而且必须能引用到旧段的文件和子目录。这里就是用来核对这一点的。
public enum IsoTree {
    /// 卷描述符里根目录记录的位置（主卷和 Joliet 扩展卷都用这个偏移）。
    private static let rootRecordOffset = 156

    /// 列出映像里的所有条目（默认两种视图都看）。
    ///
    /// - Parameters:
    ///   - imageStart: 映像里第 0 扇区对应盘上的哪个绝对扇区（整盘映像传 0）。
    ///   - views: 要不要看 Joliet 扩展卷。
    public static func entries(
        in reader: IsoImageReader,
        imageStart: Int = 0,
        includeJoliet: Bool = true,
        maxDepth: Int = 8
    ) -> [IsoDirectoryEntry] {
        var result: [IsoDirectoryEntry] = []
        var visited = Set<Int>()

        func decode(_ bytes: Data, joliet: Bool) -> String {
            if joliet {
                var units: [UInt16] = []
                var index = 0
                let raw = [UInt8](bytes)
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

        func walk(extent: Int, size: Int, joliet: Bool, depth: Int) {
            guard depth < maxDepth, extent >= 0, size > 0 else { return }
            let key = joliet ? -extent - 1 : extent
            guard visited.insert(key).inserted else { return }
            guard let block = reader.read(extent: extent, size: size) else { return }
            let bytes = [UInt8](block)
            var offset = 0
            while offset < bytes.count {
                let length = Int(bytes[offset])
                if length == 0 {
                    // 填到下一个扇区边界继续找。
                    offset = ((offset / IsoImageReader.sectorSize) + 1) * IsoImageReader.sectorSize
                    continue
                }
                guard length >= 34, offset + length <= bytes.count else { break }
                let nameLength = Int(bytes[offset + 32])
                let nameStart = offset + 33
                let isDirectory = (bytes[offset + 25] & 2) != 0
                let isDot = nameLength == 1 && (bytes[nameStart] == 0 || bytes[nameStart] == 1)
                if !isDot, nameStart + nameLength <= bytes.count {
                    let entryExtent = Int(littleEndian32(bytes, offset + 2))
                    let entrySize = Int(littleEndian32(bytes, offset + 10))
                    let name = decode(Data(bytes[nameStart..<(nameStart + nameLength)]), joliet: joliet)
                    result.append(
                        IsoDirectoryEntry(
                            name: name,
                            extent: entryExtent,
                            size: entrySize,
                            isDirectory: isDirectory,
                            isJoliet: joliet
                        )
                    )
                    if isDirectory {
                        walk(extent: entryExtent, size: entrySize, joliet: joliet, depth: depth + 1)
                    }
                }
                offset += length
            }
        }

        for (joliet, isJoliet) in [(false, false), (true, true)] {
            if joliet && !includeJoliet { continue }
            guard let root = rootRecord(in: reader, imageStart: imageStart, joliet: isJoliet) else { continue }
            walk(extent: root.extent, size: root.size, joliet: isJoliet, depth: 0)
        }
        return result
    }

    /// 找主卷（或 Joliet 扩展卷）的根目录记录。
    public static func rootRecord(
        in reader: IsoImageReader,
        imageStart: Int,
        joliet: Bool
    ) -> (extent: Int, size: Int)? {
        for index in 16..<24 {
            guard let descriptor = reader.sector(imageStart + index), descriptor.count >= 190 else { return nil }
            let bytes = [UInt8](descriptor)
            guard bytes[1] == 0x43, bytes[2] == 0x44, bytes[3] == 0x30, bytes[4] == 0x30, bytes[5] == 0x31 else {
                continue
            }
            let type = bytes[0]
            let isJolietDescriptor = type == 2 && bytes[88] == 0x25 && bytes[89] == 0x2F && bytes[90] == 0x45
            let wanted = joliet ? isJolietDescriptor : (type == 1)
            guard wanted else { continue }
            guard rootRecordOffset + 14 <= bytes.count else { return nil }
            let extent = Int(littleEndian32(bytes, rootRecordOffset + 2))
            let size = Int(littleEndian32(bytes, rootRecordOffset + 10))
            return (extent, size)
        }
        return nil
    }

    static func littleEndian32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
