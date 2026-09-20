import Foundation

#if canImport(Darwin)
import Darwin
#endif

public struct StagedEntry {
    public let source: URL
    public let destination: URL
    public let name: String
    public let isDirectory: Bool
    public let byteCount: Int64
    /// 这一项里被自动改掉的名字（含它自己与它内部的条目）。
    public let renames: [NameRename]

    public init(
        source: URL,
        destination: URL,
        name: String,
        isDirectory: Bool,
        byteCount: Int64,
        renames: [NameRename] = []
    ) {
        self.source = source
        self.destination = destination
        self.name = name
        self.isDirectory = isDirectory
        self.byteCount = byteCount
        self.renames = renames
    }
}

/// 复制到暂存目录时怎么处理名字。
public enum NamePolicy {
    /// 原样保留（默认）。
    case keep
    /// 改成各系统都能接受的名字，改名记录写进 `StagedEntry.renames`。
    case sanitize
}

public struct StageOptions {
    /// 是否剔除 macOS 垃圾文件（.DS_Store、._* 资源分叉等）。
    public var excludeJunkFiles: Bool
    /// 是否尝试使用 APFS 写时复制（clonefile），同卷时几乎瞬时完成且不占额外空间。
    public var useCloneWhenPossible: Bool
    /// 名字处理策略。
    public var namePolicy: NamePolicy
    /// `namePolicy == .sanitize` 时使用的规则。
    public var nameRules: NameRules

    public init(
        excludeJunkFiles: Bool = true,
        useCloneWhenPossible: Bool = true,
        namePolicy: NamePolicy = .keep,
        nameRules: NameRules = .default
    ) {
        self.excludeJunkFiles = excludeJunkFiles
        self.useCloneWhenPossible = useCloneWhenPossible
        self.namePolicy = namePolicy
        self.nameRules = nameRules
    }
}

/// 一次刻录任务的工作目录，负责把待刻录内容聚合到同一个目录里。
///
/// 命令行工具只能对「一个目录」生成光盘映像，所以需要先把用户选中的
/// 文件/文件夹收拢到暂存目录，并处理重名。
public final class Workspace {
    public let root: URL
    public let staging: URL

    private let fileManager = FileManager.default
    /// 刻录前会被剔除的 macOS 垃圾文件。
    public static let junkFileNames: Set<String> = [
        ".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd",
        ".TemporaryItems", ".apdisk", ".DocumentRevisions-V100",
    ]

    private static let junkNames = junkFileNames

    public init(prefix: String = "DiscBurner") throws {
        let base = try Workspace.cacheDirectory()
        let folder = base
            .appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent(Workspace.makeToken(), isDirectory: true)
        let stagingURL = folder.appendingPathComponent("staging", isDirectory: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        self.root = folder
        self.staging = stagingURL
    }

    private static func cacheDirectory() throws -> URL {
        let fileManager = FileManager.default
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            return caches
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    private static func makeToken() -> String {
        let stamp = Int(Date().timeIntervalSince1970)
        let random = String(UInt32.random(in: 0..<UInt32.max), radix: 16)
        return "job-\(stamp)-\(random)"
    }

    public func cleanup() {
        try? fileManager.removeItem(at: root)
    }

    /// 清理遗留的临时目录。
    ///
    /// 任务失败或进程被强杀时，暂存目录会留在缓存里（可能几十 GB），
    /// 所以每次启动时把「一小时前」的残留清掉；仍在运行的任务不会受影响。
    @discardableResult
    public static func purgeStale(olderThan age: TimeInterval = 3600) -> Int {
        let fileManager = FileManager.default
        guard let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DiscBurner", isDirectory: true),
            let entries = try? fileManager.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
            return 0
        }
        let cutoff = Date().addingTimeInterval(-age)
        var removed = 0
        for entry in entries where entry.lastPathComponent.hasPrefix("job-") {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? fileManager.removeItem(at: entry)
                removed += 1
            }
        }
        return removed
    }

    /// 把选中的项目复制（或克隆）到暂存目录。
    ///
    /// `options.namePolicy == .sanitize` 时，会在复制过程中把不兼容的名字就地改掉
    /// （改名只影响暂存目录里的副本，源文件不动），改名记录放在 `StagedEntry.renames`。
    ///
    /// - Parameter onProgress: 每处理完一个顶层项目回调一次（已完成数, 总数, 当前项目名）。
    public func stage(
        items: [URL],
        options: StageOptions = StageOptions(),
        onProgress: ((Int, Int, String) -> Void)? = nil
    ) throws -> [StagedEntry] {
        var entries: [StagedEntry] = []
        var usedNames = Set<String>()
        let sanitize = options.namePolicy == .sanitize

        // 顶层项目的名字也要处理：先按名字排序算出新名字，
        // 这样和预检给出的自动重命名方案完全一致。
        var rootNames: [String: String] = [:]
        if sanitize {
            let names = items.map { $0.standardizedFileURL.lastPathComponent }.filter { !NameSanitizer.isJunk($0) }
            rootNames = NameSanitizer.resolveSiblings(names: names, relativeDirectory: "", rules: options.nameRules).mapping
        }

        for (offset, item) in items.enumerated() {
            let source = item.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
                throw WorkspaceError.missingSource(source)
            }
            let original = source.lastPathComponent
            let proposed = sanitize ? (rootNames[original] ?? NameSanitizer.sanitizeComponent(original, rules: options.nameRules).name) : original
            let name = uniqueName(proposed, used: &usedNames)
            let destination = staging.appendingPathComponent(name)

            var renames: [NameRename] = []
            if name != original {
                var reasons = sanitize ? NameSanitizer.sanitizeComponent(original, rules: options.nameRules).notes : []
                if name != proposed { reasons.append("与其他项目重名，已加序号") }
                renames.append(
                    NameRename(oldRelativePath: original, newRelativePath: name, reasons: reasons)
                )
            }

            if sanitize {
                try copyTree(
                    from: source.path,
                    to: destination.path,
                    oldRelative: original,
                    newRelative: name,
                    options: options,
                    renames: &renames
                )
            } else {
                try copyItem(from: source, to: destination, options: options)
                if options.excludeJunkFiles {
                    purgeJunkFiles(in: destination)
                }
            }
            entries.append(
                StagedEntry(
                    source: source,
                    destination: destination,
                    name: name,
                    isDirectory: isDirectory.boolValue,
                    byteCount: isDirectory.boolValue ? Workspace.size(of: destination) : Workspace.fileSize(of: destination),
                    renames: renames
                )
            )
            onProgress?(offset + 1, items.count, name)
        }
        return entries
    }

    private func uniqueName(_ name: String, used: inout Set<String>) -> String {
        var candidate = name
        var counter = 2
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        while used.contains(NameSanitizer.foldKey(candidate)) || fileManager.fileExists(atPath: staging.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            counter += 1
        }
        used.insert(NameSanitizer.foldKey(candidate))
        return candidate
    }

    /// 递归复制一棵子树，边复制边把每一层的名字改成兼容形式。
    ///
    /// 目录必须自己创建再逐项复制（不能整目录 `copyItem`），否则大小写冲突
    /// 在大小写不敏感的暂存卷上会直接失败，也就没有机会改名。
    private func copyTree(
        from sourcePath: String,
        to destinationPath: String,
        oldRelative: String,
        newRelative: String,
        options: StageOptions,
        renames: inout [NameRename]
    ) throws {
        #if canImport(Darwin)
        let source = URL(fileURLWithPath: sourcePath)
        let destination = URL(fileURLWithPath: destinationPath)
        var info = stat()
        guard lstat(sourcePath, &info) == 0 else {
            throw WorkspaceError.missingSource(source)
        }
        let type = info.st_mode & S_IFMT

        if type == S_IFDIR {
            try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            if let permissions = permissions(of: sourcePath) {
                try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: destinationPath)
            }

            let children = FileTree.children(of: sourcePath, includeHidden: true)
                .filter { !(options.excludeJunkFiles && NameSanitizer.isJunk($0.name)) }
            let resolved = NameSanitizer.resolveSiblings(
                names: children.map { $0.name },
                oldDirectory: oldRelative,
                newDirectory: newRelative,
                rules: options.nameRules
            )
            renames.append(contentsOf: resolved.renames)

            for child in children {
                let newName = resolved.mapping[child.name] ?? child.name
                try copyTree(
                    from: child.path,
                    to: destination.appendingPathComponent(newName).path,
                    oldRelative: oldRelative + "/" + child.name,
                    newRelative: newRelative + "/" + newName,
                    options: options,
                    renames: &renames
                )
            }
            return
        }

        if type == S_IFLNK {
            let target = FileTree.node(at: sourcePath)?.linkTarget ?? ""
            try? fileManager.removeItem(atPath: destinationPath)
            if symlink(target, destinationPath) != 0 {
                throw WorkspaceError.copyFailed(source, POSIXError(POSIXErrorCode.ENOTSUP))
            }
            return
        }

        if type != S_IFREG {
            // 设备节点、套接字之类的条目无法刻进光盘，跳过。
            return
        }

        try? fileManager.removeItem(atPath: destinationPath)
        if options.useCloneWhenPossible, clonefile(sourcePath, destinationPath, 0) == 0 {
            return
        }
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw WorkspaceError.copyFailed(source, error)
        }
        #else
        throw WorkspaceError.copyFailed(
            URL(fileURLWithPath: sourcePath),
            POSIXError(POSIXErrorCode.ENOTSUP)
        )
        #endif
    }

    private func permissions(of path: String) -> Int? {
        #if canImport(Darwin)
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Int(info.st_mode & 0o7777)
        #else
        return nil
        #endif
    }

    private func copyItem(from source: URL, to destination: URL, options: StageOptions) throws {
        // 目的地已存在只可能是「源目录里有仅大小写不同的名字」：
        // 在大小写不敏感的卷上第二个会被当成第一个。这种情况必须让用户知道。
        if fileManager.fileExists(atPath: destination.path) {
            throw WorkspaceError.caseCollision(source)
        }
        if options.useCloneWhenPossible, cloneItem(from: source, to: destination) {
            return
        }
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            if !isDirectory(source) {
                throw WorkspaceError.copyFailed(source, error)
            }
            // 整目录复制失败：最常见的原因是源目录里有仅大小写不同的名字，
            // 在大小写不敏感的暂存卷上会被当成同一个。这里给出可执行的提示。
            if let clash = caseConflictDescription(in: source.path) {
                throw WorkspaceError.caseCollisionDetail(source, clash)
            }
            throw WorkspaceError.copyFailed(source, error)
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    /// 在源目录里找一对「只在大小写上不同」的兄弟项，用来解释复制失败的原因。
    private func caseConflictDescription(in path: String) -> String? {
        var stack = [path]
        var visited = Set<String>()
        while let directory = stack.popLast() {
            guard visited.insert(directory).inserted else { continue }
            var seen: [String: String] = [:]
            for child in FileTree.children(of: directory, includeHidden: true) {
                let key = NameSanitizer.foldKey(child.name)
                if let previous = seen[key], previous != child.name {
                    return "\(previous) 与 \(child.name)"
                }
                seen[key] = child.name
                if child.kind == .directory { stack.append(child.path) }
            }
        }
        return nil
    }

    /// 使用 clonefile(2) 做写时复制，失败时返回 false 让调用方回退到普通拷贝。
    private func cloneItem(from source: URL, to destination: URL) -> Bool {
        #if canImport(Darwin)
        if fileManager.fileExists(atPath: destination.path) { return false }
        let result = clonefile(source.path, destination.path, 0)
        return result == 0
        #else
        return false
        #endif
    }

    /// 深度优先清理垃圾文件。
    ///
    /// 这里必须用 POSIX 的 readdir：Foundation 的目录枚举会把 `._*`
    /// 这类 AppleDouble 文件直接隐藏掉，导致它们被刻进光盘。
    private func purgeJunkFiles(in url: URL) {
        #if canImport(Darwin)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }
        var stack: [String] = [url.path]
        while let directory = stack.popLast() {
            guard let handle = opendir(directory) else { continue }
            defer { closedir(handle) }
            while let entry = readdir(handle) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                    guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
                    return String(cString: base)
                }
                if name.isEmpty || name == "." || name == ".." { continue }
                let childPath = (directory as NSString).appendingPathComponent(name)

                if Workspace.junkNames.contains(name) || name.hasPrefix("._") {
                    try? fileManager.removeItem(atPath: childPath)
                    continue
                }

                // 不跟随符号链接，避免循环目录
                var info = stat()
                guard lstat(childPath, &info) == 0 else { continue }
                if (info.st_mode & S_IFMT) == S_IFDIR {
                    stack.append(childPath)
                }
            }
        }
        #endif
    }

    // MARK: - 尺寸计算

    public static func fileSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// 递归统计目录（或单个文件）的总字节数。
    public static func size(of url: URL) -> Int64 {
        FileTree.stats(of: url.path).bytes
    }

    /// 递归统计文件个数（不含目录）。
    public static func fileCount(of url: URL) -> Int {
        FileTree.stats(of: url.path).files
    }

    /// 目标卷剩余空间。
    public static func availableSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values?.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        let fallback = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        if let capacity = fallback?.volumeAvailableCapacity {
            return Int64(capacity)
        }
        return nil
    }
}

public enum WorkspaceError: LocalizedError {
    case missingSource(URL)
    case copyFailed(URL, Error)
    case caseCollision(URL)
    case caseCollisionDetail(URL, String)
    case notEnoughDiskSpace(required: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .missingSource(let url):
            return "找不到文件：\(url.path)"
        case .copyFailed(let url, let error):
            return "复制 \(url.lastPathComponent) 失败：\(error.localizedDescription)"
        case .caseCollision(let url):
            return "\(url.lastPathComponent) 里有只在大小写上不同的名字（例如 Report.txt 与 report.txt），"
                + "当前磁盘分不清这两个名字。请改用「自动重命名」后重试。"
        case .caseCollisionDetail(let url, let pair):
            return "\(url.lastPathComponent) 里的 \(pair) 只在大小写上不同，当前磁盘分不清这两个名字。"
                + "请改用「自动重命名」后重试。"
        case .notEnoughDiskSpace(let required, let available):
            return "本机磁盘空间不足：生成光盘映像需要 \(ByteText.human(required))，当前可用 \(ByteText.human(available))"
        }
    }
}
