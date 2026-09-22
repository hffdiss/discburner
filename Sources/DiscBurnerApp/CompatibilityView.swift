import SwiftUI
import DiscBurnKit

/// 右栏里的兼容性小结：一眼看出有没有问题，点「详情」看逐条原因。
struct CompatibilityPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .foregroundColor(tint)
                Text(headline)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(tint)
                Spacer()
                if model.compatibilityScanning {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                }
                Button("详情") { model.showCompatibility = true }
                    .buttonStyle(PlainButtonStyle())
                    .foregroundColor(model.compatibility == nil ? .secondary : .accentColor)
                    .font(.system(size: 11))
                    .disabled(model.compatibility == nil)
            }

            Text(detail)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("自动重命名不兼容的文件名", isOn: $model.sanitizeNames)
                .disabled(model.isBusy)
            Text("只改光盘里的副本，不动你的源文件；界面日志会列出每一个改名。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.runCompatibilityScan(reveal: true)
            } label: {
                Label("重新检查", systemImage: "checkmark.shield")
                    .frame(maxWidth: .infinity)
            }
            .disabled(model.items.isEmpty || model.isBusy || model.compatibilityScanning)
        }
    }

    private var headline: String {
        guard !model.items.isEmpty else { return "还没有添加内容" }
        if model.compatibilityScanning, model.compatibility == nil { return "正在检查…" }
        guard let report = model.compatibility else { return "正在检查…" }
        if report.isPerfect { return "未发现兼容性问题" }
        if report.hasErrors { return "\(report.headline)（建议自动重命名）" }
        return report.headline
    }

    private var detail: String {
        guard !model.items.isEmpty else { return "添加文件后会自动检查 Windows / Linux 能不能正常读。" }
        guard let report = model.compatibility else { return "正在扫描文件名…" }
        var parts: [String] = ["\(report.fileCount) 个文件 / \(report.directoryCount) 个目录"]
        if !report.renamePlan.isEmpty {
            parts.append("自动重命名可修正 \(report.renamePlan.count) 个名字")
        } else if report.isPerfect {
            parts.append("跨系统读写都没问题")
        }
        return parts.joined(separator: " · ")
    }

    private var symbolName: String {
        guard let report = model.compatibility, !model.items.isEmpty else { return "shield" }
        if report.hasErrors { return "xmark.octagon.fill" }
        if report.hasWarningsOrErrors { return "exclamationmark.triangle.fill" }
        if report.isPerfect { return "checkmark.shield.fill" }
        return "info.circle"
    }

    private var tint: Color {
        guard let report = model.compatibility, !model.items.isEmpty else { return .secondary }
        if report.hasErrors { return .red }
        if report.hasWarningsOrErrors { return .orange }
        return .green
    }
}

/// 兼容性预检详情窗口。
struct CompatibilityView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let report = model.compatibility {
                content(report)
            } else {
                VStack {
                    Spacer()
                    Text(model.items.isEmpty ? "先添加要刻录的内容。" : "正在检查…")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 580)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 20))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("兼容性预检")
                    .font(.system(size: 15, weight: .semibold))
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                model.runCompatibilityScan()
            } label: {
                Label("重新检查", systemImage: "arrow.clockwise")
            }
            .disabled(model.items.isEmpty || model.compatibilityScanning)
        }
        .padding(14)
    }

    private var summary: String {
        guard let report = model.compatibility else { return "正在检查…" }
        let view = model.preset.title
        return "\(report.headline) · \(report.fileCount) 个文件 / \(report.directoryCount) 个目录 · 目标格式：\(view)"
    }

    private func content(_ report: CompatibilityReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if report.isPerfect {
                    emptyState
                } else {
                    if report.errorCount > 0 {
                        section(title: "必须处理（\(report.errorCount)）", issues: report.issues(atLeast: .error))
                    }
                    if report.warningCount > 0 {
                        section(title: "警告（\(report.warningCount)）", issues: report.issues(atLeast: .warning).filter { $0.severity == .warning })
                    }
                    if report.infoCount > 0 {
                        section(title: "提示（\(report.infoCount)）", issues: report.issues(atLeast: .info).filter { $0.severity == .info })
                    }
                }

                if !report.renamePlan.isEmpty {
                    renameSection(report)
                }
            }
            .padding(14)
        }
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 3) {
                Text("没有发现兼容性问题")
                    .font(.system(size: 13, weight: .medium))
                Text("文件名在 Windows、macOS、Linux 上都能正常读，目录层级也在 ISO 9660 的限制内。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.textBackgroundColor)))
    }

    private func section(title: String, issues: [CompatibilityIssue]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            ForEach(issues) { issue in
                IssueRow(issue: issue)
            }
        }
    }

    private func renameSection(_ report: CompatibilityReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("自动重命名方案（\(report.renamePlan.count) 项）")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Text("勾选右栏的「自动重命名不兼容的文件名」后刻录，会按下面的方案改名；源文件不受影响。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            ForEach(Array(report.renamePlan.prefix(200).enumerated()), id: \.offset) { _, rename in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("「\(rename.oldRelativePath)」")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundColor(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Text("「\(rename.newRelativePath)」")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    if let reason = rename.reasons.first {
                        Text(reason)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
            }
            if report.renamePlan.count > 200 {
                Text("（只显示前 200 项）")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("检查只读文件名与目录结构，不会修改任何文件。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer()
            if !model.items.isEmpty {
                Toggle("自动重命名", isOn: $model.sanitizeNames)
                    .disabled(model.isBusy)
            }
            Button("关闭") { presentationMode.wrappedValue.dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(12)
    }
}

struct IssueRow: View {
    let issue: CompatibilityIssue

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: issue.severity.symbolName)
                .foregroundColor(tint)
                .font(.system(size: 12))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(issue.category.localizedName)
                        .font(.system(size: 11, weight: .medium))
                    if let path = issue.relativePath, !path.isEmpty {
                        Text(path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("整张盘")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                Text(issue.message)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Text(issue.advice)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.textBackgroundColor)))
    }

    private var tint: Color {
        switch issue.severity {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }
}

/// 「开始刻录」的确认单：先摆出预检结果，再让用户决定改名还是照原样刻。
struct BurnPrepView: View {
    @EnvironmentObject var model: AppModel
    let prep: BurnPrep
    @State private var autoRename: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(prep.summary)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)

                    if prep.isAudio {
                        audioBox
                    } else if prep.isVideo {
                        videoBox
                    } else {
                        compatibilityBox
                    }
                }
                .padding(14)
            }
            Divider()
            buttons
        }
        // 音乐 CD / 视频 DVD 的确认单没有兼容性清单，别留一大片空白。
        .frame(width: 620, height: prep.isAudio ? 340 : (prep.isVideo ? 380 : 520))
        // 默认勾上「自动重命名」：预检既然给出了方案，说明原名确实有风险。
        // 用户上次的选择会覆盖这个默认值。取消勾选后刻录，也就是「保留原名刻录」。
        .onAppear {
            // 音乐 CD / 视频 DVD 盘上没有需要改名的文件名，没有「重命名」这回事。
            autoRename = (prep.isAudio || prep.isVideo)
                ? false
                : (model.sanitizeNames || !prep.report.renamePlan.isEmpty)
        }
    }

    /// 音乐 CD 的确认框：这里要说清「盘上没有文件系统」这件事，
    /// 免得用户刻完在访达里找不到文件、以为刻坏了。
    private var audioBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "music.note.list")
                    .foregroundColor(.accentColor)
                Text("音乐 CD（红皮书音轨）")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }
            Text("盘上没有文件系统：电脑（含访达）看不到「文件」，这是红皮书音频盘的正常表现，"
                + "用 CD 机 / 车载音响 / DVD 播放机放。")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Text("文件名兼容性在这里不适用（音轨不带文件名），所以没有预检项。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.textBackgroundColor)))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.testBurn ? "opticaldiscdrive" : "opticaldiscdrive.fill")
                .font(.system(size: 20))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.testBurn ? "开始测试刻录？" : "开始刻录？")
                    .font(.system(size: 15, weight: .semibold))
                Text("刻录前最后确认")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(14)
    }

    /// 视频 DVD 的确认框：说清「盘上是 VIDEO_TS 结构」以及画面 / 码率是按什么定的，
    /// 免得用户刻完在访达里找不到「文件」，以为刻坏了。
    private var videoBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "film.stack")
                    .foregroundColor(.accentColor)
                Text("视频 DVD（DVD-Video）")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }
            Text("盘上是标准的 VIDEO_TS 结构：用 DVD 播放机 / 蓝光机 / 播放软件看，"
                + "访达里只会看到一个 VIDEO_TS 文件夹，看不到「电影文件」，这是正常的。")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Text("文件名兼容性在这里不适用（盘上只有 VIDEO_TS / VTS_xx_x 这些固定名字），所以没有预检项。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("转码要用 ffmpeg，排 VIDEO_TS 要用 dvdauthor；片长越长码率越低，全程比较慢，请留足时间。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.textBackgroundColor)))
    }
    private var compatibilityBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: prep.hasErrors ? "xmark.octagon.fill" : (prep.hasIssues ? "exclamationmark.triangle.fill" : "checkmark.shield.fill"))
                    .foregroundColor(prep.hasErrors ? .red : (prep.hasIssues ? .orange : .green))
                Text(prep.report.headline)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button("查看详情") { model.showCompatibility = true }
                    .buttonStyle(PlainButtonStyle())
                    .foregroundColor(.accentColor)
                    .font(.system(size: 11))
            }

            if prep.hasIssues {
                let highlights = prep.report.issues(atLeast: .warning).prefix(4)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(highlights)) { issue in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                                .foregroundColor(issue.severity == .error ? .red : .orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(issue.relativePath.map { "\($0)：\(issue.message)" } ?? issue.message)
                                    .font(.system(size: 11))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if prep.report.issues(atLeast: .warning).count > 4 {
                        Text("…还有 \(prep.report.issues(atLeast: .warning).count - 4) 项")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }

            if !prep.report.renamePlan.isEmpty {
                Divider()
                Toggle("自动重命名不兼容的文件名（推荐）", isOn: $autoRename)
                Text(renameExplanation)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.textBackgroundColor)))
    }

    private var renameExplanation: String {
        let count = prep.report.renamePlan.count
        if autoRename {
            return "会改掉 \(count) 个名字（示例：「\(prep.report.renamePlan.first?.oldRelativePath ?? "")」→「\(prep.report.renamePlan.first?.newRelativePath ?? "")」），只改光盘里的副本。"
        }
        return "保持原名刻录。Windows 上这些文件可能报错、显示成别的名字，或在最坏的情况下导致整理文件失败。"
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button("取消") { model.burnPrep = nil }
                .keyboardShortcut(.escape, modifiers: [])
            Spacer()
            if !prep.report.renamePlan.isEmpty {
                Button("保留原名刻录") { model.startBurn(sanitize: false) }
            }
            Button(autoRename ? "自动重命名后刻录" : (model.testBurn ? "开始测试刻录" : "开始刻录")) {
                model.startBurn(sanitize: autoRename)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }
}
