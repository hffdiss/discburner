import Foundation

/// 光盘介质类型。
public enum MediaKind: String, CaseIterable {
    case cdR = "CD-R"
    case cdRW = "CD-RW"
    case dvdR = "DVD-R"
    case dvdRW = "DVD-RW"
    case dvdPlusR = "DVD+R"
    case dvdPlusRW = "DVD+RW"
    case dvdRAM = "DVD-RAM"
    case dvdRDL = "DVD-R DL"
    case dvdPlusRDL = "DVD+R DL"
    case dvdRWDual = "DVD-RW DL"
    case bdR = "BD-R"
    case bdRE = "BD-RE"
    case bdRDL = "BD-R DL"
    case bdREDL = "BD-RE DL"
    case bdRTriple = "BD-R TL"
    case cdROM = "CD-ROM"
    case dvdROM = "DVD-ROM"
    case bdROM = "BD-ROM"
    case unknown = "未知介质"

    /// 是否为可写介质（一次写入或可重写）。
    public var isWritable: Bool {
        switch self {
        case .cdROM, .dvdROM, .bdROM, .unknown:
            return false
        default:
            return true
        }
    }

    /// 是否可重写（可擦除）。
    public var isRewritable: Bool {
        switch self {
        case .cdRW, .dvdRW, .dvdPlusRW, .dvdRAM, .dvdRWDual, .bdRE, .bdREDL:
            return true
        default:
            return false
        }
    }

    public var isBluRay: Bool {
        switch self {
        case .bdR, .bdRE, .bdRDL, .bdREDL, .bdRTriple, .bdROM:
            return true
        default:
            return false
        }
    }

    public var isCD: Bool {
        switch self {
        case .cdR, .cdRW, .cdROM:
            return true
        default:
            return false
        }
    }

    /// 是不是 DVD 介质（视频 DVD 只认这一档）。
    public var isDVD: Bool {
        switch self {
        case .dvdR, .dvdRW, .dvdRAM, .dvdPlusR, .dvdPlusRW, .dvdRDL, .dvdPlusRDL, .dvdRWDual, .dvdROM:
            return true
        default:
            return false
        }
    }

    /// 标称容量（字节），按 2048 字节/扇区计算。
    public var nominalCapacityBytes: Int64 {
        switch self {
        case .cdR, .cdRW:
            return 360_000 * 2048          // 703 MiB，80 分钟 CD
        case .cdROM:
            return 333_000 * 2048
        case .dvdR, .dvdRW, .dvdPlusR, .dvdPlusRW, .dvdRAM, .dvdROM:
            return 2_298_496 * 2048        // 4.38 GiB
        case .dvdRDL, .dvdPlusRDL, .dvdRWDual:
            return 4_171_712 * 2048        // 7.96 GiB
        case .bdR, .bdRE, .bdROM:
            return 12_219_392 * 2048       // 23.3 GiB
        case .bdRDL, .bdREDL:
            return 24_438_784 * 2048       // 46.6 GiB
        case .bdRTriple:
            return 48_878_080 * 2048       // 93.4 GiB
        case .unknown:
            return 0
        }
    }

    /// 1 倍速对应的字节/秒（用于估算烧录时间）。
    public var bytesPerSecondAt1x: Double {
        if isBluRay { return 4_500 * 1024 }
        if isCD { return 150 * 1024 }
        return 1_350 * 1024
    }

    public var displayName: String { rawValue }

    /// 把 drutil 输出的 Type 字段（以及 DiscRecording 的 DRDeviceMediaType 名称）转成介质类型。
    public static func parse(_ raw: String) -> MediaKind? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !text.isEmpty else { return nil }
        if text.contains("DRDEVICEMEDIATYPE") {
            text = text.replacingOccurrences(of: "DRDEVICEMEDIATYPE", with: "")
        }
        // 去掉所有空白与常见分隔符，方便归一化比较。
        let key = text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "+", with: "PLUS")

        switch key {
        case "CDR": return .cdR
        case "CDRW": return .cdRW
        case "CDROM": return .cdROM
        case "DVDR": return .dvdR
        case "DVDRW": return .dvdRW
        case "DVDPLUSR": return .dvdPlusR
        case "DVDPLUSRW": return .dvdPlusRW
        case "DVDRAM": return .dvdRAM
        case "DVDRDL", "DVDRDUALLAYER": return .dvdRDL
        case "DVDPLUSRDL", "DVDPLUSRDUALLAYER": return .dvdPlusRDL
        case "DVDRWDL": return .dvdRWDual
        case "DVDROM": return .dvdROM
        case "BDR": return .bdR
        case "BDRE": return .bdRE
        case "BDRDL": return .bdRDL
        case "BDREDL": return .bdREDL
        case "BDRTL", "BDRXL": return .bdRTriple
        case "BDROM": return .bdROM
        default: return .unknown
        }
    }
}

/// 介质的写入状态。
public enum Writability: String {
    case blank = "blank"
    case appendable = "appendable"
    case overwritable = "overwritable"
    case closed = "closed"
    case notWritable = "not writable"
    case unknown = "unknown"

    public init(statusText text: String) {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "blank": self = .blank
        case "appendable": self = .appendable
        case "overwritable": self = .overwritable
        case "closed", "closed disc": self = .closed
        case "not writable", "notwritable", "unwritable": self = .notWritable
        default: self = .unknown
        }
    }

    /// 数据能否写入。
    public var canBurn: Bool {
        switch self {
        case .blank, .appendable, .overwritable: return true
        case .closed, .notWritable, .unknown: return false
        }
    }

    public var localizedDescription: String {
        switch self {
        case .blank: return "空白盘，可写入"
        case .appendable: return "可追加写入（多区段）"
        case .overwritable: return "可重复写入（可覆盖）"
        case .closed: return "已完成/已关闭，无法再写"
        case .notWritable: return "不可写入"
        case .unknown: return "状态未知"
        }
    }
}

/// 字节数格式化（避免依赖 macOS 12 才有的格式化 API）。
public enum ByteText {
    public static func human(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 B" }
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.2f %@", value, units[index])
    }

    public static func decimal(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        return String(format: "%.2f %@", value, units[index])
    }
}
