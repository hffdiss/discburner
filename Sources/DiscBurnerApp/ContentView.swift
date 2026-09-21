import SwiftUI
import DiscBurnKit
import UniformTypeIdentifiers

enum ActiveAlert: Identifiable {
    case error(String)
    case notice(String)
    case erase(EraseMode)

    var id: String {
        switch self {
        case .error(let text): return "error-\(text)"
        case .notice(let text): return "notice-\(text)"
        case .erase(let mode): return "erase-\(mode.rawValue)"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var activeAlert: ActiveAlert?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                fileColumn
                Divider()
                settingsColumn
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 940, minHeight: 560)
        .onChange(of: model.lastError) { value in
            if let value = value {
                activeAlert = .error(value)
                model.lastError = nil
            }
        }
        .onChange(of: model.finishedMessage) { value in
            guard let value = value else { return }
            activeAlert = .notice(value)
            // 等这一轮视图更新结束再清空，避免在渲染过程中改 @Published 把弹窗顶掉。
            DispatchQueue.main.async { model.finishedMessage = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .discBurnerCommand)) { notification in
            guard let raw = notification.object as? String,
                  let command = AppCommand(rawValue: raw) else { return }
            handle(command)
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .error(let message):
                return Alert(
                    title: Text("出错了"),
                    message: Text(message),
                    dismissButton: .default(Text("知道了"))
                )
            case .notice(let message):
                return Alert(
                    title: Text("完成"),
                    message: Text(message),
                    dismissButton: .default(Text("好"))
                )
            case .erase(let mode):
                return Alert(
                    title: Text("擦除光盘？"),
                    message: Text("\(mode.localizedName)。\n光盘上的所有数据都会被永久清除，且无法恢复。"),
                    primaryButton: .destructive(Text("擦除")) { model.eraseDisc(mode: mode) },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
        }
        .sheet(isPresented: $model.showDiscContents) {
            DiscContentsView().environmentObject(model)
        }
        .sheet(isPresented: $model.showCompatibility) {
            CompatibilityView().environmentObject(model)
        }
        .sheet(item: $model.burnPrep) { prep in
            BurnPrepView(prep: prep).environmentObject(model)
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView().environmentObject(model)
        }
    }

    // MARK: - 左侧文件列表

    /// 左栏 = 上面「光盘里已有的内容」+ 下面「要刻录的内容」，中间可以拖动调整高度。
    private var fileColumn: some View {
        Group {
            if model.showDiscBrowser {
                VSplitView {
                    DiscBrowserPanel()
                        .frame(minHeight: 110, idealHeight: 190, maxHeight: 420)
                    burnColumn
                        .frame(minHeight: 240)
                }
            } else {
                VStack(spacing: 0) {
                    DiscBrowserPanel()
                    burnColumn
                }
            }
        }
        .frame(minWidth: 420)
    }

    private var burnColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("要刻录的内容")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                // 添加动作统一放在窗口工具栏里，这里只留「清空」，避免同一排按钮重复两遍。
                Button(action: { model.clearItems() }) {
                    Image(systemName: "trash")
                }
                .disabled(model.items.isEmpty || model.isBusy)
                .help("清空列表")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ZStack {
                if model.items.isEmpty {
                    dropPlaceholder
                } else {
                    List {
                        ForEach(model.items) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.isDirectory ? "folder.fill" : iconName(for: item.url))
                                    .foregroundColor(item.isDirectory ? Color.accentColor : .secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).lineLimit(1)
                                    Text(item.url.deletingLastPathComponent().path)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Text(item.sizeText)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Button {
                                    model.remove(item)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(PlainButtonStyle())
                                .foregroundColor(.secondary)
                                .disabled(model.isBusy)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .listStyle(PlainListStyle())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                handleDrop(providers)
            }

            Divider()
            HStack {
                Text("合计 \(ByteText.human(model.totalBytes))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(model.isOverCapacity ? .red : .primary)
                compatibilityBadge
                Spacer()
                Text(dropHint)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 左栏底部常驻的兼容性小标：有问题的名字一眼就能看到，点开是完整清单。
    @ViewBuilder
    private var compatibilityBadge: some View {
        if !model.items.isEmpty {
            Button {
                model.runCompatibilityScan(reveal: true)
            } label: {
                HStack(spacing: 4) {
                    if model.compatibilityScanning {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(0.45)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: badgeSymbol)
                            .font(.system(size: 11))
                    }
                    Text(badgeText)
                        .font(.system(size: 11))
                }
                .foregroundColor(badgeColor)
            }
            .buttonStyle(PlainButtonStyle())
            .help("打开兼容性预检详情（⌘K）")
        }
    }

    private var badgeSymbol: String {
        guard let report = model.compatibility else { return "checkmark.shield" }
        if report.hasErrors { return "xmark.octagon.fill" }
        if report.hasWarningsOrErrors { return "exclamationmark.triangle.fill" }
        return "checkmark.shield.fill"
    }

    private var badgeColor: Color {
        guard let report = model.compatibility else { return .secondary }
        if report.hasErrors { return .red }
        if report.hasWarningsOrErrors { return .orange }
        return .green
    }

    private var badgeText: String {
        guard let report = model.compatibility else { return "检查中…" }
        if report.isPerfect { return "兼容性良好" }
        return report.headline
    }

    private var dropHint: String {
        if let capacity = model.capacityBytes {
            return "光盘可用 \(ByteText.human(capacity))"
        }
        return "未检测到介质"
    }

    private var dropPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.secondary)
            VStack(spacing: 4) {
                Text("把文件或文件夹拖到这里")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text("支持任意文件类型，目录结构会被保留")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                Button("选择文件…", action: addFiles)
                Button("选择文件夹…", action: addFolder)
            }
            .disabled(model.isBusy)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                .foregroundColor(Color.primary.opacity(0.16))
                .padding(14)
        )
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func iconName(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "iso", "dmg", "cdr", "img": return "opticaldisc"
        case "mp4", "mov", "mkv", "avi": return "film"
        case "mp3", "m4a", "wav", "flac": return "music.note"
        case "jpg", "jpeg", "png", "heic", "gif": return "photo"
        case "zip", "rar", "7z", "tar", "gz": return "doc.zipper"
        case "pdf": return "doc.text"
        case "app": return "app"
        default: return "doc"
        }
    }

    // MARK: - 右侧设置

    private var settingsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("光盘设置") {
                    HStack {
                        Text("卷标")
                        Spacer()
                        TextField("卷标", text: $model.volumeName)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 190)
                    }
                    .disabled(model.isBusy)
                    Text("显示在「访达」里的光盘名称，建议不超过 16 个字符。")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    Picker("文件系统", selection: $model.preset) {
                        ForEach(FileSystemPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .disabled(model.isBusy)
                    Text(model.preset.detail)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("实际写入：\(model.filesystemSummary)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    Toggle("剔除 .DS_Store 等 macOS 垃圾文件", isOn: $model.excludeJunk)
                        .disabled(model.isBusy)
                }

                section("兼容性预检") {
                    CompatibilityPanel()
                }

                section("刻录选项") {
                    Toggle("刻录后校验数据", isOn: $model.verify)
                        .disabled(model.isBusy)
                    Toggle("完成后弹出光盘", isOn: $model.ejectWhenDone)
                        .disabled(model.isBusy)
                    Toggle("关闭光盘（之后无法追加数据）", isOn: $model.closeDisc)
                        .disabled(model.isBusy)
                    Toggle("测试模式（不打开激光、不写入介质）", isOn: $model.testBurn)
                        .disabled(model.isBusy)

                    HStack {
                        Text("刻录速度")
                        Spacer()
                        Picker("", selection: $model.speedChoice) {
                            Text(recommendedSpeedLabel).tag(SpeedChoice.recommended)
                            Text("自动").tag(SpeedChoice.automatic)
                            ForEach(speedChoices, id: \.self) { value in
                                Text("\(value)x").tag(SpeedChoice.fixed(value))
                            }
                        }
                        .frame(width: 150)
                        .disabled(model.isBusy)
                    }
                    Text(model.speedExplanation)
                        .font(.system(size: 10))
                        .foregroundColor(model.speedExplanationIsWarning ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if model.canMergeBeforeBurn {
                        Toggle(isOn: $model.mergeBeforeBurn) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("整盘合并重刻")
                                Text("追加时先读盘上旧内容，擦盘后单段刻完；不勾就只追加一段（macOS / Linux 默认只看得到第一段）。")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .disabled(model.isBusy)
                    }

                    if let notice = model.appendNotice {
                        Text(notice.text)
                            .font(.system(size: 10))
                            .foregroundColor(noticeColor(notice.level))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                section("介质") {
                    if model.drives.count > 1 {
                        HStack {
                            Text("光驱")
                            Spacer()
                            Picker("", selection: Binding(
                                get: { model.selectedDriveIndex ?? 0 },
                                set: { model.selectedDriveIndex = $0; model.refresh() }
                            )) {
                                ForEach(model.drives) { drive in
                                    Text("#\(drive.index) \(drive.displayName)").tag(drive.index)
                                }
                            }
                            .frame(width: 170)
                        }
                        .disabled(model.isBusy)
                    }
                    mediaPanel
                    Button {
                        model.showDiscContents = true
                        if model.discContents == nil {
                            model.loadDiscContents(allowMount: false)
                        }
                    } label: {
                        Label("查看光盘内容", systemImage: "list.bullet.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!model.status.isPresent || model.isBusy)
                    Button {
                        activeAlert = .erase(model.status.media.isRewritable ? .quick : .full)
                    } label: {
                        Label("擦除光盘", systemImage: "eraser")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!canErase || model.isBusy)
                    Button {
                        model.eject()
                    } label: {
                        Label("弹出光盘", systemImage: "eject")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!model.status.isPresent || model.isBusy)
                }

                section("其他") {
                    Button {
                        saveImage()
                    } label: {
                        Label("仅生成 ISO 映像", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(model.items.isEmpty || model.isBusy)
                    Text("「开始刻录」固定在窗口右下角，滚动这一栏也不会被挡住。")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

            }
            .padding(14)
        }
        .frame(width: 340)
        .background(Color(NSColor.controlBackgroundColor))
        // 底边一条渐隐，暗示这一栏还能继续往下滚（macOS 默认不常显滚动条）。
        .overlay(
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(NSColor.controlBackgroundColor).opacity(0),
                        Color(NSColor.controlBackgroundColor),
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 20)
            }
            .allowsHitTesting(false)
        )
    }

    private var speedChoices: [Int] {
        // 固定档位就是这几档；「推荐」是单独一项，所以即使建议值不在表里（例如 CD-RW 要 10x）
        // 也能一键选中，不用往列表里塞额外的数字。
        var values = Set(SpeedAdvisor.standardSpeeds)
        // 兜底：老版本存下来的档位万一不在列表里，也留着，免得选择器显示成空白。
        if case .fixed(let stored) = model.speedChoice, stored > 0 { values.insert(stored) }
        return values.sorted()
    }

    /// 推荐倍速的选项文字，例如「推荐（8x）」。
    private var recommendedSpeedLabel: String {
        guard model.status.isPresent, let speed = model.speedAdvice.recommended else {
            return "推荐（自动）"
        }
        return "推荐（\(speed)x）"
    }

    private var canBurn: Bool {
        guard !model.items.isEmpty else { return false }
        if model.testBurn { return model.status.isPresent }
        return model.status.canBurn
    }

    private var canErase: Bool {
        model.status.isPresent && (model.status.erasable || model.status.media.isRewritable)
    }

    private var mediaPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.status.isPresent {
                HStack {
                    Text(model.status.media.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(model.status.writability.localizedDescription)
                        .font(.system(size: 11))
                        .foregroundColor(model.status.canBurn ? .green : .orange)
                }
                if let capacity = model.status.writableBytes {
                    ProgressView(value: model.usageFraction)
                        .accentColor(model.isOverCapacity ? .red : .accentColor)
                    HStack {
                        Text("已选 \(ByteText.human(model.totalBytes))")
                        Spacer()
                        Text("可用 \(ByteText.human(capacity))")
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }
                if let sessions = model.status.sessions, sessions > 0 {
                    HStack(spacing: 6) {
                        Text("已有 \(sessions) 个区段")
                        if let contents = model.discContents, !contents.entries.isEmpty {
                            Text("· " + contents.shortSummary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }
            } else {
                Text("未插入光盘")
                    .font(.system(size: 13, weight: .semibold))
                Text("请放入空白 CD-R/RW、DVD±R/RW 或 BD-R/RE。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.textBackgroundColor)))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            content()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.textBackgroundColor)))
    }

    /// 「追加刻录」那行提示的颜色：普通说明用次级色，警告橙、错误红。
    private func noticeColor(_ level: AppModel.BurnNoticeLevel) -> Color {
        switch level {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    // MARK: - 底部状态栏

    private var statusBar: some View {
        VStack(spacing: 0) {
            if model.showLog {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 140)
                .background(Color(NSColor.textBackgroundColor))
            }
            HStack(spacing: 12) {
                Text(model.phase.localizedName)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 80, alignment: .leading)
                if model.isBusy {
                    if let fraction = model.taskFraction {
                        ProgressView(value: fraction)
                            .frame(width: 220)
                        Text(String(format: "%.0f%%", fraction * 100))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 44, alignment: .trailing)
                    } else {
                        ProgressView()
                            .progressViewStyle(LinearProgressViewStyle())
                            .frame(width: 220)
                    }
                }
                Text(model.taskMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !model.logLines.isEmpty {
                    Button(model.showLog ? "隐藏日志" : "显示日志") { model.showLog.toggle() }
                        .buttonStyle(PlainButtonStyle())
                        .foregroundColor(.accentColor)
                        .font(.system(size: 11))
                }
                Spacer(minLength: 12)
                // 设置藏在这颗小齿轮里（菜单「光盘刻录 → 设置…」⌘, 也能开），
                // 平时不抢注意力，要用的时候就在手边。
                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.secondary)
                .help("设置：外观、版本号（⌘,）")
                // 主操作固定在右下角：右侧设置栏是滚动区，
                // 窗口不够高时「开始刻录」会掉到折叠线以下，这里保证它永远可见。
                if model.isBusy {
                    Button("取消") { model.cancel() }
                        .keyboardShortcut(.escape, modifiers: [])
                } else {
                    primaryBurnButton
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }

    /// 右下角的主按钮。macOS 的习惯是主操作固定在窗口右下角，并且用强调色标出来，
    /// 让人一眼看出「按下去就会开始刻录」。
    ///
    /// 这里手写强调色而不是用 `.borderedProminent`：那个 API 要 macOS 12，
    /// 本项目的部署目标是 macOS 11。
    private var primaryBurnButton: some View {
        Button {
            model.prepareBurn()
        } label: {
            Label(model.testBurn ? "开始测试刻录" : "开始刻录", systemImage: "opticaldiscdrive.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(burnButtonEnabled ? .white : Color(NSColor.secondaryLabelColor))
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(burnButtonEnabled ? Color.accentColor : Color.primary.opacity(0.07))
                )
        }
        .buttonStyle(PlainButtonStyle())
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!burnButtonEnabled)
        .help(burnButtonEnabled
              ? "确认刻录内容后开始刻录（⌘⏎）"
              : "需要一张可写入的光盘（当前不可刻录）")
    }

    private var burnButtonEnabled: Bool {
        canBurn && !model.compatibilityScanning
    }

    // MARK: - 文件选择

    /// 处理来自菜单栏的命令。
    private func handle(_ command: AppCommand) {
        switch command {
        case .addFiles:
            guard !model.isBusy else { return }
            addFiles()
        case .addFolder:
            guard !model.isBusy else { return }
            addFolder()
        case .makeImage:
            guard !model.isBusy, !model.items.isEmpty else { return }
            saveImage()
        case .burn:
            guard canBurn, !model.isBusy else { return }
            model.prepareBurn()
        case .erase:
            guard canErase, !model.isBusy else { return }
            activeAlert = .erase(model.status.media.isRewritable ? .quick : .full)
        case .eject:
            guard !model.isBusy else { return }
            model.eject()
        case .showContents:
            guard model.status.isPresent else { return }
            model.showDiscContents = true
            if model.discContents == nil {
                model.loadDiscContents(allowMount: false)
            }
        case .checkCompatibility:
            guard !model.items.isEmpty else { return }
            model.runCompatibilityScan(reveal: true)
        case .settings:
            model.showSettings = true
        case .refresh:
            model.refresh()
        case .toggleLog:
            model.showLog.toggle()
        case .revealCLI:
            if let cli = AppPaths.bundledCLI {
                NSWorkspace.shared.activateFileViewerSelecting([cli])
            }
        case .openHelp:
            if let help = AppPaths.bundledHelp {
                NSWorkspace.shared.open(help)
            }
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        if panel.runModal() == .OK {
            model.add(urls: panel.urls)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        if panel.runModal() == .OK {
            model.add(urls: panel.urls)
        }
    }

    private func saveImage() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ImageBuilder.normalizeVolumeName(model.volumeName) + ".iso"
        panel.canCreateDirectories = true
        panel.prompt = "生成"
        if panel.runModal() == .OK, let url = panel.url {
            model.startMakeImage(at: url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            model.add(urls: urls)
        }
        return true
    }
}
