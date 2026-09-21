import Foundation

/// 一次刻录的记录。macOS 看不到多区段光盘里更早的区段，
/// 所以本机保留一份「我刻过什么」的账本，方便回头核对。
public struct BurnRecord: Codable, Identifiable {
    public var id: String
    public var date: Date
    public var volumeName: String
    public var mediaKind: String
    public var mediaID: String?
    public var sessionIndex: Int?
    public var payloadBytes: Int64
    public var fileCount: Int
    public var topLevelItems: [String]
    public var wasTestBurn: Bool
    /// 这次用的文件系统（旧记录里没有这个字段）。
    public var filesystem: String?

    public init(
        id: String = UUID().uuidString,
        date: Date = Date(),
        volumeName: String,
        mediaKind: String,
        mediaID: String?,
        sessionIndex: Int?,
        payloadBytes: Int64,
        fileCount: Int,
        topLevelItems: [String],
        wasTestBurn: Bool,
        filesystem: String? = nil
    ) {
        self.id = id
        self.date = date
        self.volumeName = volumeName
        self.mediaKind = mediaKind
        self.mediaID = mediaID
        self.sessionIndex = sessionIndex
        self.payloadBytes = payloadBytes
        self.fileCount = fileCount
        self.topLevelItems = topLevelItems
        self.wasTestBurn = wasTestBurn
        self.filesystem = filesystem
    }
}

public enum BurnHistory {
    private static let limit = 200

    public static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base
            .appendingPathComponent("DiscBurner", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    public static func load() -> [BurnRecord] {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([BurnRecord].self, from: data)) ?? []
    }

    @discardableResult
    public static func record(_ record: BurnRecord) -> Bool {
        guard let url = fileURL else { return false }
        var records = load()
        records.insert(record, at: 0)
        if records.count > limit { records = Array(records.prefix(limit)) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(records).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 找出与当前这张盘相关的历史记录（优先按 Media ID 匹配）。
    public static func records(mediaID: String?, limit: Int = 10) -> [BurnRecord] {
        let all = load()
        guard let mediaID = mediaID, !mediaID.isEmpty else {
            return Array(all.prefix(limit))
        }
        let matched = all.filter { $0.mediaID == mediaID }
        return Array((matched.isEmpty ? all : matched).prefix(limit))
    }
}
