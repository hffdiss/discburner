import Foundation

#if canImport(Darwin)
import Darwin
#endif

public enum FileNodeKind {
    case file
    case directory
    case symlink
    case other
}

public struct FileNode {
    public let name: String
    public let path: String
    public let kind: FileNodeKind
    public let size: Int64
    public let linkTarget: String?
}

/// 用 POSIX 接口遍历文件树。
///
/// 不能改用 `FileManager` / `URL.resourceValues`：在挂载的 UDF / Rock Ridge 光盘上
/// 读取某些条目会返回 errno 10000，而 Foundation 在把它包装成 NSError 时
/// 会直接 `Fatal error: Invalid posix errno 10000` 崩溃（无法 catch）。
/// 这里自己处理 errno，遇到读不了的条目就跳过。
public enum FileTree {

    public static func children(of path: String, includeHidden: Bool = false) -> [FileNode] {
        #if canImport(Darwin)
        guard let handle = opendir(path) else { return [] }
        defer { closedir(handle) }
        var nodes: [FileNode] = []
        while let entry = readdir(handle) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
                return String(cString: base)
            }
            if name.isEmpty || name == "." || name == ".." { continue }
            if !includeHidden && name.hasPrefix(".") { continue }
            let childPath = path.hasSuffix("/") ? path + name : path + "/" + name
            guard let node = node(at: childPath, name: name) else { continue }
            nodes.append(node)
        }
        return nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        #else
        return []
        #endif
    }

    public static func node(at path: String, name: String? = nil) -> FileNode? {
        #if canImport(Darwin)
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let type = info.st_mode & S_IFMT
        let kind: FileNodeKind
        switch type {
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        case S_IFREG: kind = .file
        default: kind = .other
        }
        var target: String?
        if kind == .symlink {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let length = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
                guard let base = pointer.baseAddress else { return 0 }
                return readlink(path, base, pointer.count - 1)
            }
            if length > 0 {
                target = String(cString: buffer)
            }
        }
        return FileNode(
            name: name ?? (path as NSString).lastPathComponent,
            path: path,
            kind: kind,
            size: Int64(info.st_size),
            linkTarget: target
        )
        #else
        return nil
        #endif
    }

    public struct Stats {
        public var files = 0
        public var directories = 0
        public var bytes: Int64 = 0
    }

    /// 递归统计（不跟随符号链接，符号链接按自身长度计入字节数）。
    public static func stats(of path: String, includeHidden: Bool = false, followRoot: Bool = true) -> Stats {
        var stats = Stats()
        guard let root = node(at: path) else { return stats }
        if root.kind == .file {
            stats.files = 1
            stats.bytes = root.size
            return stats
        }
        guard root.kind == .directory || followRoot else { return stats }
        var stack = [path]
        while let directory = stack.popLast() {
            for child in children(of: directory, includeHidden: includeHidden) {
                switch child.kind {
                case .directory:
                    stats.directories += 1
                    stack.append(child.path)
                case .file, .symlink, .other:
                    stats.files += 1
                    stats.bytes += child.size
                }
            }
        }
        return stats
    }
}
