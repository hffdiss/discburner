import Foundation

// MARK: - 命名规则

/// 「名字要多保守」的一套规则。
///
/// 兼容性预检（`CompatibilityChecker`）与自动重命名（`NameSanitizer`）共用同一份规则，
/// 这样「预检里提示的」和「真正刻进光盘的」一定一致。
public struct NameRules {
    /// 单个名字的字节上限：APFS、ext4、UDF 都是 255 字节。
    public var maxBytes: Int
    /// Joliet 视图的名字长度上限（字符数）；nil 表示不检查。
    public var jolietMaxCharacters: Int?
    /// 是否检查 ISO 9660 视图（8.3 名字、8 层目录）。
    public var checkISO9660: Bool
    /// 是否检查 Windows 的非法字符与保留名。
    public var enforceWindows: Bool
    /// 自动重命名时是否也按字符数截断；只有「只有 Joliet、没有 UDF」时才需要。
    public var sanitizeCharacterLimit: Int?

    public init(
        maxBytes: Int = 255,
        jolietMaxCharacters: Int? = 64,
        checkISO9660: Bool = true,
        enforceWindows: Bool = true,
        sanitizeCharacterLimit: Int? = nil
    ) {
        self.maxBytes = maxBytes
        self.jolietMaxCharacters = jolietMaxCharacters
        self.checkISO9660 = checkISO9660
        self.enforceWindows = enforceWindows
        self.sanitizeCharacterLimit = sanitizeCharacterLimit
    }

    public static let `default` = NameRules()

    /// 最宽松：只保证文件系统本身放得下，不做跨系统提示。
    public static let permissive = NameRules(
        maxBytes: 255,
        jolietMaxCharacters: nil,
        checkISO9660: false,
        enforceWindows: false,
        sanitizeCharacterLimit: nil
    )
}

// MARK: - 问题模型

public enum CompatibilitySeverity: Int, Comparable {
    /// 仅供参考，不影响使用。
    case info = 0
    /// 别的系统上可能打不开 / 显示成别的名字。
    case warning = 1
    /// 会丢数据或直接写不进去，必须处理。
    case error = 2

    public static func < (lhs: CompatibilitySeverity, rhs: CompatibilitySeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var localizedName: String {
        switch self {
        case .info: return "提示"
        case .warning: return "警告"
        case .error: return "需处理"
        }
    }

    public var symbolName: String {
        switch self {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }
}

public enum CompatibilityCategory: String, Hashable {
    case controlCharacter
    case illegalCharacter
    case trailingDotOrSpace
    case reservedName
    case nameTooLong
    case jolietNameTooLong
    case caseConflict
    case unicodeConflict
    case iso9660Name
    case iso9660Depth
    case symlink

    public var localizedName: String {
        switch self {
        case .controlCharacter: return "控制字符"
        case .illegalCharacter: return "系统不允许的字符"
        case .trailingDotOrSpace: return "结尾的点或空格"
        case .reservedName: return "Windows 保留名"
        case .nameTooLong: return "名字过长"
        case .jolietNameTooLong: return "Joliet 名字过长"
        case .caseConflict: return "大小写冲突"
        case .unicodeConflict: return "Unicode 重名"
        case .iso9660Name: return "ISO 9660 名字"
        case .iso9660Depth: return "ISO 9660 目录层级"
        case .symlink: return "符号链接"
        }
    }
}

public struct CompatibilityIssue: Identifiable, Hashable {
    public let id: String
    public let severity: CompatibilitySeverity
    public let category: CompatibilityCategory
    /// 相对刻录根目录的路径；nil 表示整张盘层面的汇总提示。
    public let relativePath: String?
    public let message: String
    public let advice: String

    public init(
        severity: CompatibilitySeverity,
        category: CompatibilityCategory,
        relativePath: String?,
        message: String,
        advice: String
    ) {
        self.severity = severity
        self.category = category
        self.relativePath = relativePath
        self.message = message
        self.advice = advice
        self.id = "\(category.rawValue)|\(relativePath ?? "*")|\(message)"
    }
}

/// 自动重命名方案里的一条记录。
public struct NameRename: Hashable {
    /// 改名前的相对路径（相对刻录根目录，也就是用户看到的路径）。
    public let oldRelativePath: String
    /// 改名后的相对路径。
    public let newRelativePath: String
    /// 为什么改，用于给用户解释。
    public let reasons: [String]

    public init(oldRelativePath: String, newRelativePath: String, reasons: [String]) {
        self.oldRelativePath = oldRelativePath
        self.newRelativePath = newRelativePath
        self.reasons = reasons
    }
}

public struct CompatibilityReport {
    public var rules: NameRules = .default
    /// 被扫描的顶层项目路径。
    public var scannedRoots: [String] = []
    public var issues: [CompatibilityIssue] = []
    /// 如果选择「自动重命名」，这些名字会被改掉。
    public var renamePlan: [NameRename] = []
    public var fileCount = 0
    public var directoryCount = 0
    public var totalBytes: Int64 = 0
    /// 最深的目录层级（根目录下的文件算第 1 层）。
    public var maxDepth = 0

    public init() {}

    public var errorCount: Int { issues.filter { $0.severity == .error }.count }
    public var warningCount: Int { issues.filter { $0.severity == .warning }.count }
    public var infoCount: Int { issues.filter { $0.severity == .info }.count }

    /// 有必须处理的问题（会丢数据 / 写不进去）。
    public var hasErrors: Bool { errorCount > 0 }

    /// 除「提示」以外还有别的发现。
    public var hasWarningsOrErrors: Bool { !issues.filter { $0.severity > .info }.isEmpty }

    /// 完全没有问题（含提示）。
    public var isPerfect: Bool { issues.isEmpty }

    public var headline: String {
        guard !issues.isEmpty else { return "未发现兼容性问题" }
        var parts: [String] = []
        if errorCount > 0 { parts.append("\(errorCount) 项需处理") }
        if warningCount > 0 { parts.append("\(warningCount) 项警告") }
        if infoCount > 0 { parts.append("\(infoCount) 项提示") }
        return parts.joined(separator: "、")
    }

    /// 严重程度从高到低、同一级别按路径排序，方便直接铺在界面上。
    public func sortedIssues() -> [CompatibilityIssue] {
        issues.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return (lhs.relativePath ?? "") < (rhs.relativePath ?? "")
        }
    }

    public func issues(atLeast severity: CompatibilitySeverity) -> [CompatibilityIssue] {
        sortedIssues().filter { $0.severity >= severity }
    }

    /// 给日志用的一行摘要。
    public var logSummary: String {
        var text = "兼容性预检：\(headline)"
        if !renamePlan.isEmpty {
            text += "，自动重命名可修正 \(renamePlan.count) 个名字"
        }
        return text
    }
}

// MARK: - 名字清洗

/// 把名字改成「各个系统都能接受」的样子，并解释改了什么。
public enum NameSanitizer {
    /// Windows / Joliet 都不接受的字符（不含路径分隔符本身，调用方只传单个名字）。
    public static let illegalCharacters: [Character] = ["\\", ":", "*", "?", "\"", "<", ">", "|"]

    /// Windows 保留的设备名，带扩展名也一样被保留。
    public static let windowsReservedNames: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
        "CONIN$", "CONOUT$",
    ]

    public struct Result {
        public let name: String
        public let notes: [String]
        public var changed: Bool { !notes.isEmpty }
    }

    // MARK: 单个名字

    public static func sanitizeComponent(_ raw: String, rules: NameRules = .default) -> Result {
        var notes: [String] = []
        var characters: [Character] = []
        var illegal: [Character] = []
        var hadControl = false

        for character in raw {
            if character.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                hadControl = true
                characters.append("_")
            } else if illegalCharacters.contains(character) {
                if !illegal.contains(character) { illegal.append(character) }
                characters.append("_")
            } else {
                characters.append(character)
            }
        }

        var name = String(characters)
        if hadControl { notes.append("去掉控制字符") }
        if !illegal.isEmpty {
            notes.append("把 \(illegal.map { String($0) }.joined(separator: " ")) 换成 _")
        }

        // Windows 会静默丢掉结尾的点和空格，干脆先去掉。
        var trimmed = name
        while let last = trimmed.last, last == "." || last == " " {
            trimmed.removeLast()
        }
        if trimmed != name {
            notes.append("去掉结尾的点或空格")
            name = trimmed
        }

        if name.isEmpty {
            name = "未命名"
            notes.append("名字为空，改用「未命名」")
        }

        if rules.enforceWindows, let escaped = escapeWindowsReservedName(name) {
            notes.append("「\(reservedBase(name))」是 Windows 保留名，前面加 _")
            name = escaped
        }

        if let limit = rules.sanitizeCharacterLimit, name.count > limit {
            name = truncate(name, maxCharacters: limit, maxBytes: rules.maxBytes)
            notes.append("截断到 \(limit) 个字符（Joliet 上限）")
        } else if name.utf8.count > rules.maxBytes {
            name = truncate(name, maxCharacters: nil, maxBytes: rules.maxBytes)
            notes.append("截断到 \(rules.maxBytes) 字节")
        }

        return Result(name: name, notes: notes)
    }

    /// 比较用的键：先做 Unicode 归一化再忽略大小写，
    /// 对应「Windows / 大小写不敏感磁盘会把这两个名字当成同一个」。
    public static func foldKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    public static func isWindowsReservedName(_ name: String) -> Bool {
        windowsReservedNames.contains(reservedBase(name).uppercased())
    }

    /// 取「主名」：Windows 认为 `CON.txt` 依然指向设备 CON。
    public static func reservedBase(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        guard let dot = trimmed.firstIndex(of: ".") else { return trimmed }
        return String(trimmed[trimmed.startIndex..<dot])
    }

    private static func escapeWindowsReservedName(_ name: String) -> String? {
        guard isWindowsReservedName(name) else { return nil }
        return "_" + name
    }

    static func truncate(_ name: String, maxCharacters: Int?, maxBytes: Int) -> String {
        func fits(_ text: String) -> Bool {
            if let limit = maxCharacters, text.count > limit { return false }
            return text.utf8.count <= maxBytes
        }
        if fits(name) { return name }

        let ext = (name as NSString).pathExtension
        var base = (name as NSString).deletingPathExtension
        while !base.isEmpty {
            let candidate = ext.isEmpty ? base : base + "." + ext
            if fits(candidate) { return candidate }
            base.removeLast()
        }

        var result = ""
        for character in name {
            let candidate = result + String(character)
            if fits(candidate) { result = candidate } else { break }
        }
        return result.isEmpty ? "未命名" : result
    }

    /// 在同一个目录里找一个不重名的名字（重复时加「 2」「 3」）。
    @discardableResult
    public static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var candidate = name
        var counter = 2
        while used.contains(foldKey(candidate)) {
            candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            counter += 1
        }
        used.insert(foldKey(candidate))
        return candidate
    }

    // MARK: 同目录批量处理

    /// 算出一个目录里每一项的新名字，以及需要向用户交代的改名记录。
    ///
    /// 处理顺序固定按名字排序，保证「预检给出的方案」和「实际复制时的结果」一致。
    public static func resolveSiblings(
        names: [String],
        oldDirectory: String,
        newDirectory: String,
        rules: NameRules = .default
    ) -> (mapping: [String: String], renames: [NameRename]) {
        var used = Set<String>()
        var mapping: [String: String] = [:]
        var renames: [NameRename] = []
        let oldPrefix = oldDirectory.isEmpty ? "" : oldDirectory + "/"
        let newPrefix = newDirectory.isEmpty ? "" : newDirectory + "/"

        for name in names.sorted(by: { $0 < $1 }) {
            guard mapping[name] == nil else { continue }
            let result = sanitizeComponent(name, rules: rules)
            let unique = uniqueName(result.name, used: &used)
            mapping[name] = unique
            guard unique != name else { continue }
            var reasons = result.notes
            if unique != result.name { reasons.append("与同目录下的其他项重名，已加序号") }
            if reasons.isEmpty { reasons.append("与同目录下的其他名字冲突") }
            renames.append(
                NameRename(
                    oldRelativePath: oldPrefix + name,
                    newRelativePath: newPrefix + unique,
                    reasons: reasons
                )
            )
        }
        return (mapping, renames)
    }

    /// 改名前后目录名相同的简易版本（预检内部与顶层项目用）。
    public static func resolveSiblings(
        names: [String],
        relativeDirectory: String,
        rules: NameRules = .default
    ) -> (mapping: [String: String], renames: [NameRename]) {
        resolveSiblings(
            names: names,
            oldDirectory: relativeDirectory,
            newDirectory: relativeDirectory,
            rules: rules
        )
    }

    /// 只算方案、不碰磁盘，用来在界面上预览「自动重命名」会改哪些名字。
    public static func plan(
        roots: [URL],
        rules: NameRules = .default,
        includeHidden: Bool = true
    ) -> [NameRename] {
        let paths = roots.map { $0.standardizedFileURL.path }
        let rootNames = paths.map { ($0 as NSString).lastPathComponent }.filter { !isJunk($0) }
        let rootResolved = resolveSiblings(names: rootNames, relativeDirectory: "", rules: rules)
        var renames = rootResolved.renames

        // 栈里同时带着「原路径」和「改名后的相对路径」，父目录改名时子项也能显示正确的新路径。
        var stack: [(path: String, newRelative: String)] = paths.compactMap { path in
            guard let node = FileTree.node(at: path) else { return nil }
            guard node.kind == .directory else { return nil }
            let name = (path as NSString).lastPathComponent
            return (path, rootResolved.mapping[name] ?? name)
        }

        var visited = Set<String>()
        while let current = stack.popLast() {
            guard visited.insert(current.path).inserted else { continue }
            let children = FileTree.children(of: current.path, includeHidden: includeHidden)
                .filter { !isJunk($0.name) }
            let resolved = resolveSiblings(
                names: children.map { $0.name },
                oldDirectory: current.newRelative,
                newDirectory: current.newRelative,
                rules: rules
            )
            renames.append(contentsOf: resolved.renames)
            for child in children where child.kind == .directory {
                stack.append((child.path, current.newRelative + "/" + (resolved.mapping[child.name] ?? child.name)))
            }
        }
        return renames
    }

    /// macOS 垃圾文件：刻录前会被剔除，所以预检里也不提示它们。
    public static func isJunk(_ name: String) -> Bool {
        Workspace.junkFileNames.contains(name) || name.hasPrefix("._")
    }
}

// MARK: - 兼容性预检

public enum CompatibilityChecker {
    /// 扫描待刻录内容，找出在 Windows / Linux / 老设备上会出问题的名字。
    ///
    /// 扫描是只读的，不会修改任何文件；`report.renamePlan` 给出自动重命名方案。
    public static func scan(
        items: [URL],
        rules: NameRules = .default,
        includeHidden: Bool = true
    ) -> CompatibilityReport {
        var report = CompatibilityReport()
        report.rules = rules

        var roots: [Entry] = []
        for item in items {
            let url = item.standardizedFileURL
            report.scannedRoots.append(url.path)
            guard !NameSanitizer.isJunk(url.lastPathComponent) else { continue }
            guard let node = FileTree.node(at: url.path) else { continue }
            roots.append(
                Entry(
                    path: url.path,
                    name: url.lastPathComponent,
                    relative: url.lastPathComponent,
                    depth: 1,
                    kind: node.kind,
                    byteCount: node.size
                )
            )
        }

        var stats = Stats()
        analyze(entries: roots, relativeDirectory: "", report: &report, stats: &stats)

        var visited = Set<String>()
        var stack = roots.filter { $0.kind == .directory }
        while let current = stack.popLast() {
            guard visited.insert(current.path).inserted else { continue }
            let children = FileTree.children(of: current.path, includeHidden: includeHidden)
                .filter { !NameSanitizer.isJunk($0.name) }
                .map { child in
                    Entry(
                        path: child.path,
                        name: child.name,
                        relative: current.relative + "/" + child.name,
                        depth: current.depth + 1,
                        kind: child.kind,
                        byteCount: child.size
                    )
                }
            report.maxDepth = max(report.maxDepth, current.depth + 1)
            analyze(entries: children, relativeDirectory: current.relative, report: &report, stats: &stats)
            stack.append(contentsOf: children.filter { $0.kind == .directory })
        }

        report.issues.append(contentsOf: aggregateIssues(stats: stats, report: report, rules: rules))
        report.renamePlan = NameSanitizer.plan(roots: items, rules: rules, includeHidden: includeHidden)
        return report
    }

    /// 检查一个名字本身。公开出来是为了能单独测试，也被 `scan` 内部使用。
    public static func nameIssues(
        name: String,
        relativePath: String,
        rules: NameRules = .default
    ) -> [CompatibilityIssue] {
        var issues: [CompatibilityIssue] = []

        let controlCharacters = name.unicodeScalars.filter { $0.value < 0x20 || $0.value == 0x7F }
        if !controlCharacters.isEmpty {
            issues.append(
                CompatibilityIssue(
                    severity: .error,
                    category: .controlCharacter,
                    relativePath: relativePath,
                    message: "名字里有 \(controlCharacters.count) 个控制字符（换行、制表符等）",
                    advice: "几乎所有系统都无法正常显示或复制这种文件，请改名。"
                )
            )
        }

        if rules.enforceWindows {
            let illegal = NameSanitizer.illegalCharacters.filter { name.contains($0) }
            if !illegal.isEmpty {
                let list = illegal.map { "「\($0)」" }.joined(separator: "、")
                var message = "名字里有 Windows 不允许的字符：\(list)"
                var advice = "Windows 的资源管理器无法创建或复制这种文件（可能直接报错）。"
                let jolietAffected = illegal.filter { ["\\", ":", "*", "?"].contains($0) }
                if rules.jolietMaxCharacters != nil, !jolietAffected.isEmpty {
                    message += "；Joliet 视图也会把它们替换成「_」"
                    advice += " 车机、老设备看到的会是替换后的名字。"
                }
                issues.append(
                    CompatibilityIssue(
                        severity: .warning,
                        category: .illegalCharacter,
                        relativePath: relativePath,
                        message: message,
                        advice: advice
                    )
                )
            }

            if name.hasSuffix(".") || name.hasSuffix(" ") {
                issues.append(
                    CompatibilityIssue(
                        severity: .warning,
                        category: .trailingDotOrSpace,
                        relativePath: relativePath,
                        message: "名字以「\(name.hasSuffix(" ") ? "空格" : "点")」结尾",
                        advice: "Windows 保存时会静默去掉结尾的空格和点，导致两边名字对不上。"
                    )
                )
            }

            if NameSanitizer.isWindowsReservedName(name) {
                issues.append(
                    CompatibilityIssue(
                        severity: .warning,
                        category: .reservedName,
                        relativePath: relativePath,
                        message: "「\(NameSanitizer.reservedBase(name))」是 Windows 的保留设备名",
                        advice: "Windows 无法创建这种名字（即使带扩展名也不行），建议改成 _\(name)。"
                    )
                )
            }
        }

        let byteCount = name.utf8.count
        if byteCount > rules.maxBytes {
            issues.append(
                CompatibilityIssue(
                    severity: .error,
                    category: .nameTooLong,
                    relativePath: relativePath,
                    message: "名字有 \(byteCount) 字节，超过 \(rules.maxBytes) 字节上限",
                    advice: "APFS / ext4 / UDF 都放不下这个名字，必须改短。"
                )
            )
        }

        if let limit = rules.jolietMaxCharacters, name.count > limit {
            issues.append(
                CompatibilityIssue(
                    severity: .warning,
                    category: .jolietNameTooLong,
                    relativePath: relativePath,
                    message: "名字有 \(name.count) 个字符，超过 Joliet 的 \(limit) 字符上限",
                    advice: "Windows / macOS 会走 UDF 视图看到完整名字，但车机和老设备走 Joliet，只会看到前 \(limit) 个字符。"
                )
            )
        }

        return issues
    }

    /// 同一个目录里名字互相冲突（大小写 / Unicode 归一化）。
    public static func conflictIssues(
        names: [String],
        relativeDirectory: String,
        rules: NameRules = .default
    ) -> [CompatibilityIssue] {
        guard names.count > 1 else { return [] }
        var groups: [String: [String]] = [:]
        var order: [String] = []
        for name in names {
            let key = NameSanitizer.foldKey(name)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(name)
        }

        var issues: [CompatibilityIssue] = []
        let directory = relativeDirectory.isEmpty ? "光盘根目录" : relativeDirectory + "/"
        for key in order {
            guard let group = groups[key], group.count > 1 else { continue }
            let normalized = Set(group.map { $0.precomposedStringWithCanonicalMapping })
            let list = group.map { "「\($0)」" }.joined(separator: "、")

            if normalized.count < group.count {
                issues.append(
                    CompatibilityIssue(
                        severity: .warning,
                        category: .unicodeConflict,
                        relativePath: relativeDirectory,
                        message: "\(directory) 下有 Unicode 归一化后相同的名字：\(list)",
                        advice: "macOS 的 HFS+、Windows 会把它们当成同一个名字，可能互相覆盖。"
                    )
                )
            } else {
                issues.append(
                    CompatibilityIssue(
                        severity: .error,
                        category: .caseConflict,
                        relativePath: relativeDirectory,
                        message: "\(directory) 下有只在大小写上不同的名字：\(list)",
                        advice: "Windows 和大小写不敏感的磁盘只能保留一个；复制到暂存目录时会直接失败。选「自动重命名」可改成带序号的名字。"
                    )
                )
            }
        }
        return issues
    }

    /// ISO 9660 level 1：主名 1–8 个 A–Z / 0–9 / `_`，扩展名最多 3 个。
    public static func isISO9660Compliant(_ name: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        let parts = name.components(separatedBy: ".")
        guard parts.count <= 2 else { return false }
        let base = parts[0]
        guard !base.isEmpty, base.count <= 8, base.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return false
        }
        if parts.count == 2 {
            let ext = parts[1]
            guard !ext.isEmpty, ext.count <= 3, ext.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                return false
            }
        }
        return true
    }

    // MARK: 内部

    struct Entry {
        let path: String
        let name: String
        let relative: String
        let depth: Int
        let kind: FileNodeKind
        let byteCount: Int64
    }

    struct Stats {
        var isoNonCompliant = 0
        var isoNonCompliantSamples: [String] = []
        var symlinks = 0
        var symlinkSample: String?
    }

    private static func analyze(
        entries: [Entry],
        relativeDirectory: String,
        report: inout CompatibilityReport,
        stats: inout Stats
    ) {
        guard !entries.isEmpty else { return }

        for entry in entries {
            switch entry.kind {
            case .directory:
                report.directoryCount += 1
            default:
                report.fileCount += 1
                report.totalBytes += entry.byteCount
            }

            report.issues.append(contentsOf: nameIssues(
                name: entry.name,
                relativePath: entry.relative,
                rules: report.rules
            ))

            if report.rules.checkISO9660, !isISO9660Compliant(entry.name) {
                stats.isoNonCompliant += 1
                if stats.isoNonCompliantSamples.count < 3 { stats.isoNonCompliantSamples.append(entry.name) }
            }
            if entry.kind == .symlink {
                stats.symlinks += 1
                if stats.symlinkSample == nil { stats.symlinkSample = entry.relative }
            }
        }

        report.issues.append(contentsOf: conflictIssues(
            names: entries.map { $0.name },
            relativeDirectory: relativeDirectory,
            rules: report.rules
        ))
    }

    private static func aggregateIssues(
        stats: Stats,
        report: CompatibilityReport,
        rules: NameRules
    ) -> [CompatibilityIssue] {
        var issues: [CompatibilityIssue] = []

        if report.maxDepth > 8 {
            issues.append(
                CompatibilityIssue(
                    severity: .warning,
                    category: .iso9660Depth,
                    relativePath: nil,
                    message: "内容最深 \(report.maxDepth) 层，超过 ISO 9660 的 8 层（含根目录）限制",
                    advice: "只认 ISO 视图的老设备和部分车机会看不到更深的内容；建议把目录压平，或只依赖 UDF / Joliet 视图。"
                )
            )
        }

        if stats.isoNonCompliant > 0 && rules.checkISO9660 {
            let samples = stats.isoNonCompliantSamples.map { "「\($0)」" }.joined(separator: "、")
            issues.append(
                CompatibilityIssue(
                    severity: .info,
                    category: .iso9660Name,
                    relativePath: nil,
                    message: "\(stats.isoNonCompliant) 个名字不是 ISO 9660 的 8.3 形式（大写字母 / 数字 / 下划线，示例：\(samples)）",
                    advice: "Windows / macOS / Linux 走 Joliet 或 UDF 视图，名字完整；只有只认 ISO 视图的老设备和部分车机会看到截断后的 8.3 名字。"
                )
            )
        }

        if stats.symlinks > 0 {
            var message = "有 \(stats.symlinks) 个符号链接"
            if let sample = stats.symlinkSample { message += "（例如「\(sample)」）" }
            issues.append(
                CompatibilityIssue(
                    severity: .warning,
                    category: .symlink,
                    relativePath: nil,
                    message: message,
                    advice: "符号链接在 Windows 上会失效；用 UDF 视图时 macOS 也读不到链接目标。要保留链接请改用 Rock Ridge 格式，或把目标文件复制成实体文件。"
                )
            )
        }

        return issues
    }
}
