import SwiftUI
import DiscBurnKit

/// 「光盘内容」窗口：显示光盘里已经刻了什么，以及本机在这张盘上的刻录记录。
struct DiscContentsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 460, idealHeight: 540)
        .onAppear {
            if model.discContents == nil {
                model.loadDiscContents(allowMount: false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 22))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.discContents?.volumeName ?? "光盘内容")
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if model.discContentsLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.7)
            }
            Button {
                model.loadDiscContents(allowMount: false)
            } label: {
                Label("重新读取", systemImage: "arrow.clockwise")
            }
            .disabled(model.discContentsLoading || model.status.deviceNode == nil)
        }
        .padding(14)
    }

    private var subtitle: String {
        guard model.status.isPresent else { return "未插入光盘" }
        var parts: [String] = [model.status.media.displayName]
        if let contents = model.discContents {
            if let sessions = contents.sessionCount, sessions > 1 {
                parts.append("共 \(sessions) 个区段")
            }
            if !contents.entries.isEmpty {
                parts.append(contents.shortSummary)
            }
        } else {
            parts.append("尚未读取")
        }
        return parts.joined(separator: " · ")
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let note = model.discContents?.note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.discContentsError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                        Button {
                            model.loadDiscContents(allowMount: true)
                        } label: {
                            Label("临时挂载并读取", systemImage: "externaldrive.badge.plus")
                        }
                        Text("系统没有自动挂载这张盘时（例如未关闭的区段），可以临时挂载读取一遍，读完会自动弹出。")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                if let contents = model.discContents, !contents.entries.isEmpty {
                    fileList(contents)
                } else if model.discContentsLoading {
                    HStack(spacing: 8) {
                        ProgressView().progressViewStyle(CircularProgressViewStyle()).scaleEffect(0.6)
                        Text("正在读取光盘内容…").font(.system(size: 12)).foregroundColor(.secondary)
                    }
                } else if model.discContentsError == nil {
                    Text(model.status.isPresent ? "这张盘上还没有可读取的内容。" : "请先插入光盘。")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                if !model.burnHistory.isEmpty {
                    historySection
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fileList(_ contents: DiscContents) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("光盘上的内容")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            ForEach(contents.entries) { entry in
                ForEach(entry.flatten(), id: \.entry.id) { item in
                    DiscEntryRow(entry: item.entry, depth: item.depth)
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("本机刻录记录")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Text("macOS 每次只会挂载多区段光盘的其中一段，其余区段系统自己也不显示，这里是本机的记录。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            ForEach(model.burnHistory) { record in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(record.volumeName)
                            .font(.system(size: 12, weight: .medium))
                        Text(Self.dateFormatter.string(from: record.date))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(record.fileCount) 个文件 · \(ByteText.human(record.payloadBytes))")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    if !record.topLevelItems.isEmpty {
                        Text(record.topLevelItems.joined(separator: "、"))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
            }
        }
    }

    private var footer: some View {
        HStack {
            if let url = BurnHistory.fileURL {
                Text("记录保存在 \(url.path)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("关闭") { presentationMode.wrappedValue.dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(12)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
