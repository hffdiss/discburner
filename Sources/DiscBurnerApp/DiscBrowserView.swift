import SwiftUI
import DiscBurnKit

/// 光盘内容列表里的一行（缩进 + 图标 + 名字 + 大小）。
/// 主界面左上的「已有文件列表」和「查看光盘内容」窗口共用同一个样式。
struct DiscEntryRow: View {
    let entry: DiscEntry
    let depth: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundColor(entry.isDirectory ? .accentColor : .secondary)
                .frame(width: 16)
            Text(entry.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            if let target = entry.linkTarget {
                Text("→ \(target)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if !entry.isDirectory {
                Text(ByteText.human(entry.byteCount))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.vertical, 1)
    }

    private var symbol: String {
        if entry.isSymlink { return "arrow.turn.down.right" }
        return entry.isDirectory ? "folder.fill" : "doc"
    }
}

/// 主界面左上角的「光盘里已有的内容」栏。
///
/// 一开始就摆在要刻录的内容上面，是因为「这张盘里已经有什么」直接决定了这次该刻什么、
/// 还剩多少空间。系统每次只挂载多区段光盘的其中一段，所以栏里会写明区段数。
struct DiscBrowserPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.showDiscBrowser {
                Divider()
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - 标题栏

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "opticaldisc")
                .foregroundColor(model.status.isPresent ? .accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("光盘里已有的内容")
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if model.discContentsLoading || model.discWholeContentLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            }
            Button {
                model.reloadDiscContents()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(PlainButtonStyle())
            .foregroundColor(.accentColor)
            .help("重新读取光盘内容")
            .disabled(model.discContentsLoading || model.discWholeContentLoading || !model.status.isPresent)

            Button {
                model.showDiscContents = true
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(PlainButtonStyle())
            .foregroundColor(.accentColor)
            .help("在独立窗口里打开（⌘I）")

            Button {
                model.showDiscBrowser.toggle()
            } label: {
                Image(systemName: model.showDiscBrowser ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(PlainButtonStyle())
            .foregroundColor(.secondary)
            .help(model.showDiscBrowser ? "收起这一栏" : "展开这一栏")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var subtitle: String {
        guard model.status.isPresent else { return "未插入光盘" }
        var parts: [String] = [model.status.media.displayName]
        if let sessions = model.status.sessions, sessions > 0 {
            parts.append("共 \(sessions) 个区段")
        }
        if let contents = displayContents, !contents.entries.isEmpty {
            if let volume = contents.volumeName { parts.append(volume) }
            parts.append(contents.shortSummary)
        } else if model.discContentsLoading || model.discWholeContentLoading {
            parts.append("正在读取…")
        } else if displayContents == nil {
            parts.append("尚未读取")
        }
        return parts.joined(separator: " · ")
    }

    /// 优先显示按扇区读出来的「整盘内容」：系统只挂载多区段盘的其中一段，
    /// 直接显示挂载结果会让用户以为盘上少了东西。
    private var displayContents: DiscContents? {
        if let whole = model.discWholeContent, !whole.entries.isEmpty { return whole }
        return model.discContents
    }

    /// 现在显示的是不是原始扇区读出来的完整内容（而不是系统挂载的那一段）。
    private var showingWholeDisc: Bool {
        model.discWholeContent?.entries.isEmpty == false
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        if let contents = displayContents, !contents.entries.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if showingWholeDisc, let sessions = contents.sessionCount, sessions > 1 {
                    Text("这张盘共有 \(sessions) 个区段；下面是按扇区读出来的整盘内容（含全部区段），不是系统挂载的那一段。")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                } else if let sessions = contents.sessionCount, sessions > 1 {
                    Text("这张盘共有 \(sessions) 个区段，系统每次只挂载其中一段；这里显示的是系统当前挂载的那一段，其余区段看「本机刻录记录」。")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(contents.entries) { entry in
                            ForEach(entry.flatten(), id: \.entry.id) { item in
                                DiscEntryRow(entry: item.entry, depth: item.depth)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.discContentsLoading {
                HStack(spacing: 8) {
                    ProgressView().progressViewStyle(CircularProgressViewStyle()).scaleEffect(0.55)
                    Text("正在读取光盘内容…")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            } else if let error = model.discContentsError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                mountButton
            } else if !model.status.isPresent {
                Text("还没有放光盘。放入后这里会列出盘里已有的文件，方便决定这次刻什么。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let note = displayContents?.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if canMountTemporarily { mountButton }
            } else {
                Text("这张盘是空白的。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 系统没有自动挂载这张盘（例如区段未关闭）时可以临时挂载读一遍。
    private var canMountTemporarily: Bool {
        model.status.isPresent && (model.discContents?.mountPoint == nil)
    }

    private var mountButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                model.loadDiscContents(allowMount: true)
            } label: {
                Label("临时挂载并读取", systemImage: "externaldrive.badge.plus")
                    .font(.system(size: 11))
            }
            .disabled(model.discContentsLoading)
            Text("读完会自动弹出，不会在访达里留下多余的卷。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
