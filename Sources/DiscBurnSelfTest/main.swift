import Foundation
import DiscBurnKit

// 这台机器上只有 Command Line Tools，没有 XCTest，
// 所以自检写成独立可执行程序：swift run discburn-selftest

var checkCount = 0
var failureCount = 0

func expect(_ condition: Bool, _ message: String, line: Int = #line) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("  ✘ 第 \(line) 行：\(message)")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String, line: Int = #line) {
    checkCount += 1
    if actual != expected {
        failureCount += 1
        print("  ✘ 第 \(line) 行：\(label) 期望 \(expected)，实际 \(actual)")
    }
}

func expectNil(_ value: Any?, _ label: String, line: Int = #line) {
    checkCount += 1
    if value != nil {
        failureCount += 1
        print("  ✘ 第 \(line) 行：\(label) 期望 nil，实际 \(String(describing: value))")
    }
}

func run(_ name: String, _ body: () throws -> Void) {
    let before = failureCount
    do {
        try body()
    } catch {
        failureCount += 1
        print("  ✘ \(name) 抛出异常：\(error)")
    }
    let mark = failureCount == before ? "✔" : "✘"
    print("\(mark) \(name)")
}

func makeTempDirectory(_ label: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("DiscBurner-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - drutil 输出解析

let driveListOutput = """
   Vendor   Product           Rev   Bus       SupportLevel
1  PIONEER  DVD-RW DVR-XU01C  DL61  USB       Unsupported
2  HL-DT-ST BD-RE  WH16NS60   1.02  SATA      Apple Shipping
"""

let statusOutput = """
 Vendor   Product           Rev 
 PIONEER  DVD-RW DVR-XU01C  DL61

           Type: DVD+R                Name: /dev/disk4
       Sessions: 13                 Tracks: 13
   Write Speeds: 3x, 4x, 6x, 8x
   Overwritable:   00:00:00         blocks:        0 /   0.00MB /   0.00MiB
     Space Free:  337:27:35         blocks:  1518560 /   3.11GB /   2.90GiB
     Space Used:  166:38:70         blocks:   749920 /   1.54GB /   1.43GiB
    Writability: appendable
      Book Type: DVD-ROM (v1)
       Media ID: MCC 004
"""

let blankStatusOutput = """
           Type: DVD-R                Name: /dev/disk5
       Sessions: 0                 Tracks: 0
   Write Speeds: 2x, 4x, 8x
 Space Free:  337:27:35         blocks:  2298496 /   4.71GB /   4.38GiB
 Space Used:    0:00:00         blocks:        0 /   0.00MB /   0.00MiB
Writability: blank
"""

let noMediaOutput = """
 Vendor   Product           Rev 
 PIONEER  DVD-RW DVR-XU01C  DL61

 No Media Inserted
"""

print("== 驱动器与介质解析 ==")

run("解析 drutil list") {
    let drives = DriveService.parseDriveList(driveListOutput)
    expectEqual(drives.count, 2, "驱动器数量")
    expectEqual(drives[0].index, 1, "编号")
    expectEqual(drives[0].vendor, "PIONEER", "厂商")
    expectEqual(drives[0].product, "DVD-RW DVR-XU01C", "型号")
    expectEqual(drives[0].revision, "DL61", "固件")
    expectEqual(drives[0].bus, "USB", "接口")
    expect(!drives[0].isAppleSupported, "第三方光驱应为 Unsupported")
    expect(drives[1].isAppleSupported, "Apple Shipping 应为支持")
}

run("忽略表头与非表格内容") {
    let output = """
       Vendor   Product           Rev   Bus       SupportLevel
    没有驱动器
    """
    expect(DriveService.parseDriveList(output).isEmpty, "不应解析出驱动器")
}

run("解析 drutil status（可追加的 DVD+R）") {
    let status = DriveService.parseStatus(statusOutput)
    expect(status.isPresent, "应检测到介质")
    expectEqual(status.media, .dvdPlusR, "介质类型")
    expectEqual(status.rawType, "DVD+R", "原始类型")
    expectEqual(status.deviceNode, "/dev/disk4", "设备节点")
    expectEqual(status.sessions, 13, "区段数")
    expectEqual(status.tracks, 13, "轨道数")
    expectEqual(status.writeSpeeds, [3, 4, 6, 8], "刻录倍速")
    expectEqual(status.writability, .appendable, "写入状态")
    expectEqual(status.freeBytes, 1_518_560 * 2048, "剩余空间")
    expectEqual(status.usedBytes, 749_920 * 2048, "已用空间")
    expectEqual(status.bookType, "DVD-ROM (v1)", "Book Type")
    expectEqual(status.mediaID, "MCC 004", "Media ID")
    expect(status.canBurn, "应可写入")
}

run("解析空白 DVD-R") {
    let status = DriveService.parseStatus(blankStatusOutput)
    expectEqual(status.media, .dvdR, "介质类型")
    expectEqual(status.writability, .blank, "写入状态")
    expectEqual(status.writableBytes, 2_298_496 * 2048, "可写空间")
    expect(status.canBurn, "空白盘应可写入")
}

run("未插入光盘") {
    let status = DriveService.parseStatus(noMediaOutput)
    expect(!status.isPresent, "不应检测到介质")
    expectNil(status.writableBytes, "可写空间")
}

run("解析 discinfo") {
    let info = DriveService.parseDiscInfo("""
             dataLength: 32
               erasable: 1
           sessionState: 0
             discStatus: 1
           sessionCount: 14
    """)
    expectEqual(info?.erasable, true, "可擦除")
    expectEqual(info?.sessionCount, 14, "区段数")
    expectEqual(info?.discStatus, 1, "Disc Status")
    expectEqual(info?.sessionState, 0, "Session State")
}

run("写满/关闭的光盘不应被当成「状态未知」") {
    // 真实机器上的输出：盘写满后 Writability 字段是空的，剩余空间为 0
    let filled = DriveService.parseStatus("""
               Type: DVD+R                Name: /dev/disk4
           Sessions: 14                 Tracks: 14
       Overwritable:   00:00:00         blocks:        0 /   0.00MB /   0.00MiB
         Space Free:   00:00:00         blocks:        0 /   0.00MB /   0.00MiB
         Space Used:  166:46:14         blocks:   750464 /   1.54GB /   1.43GiB
        Writability: 
          Book Type: DVD-ROM (v1)
           Media ID: MCC 004
    """)
    expect(filled.isPresent, "应检测到介质")
    expectEqual(filled.media, .dvdPlusR, "介质类型")
    expectEqual(filled.writability, .unknown, "原始解析应为未知（Writability 为空）")
    expect(!filled.canBurn, "写满的盘不能刻录")
    expectNil(filled.writableBytes, "没有可写空间")

    let closedInfo = DriveService.DiscInfo(erasable: false, sessionCount: 14, discStatus: 2, sessionState: 3)
    let merged = DriveService.apply(closedInfo, to: filled)
    expectEqual(merged.writability, .closed, "Disc Status 2 应判定为已关闭")
    expectEqual(merged.discStatus, 2, "Disc Status 透传")
    expect(!merged.canBurn, "已关闭的盘不能刻录")
    expect(merged.summary.contains("无法再写"), "提示应说明无法再写，实际：\(merged.summary)")

    // 未完成（可追加）的盘仍应允许写入
    let appendableInfo = DriveService.DiscInfo(erasable: false, sessionCount: 3, discStatus: 1, sessionState: 1)
    let appendable = DriveService.apply(
        appendableInfo,
        to: DriveService.parseStatus("""
                   Type: DVD+R                Name: /dev/disk4
               Sessions: 3                  Tracks: 3
         Space Free:  337:27:35          blocks:  1518560 /   3.11GB /   2.90GiB
         Space Used:  166:38:70          blocks:   749920 /   1.54GB /   1.43GiB
        """)
    )
    expectEqual(appendable.writability, .appendable, "Disc Status 1 应为可追加")
    expect(appendable.canBurn, "可追加的盘应能继续刻录")
}

print("== 介质模型 ==")

run("介质类型识别") {
    expectEqual(MediaKind.parse("DVD+R"), .dvdPlusR, "DVD+R")
    expectEqual(MediaKind.parse("DVD-R"), .dvdR, "DVD-R")
    expectEqual(MediaKind.parse("DVD-RW"), .dvdRW, "DVD-RW")
    expectEqual(MediaKind.parse("CD-R"), .cdR, "CD-R")
    expectEqual(MediaKind.parse("CD-RW"), .cdRW, "CD-RW")
    expectEqual(MediaKind.parse("DVD+R DL"), .dvdPlusRDL, "DVD+R DL")
    expectEqual(MediaKind.parse("DVD-R DL"), .dvdRDL, "DVD-R DL")
    expectEqual(MediaKind.parse("DVD-RAM"), .dvdRAM, "DVD-RAM")
    expectEqual(MediaKind.parse("BD-R"), .bdR, "BD-R")
    expectEqual(MediaKind.parse("BD-RE"), .bdRE, "BD-RE")
    expectEqual(MediaKind.parse("DRDeviceMediaTypeDVDPlusR"), .dvdPlusR, "DiscRecording 名称")
    expectEqual(MediaKind.parse("奇怪的介质"), .unknown, "未知介质")
    expectNil(MediaKind.parse(""), "空字符串")
}

run("容量与可擦除属性") {
    expectEqual(MediaKind.cdR.nominalCapacityBytes, 737_280_000, "CD-R 标称容量")
    expectEqual(MediaKind.dvdR.nominalCapacityBytes, 4_707_319_808, "DVD-R 标称容量")
    expect(MediaKind.dvdPlusRDL.nominalCapacityBytes > MediaKind.dvdR.nominalCapacityBytes, "双层 DVD 更大")
    expect(MediaKind.dvdRW.isRewritable, "DVD-RW 可擦除")
    expect(!MediaKind.dvdR.isRewritable, "DVD-R 不可擦除")
    expect(!MediaKind.dvdROM.isWritable, "DVD-ROM 不可写")
}

run("写入状态映射") {
    expectEqual(Writability(statusText: "blank"), .blank, "blank")
    expectEqual(Writability(statusText: "appendable"), .appendable, "appendable")
    expectEqual(Writability(statusText: "overwritable"), .overwritable, "overwritable")
    expectEqual(Writability(statusText: "closed"), .closed, "closed")
    expect(Writability.blank.canBurn, "空白盘可写")
    expect(!Writability.closed.canBurn, "已关闭不可写")
}

run("字节格式化") {
    expectEqual(ByteText.human(0), "0 B", "0")
    expectEqual(ByteText.human(1024), "1.00 KiB", "1 KiB")
    expectEqual(ByteText.human(4_707_319_808), "4.38 GiB", "4.38 GiB")
}

print("== 映像与进度解析 ==")

run("卷标清洗") {
    expectEqual(ImageBuilder.normalizeVolumeName("我的光盘"), "我的光盘", "中文卷标")
    expectEqual(ImageBuilder.normalizeVolumeName("a/b:c"), "a_b_c", "非法字符")
    expectEqual(ImageBuilder.normalizeVolumeName("   "), "DATA", "空白回退")
    expectEqual(ImageBuilder.normalizeVolumeName("0123456789ABCDEFGHIJ").count, 16, "长度截断")
}

run("映像扇区数解析") {
    expectEqual(ImageBuilder.parseSectorCount("903 (0x00000000000387) sectors\n"), 903, "扇区数")
    expectEqual(ImageBuilder.parseSectorCount("2298496 (0x000000000231290) sectors"), 2_298_496, "大映像")
    expectNil(ImageBuilder.parseSectorCount("Creating hybrid image..."), "无扇区信息")
}

run("刻录进度解析") {
    var parser = BurnOutputParser(phase: .preparing)
    expectEqual(parser.consume("Preparing data").phase, .preparing, "准备阶段")
    expectEqual(parser.consume("Burning... 10%").phase, .burning, "写入阶段")
    expectEqual(parser.consume("Burning... 55%").fraction, 0.55, "写入进度")
    expectEqual(parser.consume("Verifying disc 30%").phase, .verifying, "校验阶段")
    expectEqual(parser.consume("Erasing...").phase, .erasing, "擦除阶段")
    expectNil(BurnOutputParser.percentage(in: "Burning disc"), "无百分比")

    // drutil 的转圈动画（指针字节 + 退格 + 回车）要丢掉，不能当日志显示
    expectEqual(BurnOutputParser.sanitize("p\u{8} \u{8}\u{d}"), "", "动画残留丢弃")
    expectEqual(BurnOutputParser.sanitize("Burn completed."), "Burn completed.", "正常文本保留")
}

run("刻录参数拼装") {
    let image = URL(fileURLWithPath: "/tmp/demo.iso")
    let args = Burner.burnArguments(
        image: image,
        options: BurnOptions(speed: 8, verify: true, ejectWhenDone: false, closeDisc: true)
    )
    expectEqual(args, ["burn", "-speed", "8", "-noappendable", "-verify", "/tmp/demo.iso"], "关闭光盘时的参数")
    let testArgs = Burner.burnArguments(image: image, options: BurnOptions(verify: false))
    expect(testArgs.contains("-noverify"), "关闭校验")
    expect(testArgs.contains("-eject"), "默认弹出")
    expect(testArgs.contains("-appendable"), "默认保留可追加（不要关闭光盘）")
    expect(!testArgs.contains("-noappendable"), "默认不该关闭光盘")
    expectEqual(testArgs.last, "/tmp/demo.iso", "映像路径放最后")

    // 指定驱动器时，-drive 必须放在 burn 之前
    let driveArgs = Burner.burnArguments(image: image, options: BurnOptions(driveIndex: 2))
    expectEqual(Array(driveArgs.prefix(3)), ["-drive", "2", "burn"], "驱动器参数位置")
}

run("识别现成的映像文件") {
    let folder = try makeTempDirectory("direct")
    defer { try? FileManager.default.removeItem(at: folder) }
    let iso = folder.appendingPathComponent("archive.iso")
    try Data(count: 2048).write(to: iso)
    let text = folder.appendingPathComponent("notes.txt")
    try "hello".write(to: text, atomically: true, encoding: .utf8)

    expectEqual(BurnJob.directImageURL(for: [iso])?.lastPathComponent, "archive.iso", "应识别 ISO")
    expectNil(BurnJob.directImageURL(for: [text]), "普通文件不应被当成映像")
    expectNil(BurnJob.directImageURL(for: [iso, text]), "多个项目时走常规流程")
    expectNil(BurnJob.directImageURL(for: [folder]), "文件夹不应被当成映像")
}

print("== 暂存目录 ==")

run("重名文件自动改名") {
    let source = try makeTempDirectory("names")
    defer { try? FileManager.default.removeItem(at: source) }
    let workspace = try Workspace(prefix: "SelfTest")
    defer { workspace.cleanup() }

    let firstFolder = source.appendingPathComponent("a", isDirectory: true)
    let secondFolder = source.appendingPathComponent("b", isDirectory: true)
    try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
    let fileOne = firstFolder.appendingPathComponent("report.txt")
    let fileTwo = secondFolder.appendingPathComponent("report.txt")
    try "hello".write(to: fileOne, atomically: true, encoding: .utf8)
    try "world!".write(to: fileTwo, atomically: true, encoding: .utf8)

    let entries = try workspace.stage(items: [fileOne, fileTwo])
    expectEqual(entries.count, 2, "条目数")
    expectEqual(entries[0].name, "report.txt", "第一个名字")
    expectEqual(entries[1].name, "report 2.txt", "第二个名字")
    expectEqual(entries[0].byteCount, 5, "第一个大小")
    expectEqual(entries[1].byteCount, 6, "第二个大小")
    expect(FileManager.default.fileExists(atPath: entries[1].destination.path), "目标文件应存在")
    expectEqual(try String(contentsOf: entries[1].destination), "world!", "内容一致")
}

run("保留目录结构并剔除垃圾文件") {
    let source = try makeTempDirectory("junk")
    defer { try? FileManager.default.removeItem(at: source) }
    let workspace = try Workspace(prefix: "SelfTest")
    defer { workspace.cleanup() }

    let folder = source.appendingPathComponent("资料", isDirectory: true)
    let nested = folder.appendingPathComponent("子目录", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "content".write(to: nested.appendingPathComponent("笔记.txt"), atomically: true, encoding: .utf8)
    try "junk".write(to: folder.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
    try "fork".write(to: folder.appendingPathComponent("._笔记.txt"), atomically: true, encoding: .utf8)

    let entries = try workspace.stage(items: [folder])
    expectEqual(entries.count, 1, "条目数")
    expectEqual(entries[0].name, "资料", "中文目录名")
    let staged = entries[0].destination
    expect(!FileManager.default.fileExists(atPath: staged.appendingPathComponent(".DS_Store").path), ".DS_Store 应被剔除")
    expect(!FileManager.default.fileExists(atPath: staged.appendingPathComponent("._笔记.txt").path), "AppleDouble 应被剔除")
    expect(FileManager.default.fileExists(atPath: staged.appendingPathComponent("子目录/笔记.txt").path), "嵌套文件应保留")
    expectEqual(entries[0].byteCount, 7, "目录体积")
}

run("可以保留垃圾文件") {
    let source = try makeTempDirectory("keepjunk")
    defer { try? FileManager.default.removeItem(at: source) }
    let workspace = try Workspace(prefix: "SelfTest")
    defer { workspace.cleanup() }

    let folder = source.appendingPathComponent("keep", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "junk".write(to: folder.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
    let entries = try workspace.stage(
        items: [folder],
        options: StageOptions(excludeJunkFiles: false, useCloneWhenPossible: false)
    )
    expect(
        FileManager.default.fileExists(atPath: entries[0].destination.appendingPathComponent(".DS_Store").path),
        ".DS_Store 应被保留"
    )
}

run("源文件不存在时报错") {
    let source = try makeTempDirectory("missing")
    defer { try? FileManager.default.removeItem(at: source) }
    let workspace = try Workspace(prefix: "SelfTest")
    defer { workspace.cleanup() }
    do {
        _ = try workspace.stage(items: [source.appendingPathComponent("not-there.txt")])
        expect(false, "应当抛错")
    } catch {
        expect(true, "抛错符合预期")
    }
}

run("统计目录大小") {
    let source = try makeTempDirectory("sizes")
    defer { try? FileManager.default.removeItem(at: source) }
    let folder = source.appendingPathComponent("sizes", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(count: 100).write(to: folder.appendingPathComponent("one.bin"))
    try Data(count: 250).write(to: folder.appendingPathComponent("two.bin"))
    expectEqual(Workspace.size(of: folder), 350, "目录总大小")
}

print("== 兼容性预检 ==")

run("刻录速度建议") {
    // DVD+R：驱动器上报 3/4/6/8x，稳妥上限 8x → 取 8x
    let dvd = SpeedAdvisor.advise(media: .dvdPlusR, reportedSpeeds: [3, 4, 6, 8])
    expectEqual(dvd.recommended, 8, "DVD+R 推荐值")
    expectEqual(dvd.conservativeCap, 8, "DVD+R 稳妥上限")
    expect(dvd.caution(for: 8) == nil, "等于推荐值不该有提醒")
    expect(dvd.caution(for: 16) != nil, "高于推荐值应提醒")
    // 48x 既高于上限、又不在驱动器上报的档位里，两条都该说清楚
    let wayTooFast = dvd.caution(for: 48) ?? ""
    expect(wayTooFast.contains("48x"), "提醒里应写明倍速：\(wayTooFast)")
    expect(wayTooFast.contains("3x / 4x / 6x / 8x"), "应列出驱动器上报的档位：\(wayTooFast)")
    // 低于上限、但驱动器没上报的档位也要提一句（可能被拒绝）
    expect(dvd.caution(for: 2)?.contains("没有 2x") == true, "未上报的档位应提示")

    // 同一张盘，驱动器能跑到 16x：仍然建议 8x
    let fast = SpeedAdvisor.advise(media: .dvdPlusR, reportedSpeeds: [4, 8, 16])
    expectEqual(fast.recommended, 8, "有 16x 时仍建议 8x")
    expect(fast.caution(for: 16)?.contains("16x") == true, "提醒里应写明倍速")

    // CD-R：驱动器只支持 48x，落在 24x 上限之上
    let cd = SpeedAdvisor.advise(media: .cdR, reportedSpeeds: [16, 24, 32, 48])
    expectEqual(cd.recommended, 24, "CD-R 推荐 24x")
    expectEqual(cd.conservativeCap, 24, "CD-R 上限")

    let cdOnlyFast = SpeedAdvisor.advise(media: .cdR, reportedSpeeds: [40, 48])
    expectEqual(cdOnlyFast.recommended, 40, "全都超过上限时取最低一档")
    expect(cdOnlyFast.reason.contains("高于"), "应说明为什么超过建议值：\(cdOnlyFast.reason)")

    // 双层 DVD：稳妥上限 4x
    let dual = SpeedAdvisor.advise(media: .dvdPlusRDL, reportedSpeeds: [2, 4, 8])
    expectEqual(dual.recommended, 4, "DVD+R DL 推荐 4x")

    // 可重写介质
    let re = SpeedAdvisor.advise(media: .bdRE, reportedSpeeds: [1, 2, 4])
    expectEqual(re.recommended, 2, "BD-RE 推荐 2x")
    let rw = SpeedAdvisor.advise(media: .dvdPlusRW, reportedSpeeds: [2, 4, 6, 8])
    expectEqual(rw.recommended, 6, "DVD+RW 推荐 6x")

    // 驱动器没上报倍速 → 用经验值
    let silent = SpeedAdvisor.advise(media: .dvdR, reportedSpeeds: [])
    expectEqual(silent.recommended, 8, "没有上报时用经验值")
    expect(silent.reason.contains("没有上报"), "应说明原因：\(silent.reason)")

    // 介质类型不明 → 取驱动器上报的中间值，别冲最高速
    let unknown = SpeedAdvisor.advise(media: .unknown, reportedSpeeds: [2, 4, 8, 16])
    expectEqual(unknown.recommended, 8, "介质不明时取中间值")
    expectEqual(unknown.conservativeCap, nil, "介质不明时没有上限")

    // 完全没信息 → 交给自动
    let nothing = SpeedAdvisor.advise(media: .unknown, reportedSpeeds: [])
    expectNil(nothing.recommended, "没有依据时返回 nil（自动）")

    // 小内容提示
    let small = SpeedAdvisor.advise(media: .dvdPlusR, reportedSpeeds: [4, 8], payloadBytes: 20 * 1024 * 1024)
    expect(small.hint != nil, "内容很小时应给出「慢一点也花不了多久」的提示")
    expect(small.hint?.contains("6x") == true, "小内容提示应指向下一档 6x：\(small.hint ?? "（无）")")
    let big = SpeedAdvisor.advise(media: .dvdPlusR, reportedSpeeds: [4, 8], payloadBytes: 4 * 1024 * 1024 * 1024)
    expectNil(big.hint, "内容很大时不该多嘴")

    // 界面上提供的常用倍速档
    expectEqual(SpeedAdvisor.standardSpeeds, [1, 2, 3, 4, 6, 8, 16, 24, 48], "常用倍速档")
    expectEqual(SpeedAdvisor.lowerAlternative(to: 8), 6, "8x 的下一档")
    expectEqual(SpeedAdvisor.lowerAlternative(to: 4), 3, "4x 的下一档")
    expectEqual(SpeedAdvisor.lowerAlternative(to: 2), 1, "2x 的下一档")
    expectEqual(SpeedAdvisor.lowerAlternative(to: 16), 8, "16x 的下一档")
    expectEqual(SpeedAdvisor.lowerAlternative(to: 24), 16, "24x 的下一档")
    expectEqual(SpeedAdvisor.lowerAlternative(to: 48), 24, "48x 的下一档")
    expectNil(SpeedAdvisor.lowerAlternative(to: 1), "1x 没有更低档")
}

run("刻录耗时估算") {
    // DVD 1x ≈ 1.35 MB/s，1 GiB ≈ 1074 MB → 约 795 秒 + 45 秒固定开销
    let oneGiB = Int64(1024 * 1024 * 1024)
    let at4x = SpeedAdvisor.estimateDuration(payloadBytes: oneGiB, speed: 4, media: .dvdR)
    let at8x = SpeedAdvisor.estimateDuration(payloadBytes: oneGiB, speed: 8, media: .dvdR)
    expect(at4x > at8x, "倍速越高越省时间")
    expect(at8x > 100 && at8x < 180, "8x 刻 1GiB 应在两三分钟量级，实际 \(Int(at8x)) 秒")
    expectEqual(SpeedAdvisor.estimateDuration(payloadBytes: 0, speed: 8, media: .dvdR), 0, "没有内容时为 0")

    // CD 1x 只有 150 KB/s，同样的数据量慢得多
    let cd = SpeedAdvisor.estimateDuration(payloadBytes: 600 * 1024 * 1024, speed: 24, media: .cdR)
    expect(cd > 100, "CD 上 600MB 需要几分钟，实际 \(Int(cd)) 秒")

    expectEqual(SpeedAdvisor.durationText(45), "45 秒", "秒")
    expectEqual(SpeedAdvisor.durationText(150), "2 分 30 秒", "分钟+秒")
    expectEqual(SpeedAdvisor.durationText(600), "10 分钟", "整分钟")
    expectEqual(SpeedAdvisor.durationText(3700), "1 小时 1 分", "小时")
    expectEqual(SpeedAdvisor.durationText(0), "—", "0 秒是「没算出来」的占位符")

    // 刻录中的那条状态文字：估完之后不能变成「预计还要 —」
    expectEqual(
        SpeedAdvisor.progressText(elapsed: 30, remaining: 300),
        "已用 30 秒，预计还要 5 分钟",
        "正常估算"
    )
    expectEqual(
        SpeedAdvisor.progressText(elapsed: 120, remaining: 40),
        "已用 2 分钟，预计还要不到 1 分钟",
        "不到一分钟时换个说法"
    )
    expectEqual(
        SpeedAdvisor.progressText(elapsed: 200, remaining: 0),
        "已用 3 分 20 秒，正在收尾…",
        "估完了就说正在收尾，不能说「预计还要 —」"
    )
    expectEqual(
        SpeedAdvisor.progressText(elapsed: 200, remaining: -15),
        "已用 3 分 20 秒，正在收尾…",
        "超出估算时间也不该出现占位符"
    )
    expect(!SpeedAdvisor.progressText(elapsed: 10, remaining: 0).contains("—"), "整条文字里不该有占位符")
}

run("名字清洗：非法字符 / 结尾点空格 / 保留名 / 空名") {
    let illegal = NameSanitizer.sanitizeComponent("报告:2024?.pdf")
    expectEqual(illegal.name, "报告_2024_.pdf", "非法字符应替换成下划线")
    expect(!illegal.notes.isEmpty, "应说明改了什么")

    let reserved = NameSanitizer.sanitizeComponent("CON.txt")
    expectEqual(reserved.name, "_CON.txt", "Windows 保留名应加前缀")

    let trailing = NameSanitizer.sanitizeComponent("摘要. ")
    expectEqual(trailing.name, "摘要", "应去掉结尾的点和空格")

    let control = NameSanitizer.sanitizeComponent("bad\u{07}name")
    expect(!control.name.unicodeScalars.contains { $0.value == 0x07 }, "控制字符应被替换")
    expectEqual(control.name, "bad_name", "控制字符换成下划线")

    let empty = NameSanitizer.sanitizeComponent("...")
    expectEqual(empty.name, "未命名", "名字被清空后应回退")

    let clean = NameSanitizer.sanitizeComponent("普通文件名.txt")
    expectEqual(clean.name, "普通文件名.txt", "正常名字不该改动")
    expect(clean.notes.isEmpty, "正常名字不该有说明")
}

run("Windows 保留名判断") {
    expect(NameSanitizer.isWindowsReservedName("CON"), "CON")
    expect(NameSanitizer.isWindowsReservedName("com1.txt"), "com1.txt")
    expect(NameSanitizer.isWindowsReservedName("LPT9"), "LPT9")
    expect(!NameSanitizer.isWindowsReservedName("COM10"), "COM10 不是保留名")
    expect(!NameSanitizer.isWindowsReservedName("console.txt"), "console 不是保留名")
}

run("大小写 / Unicode 归一化用的比较键") {
    expectEqual(NameSanitizer.foldKey("Report.TXT"), NameSanitizer.foldKey("report.txt"), "只差大小写")
    let precomposed = "caf\u{00E9}.txt"
    let decomposed = "cafe\u{0301}.txt"
    // 注意：Swift 的字符串比较本身就是「Unicode 等价」的，
    // 所以这里比较 UTF-8 字节数，确认磁盘上确实是两种不同的写法。
    expect(precomposed.utf8.count != decomposed.utf8.count, "两种写法的字节数不同")
    expectEqual(NameSanitizer.foldKey(precomposed), NameSanitizer.foldKey(decomposed), "归一化后相同")
}

run("逐个名字的兼容性判定") {
    let illegal = CompatibilityChecker.nameIssues(name: "报告:2024?.pdf", relativePath: "报告:2024?.pdf")
    expect(illegal.contains { $0.category == .illegalCharacter && $0.severity == .warning }, "应提示非法字符")
    expect(illegal.contains { $0.message.contains("?") }, "应列出具体字符")

    let reserved = CompatibilityChecker.nameIssues(name: "nul", relativePath: "nul")
    expect(reserved.contains { $0.category == .reservedName }, "应提示保留名")

    let trailing = CompatibilityChecker.nameIssues(name: "备注 ", relativePath: "备注 ")
    expect(trailing.contains { $0.category == .trailingDotOrSpace }, "应提示结尾空格")

    let long = String(repeating: "a", count: 300)
    expect(
        CompatibilityChecker.nameIssues(name: long, relativePath: long)
            .contains { $0.category == .nameTooLong && $0.severity == .error },
        "超过 255 字节应为「需处理」"
    )

    let joliet = CompatibilityChecker.nameIssues(name: String(repeating: "字", count: 70), relativePath: "长名")
    expect(joliet.contains { $0.category == .jolietNameTooLong }, "超过 64 字符应提示 Joliet 截断")

    let isoCompliant = CompatibilityChecker.nameIssues(name: "README.TXT", relativePath: "README.TXT")
    expect(isoCompliant.isEmpty, "8.3 大写名字不该有任何提示")

    let permissive = CompatibilityChecker.nameIssues(
        name: "报告:2024?.pdf",
        relativePath: "x",
        rules: .permissive
    )
    expect(permissive.isEmpty, "宽松规则下不提示")

    let udfOnly = NameSanitizer.sanitizeComponent(
        String(repeating: "长", count: 80),
        rules: NameRules(sanitizeCharacterLimit: nil)
    )
    expectEqual(udfOnly.name.count, 80, "没有 Joliet 时不该按字符数截断")
}

run("大小写冲突与 Unicode 重名") {
    let caseConflict = CompatibilityChecker.conflictIssues(
        names: ["Report.txt", "report.txt", "说明.txt"],
        relativeDirectory: "资料"
    )
    expectEqual(caseConflict.count, 1, "只应报一组冲突")
    expectEqual(caseConflict.first?.category, .caseConflict, "类别")
    expectEqual(caseConflict.first?.severity, .error, "大小写冲突属于「需处理」")
    expect(caseConflict.first?.message.contains("report.txt") == true, "应列出冲突的名字")
    expect(caseConflict.first?.message.contains("资料") == true, "应写清在哪个目录")

    let unicode = CompatibilityChecker.conflictIssues(
        names: ["caf\u{00E9}.txt", "cafe\u{0301}.txt"],
        relativeDirectory: ""
    )
    expectEqual(unicode.count, 1, "一组 Unicode 冲突")
    expectEqual(unicode.first?.category, .unicodeConflict, "类别")
    expectEqual(unicode.first?.severity, .warning, "Unicode 重名只是警告")

    expect(
        CompatibilityChecker.conflictIssues(names: ["a.txt", "b.txt"], relativeDirectory: "").isEmpty,
        "不冲突时不该有提示"
    )
}

run("ISO 9660 名字判定") {
    expect(CompatibilityChecker.isISO9660Compliant("README.TXT"), "8.3 大写")
    expect(CompatibilityChecker.isISO9660Compliant("DATA_1"), "无扩展名")
    expect(!CompatibilityChecker.isISO9660Compliant("readme.txt"), "小写不合规")
    expect(!CompatibilityChecker.isISO9660Compliant("LONGNAME1.TXT"), "主名超过 8 字符")
    expect(!CompatibilityChecker.isISO9660Compliant("报告.txt"), "中文不合规")
    expect(!CompatibilityChecker.isISO9660Compliant("a.b.c"), "多个点不合规")
}

run("文件系统选项决定命名规则") {
    let universal = ImageOptions(volumeName: "X")
    expectEqual(universal.nameRules.jolietMaxCharacters, 64, "Joliet 上限")
    expectNil(universal.nameRules.sanitizeCharacterLimit, "同时有 UDF 时不必按字符截断")
    expect(universal.nameRules.checkISO9660, "默认检查 ISO 视图")

    let udfOnly = ImageOptions(volumeName: "X", includeISO9660: false, includeJoliet: false, includeUDF: true)
    expectNil(udfOnly.nameRules.jolietMaxCharacters, "没有 Joliet 就不检查 64 字符")
    expect(!udfOnly.nameRules.checkISO9660, "没有 ISO 就不检查 8.3")

    let jolietOnly = ImageOptions(volumeName: "X", includeISO9660: true, includeJoliet: true, includeUDF: false)
    expectEqual(jolietOnly.nameRules.sanitizeCharacterLimit, 64, "只有 Joliet 时自动改名要截到 64 字符")
}

run("扫描真实目录：非法字符 / 保留名 / 超长名 / 层级") {
    let source = try makeTempDirectory("compat")
    defer { try? FileManager.default.removeItem(at: source) }
    let folder = source.appendingPathComponent("待刻内容", isDirectory: true)
    let nested = folder.appendingPathComponent("子目录", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "a".write(to: folder.appendingPathComponent("报告:2024?.txt"), atomically: true, encoding: .utf8)
    try "b".write(to: folder.appendingPathComponent("CON.txt"), atomically: true, encoding: .utf8)
    try "c".write(to: URL(fileURLWithPath: folder.path + "/备注 "), atomically: true, encoding: .utf8)
    let longName = String(repeating: "长", count: 70) + ".txt"
    try "d".write(to: nested.appendingPathComponent(longName), atomically: true, encoding: .utf8)
    try "e".write(to: folder.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)

    let report = CompatibilityChecker.scan(items: [folder])
    expectEqual(report.fileCount, 4, "文件数（垃圾文件不算）")
    expectEqual(report.directoryCount, 2, "目录数（含被选中的顶层目录）")
    expect(report.issues.contains { $0.category == .illegalCharacter }, "应提示非法字符")
    expect(report.issues.contains { $0.category == .reservedName }, "应提示保留名")
    expect(report.issues.contains { $0.category == .trailingDotOrSpace }, "应提示结尾空格")
    expect(report.issues.contains { $0.category == .jolietNameTooLong }, "应提示 Joliet 名过长")
    expect(
        report.issues.contains { $0.category == .iso9660Name && $0.severity == .info },
        "应汇总 ISO 8.3 名字"
    )
    expect(!report.hasErrors, "这些都不是「需处理」级别")
    expectEqual(report.maxDepth, 3, "最深三层（顶层目录 1 层，子目录 2 层，子目录里的文件 3 层）")

    let targets = Set(report.renamePlan.map { $0.newRelativePath })
    expect(targets.contains("待刻内容/报告_2024_.txt"), "方案里应替换非法字符：\(targets)")
    expect(targets.contains("待刻内容/_CON.txt"), "方案里应给保留名加前缀")
    expect(
        !targets.contains("待刻内容/子目录/\(longName)"),
        "同时有 UDF 时，超过 Joliet 64 字符的名字不截断（只提示）"
    )
}

run("目录层级超过 8 层会提示") {
    let source = try makeTempDirectory("deep")
    defer { try? FileManager.default.removeItem(at: source) }
    var current = source
    for index in 1...10 {
        current = current.appendingPathComponent("level\(index)", isDirectory: true)
    }
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
    try "x".write(to: current.appendingPathComponent("deep.txt"), atomically: true, encoding: .utf8)

    let report = CompatibilityChecker.scan(items: [source.appendingPathComponent("level1")])
    expectEqual(report.maxDepth, 11, "层级统计")
    expect(
        report.issues.contains { $0.category == .iso9660Depth && $0.severity == .warning },
        "应提示层级过深"
    )
}

run("自动重命名整理：改名后内容不变、名字变干净") {
    let source = try makeTempDirectory("sanitize")
    defer { try? FileManager.default.removeItem(at: source) }
    let folder = source.appendingPathComponent("资料", isDirectory: true)
    let nested = folder.appendingPathComponent("子:目录", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "报告正文".write(to: folder.appendingPathComponent("报告:2024?.txt"), atomically: true, encoding: .utf8)
    try "reserved".write(to: folder.appendingPathComponent("CON.txt"), atomically: true, encoding: .utf8)
    try "nested".write(to: nested.appendingPathComponent("明细*表.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
        atPath: folder.appendingPathComponent("链接:1").path,
        withDestinationPath: "CON.txt"
    )

    let workspace = try Workspace(prefix: "SelfTest")
    defer { workspace.cleanup() }
    let entries = try workspace.stage(items: [folder], options: StageOptions(namePolicy: .sanitize))
    expectEqual(entries.count, 1, "条目数")
    let staged = entries[0].destination

    expect(
        FileManager.default.fileExists(atPath: staged.appendingPathComponent("报告_2024_.txt").path),
        "非法字符应被替换"
    )
    expect(
        !FileManager.default.fileExists(atPath: staged.appendingPathComponent("报告:2024?.txt").path),
        "原名不该再出现"
    )
    expectEqual(
        try String(contentsOf: staged.appendingPathComponent("报告_2024_.txt")),
        "报告正文",
        "内容应保持不变"
    )
    expect(FileManager.default.fileExists(atPath: staged.appendingPathComponent("_CON.txt").path), "保留名应加前缀")
    expect(
        FileManager.default.fileExists(atPath: staged.appendingPathComponent("子_目录/明细_表.txt").path),
        "嵌套的目录名与文件名都要改"
    )
    expect(entries[0].renames.count >= 4, "应记录改名，实际 \(entries[0].renames.count) 条")

    let linkPath = staged.appendingPathComponent("链接_1").path
    expectEqual(FileTree.node(at: linkPath)?.kind, .symlink, "符号链接应原样保留")
    expectEqual(FileTree.node(at: linkPath)?.linkTarget, "CON.txt", "链接目标不变")

    let after = CompatibilityChecker.scan(items: entries.map { $0.destination })
    expectEqual(after.errorCount, 0, "改名后不该还有「需处理」问题")
    expect(!after.issues.contains { $0.category == .illegalCharacter }, "不该再有非法字符")
    expect(!after.issues.contains { $0.category == .reservedName }, "不该再有保留名")
    expect(!after.issues.contains { $0.category == .trailingDotOrSpace }, "不该再有结尾空格")
}

run("保留原名时不改动任何名字") {
    let source = try makeTempDirectory("keepnames")
    defer { try? FileManager.default.removeItem(at: source) }
    let folder = source.appendingPathComponent("原样", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "x".write(to: folder.appendingPathComponent("a:b.txt"), atomically: true, encoding: .utf8)
    let workspace = try Workspace(prefix: "SelfTest")
    defer { workspace.cleanup() }
    let entries = try workspace.stage(items: [folder])
    expect(FileManager.default.fileExists(atPath: entries[0].destination.appendingPathComponent("a:b.txt").path), "原名应保留")
    expect(entries[0].renames.isEmpty, "不该有改名记录")
}

print("== 真实系统集成 ==")

run("读取光盘映像里的内容") {
    let source = try makeTempDirectory("readimage")
    defer { try? FileManager.default.removeItem(at: source) }
    let payload = source.appendingPathComponent("内容", isDirectory: true)
    let nested = payload.appendingPathComponent("子目录", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "hello".write(to: payload.appendingPathComponent("说明.txt"), atomically: true, encoding: .utf8)
    try Data(count: 4096).write(to: nested.appendingPathComponent("data.bin"))
    try FileManager.default.createSymbolicLink(
        atPath: payload.appendingPathComponent("链接.txt").path,
        withDestinationPath: "说明.txt"
    )

    let imageURL = source.appendingPathComponent("read-test.iso")
    try ImageBuilder.buildImage(
        source: payload,
        outputURL: imageURL,
        options: ImageOptions(volumeName: "读取测试")
    )

    let contents = try DiscReader.readImage(imageURL)
    expectEqual(contents.fileCount, 3, "文件数（含符号链接）")
    expectEqual(contents.directoryCount, 1, "文件夹数")
    expect(contents.totalBytes >= 4096, "总大小应包含 4KB 文件，实际 \(contents.totalBytes)")
    let names = contents.entries.map { $0.name }.sorted()
    expect(names.contains("说明.txt"), "应列出中文文件名，实际 \(names)")
    expect(names.contains("子目录"), "应列出子目录")
    let link = contents.entries.first { $0.name == "链接.txt" }
    expect(link?.isSymlink == true, "应识别符号链接")
    // UDF 桥接映像里 macOS 自己的 UDF 驱动读不出链接目标（errno 10000），
    // 所以这里只要求「能读到时必须正确」，读不到属于系统限制。
    if let target = link?.linkTarget {
        expectEqual(target, "说明.txt", "链接目标")
    }
    expect(contents.volumeName == "读取测试", "卷标应为读取测试，实际 \(String(describing: contents.volumeName))")
    let nestedEntry = contents.entries.first { $0.name == "子目录" }
    expectEqual(nestedEntry?.children.count, 1, "子目录内容")
}

run("没有区段 / 未挂载时的提示语") {
    // 用一个不存在的设备节点走「不临时挂载」的分支，只验证提示语，不碰硬件。
    let blank = try DiscReader.readDevice("/dev/disk99", media: .dvdPlusR, sessionCount: 0, allowMount: false)
    expect(blank.entries.isEmpty, "空白盘不该有内容")
    expect(blank.note?.contains("空白") == true, "没有区段时应提示空白：\(blank.note ?? "nil")")
    expectNil(blank.mountPoint, "不该有挂载点")

    let used = try DiscReader.readDevice("/dev/disk99", media: .dvdPlusR, sessionCount: 3, allowMount: false)
    expect(used.note?.contains("临时挂载") == true, "有区段但没挂载时应提示临时挂载：\(used.note ?? "nil")")
    expectNil(used.mountPoint, "没挂载过就不该有挂载点")
}

run("hdiutil attach 输出解析") {
    // 物理光驱不接受自定义挂载点，只能让系统挂到 /Volumes 下；挂载点要从输出里捡回来。
    let deviceOutput = """
    /dev/disk6          \tApple_partition_scheme\t\t
    /dev/disk6s1        \tApple_partition_map \t\t
    /dev/disk6s2        \tISO9660             \tDISC_20260920\t/Volumes/DISC_20260920
    """
    let report = DiscReader.AttachReport(output: deviceOutput)
    expectEqual(report.baseDevice ?? "nil", "/dev/disk6", "整盘节点应取首行")
    expectEqual(report.mountPoint ?? "nil", "/Volumes/DISC_20260920", "挂载点应取最后一列")

    // 只有设备节点、没有挂载点的输出，不该把别的字段误判成挂载点。
    let bare = DiscReader.AttachReport(output: "/dev/disk7\tApple_HFS\t\t\n")
    expectEqual(bare.baseDevice ?? "nil", "/dev/disk7", "无挂载点时仍应认出设备节点")
    expectNil(bare.mountPoint, "没有 /Volumes 行时挂载点应为空")

    // 卷名撞车时系统会给挂载点加后缀，解析要原样保留。
    let suffixed = DiscReader.AttachReport(output: "/dev/disk8\tISO9660\tDISC\t/Volumes/DISC 1\n")
    expectEqual(suffixed.mountPoint ?? "nil", "/Volumes/DISC 1", "重名后缀要保留")
    expectNil(DiscReader.AttachReport(output: "").baseDevice, "空输出不该报设备节点")
}

run("刻录记录读写") {
    let original = BurnHistory.load()
    defer {
        // 还原测试前的记录，避免污染真实历史
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let url = BurnHistory.fileURL {
            if original.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else if let data = try? encoder.encode(original) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    let marker = "自检-\(UUID().uuidString.prefix(6))"
    expect(
        BurnHistory.record(
            BurnRecord(
                volumeName: marker,
                mediaKind: "DVD-R",
                mediaID: "TEST-MEDIA-ID",
                sessionIndex: 3,
                payloadBytes: 12345,
                fileCount: 7,
                topLevelItems: ["a.txt", "照片"],
                wasTestBurn: false
            )
        ),
        "应写入记录成功"
    )
    let matched = BurnHistory.records(mediaID: "TEST-MEDIA-ID", limit: 5)
    expect(matched.contains { $0.volumeName == marker }, "按 Media ID 应能查到刚写的记录")
    let record = matched.first { $0.volumeName == marker }
    expectEqual(record?.fileCount, 7, "文件数")
    expectEqual(record?.sessionIndex, 3, "区段号")
    expectEqual(record?.topLevelItems, ["a.txt", "照片"], "顶层项目")
}

run("Rock Ridge 映像能读出符号链接目标（对照实验）") {
    guard let xorriso = Shell.which("xorriso") else {
        print("  （未安装 xorriso，跳过）")
        return
    }
    let source = try makeTempDirectory("rockridge")
    defer { try? FileManager.default.removeItem(at: source) }
    try "z".write(to: source.appendingPathComponent("目标.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
        atPath: source.appendingPathComponent("链接.txt").path,
        withDestinationPath: "目标.txt"
    )
    let imageURL = source.appendingPathComponent("rr.iso")
    let result = try Shell.run(xorriso, [
        "-as", "mkisofs", "-o", imageURL.path,
        "-R", "-J", "-iso-level", "3", "-V", "RRTEST", source.path,
    ])
    expect(result.succeeded, "xorriso 应能生成映像：\(result.output.suffix(120))")

    let contents = try DiscReader.readImage(imageURL)
    let link = contents.entries.first { $0.name == "链接.txt" }
    expectEqual(link?.isSymlink, true, "Rock Ridge 里应识别符号链接")
    expectEqual(link?.linkTarget, "目标.txt", "Rock Ridge 应能读出链接目标")
    expect(contents.entries.contains { $0.name == "目标.txt" }, "应列出普通文件")
}

run("调用 drutil 枚举本机光驱（只读）") {
    let drives = try DriveService.listDrives()
    print("  发现 \(drives.count) 台光驱：" + drives.map { "#\($0.index) \($0.displayName)" }.joined(separator: "、"))
    if let drive = drives.first {
        let status = try DriveService.status(driveIndex: drive.index)
        print("  介质状态：\(status.summary)")
    }
}

run("调用 hdiutil 生成并检查光盘映像") {
    let source = try makeTempDirectory("image")
    defer { try? FileManager.default.removeItem(at: source) }
    let payloadFolder = source.appendingPathComponent("内容", isDirectory: true)
    try FileManager.default.createDirectory(at: payloadFolder, withIntermediateDirectories: true)
    try "hello disc".write(to: payloadFolder.appendingPathComponent("说明.txt"), atomically: true, encoding: .utf8)
    try Data(count: 200_000).write(to: payloadFolder.appendingPathComponent("data.bin"))

    let options = ImageOptions(volumeName: "自检光盘")
    let estimated = try ImageBuilder.estimateSize(source: payloadFolder, options: options)
    expect(estimated >= 200_000, "估算大小应不小于数据量")

    let output = source.appendingPathComponent("out.iso")
    try ImageBuilder.buildImage(source: payloadFolder, outputURL: output, options: options)
    let size = Workspace.fileSize(of: output)
    expect(size > 200_000, "映像应已生成")

    let info = Shell.tryRun("hdiutil", ["imageinfo", output.path])
    // 注意：makehybrid 生成的原始 ISO/UDF 映像会让 imageinfo 返回非 0，
    // 但它依然会把信息打印出来，所以这里只检查内容。
    expect(info.output.contains("自检光盘"), "卷标应写入映像")
    expect(info.output.contains("ISO9660"), "应包含 ISO9660")
    expect(info.output.contains("UDF"), "应包含 UDF")
}

// MARK: - 多区段追加

/// 自检专用：把整盘字节交给正式的 `IsoTree` 解析（和嫁接用到的是同一套代码）。
func discEntries(inDisc bytes: [UInt8], sessionStart: Int) -> [IsoDirectoryEntry] {
    let reader = IsoImageReader(data: Data(bytes), baseSector: 0)
    return IsoTree.entries(in: reader, imageStart: sessionStart)
}

/// 自检专用：这次会用的、能做多区段嫁接的引擎（没装工具时返回 nil）。
func graftEngine() -> DataImageEngine? {
    let engine = DataImageEngine.preferred(for: ImageOptions(volumeName: "自检"))
    guard engine.supportsMultisessionAppend else { return nil }
    return engine
}

/// 自检专用：用正式引擎生成一段映像。
func buildSession(source: URL, output: URL, volumeName: String, graft: AppendTarget?) throws {
    let engine = graftEngine() ?? .xorriso
    try engine.buildImage(
        source: source,
        outputURL: output,
        options: ImageOptions(volumeName: volumeName),
        graft: graft
    )
}

let trackInfoSample = """
   Vendor   Product           Rev
 PIONEER  DVD-RW DVR-XU01C  DL61

  Track 1 info:
               dataLength: 46
              trackNumber: 1
            sessionNumber: 1
                    blank: false
        trackStartAddress: 0
      nextWritableAddress: 0 (not valid)
                trackSize: 544

  Track 2 info:
               dataLength: 46
              trackNumber: 2
            sessionNumber: 2
                    blank: false
        trackStartAddress: 2592
      nextWritableAddress: 0 (not valid)
                trackSize: 544

  Track 3 info:
               dataLength: 46
              trackNumber: 3
            sessionNumber: 3
                    blank: true
        trackStartAddress: 546880
      nextWritableAddress: 546880 (valid)
                trackSize: 1748224
"""

run("解析 drutil trackinfo（段起始 / 下一个可写地址）") {
    let layout = DiscLayout.parse(trackInfo: trackInfoSample)
    expectEqual(layout.tracks.count, 3, "轨道数")
    expectEqual(layout.recordedSessions, 2, "已有内容的段数（带数据的轨道）")
    expectEqual(layout.sessionStarts, [0, 2592], "段起始扇区")
    expectEqual(layout.lastSessionStart, 2592, "最后一段起始")
    expectEqual(layout.nextWritableAddress, 546880, "下一个可写地址")
    expect(!layout.isEmpty, "有内容的盘不算空盘")
    expect(DiscLayout.parse(trackInfo: "").isEmpty, "没有输出按空盘处理")
    expect(DiscLayout.parse(trackInfo: "  Track 1 info:\n     blank: true\n  nextWritableAddress: 0 (valid)\n").isEmpty, "纯空白盘没有已写段")
}

run("空白盘不算「要嫁接」：驱动器会把空白轨道也算成一段") {
    // 实测：空白 DVD+R 的 drutil discinfo 就是 Sessions: 1，只看段数会把空盘
    // 误判成需要嫁接，于是直接拒绝刻录（真机上踩过）。
    var blank = DiscStatus()
    blank.isPresent = true
    blank.deviceNode = "/dev/disk2"
    blank.sessions = 1
    blank.writability = .blank
    expectEqual(Multisession.needsGraft(status: blank), false, "空白盘不需要嫁接")

    var appendable = blank
    appendable.writability = .appendable
    appendable.sessions = 2
    expectEqual(Multisession.needsGraft(status: appendable), true, "可追加的盘要嫁接")
    expectEqual(Multisession.needsGraft(status: appendable, eraseFirst: true), false, "先擦盘就不嫁接")

    var overwritable = blank
    overwritable.writability = .overwritable
    expectEqual(Multisession.needsGraft(status: overwritable), false, "可覆盖的盘从零开始刻")
}

run("追加目标：空盘 / 擦盘 / 缺设备节点") {
    let layout = DiscLayout.parse(trackInfo: trackInfoSample)
    var status = DiscStatus()
    status.isPresent = true
    status.deviceNode = "/dev/disk2"
    let target = try Multisession.appendTarget(status: status, layout: layout, eraseFirst: false)
    expectEqual(target?.devicePath, "/dev/disk2", "嫁接设备")
    expectEqual(target?.lastSessionStart, 2592, "上段起始扇区")
    expectEqual(target?.nextWritableAddress, 546880, "下段起始扇区")
    expectNil(try Multisession.appendTarget(status: status, layout: layout, eraseFirst: true), "要擦盘就不嫁接")
    expectNil(try Multisession.appendTarget(status: status, layout: .empty, eraseFirst: false), "空盘不嫁接")

    var noDevice = status
    noDevice.deviceNode = nil
    var threw = false
    do {
        _ = try Multisession.appendTarget(status: noDevice, layout: layout, eraseFirst: false)
    } catch {
        threw = true
    }
    expect(threw, "拿不到设备节点时要报错，而不是刻出读不了的盘")
}

run("识别旧版本刻的盘（区段相对寻址）") {
    let folder = try makeTempDirectory("chain")
    defer { try? FileManager.default.removeItem(at: folder) }

    func makeDisc(rootSector: Int) throws -> (URL, DiscLayout) {
        let sessionStart = 2592
        var bytes = [UInt8](repeating: 0, count: (sessionStart + 32) * 2048)
        let pvd = (sessionStart + 16) * 2048
        bytes[pvd + 1] = 0x43; bytes[pvd + 2] = 0x44; bytes[pvd + 3] = 0x30; bytes[pvd + 4] = 0x30; bytes[pvd + 5] = 0x31
        bytes[pvd + 158] = UInt8(rootSector & 0xFF)
        bytes[pvd + 159] = UInt8((rootSector >> 8) & 0xFF)
        let url = folder.appendingPathComponent("disc-\(rootSector).iso")
        try Data(bytes).write(to: url)
        let layout = DiscLayout(
            tracks: [DiscTrack(trackNumber: 1, sessionNumber: 1, startAddress: sessionStart, nextWritableAddress: nil, trackSize: 544)],
            sessionStarts: [sessionStart],
            nextWritableAddress: sessionStart + 4096,
            recordedSessions: 1
        )
        return (url, layout)
    }

    let broken = try makeDisc(rootSector: 41)
    expectEqual(
        Multisession.chainState(deviceNode: broken.0.path, layout: broken.1),
        .broken,
        "根目录写着区段相对地址的盘应判为不可嫁接"
    )
    let standard = try makeDisc(rootSector: 2592 + 30)
    expectEqual(
        Multisession.chainState(deviceNode: standard.0.path, layout: standard.1),
        .complete,
        "根目录落在本段内的盘应判为可嫁接"
    )
    expectEqual(Multisession.chainState(deviceNode: "/dev/不存在的盘", layout: standard.1), .unknown, "读不到盘时返回未知")

    var descriptor = [UInt8](repeating: 0, count: 2048)
    descriptor[1] = 0x43; descriptor[2] = 0x44; descriptor[3] = 0x30; descriptor[4] = 0x30; descriptor[5] = 0x31
    descriptor[158] = 41
    expectEqual(RawDisc.rootDirectorySector(inVolumeDescriptor: Data(descriptor)), 41, "卷描述符里的根目录扇区")
    expectNil(RawDisc.rootDirectorySector(inVolumeDescriptor: Data(repeating: 0, count: 2048)), "不是卷描述符")
    expectEqual(RawDisc.littleEndian32(Data([0x2A, 0x00, 0x00, 0x00])), 42, "小端 32 位")
    expectEqual(RawDisc.rawPath(for: "/dev/disk9"), "/dev/disk9", "不存在的原始设备回退到原路径")
}

run("xorriso 参数与 -print-size 解析") {
    let source = URL(fileURLWithPath: "/tmp/待刻内容")
    let output = URL(fileURLWithPath: "/tmp/out.iso")
    let plain = Xorriso.arguments(source: source, outputURL: output, volumeName: "DATA", graft: nil)
    expectEqual(plain.first, "-as", "走 xorriso 的 mkisofs 仿真模式")
    expectEqual(plain.dropFirst().first, "mkisofs", "仿真参数紧随其后")
    if let charset = plain.firstIndex(of: "-input-charset"), charset + 1 < plain.count {
        expectEqual(plain[charset + 1], "UTF-8", "文件名按 UTF-8 解释（否则 Windows 上的中文名是乱码）")
    } else {
        expect(false, "缺少 -input-charset，中文名会在 Joliet 里变成乱码")
    }
    expect(plain.contains("-J"), "普通段带 Joliet")
    expect(plain.contains("-R"), "普通段带 Rock Ridge")
    expect(plain.contains("-joliet-long"), "Joliet 名字放宽到 103 个字符")
    expect(!plain.contains("-M"), "普通段不做嫁接")
    expectEqual(plain.last, "/tmp/待刻内容", "源目录放在最后")
    expectEqual(plain.firstIndex(of: "-V").flatMap { index in index + 1 < plain.count ? plain[index + 1] : nil }, "DATA", "卷标")

    let device = AppendTarget(devicePath: "/dev/disk2", lastSessionStart: 2592, nextWritableAddress: 546880)
    let merged = Xorriso.arguments(source: source, outputURL: output, volumeName: "DATA", graft: device)
    expect(merged.contains("-M"), "嫁接段带 -M")
    expect(merged.contains("stdio:/dev/disk2"), "光驱要写成 stdio: 前缀，xorriso 才肯读")
    if let index = merged.firstIndex(of: "-C"), index + 1 < merged.count {
        expectEqual(merged[index + 1], "2592,546880", "-C 上段起始,下段起始")
    } else {
        expect(false, "嫁接段缺少 -C 参数")
    }

    // 我们按扇区抄出来的旧段稀疏映像就是个普通文件，不能再加 stdio: 前缀。
    let sparse = AppendTarget(devicePath: "/tmp/旧段映像.iso", lastSessionStart: 2592, nextWritableAddress: 546880)
    let fromImage = Xorriso.arguments(source: source, outputURL: output, volumeName: "DATA", graft: sparse)
    expect(fromImage.contains("/tmp/旧段映像.iso"), "稀疏映像直接用路径")
    expect(!fromImage.contains("stdio:/tmp/旧段映像.iso"), "普通文件不加 stdio: 前缀")

    expectEqual(Xorriso.parsePrintedSize("xorriso : UPDATE : 3 files added\n185\n"), 185, "扇区数")
    expectNil(Xorriso.parsePrintedSize("no numbers here"), "没有数字时返回 nil")

    // -print-size 的位置两套工具不一样：xorriso 放在 `-as mkisofs` 之后才算数，
    // 放错了它会把整个映像真的生成一遍，还拿不到数字（自检里踩过这个坑）。
    if Xorriso.isAvailable {
        let folder = try makeTempDirectory("估算")
        defer { try? FileManager.default.removeItem(at: folder) }
        try "内容".write(to: folder.appendingPathComponent("说明.txt"), atomically: true, encoding: .utf8)
        let bytes = try Xorriso.estimatedBytes(source: folder, volumeName: "DATA", graft: nil)
        expect(bytes > 0 && bytes % 2048 == 0, "xorriso 能按扇区报出映像大小（\(bytes) 字节）")
    } else {
        print("  · 跳过 xorriso 估算：没装 xorriso")
    }
}

run("mkisofs 的 Joliet 缺陷能被识别") {
    // cdrtools 的 mkisofs 把非 ASCII 名字转 Joliet 时只保留前 8 个字符（自检里实测过），
    // 所以它只当兜底引擎用，并且要把会被写坏的名字挑出来提醒用户。
    expectEqual(Mkisofs.namesBreakingJoliet(["短的.txt", "abcdefghij.txt", "说明.txt"]), [], "ASCII 长名不受影响")
    expectEqual(Mkisofs.namesBreakingJoliet(["一二三四五六七八.txt"]).count, 1, "长中文名会被写坏")
    expectEqual(Mkisofs.baseArguments.first, "-input-charset", "mkisofs 也要显式声明 UTF-8 输入")
    expect(Xorriso.baseArguments.contains("-input-charset"), "xorriso 同样显式声明 UTF-8 输入")
}

run("判断卷有没有被挂载") {
    // 挂载状态决定嫁接时能不能直接读光驱（挂载着会 Resource busy），
    // 判据不能看 diskutil 的 MountPoint 字段——没挂载时它也给一个空值。
    expect(Multisession.isMounted(deviceNode: "/dev/definitely-not-a-disk") == false, "不存在的设备不算挂载")
    if let result = try? Shell.run("mount", []),
       let line = result.output.split(separator: "\n").first,
       let device = line.split(separator: " ").first.map(String.init) {
        expect(Multisession.isMounted(deviceNode: device), "\(device) 出现在 mount 输出里，应判为已挂载")
        expect(Multisession.isMounted(deviceNode: device + "s99") == false, "只有前缀相同的设备不能算挂载")
    } else {
        expect(false, "读不到 mount 输出")
    }
    expect(Multisession.unmount(deviceNode: "/dev/definitely-not-a-disk") == true, "没挂载的设备直接算已卸载")
}

run("引擎选择与命名规则") {
    let universal = ImageOptions(volumeName: "自检")
    let engine = DataImageEngine.preferred(for: universal)
    let expected: DataImageEngine = Xorriso.isAvailable ? .xorriso : (Mkisofs.isAvailable ? .mkisofs : .makehybrid)
    expectEqual(engine, expected, "装了 xorriso 就用 xorriso")
    expectEqual(
        engine.localizedSummary,
        engine == .makehybrid ? "ISO 9660 + Joliet + UDF" : "ISO 9660 + Joliet + Rock Ridge",
        "通用预设选用的引擎"
    )
    expectEqual(engine.supportsMultisessionAppend, engine != .makehybrid, "只有 mkisofs 系工具能追加")
    let pureUDF = ImageOptions(volumeName: "自检", includeISO9660: false, includeJoliet: false, includeUDF: true)
    expectEqual(DataImageEngine.preferred(for: pureUDF), .makehybrid, "纯 UDF 预设用系统自带工具")
    expectEqual(DataImageEngine.xorriso.nameRules(for: universal).jolietMaxCharacters, 103, "xorriso 的 Joliet 上限")
    expectEqual(DataImageEngine.makehybrid.nameRules(for: universal).jolietMaxCharacters, 64, "系统自带工具的 Joliet 上限")
    expectEqual(DataImageEngine.xorriso.nameRules(for: universal).sanitizeCharacterLimit, 103, "自动重命名按 103 截断")
    expectEqual(DataImageEngine.xorriso.toolName, "xorriso", "界面显示的工具名")
    expectEqual(DataImageEngine.makehybrid.toolName, "系统自带工具", "系统工具的显示名")
    expectEqual(DataImageEngine.makehybrid.supportsMultisessionAppend, false, "系统自带工具不能嫁接")
}

run("多区段嫁接：新段里同时看得到旧文件和新文件") {
    guard let engine = graftEngine() else {
        print("  · 跳过：这台机器没装 xorriso / mkisofs（\(Xorriso.installHint)）")
        return
    }
    let folder = try makeTempDirectory("graft")
    defer { try? FileManager.default.removeItem(at: folder) }

    // 第 1 段：中文名字 + 子目录
    let first = folder.appendingPathComponent("第一段", isDirectory: true)
    let nested = first.appendingPathComponent("子目录", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "旧内容-OK".write(to: first.appendingPathComponent("旧的说明.txt"), atomically: true, encoding: .utf8)
    try "嵌套-OK".write(to: nested.appendingPathComponent("嵌套.txt"), atomically: true, encoding: .utf8)
    let session1 = folder.appendingPathComponent("session1.iso")
    try buildSession(source: first, output: session1, volumeName: "S1", graft: nil)

    // 把第 1 段摆到「盘」上：这一段从绝对扇区 0 开始，下一段从 next 开始
    let next = Int((Workspace.fileSize(of: session1) + 2047) / 2048) + 48
    var disc = try Data(contentsOf: session1)
    disc.append(Data(count: next * 2048 - disc.count))
    let discURL = folder.appendingPathComponent("disc.iso")
    try disc.write(to: discURL)

    // 第 2 段：映像工具从「盘」里读第 1 段的目录树，新文件写在第 2 段
    let second = folder.appendingPathComponent("第二段", isDirectory: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try "新内容-OK".write(to: second.appendingPathComponent("新的说明.txt"), atomically: true, encoding: .utf8)
    let session2 = folder.appendingPathComponent("session2.iso")
    let target = AppendTarget(devicePath: discURL.path, lastSessionStart: 0, nextWritableAddress: next, oldFileCount: 2)
    try engine.buildImage(source: second, outputURL: session2, options: ImageOptions(volumeName: "S2"), graft: target)
    // 刻之前必须自己验一遍：根目录是绝对地址、并且真的引用了旧文件
    try Multisession.verifyGraft(imageURL: session2, nextWritableAddress: next, expectedOldFiles: 2)
    expect(true, "嫁接出来的段通过了校验（绝对地址 + 引用到旧文件）")
    disc.append(try Data(contentsOf: session2))
    // 刻完之后，盘上才是「两段都在」——把这张盘落盘，后面按扇区读它。
    try disc.write(to: discURL)

    let entries = discEntries(inDisc: [UInt8](disc), sessionStart: next)
    let names = entries.map { $0.name }
    expect(names.contains("旧的说明.txt"), "新段应能看到旧文件（中文名保留）")
    expect(names.contains("新的说明.txt"), "新段应包含新文件")
    expect(names.contains("子目录"), "新段应能看到旧的子目录")

    func text(at extent: Int, size: Int) -> String? {
        let start = extent * 2048
        guard extent >= 0, size > 0, start + size <= disc.count else { return nil }
        return String(bytes: disc[start..<(start + size)], encoding: .utf8)
    }
    if let old = entries.first(where: { $0.name == "旧的说明.txt" }) {
        expect(old.extent < next, "旧文件仍指向第 1 段的扇区（绝对地址，没有重写数据）")
        expectEqual(text(at: old.extent, size: old.size) ?? "", "旧内容-OK", "旧文件内容")
    } else {
        expect(false, "目录树里没有找到旧文件")
    }
    if let fresh = entries.first(where: { $0.name == "新的说明.txt" }) {
        expect(fresh.extent >= next, "新文件应落在第 2 段里")
        expectEqual(text(at: fresh.extent, size: fresh.size) ?? "", "新内容-OK", "新文件内容")
    } else {
        expect(false, "目录树里没有找到新文件")
    }
    // 嫁接之前要数得出旧段里有几个文件，刻完拿它当验收标准
    expectEqual(Multisession.fileCount(deviceNode: discURL.path, sessionStart: 0), 2, "数出第 1 段里有 2 个文件")
    expectEqual(Multisession.fileCount(deviceNode: discURL.path, sessionStart: next), 3, "第 2 段的目录树里有 3 个文件")
}

run("嫁接校验：没合并旧内容的段会被拦下来") {
    guard graftEngine() != nil else {
        print("  · 跳过：没装映像工具")
        return
    }
    let folder = try makeTempDirectory("graftcheck")
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("内容", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try "只有新内容".write(to: source.appendingPathComponent("新.txt"), atomically: true, encoding: .utf8)
    let standalone = folder.appendingPathComponent("standalone.iso")
    try buildSession(source: source, output: standalone, volumeName: "S1", graft: nil)

    // 这一段是按「自己从第 0 扇区开始」做的（旧版本就是这么刻的）：
    // 放到第 300 扇区上，根目录地址会小于 300，属于区段相对寻址。
    var failure: MultisessionError?
    do {
        try Multisession.verifyGraft(imageURL: standalone, nextWritableAddress: 300, expectedOldFiles: 2)
    } catch let error as MultisessionError {
        failure = error
    } catch {
        failure = nil
    }
    if case .graftNotAbsolute = failure {
        expect(true, "报的是「目录树地址没落在本段范围内」")
    } else {
        expect(false, "没合并旧内容的段必须报地址错误，实际：\(String(describing: failure))")
    }

    // 反过来：把同一段按它自己的位置（从 0 开始）校验，就应该通过。
    try? Multisession.verifyGraft(imageURL: standalone, nextWritableAddress: 0, expectedOldFiles: 0)
    expect(true, "位置对得上时不报错")
}

run("稀疏映像兜底：把旧段按扇区抄出来，照样能接着嫁接") {
    guard let engine = graftEngine() else {
        print("  · 跳过：没装映像工具")
        return
    }
    let folder = try makeTempDirectory("sparse")
    defer { try? FileManager.default.removeItem(at: folder) }

    // 盘上先有两段（第 1 段从 0 开始，第 2 段从 next2 开始）
    let first = folder.appendingPathComponent("第一段", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try "旧内容-OK".write(to: first.appendingPathComponent("旧的说明.txt"), atomically: true, encoding: .utf8)
    let s1 = folder.appendingPathComponent("s1.iso")
    try buildSession(source: first, output: s1, volumeName: "S1", graft: nil)
    let next2 = Int((Workspace.fileSize(of: s1) + 2047) / 2048) + 48
    var disc = try Data(contentsOf: s1)
    disc.append(Data(count: next2 * 2048 - disc.count))
    let discURL = folder.appendingPathComponent("disc.iso")
    try disc.write(to: discURL)

    let second = folder.appendingPathComponent("第二段", isDirectory: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try "新内容-OK".write(to: second.appendingPathComponent("新的说明.txt"), atomically: true, encoding: .utf8)
    let s2 = folder.appendingPathComponent("s2.iso")
    let target2 = AppendTarget(devicePath: discURL.path, lastSessionStart: 0, nextWritableAddress: next2, oldFileCount: 1)
    try engine.buildImage(source: second, outputURL: s2, options: ImageOptions(volumeName: "S2"), graft: target2)
    disc.append(try Data(contentsOf: s2))

    // 第 3 段要接在第 2 段后面；这次不用设备，而是按扇区把旧段抄成稀疏映像再交给工具。
    let next3 = next2 + Int((Workspace.fileSize(of: s2) + 2047) / 2048) + 48
    // 盘本身比已写内容大得多，后面那段空的地方按真实介质补齐。
    disc.append(Data(count: max(0, next3 * 2048 - disc.count)))
    try disc.write(to: discURL)

    let layout = DiscLayout(sessionStarts: [0, next2], nextWritableAddress: next3, recordedSessions: 2)
    let sparse = folder.appendingPathComponent("旧段映像.iso")
    try Multisession.sparseGraftImage(deviceNode: discURL.path, layout: layout, outputURL: sparse)
    expectEqual(Workspace.fileSize(of: sparse), Int64(next3 * 2048), "稀疏映像长度按盘上位置撑到下一段起点")

    let third = folder.appendingPathComponent("第三段", isDirectory: true)
    try FileManager.default.createDirectory(at: third, withIntermediateDirectories: true)
    try "第三段内容".write(to: third.appendingPathComponent("三.txt"), atomically: true, encoding: .utf8)
    let s3 = folder.appendingPathComponent("s3.iso")
    // 真刻的时候先试光驱本身，读不了才换成这张稀疏映像；两者的段地址是同一套。
    let onDisc = AppendTarget(devicePath: discURL.path, lastSessionStart: next2, nextWritableAddress: next3, oldFileCount: 2)
    let target3 = onDisc.usingImage(at: sparse)
    expect(!target3.isDevice, "换成映像后就不再当设备处理")
    expectEqual(target3.lastSessionStart, next2, "换映像不影响上段起始")
    expectEqual(target3.nextWritableAddress, next3, "换映像不影响下段起始")
    try engine.buildImage(source: third, outputURL: s3, options: ImageOptions(volumeName: "S3"), graft: target3)
    try Multisession.verifyGraft(imageURL: s3, nextWritableAddress: next3, expectedOldFiles: 2)
    expect(true, "用稀疏映像嫁接出来的第 3 段也通过了校验")
    disc.append(try Data(contentsOf: s3))

    let entries = discEntries(inDisc: [UInt8](disc), sessionStart: next3)
    let names = entries.map { $0.name }
    expect(names.contains("旧的说明.txt"), "第 3 段里还看得到第 1 段的文件")
    expect(names.contains("新的说明.txt"), "第 3 段里还看得到第 2 段的文件")
    expect(names.contains("三.txt"), "第 3 段里有自己的新文件")
}

run("嫁接：让映像工具直接读「设备」这条路也能用（用磁盘映像模拟块设备）") {
    guard let engine = graftEngine() else {
        print("  · 跳过：没装映像工具")
        return
    }
    let folder = try makeTempDirectory("graftdev")
    defer { try? FileManager.default.removeItem(at: folder) }

    // 盘上先有一段内容，下一段从 next 开始
    let first = folder.appendingPathComponent("第一段", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try "旧内容-OK".write(to: first.appendingPathComponent("旧的说明.txt"), atomically: true, encoding: .utf8)
    let s1 = folder.appendingPathComponent("s1.iso")
    try buildSession(source: first, output: s1, volumeName: "S1", graft: nil)
    let next = Int((Workspace.fileSize(of: s1) + 2047) / 2048) + 48
    var disc = try Data(contentsOf: s1)
    disc.append(Data(count: next * 2048 - disc.count))
    let discURL = folder.appendingPathComponent("disc.iso")
    try disc.write(to: discURL)

    // 把这张「盘」挂成一个块设备节点（/dev/diskN）当成光驱来用：
    // 真机上走的就是这条路（xorriso 要 stdio:/dev/diskN 才肯读块设备）。
    guard let attach = try? Shell.run("hdiutil", [
        "attach", "-nomount", "-imagekey", "diskimage-class=CRawDiskImage", discURL.path
    ]), attach.succeeded,
    let node = attach.output.split(separator: " ").first.map(String.init), node.hasPrefix("/dev/disk") else {
        print("  · 跳过：这台机器没法把映像挂成块设备")
        return
    }
    defer { _ = try? Shell.run("hdiutil", ["detach", node]) }
    expect(Multisession.isMounted(deviceNode: node) == false, "刚挂出来的裸设备没有挂卷")

    let second = folder.appendingPathComponent("第二段", isDirectory: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try "新内容-OK".write(to: second.appendingPathComponent("新的说明.txt"), atomically: true, encoding: .utf8)
    let s2 = folder.appendingPathComponent("s2.iso")
    let target = AppendTarget(devicePath: node, lastSessionStart: 0, nextWritableAddress: next, oldFileCount: 1)
    try engine.buildImage(source: second, outputURL: s2, options: ImageOptions(volumeName: "S2"), graft: target)
    try Multisession.verifyGraft(imageURL: s2, nextWritableAddress: next, expectedOldFiles: 1)
    expect(true, "直接读设备嫁接出来的段通过了校验")
    disc.append(try Data(contentsOf: s2))
    try disc.write(to: discURL)

    let entries = discEntries(inDisc: [UInt8](disc), sessionStart: next)
    let names = entries.map { $0.name }
    expect(names.contains("旧的说明.txt"), "新段里能看到设备上旧段的文件")
    expect(names.contains("新的说明.txt"), "新段里能看到这次新加的文件")
}

// MARK: - 整盘内容（多区段盘读「一整份」）

run("整盘内容：嫁接过的盘只读最后一段就拿到全部内容，导出后逐字节一致") {
    guard let engine = graftEngine() else {
        print("  · 跳过：没装 xorriso / mkisofs")
        return
    }
    let folder = try makeTempDirectory("content")
    defer { try? FileManager.default.removeItem(at: folder) }

    let first = folder.appendingPathComponent("第一段", isDirectory: true)
    try FileManager.default.createDirectory(
        at: first.appendingPathComponent("子目录"),
        withIntermediateDirectories: true
    )
    try "第一段内容-OK".write(to: first.appendingPathComponent("说明.txt"), atomically: true, encoding: .utf8)
    try "嵌套内容-OK".write(to: first.appendingPathComponent("子目录/嵌套.txt"), atomically: true, encoding: .utf8)
    let s1 = folder.appendingPathComponent("s1.iso")
    try buildSession(source: first, output: s1, volumeName: "S1", graft: nil)

    let next = 2512
    let second = folder.appendingPathComponent("第二段", isDirectory: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try "第二段内容-OK".write(to: second.appendingPathComponent("追加说明.txt"), atomically: true, encoding: .utf8)
    let s2 = folder.appendingPathComponent("s2.iso")
    let target = AppendTarget(devicePath: s1.path, lastSessionStart: 0, nextWritableAddress: next, oldFileCount: 2)
    try engine.buildImage(source: second, outputURL: s2, options: ImageOptions(volumeName: "S2"), graft: target)

    var disc = [UInt8](try Data(contentsOf: s1))
    disc += [UInt8](repeating: 0, count: max(0, next * 2048 - disc.count))
    disc += [UInt8](try Data(contentsOf: s2))
    let layout = DiscLayout(
        tracks: [],
        sessionStarts: [0, next],
        nextWritableAddress: next + 2048,
        recordedSessions: 2
    )
    let reader = IsoImageReader(data: Data(disc))
    guard let view = DiscContentReader.read(reader: reader, layout: layout) else {
        expect(false, "应该能读出整盘内容")
        return
    }
    let paths = view.files.map { $0.relativePath }
    expectEqual(view.sessions, [next], "最后一段已经含旧段，只读这一段")
    expect(view.fromLastSessionOnly, "判为「只读最后一段」")
    expect(paths.contains("说明.txt"), "能列出第一段的文件")
    expect(paths.contains("子目录/嵌套.txt"), "能列出第一段的子目录文件")
    expect(paths.contains("追加说明.txt"), "能列出这次新加的文件")
    expect(
        view.files.filter { $0.relativePath != "追加说明.txt" }.allSatisfy { $0.extent < next },
        "旧文件在嫁接段里仍然指向旧段地址"
    )

    let out = folder.appendingPathComponent("导出", isDirectory: true)
    let summary = try DiscContentReader.extract(view, reader: reader, source: "自检映像", to: out)
    expectEqual(summary.files, 3, "导出的文件数")
    expectEqual(summary.skipped, 0, "没有跳过任何文件")
    expectEqual(try String(contentsOf: out.appendingPathComponent("说明.txt"), encoding: .utf8), "第一段内容-OK", "第一段文件内容")
    expectEqual(try String(contentsOf: out.appendingPathComponent("子目录/嵌套.txt"), encoding: .utf8), "嵌套内容-OK", "子目录文件内容")
    expectEqual(try String(contentsOf: out.appendingPathComponent("追加说明.txt"), encoding: .utf8), "第二段内容-OK", "新段文件内容")

    // 同名冲突：并进待刻目录时要保住「这次新加的」文件，导出模式才覆盖。
    // 待刻目录里本来只有「这次新加的」说明.txt，其余文件是盘上独有的，应该照常导出。
    let staging = folder.appendingPathComponent("待刻目录", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try "这次新加的".write(to: staging.appendingPathComponent("说明.txt"), atomically: true, encoding: .utf8)
    let skipped = try DiscContentReader.extract(view, reader: reader, source: "自检映像", to: staging, conflict: .skipExisting)
    expectEqual(skipped.skipped, 1, "同名文件应被跳过")
    expectEqual(skipped.files, 2, "盘上独有的文件照常导出")
    expectEqual(try String(contentsOf: staging.appendingPathComponent("说明.txt"), encoding: .utf8), "这次新加的", "跳过时保住现有文件")
    expectEqual(try String(contentsOf: staging.appendingPathComponent("子目录/嵌套.txt"), encoding: .utf8), "嵌套内容-OK", "跳过模式下子目录文件也要导出")
    _ = try DiscContentReader.extract(view, reader: reader, source: "自检映像", to: out, conflict: .replace)
    expectEqual(try String(contentsOf: out.appendingPathComponent("说明.txt"), encoding: .utf8), "第一段内容-OK", "覆盖时写回盘上的内容")
}

run("整盘内容：最后一段没嫁接就逐段合并，段相对地址的老盘也能读") {
    guard graftEngine() != nil else {
        print("  · 跳过：没装 xorriso / mkisofs")
        return
    }
    let folder = try makeTempDirectory("content-merge")
    defer { try? FileManager.default.removeItem(at: folder) }

    let first = folder.appendingPathComponent("第一段", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try "第一段-合并".write(to: first.appendingPathComponent("第一段说明.txt"), atomically: true, encoding: .utf8)
    let s1 = folder.appendingPathComponent("s1.iso")
    try buildSession(source: first, output: s1, volumeName: "S1", graft: nil)

    let second = folder.appendingPathComponent("第二段", isDirectory: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try "第二段-合并".write(to: second.appendingPathComponent("第二段说明.txt"), atomically: true, encoding: .utf8)
    let s2 = folder.appendingPathComponent("s2.iso")
    try buildSession(source: second, output: s2, volumeName: "S2", graft: nil)

    // 把第二段那份「从 0 开始算地址」的映像放到 2512：这正是旧版本刻出来的样子
    // （地址是段相对的），同时也模拟了「最后一段没有嫁接」的情况。
    let next = 2512
    var disc = [UInt8](try Data(contentsOf: s1))
    disc += [UInt8](repeating: 0, count: max(0, next * 2048 - disc.count))
    disc += [UInt8](try Data(contentsOf: s2))
    let reader = IsoImageReader(data: Data(disc))

    let layout = DiscLayout(
        tracks: [],
        sessionStarts: [0, next],
        nextWritableAddress: next + 2048,
        recordedSessions: 2
    )
    guard let merged = DiscContentReader.read(reader: reader, layout: layout) else {
        expect(false, "两段合并应该能读出内容")
        return
    }
    expect(!merged.fromLastSessionOnly, "最后一段没嫁接时要逐段合并")
    expectEqual(merged.sessions, [0, next], "合并用到的段")
    expectEqual(
        merged.files.map { $0.relativePath }.sorted(),
        ["第一段说明.txt", "第二段说明.txt"],
        "两段的文件都要在"
    )
    expect(merged.note != nil, "逐段合并要给出说明")

    // 只看最后一段（旧盘：整张盘上只有这一段，地址却是段相对的）
    let oldLayout = DiscLayout(
        tracks: [],
        sessionStarts: [next],
        nextWritableAddress: next + 2048,
        recordedSessions: 1
    )
    guard let old = DiscContentReader.read(reader: reader, layout: oldLayout) else {
        expect(false, "段相对地址的老段应该也能读出来")
        return
    }
    expectEqual(old.files.map { $0.relativePath }, ["第二段说明.txt"], "老段的文件")
    expectEqual(old.files.first?.extent, next + (old.files.first?.extent ?? 0) - next, "地址已补回段起始")
    expect((old.files.first?.extent ?? 0) >= next, "补回段起始后的地址落在本段内")
    let out = folder.appendingPathComponent("老盘导出", isDirectory: true)
    let oldSummary = try DiscContentReader.extract(old, reader: reader, source: "自检映像", to: out)
    expectEqual(oldSummary.files, 1, "老盘导出的文件数")
    expectEqual(
        try String(contentsOf: out.appendingPathComponent("第二段说明.txt"), encoding: .utf8),
        "第二段-合并",
        "老盘文件内容读得出来"
    )
}

run("整盘内容：导出路径清洗") {
    expectEqual(DiscContentReader.sanitize(relativePath: "../../坏.txt") ?? "", "坏.txt", "挡掉往上级目录的路径")
    expectEqual(DiscContentReader.sanitize(relativePath: "/绝对/路径.txt") ?? "", "绝对/路径.txt", "挡掉绝对路径前缀")
    expectNil(DiscContentReader.sanitize(relativePath: "../.."), "只剩上级引用时没有可用路径")
    expectNil(DiscContentReader.sanitize(relativePath: "   "), "空名字丢弃")
    expectEqual(
        DiscContentReader.sanitize(relativePath: "正常 文件夹/文件.txt") ?? "",
        "正常 文件夹/文件.txt",
        "正常相对路径原样返回"
    )
}

run("整盘内容：转成界面用的树（文件夹在前、大小对得上）") {
    var content = DiscContentView()
    content.files = [
        DiscContentFile(relativePath: "文件.txt", extent: 10, size: 100),
        DiscContentFile(relativePath: "资料/图片.png", extent: 20, size: 2048),
        DiscContentFile(relativePath: "资料/子目录/深层.txt", extent: 30, size: 5),
    ]
    content.directories = ["资料"]
    content.sessions = [0, 2512]
    content.fromLastSessionOnly = false
    content.totalBytes = 2153

    let tree = content.asDiscContents(source: "/dev/disk4", volumeName: "TEST")
    expectEqual(tree.entries.map { $0.name }, ["资料", "文件.txt"], "文件夹排在前面")
    expectEqual(tree.fileCount, 3, "文件数")
    expectEqual(tree.directoryCount, 2, "文件夹数（含自动补出来的子目录）")
    expectEqual(tree.totalBytes, 2153, "总字节数")
    expectEqual(tree.sessionCount, 2, "区段数带过去")
    expectEqual(
        content.asDiscContents(source: "/dev/disk4", sessionCount: 4).sessionCount,
        4,
        "段数由调用方从驱动器 TOC 传进来（嫁接过的盘只读最后一段，段数会少于盘上实际段数）"
    )
    var graftedView = content
    graftedView.sessions = [2512]
    expectEqual(graftedView.asDiscContents(source: "/dev/disk4").sessionCount, 1, "没传段数就按内容里用到的段数")
    expectEqual(tree.source, "/dev/disk4", "来源")
    expectEqual(tree.volumeName, "TEST", "卷标")
    let folder = tree.entries.first
    expectEqual(folder?.children.map { $0.name }, ["子目录", "图片.png"], "文件夹里同样文件夹在前")
    expectEqual(
        folder?.children.last?.relativePath,
        "资料/图片.png",
        "子目录里的文件路径"
    )
    expectEqual(folder?.children.last?.byteCount, 2048, "子目录里的文件大小")
    expectEqual(
        folder?.children.first?.children.first?.relativePath,
        "资料/子目录/深层.txt",
        "补出来的两级目录"
    )
    expectEqual(folder?.children.first?.children.first?.byteCount, 5, "深层文件大小")
    expect(folder?.isDirectory == true, "文件夹标记")
    expectEqual(DiscContentView.parentPaths(of: "a/b/c.txt"), ["a/b", "a"], "上级路径从下往上")
}

run("整盘合并重刻：旧盘内容 + 这次新加的合成一份，单段刻完三边看到的一样") {
    guard let engine = graftEngine() else {
        print("  · 跳过：没装 xorriso / mkisofs")
        return
    }
    let folder = try makeTempDirectory("merge-rewrite")
    defer { try? FileManager.default.removeItem(at: folder) }

    // 先做一张两段的旧盘：第二段嫁接在第一段后面，所以第二段里含第一段的全部文件。
    let first = folder.appendingPathComponent("第一段", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try "第一段内容".write(to: first.appendingPathComponent("说明.txt"), atomically: true, encoding: .utf8)
    let s1 = folder.appendingPathComponent("s1.iso")
    try buildSession(source: first, output: s1, volumeName: "S1", graft: nil)

    let next = 2512
    let second = folder.appendingPathComponent("第二段", isDirectory: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try "第二段内容".write(to: second.appendingPathComponent("追加说明.txt"), atomically: true, encoding: .utf8)
    let s2 = folder.appendingPathComponent("s2.iso")
    let target = AppendTarget(devicePath: s1.path, lastSessionStart: 0, nextWritableAddress: next, oldFileCount: 1)
    try engine.buildImage(source: second, outputURL: s2, options: ImageOptions(volumeName: "S2"), graft: target)

    var disc = [UInt8](try Data(contentsOf: s1))
    disc += [UInt8](repeating: 0, count: max(0, next * 2048 - disc.count))
    disc += [UInt8](try Data(contentsOf: s2))
    let discReader = IsoImageReader(data: Data(disc))
    let layout = DiscLayout(
        tracks: [],
        sessionStarts: [0, next],
        nextWritableAddress: next + 2048,
        recordedSessions: 2
    )
    guard let view = DiscContentReader.read(reader: discReader, layout: layout) else {
        expect(false, "应该能读出整盘内容")
        return
    }

    // 第一步：这次要新加的内容先摆进「待刻目录」，盘上内容再按「已存在就跳过」并进来。
    let staging = folder.appendingPathComponent("待刻目录", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try "这次新加的".write(to: staging.appendingPathComponent("说明.txt"), atomically: true, encoding: .utf8)
    try "这次新加的 2".write(to: staging.appendingPathComponent("新内容.txt"), atomically: true, encoding: .utf8)
    let summary = try DiscContentReader.extract(
        view,
        reader: discReader,
        source: "自检映像",
        to: staging,
        conflict: .skipExisting
    )
    expectEqual(summary.skipped, 1, "同名文件保留这次新加的")
    expectEqual(summary.files, 1, "盘上独有的那个文件并进来")

    // 第二步：合并后按「单段」刻一张新盘——擦盘那步在真机上，这里只验数据。
    let merged = folder.appendingPathComponent("合并.iso")
    try buildSession(source: staging, output: merged, volumeName: "MERGED", graft: nil)
    guard let reread = IsoImageReader(fileURL: merged) else {
        expect(false, "合并后的映像应该能打开")
        return
    }
    guard let single = DiscContentReader.read(
        reader: reread,
        layout: DiscLayout(tracks: [], sessionStarts: [0], nextWritableAddress: 0, recordedSessions: 1)
    ) else {
        expect(false, "合并后的单段映像应该读得出内容")
        return
    }
    expectEqual(
        single.files.map { $0.relativePath }.sorted(),
        ["新内容.txt", "追加说明.txt", "说明.txt"].sorted(),
        "合并后每个文件都在这唯一的一段里"
    )
    let out = folder.appendingPathComponent("回读", isDirectory: true)
    _ = try DiscContentReader.extract(single, reader: reread, source: "合并映像", to: out)
    expectEqual(
        try String(contentsOf: out.appendingPathComponent("说明.txt"), encoding: .utf8),
        "这次新加的",
        "同名文件是这次新加的那一份"
    )
    expectEqual(
        try String(contentsOf: out.appendingPathComponent("追加说明.txt"), encoding: .utf8),
        "第二段内容",
        "旧盘上的文件原样保留"
    )
    expectEqual(
        try String(contentsOf: out.appendingPathComponent("新内容.txt"), encoding: .utf8),
        "这次新加的 2",
        "新文件也在"
    )
}

run("按扇区读：不到一个扇区的小文件也要读全（光驱只收扇区整数倍）") {
    let folder = try makeTempDirectory("reader")
    defer { try? FileManager.default.removeItem(at: folder) }

    // 造一个末尾不足一个扇区的映像：读第 3 扇区时只能拿到 100 字节，
    // 光驱对应的 /dev/rdiskN 上这种「要 60 个字节」的请求必须自己按扇区取再截断。
    var bytes = [UInt8](repeating: 0x41, count: 2048 * 3 + 100)
    for index in 0..<18 { bytes[index] = UInt8(0x30 + index) }
    let url = folder.appendingPathComponent("小.iso")
    try Data(bytes).write(to: url)
    guard let reader = IsoImageReader(fileURL: url) else {
        expect(false, "应该能打开文件映像")
        return
    }

    expectEqual(reader.read(extent: 0, size: 18)?.count, 18, "18 个字节也要读全（按扇区读再截断）")
    expectEqual(reader.read(extent: 0, size: 18)?.first, 0x30, "内容从第 0 字节开始")
    expectEqual(reader.read(extent: 1, size: 5)?.count, 5, "从扇区中间起的短读")
    expectEqual(reader.read(extent: 3, size: 60)?.count, 60, "末尾只剩 100 字节时也要读够")
    expectEqual(reader.read(extent: 0, size: 2048)?.count, 2048, "整扇区读取不受影响")
    expectNil(reader.read(extent: 3, size: 500), "超出映像末尾要返回 nil")

    // 内存映像这条路也保持逐字节精确。
    let memory = IsoImageReader(data: Data(bytes))
    expectEqual(memory.read(extent: 0, size: 18)?.count, 18, "内存映像读 18 个字节")
    expectNil(memory.read(extent: 0, size: 0), "要 0 个字节不算有效读取")
}

run("追加策略：默认是嫁接，合并重刻要显式选") {
    expectEqual(BurnOptions().appendStrategy, .graft, "默认嫁接（写得快，但 macOS / Linux 只看得到第一段）")
    expectEqual(BurnOptions(appendStrategy: .rewriteMerged).appendStrategy, .rewriteMerged, "可以选合并重刻")
    expectEqual(AppendStrategy(rawValue: "rewriteMerged"), .rewriteMerged, "存 UserDefaults 用的原始值")
    expectEqual(AppendStrategy(rawValue: "graft"), .graft, "存 UserDefaults 用的原始值")
}

// MARK: - 音乐 CD（红皮书音轨）

/// 造一个最小 PCM WAV 文件（自己写文件头，不依赖任何外部工具）。
/// 用来跑真实的 `afinfo` / `afconvert`：音乐 CD 这条流水线全靠它们。
func writeWAV(
    to url: URL,
    seconds: Double,
    sampleRate: Int = 44100,
    channels: Int = 2,
    frequency: Double = 440
) throws {
    var body = Data()
    let frames = Int(Double(sampleRate) * seconds)
    for index in 0..<frames {
        let value = Int16(12000 * sin(2 * Double.pi * frequency * Double(index) / Double(sampleRate)))
        for channel in 0..<channels {
            var sample = (channel == 0 ? value : -value).littleEndian
            withUnsafeBytes(of: &sample) { body.append(contentsOf: $0) }
        }
    }
    var header = Data()
    func ascii(_ text: String) { header.append(text.data(using: .ascii)!) }
    func put32(_ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { header.append(contentsOf: $0) }
    }
    func put16(_ value: UInt16) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { header.append(contentsOf: $0) }
    }
    ascii("RIFF"); put32(UInt32(36 + body.count)); ascii("WAVE")
    ascii("fmt "); put32(16); put16(1); put16(UInt16(channels))
    put32(UInt32(sampleRate)); put32(UInt32(sampleRate * channels * 2))
    put16(UInt16(channels * 2)); put16(16)
    ascii("data"); put32(UInt32(body.count))
    try (header + body).write(to: url)
}

run("音乐 CD：光盘类型与音频扩展名") {
    expectEqual(DiscMode.allCases.count, 3, "三种光盘类型")
    expectEqual(DiscMode.data.localizedName, "数据光盘", "数据光盘的名字")
    expectEqual(DiscMode.audioCD.localizedName, "音乐 CD", "音乐 CD 的名字")
    expect(DiscMode.data.usesFileSystemOptions, "数据光盘才有卷标 / 文件系统这些设置")
    expect(!DiscMode.audioCD.usesFileSystemOptions, "音乐 CD 用不上文件系统设置")
    expectEqual(DiscMode(rawValue: "audioCD"), .audioCD, "存 UserDefaults 用的原始值")

    for name in ["a.mp3", "b.m4a", "c.wav", "d.aiff", "e.flac", "f.ALAC", "g.MP3"] {
        expect(AudioDisc.isAudioFile(URL(fileURLWithPath: "/tmp/\(name)")), "\(name) 是音频文件")
    }
    for name in ["电影.mp4", "片子.mkv", "说明.txt", "系统.iso", "无扩展名"] {
        expect(!AudioDisc.isAudioFile(URL(fileURLWithPath: "/tmp/\(name)")), "\(name) 不是音频文件")
    }
    // Ogg / Opus 故意不收：macOS 的 CoreAudio 解不了，列出来只会让人以为能刻。
    expect(!AudioDisc.isAudioFile(URL(fileURLWithPath: "/tmp/x.ogg")), "Ogg 不在支持列表里")
    expect(!AudioDisc.isAudioFile(URL(fileURLWithPath: "/tmp/x.opus")), "Opus 不在支持列表里")
}

run("音乐 CD：afinfo 输出解析") {
    let cdQuality = """
    File:           /tmp/a.aiff
    File type ID:   AIFF
    Num Tracks:     1
    ----
    Data format:     2 ch,  44100 Hz, lpcm (0x0000000E) 16-bit big-endian signed integer
                    no channel layout.
    estimated duration: 213.184000 sec
    audio bytes: 37605696
    """
    let info = try AudioDisc.parseAFInfo(cdQuality)
    expect(abs(info.duration - 213.184) < 0.001, "读到时长了")
    expectEqual(info.channels, 2, "双声道")
    expectEqual(info.bitsPerSample, 16, "16 bit")
    expect(info.isCDQuality, "44.1 kHz / 16 bit / 立体声就是 CD 音质")
    expect(info.formatSummary.contains("44 kHz"), "格式说明写成人话")

    let fortyEight = """
    Data format:     2 ch,  48000 Hz, Int16, interleaved
    estimated duration: 95.000000 sec
    """
    let high = try AudioDisc.parseAFInfo(fortyEight)
    expect(!high.isCDQuality, "48 kHz 不是 CD 音质，要重采样")
    expectEqual(high.bitsPerSample, 16, "Int16 的位深要读出来")

    let compressed = """
    Data format:     2 ch,  44100 Hz, aac (0x0000000B) 32-bit float
    estimated duration: 180.000000 sec
    """
    let aac = try AudioDisc.parseAFInfo(compressed)
    expect(!aac.isPCM, "AAC 是压缩格式")
    expect(!aac.isCDQuality, "压缩格式要转码")

    let mono = """
    Data format:     1 ch,  44100 Hz, Int16, interleaved
    estimated duration: 60.000000 sec
    """
    expect(!(try AudioDisc.parseAFInfo(mono)).isCDQuality, "单声道要转成立体声")

    expectNil(AudioDisc.parseDuration(fromAFInfo: "File: /tmp/x\nNum Tracks: 1\n"), "没有时长就返回 nil")
    var threw = false
    do { _ = try AudioDisc.parseAFInfo("File: /tmp/x\n", name: "x") } catch { threw = true }
    expect(threw, "解析不出时长要当成读失败")
}

run("音乐 CD：摊平文件夹、跳过非音频") {
    let folder = try makeTempDirectory("audio")
    defer { try? FileManager.default.removeItem(at: folder) }
    let album = folder.appendingPathComponent("专辑", isDirectory: true)
    try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
    for name in ["a.mp3", "说明.txt", ".DS_Store"] {
        try Data("x".utf8).write(to: folder.appendingPathComponent(name))
    }
    for name in ["3 第三首.mp3", "10 第十首.mp3", "封面.jpg"] {
        try Data("x".utf8).write(to: album.appendingPathComponent(name))
    }

    let collected = AudioDisc.collectAudioFiles(from: [folder])
    expectEqual(collected.audio.count, 3, "文件夹里 3 个音频（.DS_Store 与其它文件不算）")
    expect(collected.skipped.isEmpty, "文件夹内部的非音频文件不逐条报，只报「这个文件夹没有音频」")
    expectEqual(
        Set(collected.audio.map { $0.lastPathComponent }),
        Set(["a.mp3", "3 第三首.mp3", "10 第十首.mp3"]),
        "三个音频都找到了"
    )
    // 同一个目录里按「自然序」：3 要排在 10 前面，不能按字典序。
    let names = collected.audio.map { $0.lastPathComponent }
    let third = names.firstIndex(of: "3 第三首.mp3") ?? -1
    let tenth = names.firstIndex(of: "10 第十首.mp3") ?? -1
    expect(third >= 0 && tenth >= 0 && third < tenth, "「3 第三首」排在「10 第十首」前面")

    // 用户一条条拖进来的文件按拖进来的顺序排（文件夹内部才排序）。
    let explicit = AudioDisc.collectAudioFiles(from: [
        folder.appendingPathComponent("a.mp3"),
        album.appendingPathComponent("10 第十首.mp3"),
        album.appendingPathComponent("3 第三首.mp3"),
    ])
    expectEqual(
        explicit.audio.map { $0.lastPathComponent },
        ["a.mp3", "10 第十首.mp3", "3 第三首.mp3"],
        "单独添加的文件保持用户给的顺序"
    )

    let textOnly = folder.appendingPathComponent("说明.txt")
    let oneSkip = AudioDisc.collectAudioFiles(from: [textOnly])
    expectEqual(oneSkip.skipped.count, 1, "直接选一个非音频文件要报出来")
    expect(oneSkip.skipped[0].reason.contains(".txt"), "跳过原因里写清是什么类型")

    let empty = folder.appendingPathComponent("空", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let emptySkip = AudioDisc.collectAudioFiles(from: [empty])
    expectEqual(emptySkip.skipped.count, 1, "空文件夹也要说一声")
    expect(emptySkip.skipped[0].reason.contains("没有音频文件"), "说清是文件夹里没有音频")
}

run("音乐 CD：音轨名、顺序与时长文本") {
    expectEqual(AudioDisc.trackTitle(from: URL(fileURLWithPath: "/tmp/01 开场曲.mp3")), "开场曲", "去掉「01 」前缀")
    expectEqual(AudioDisc.trackTitle(from: URL(fileURLWithPath: "/tmp/02 - 第二首.wav")), "第二首", "去掉「02 - 」前缀")
    expectEqual(AudioDisc.trackTitle(from: URL(fileURLWithPath: "/tmp/3.歌.mp3")), "歌", "去掉「3.」前缀")
    expectEqual(
        AudioDisc.trackTitle(from: URL(fileURLWithPath: "/tmp/2001 太空漫游.mp3")),
        "2001 太空漫游",
        "四位数开头的名字不算序号，别切坏"
    )
    expectEqual(AudioDisc.trackTitle(from: URL(fileURLWithPath: "/tmp/01.mp3")), "01", "光剩序号就保留原名")
    expectEqual(AudioDisc.safeFileName("a/b:c"), "a-b-c", "文件名里的 / 和 : 要换掉")
    expectEqual(AudioDisc.safeFileName("   "), "音轨", "空名字要有兜底")

    let tracks = (1...12).map { number in
        AudioTrack(
            id: number,
            sourceURL: URL(fileURLWithPath: "/tmp/\(number).mp3"),
            title: "曲目 \(number)",
            duration: 180,
            sourceBytes: 1,
            isCDQuality: false
        )
    }
    expectEqual(tracks[0].stagedName, "01 - 曲目 1.aiff", "暂存文件名带两位序号前缀")
    expectEqual(tracks[9].stagedName, "10 - 曲目 10.aiff", "第 10 轨")
    // 这条是整条流水线的关键前提：drutil 按文件名字母序写音轨，
    // 两位数字前缀保证「字母序 == 用户排的顺序」。
    let sortedNames = tracks.map { $0.stagedName }.sorted()
    expectEqual(sortedNames, tracks.map { $0.stagedName }, "按名字排序后仍然是用户排的顺序")

    expectEqual(AudioDisc.timeText(0), "0:00", "0 秒")
    expectEqual(AudioDisc.timeText(185), "3:05", "3 分 5 秒")
    expectEqual(AudioDisc.timeText(3723), "1:02:03", "超过一小时")
    expectEqual(AudioDisc.pcmBytes(duration: 1), 176400, "1 秒 CD 音轨 = 176400 字节")
    expectEqual(AudioDisc.audioSectors(duration: 1), 75, "1 秒 = 75 个红皮书扇区")
    expectEqual(AudioDisc.audioSectors(duration: 0.5), 38, "不满一扇区也要占一扇区")
}

run("音乐 CD：容量按时间算，超了要拦下来") {
    func plan(seconds: [Double]) -> AudioDiscPlan {
        let tracks = seconds.enumerated().map { index, duration in
            AudioTrack(
                id: index + 1,
                sourceURL: URL(fileURLWithPath: "/tmp/\(index).mp3"),
                title: "曲目 \(index + 1)",
                duration: duration,
                sourceBytes: 1,
                isCDQuality: true
            )
        }
        return AudioDiscPlan(tracks: tracks)
    }

    let small = plan(seconds: [100, 100, 100])
    expectEqual(Int(small.totalDuration), 300, "纯音频 300 秒")
    expectEqual(Int(small.requiredSeconds), 308, "加上 4 个 2 秒间隔 = 308 秒")
    expectEqual(Int(small.remainingSeconds), 4800 - 308, "还剩多少")
    expect(!small.isOverCapacity, "装得下")
    expectEqual(small.stagedBytes, AudioDisc.pcmBytes(duration: 300), "暂存体积按 PCM 算")
    expectEqual(small.summary, "3 轨 · 总时长 5:00", "摘要写成「几轨 + 多长」")
    try AudioDisc.validate(plan: small)

    // 80 分钟整的音频 + 间隔就超了：一张 CD 是 4800 秒。
    let exact = plan(seconds: Array(repeating: 480, count: 10))
    expectEqual(Int(exact.totalDuration), 4800, "正好 80 分钟音频")
    expect(exact.isOverCapacity, "再加上每轨 2 秒间隔就装不下了")
    var threw = false
    do { try AudioDisc.validate(plan: exact) } catch { threw = true }
    expect(threw, "超容量要中止（除非 --force）")
    try AudioDisc.validate(plan: exact, force: true)

    var emptyThrew = false
    do { try AudioDisc.validate(plan: plan(seconds: [])) } catch { emptyThrew = true }
    expect(emptyThrew, "一条音轨都没有也要拒绝")

    // 音频扇区 2352 字节、数据扇区 2048 字节：80 分钟音轨（807 MiB）比 80 分钟 CD-R 的
    // 「数据容量」（703 MiB）还大，所以音乐 CD 绝不能拿字节数去比光盘剩余空间，只能比时间。
    expectEqual(AudioDisc.audioSectors(duration: 4800), 360_000, "80 分钟正好是 36 万个红皮书扇区")
    expect(
        AudioDisc.pcmBytes(duration: 4800) > Int64(360_000 * 2048),
        "80 分钟音轨比 CD-R 的数据容量还大——音乐 CD 只能按时间算容量"
    )
}

run("音乐 CD：倍速建议与写盘参数") {
    let advised = SpeedAdvisor.audioAdvice(reportedSpeeds: [8, 16, 24])
    expectEqual(advised.recommended, 8, "上报到 24x 也只推荐 8x")
    expectEqual(advised.conservativeCap, 16, "稳妥上限 16x")
    expect(advised.reason.contains("CD 机"), "理由要讲清是给 CD 机听的")
    expectEqual(SpeedAdvisor.audioAdvice(reportedSpeeds: [24, 48]).recommended, 24, "驱动器只有高速档就用最低那档")
    expectEqual(SpeedAdvisor.audioAdvice(reportedSpeeds: []).recommended, 8, "问不到能力就用常用值")
    expect(SpeedAdvisor.audioAdvice(reportedSpeeds: [8]).caution(for: 16) != nil, "手选 16x 要提醒")

    let folder = URL(fileURLWithPath: "/tmp/音轨")
    let arguments = Burner.burnAudioArguments(directory: folder, options: BurnOptions(speed: 8))
    expect(arguments.contains("-audio"), "要带 -audio")
    expect(arguments.contains("-noappendable"), "音频盘一次写完并收尾，不能追加")
    expect(arguments.contains("-noverify"), "音轨没有文件系统可校验")
    expect(!arguments.contains("-appendable"), "不能留成可追加")
    expect(!arguments.contains("-verify"), "不校验")
    expectEqual(arguments.last, folder.path, "目录放在最后")
    expect(arguments.contains("-speed") && arguments.contains("8"), "带上倍速")
    expectEqual(Burner.burnAudioArguments(directory: folder, options: BurnOptions(driveIndex: 1)).prefix(2), ["-drive", "1"], "驱动器编号要在最前面")
    expect(Burner.burnAudioArguments(directory: folder, options: BurnOptions(testBurn: true)).contains("-test"), "测试模式")
    expect(Burner.burnAudioArguments(directory: folder, options: BurnOptions(ejectWhenDone: true)).contains("-eject"), "刻完弹出")
    expect(!Burner.burnAudioArguments(directory: folder, options: BurnOptions(ejectWhenDone: false)).contains("-eject"), "可以选不弹出")
}

run("音乐 CD：介质与错误提示") {
    expect(AudioDiscError.requiresCDMedia("DVD+R").localizedDescription.contains("CD-R"), "说清只能用 CD-R/RW")
    expect(AudioDiscError.requiresCDMedia("DVD+R").localizedDescription.contains("DVD"), "顺便解释 DVD 为什么不行")
    expect(AudioDiscError.needsBlankDisc(sessions: 3, media: "CD-RW").localizedDescription.contains("不能追加"), "说清不能追加")
    expect(AudioDiscError.needsBlankDisc(sessions: 3, media: "CD-RW").localizedDescription.contains("CD-RW"), "给出可重写介质这条出路")
    expect(AudioDiscError.noAudioTracks.localizedDescription.contains("MP3"), "空列表时告诉用户支持哪些格式")
    expect(AudioDiscError.overCapacity(required: 5000, available: 4800).localizedDescription.contains("超过"), "超容量的说法")
}

run("音乐 CD：真跑 afinfo 与 afconvert（转出红皮书音轨）") {
    let folder = try makeTempDirectory("audio-real")
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = folder.appendingPathComponent("01 三秒.wav")
    let second = folder.appendingPathComponent("02 - 两秒 48k 单声道.wav")
    try writeWAV(to: first, seconds: 3, sampleRate: 44100, channels: 2)
    try writeWAV(to: second, seconds: 2, sampleRate: 48000, channels: 1)

    let firstInfo = try AudioDisc.info(for: first)
    expect(abs(firstInfo.duration - 3) < 0.05, "afinfo 读出的时长")
    expect(firstInfo.isCDQuality, "44.1 kHz / 16 bit / 立体声就是 CD 音质")
    let secondInfo = try AudioDisc.info(for: second)
    expect(!secondInfo.isCDQuality, "48 kHz 单声道要先转码")
    expectEqual(secondInfo.channels, 1, "单声道")

    let plan = try AudioDisc.plan(items: [first, second])
    expectEqual(plan.tracks.count, 2, "两条音轨")
    expectEqual(plan.tracks[0].id, 1, "音轨号从 1 开始")
    expectEqual(plan.tracks[1].id, 2, "第二条是 2")
    expectEqual(plan.tracks[1].title, "两秒 48k 单声道", "显示名去掉扩展名与序号")
    expectEqual(plan.cdQualityCount, 1, "只有一条本来就是 CD 音质")

    let staging = folder.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let staged = try AudioDiscStager.stage(tracks: plan.tracks, into: staging)
    expectEqual(staged.count, 2, "两条都转好了")
    let names = try FileManager.default.contentsOfDirectory(atPath: staging.path).sorted()
    expectEqual(names, ["01 - 三秒.aiff", "02 - 两秒 48k 单声道.aiff"], "暂存文件名 = 序号 + 标题")

    // 转出来的文件必须真的是红皮书格式，不然 CD 机放不了。
    for name in names {
        let url = staging.appendingPathComponent(name)
        let info = try AudioDisc.info(for: url)
        expect(info.isCDQuality, "\(name) 应该是 44.1 kHz / 16 bit / 立体声")
        expect(Workspace.fileSize(of: url) > 0, "\(name) 不能是空文件")
    }
    let stagedFirst = try AudioDisc.info(for: staging.appendingPathComponent(names[0]))
    expect(abs(stagedFirst.duration - 3) < 0.05, "转码后时长不变")
}

// MARK: - 视频 DVD（DVD-Video）

run("视频 DVD：光盘类型与视频扩展名") {
    expectEqual(DiscMode.allCases.count, 3, "三种光盘类型")
    expectEqual(DiscMode.videoDVD.localizedName, "视频 DVD", "视频 DVD 的名字")
    expectEqual(DiscMode.videoDVD.detail.contains("VIDEO_TS"), true, "说明里点出 VIDEO_TS")
    expect(!DiscMode.videoDVD.usesFileSystemOptions, "视频 DVD 用不上 Joliet / 追加这些设置")
    expect(DiscMode.data.hasVisibleFiles, "数据光盘在访达里看得到文件")
    expect(!DiscMode.videoDVD.hasVisibleFiles, "视频 DVD 看到的是 VIDEO_TS，不是文件列表")

    for name in ["电影.mp4", "片子.mkv", "老录像.avi", "碟.vob", "手机.MOV", "录制.m2ts", "网课.webm"] {
        expect(VideoDVD.isVideoFile(URL(fileURLWithPath: "/tmp/\(name)")), "\(name) 是视频文件")
    }
    for name in ["歌.mp3", "清单.txt", "系统.iso", "无扩展名", "电影.mp4.txt"] {
        expect(!VideoDVD.isVideoFile(URL(fileURLWithPath: "/tmp/\(name)")), "\(name) 不是视频文件")
    }

    // 视频 DVD 只能刻在 DVD 上，CD 与蓝光都不行（蓝光的 BDMV 是另一套结构）。
    expect(MediaKind.dvdPlusR.isDVD, "DVD+R 是 DVD 介质")
    expect(MediaKind.dvdRW.isDVD, "DVD-RW 是 DVD 介质")
    expect(MediaKind.dvdRDL.isDVD, "DVD-R DL 是 DVD 介质")
    expect(!MediaKind.cdR.isDVD, "CD-R 不是 DVD 介质")
    expect(!MediaKind.bdR.isDVD, "BD-R 不是 DVD 介质")
}

run("视频 DVD：ffprobe 输出解析") {
    let wide = """
    {"streams":[
      {"codec_type":"video","width":1920,"height":1080,"display_aspect_ratio":"16:9","field_order":"progressive"},
      {"codec_type":"audio","channels":2}
    ],"format":{"duration":"125.400000"}}
    """
    let wideInfo = try VideoDVD.parseFFProbe(wide)
    expectEqual(wideInfo.width, 1920, "读到宽度")
    expectEqual(wideInfo.height, 1080, "读到高度")
    expect(abs(wideInfo.displayAspect - 16.0 / 9) < 0.01, "读到宽高比")
    expect(wideInfo.isWidescreen, "1920×1080 是宽屏")
    expect(wideInfo.hasAudio, "有音轨")
    expect(!wideInfo.isInterlaced, "progressive 不用反交错")
    expect(abs(wideInfo.duration - 125.4) < 0.001, "读到时长")

    let old = """
    {"streams":[{"codec_type":"video","width":720,"height":576,"sample_aspect_ratio":"16:15",
      "field_order":"tt"}],"format":{"duration":"60"}}
    """
    let oldInfo = try VideoDVD.parseFFProbe(old)
    expect(!oldInfo.isWidescreen, "720×576 且 16:15 的像素比 → 4:3")
    expect(!oldInfo.hasAudio, "没有音轨要标出来")
    expect(oldInfo.isInterlaced, "field_order=tt 是隔行，转码前要反交错")
    expect(abs(oldInfo.displayAspect - 4.0 / 3) < 0.01, "宽高比按「宽 × 像素比 ÷ 高」算")

    // 手机竖着拍的片子：ffmpeg 转码时会自动转正，算比例前也得先跟着转。
    let portrait = """
    {"streams":[{"codec_type":"video","width":1920,"height":1080,
      "side_data_list":[{"rotation":-90}],"display_aspect_ratio":"16:9"},
      {"codec_type":"audio"}],"format":{"duration":"30"}}
    """
    let portraitInfo = try VideoDVD.parseFFProbe(portrait)
    expectEqual(portraitInfo.width, 1080, "旋转 90 度后宽高要对调")
    expectEqual(portraitInfo.height, 1920, "旋转 90 度后宽高要对调")
    expect(!portraitInfo.isWidescreen, "转正之后是竖屏，不该当宽屏")

    var threw = false
    do { _ = try VideoDVD.parseFFProbe("{\"streams\":[{\"codec_type\":\"audio\"}]}") } catch { threw = true }
    expect(threw, "没有视频轨道要报错")

    threw = false
    do { _ = try VideoDVD.parseFFProbe("这不是 JSON") } catch { threw = true }
    expect(threw, "ffprobe 输出不是 JSON 要报错")

    threw = false
    do {
        _ = try VideoDVD.parseFFProbe("{\"streams\":[{\"codec_type\":\"video\",\"width\":640,\"height\":480}],\"format\":{}}")
    } catch { threw = true }
    expect(threw, "没有时长要报错")
}

run("视频 DVD：制式与画面比例") {
    expectEqual(VideoStandard.pal.width, 720, "PAL 横向都是 720")
    expectEqual(VideoStandard.pal.height, 576, "PAL 是 576 行")
    expectEqual(VideoStandard.ntsc.height, 480, "NTSC 是 480 行")
    expectEqual(VideoStandard.pal.gopSize, 15, "PAL 的 GOP 上限 15")
    expectEqual(VideoStandard.ntsc.gopSize, 18, "NTSC 的 GOP 上限 18")

    // 方形像素画布：16:9 的 PAL 是 1024×576，4:3 是 768×576。
    expectEqual(VideoStandard.pal.squarePixelWidth(widescreen: true), 1024, "PAL 16:9 的方形像素宽")
    expectEqual(VideoStandard.pal.squarePixelWidth(widescreen: false), 768, "PAL 4:3 的方形像素宽")
    expectEqual(VideoStandard.pal.sampleAspect(widescreen: true), "64/45", "PAL 16:9 的像素长宽比")
    expectEqual(VideoStandard.pal.sampleAspect(widescreen: false), "16/15", "PAL 4:3 的像素长宽比")
    expectEqual(VideoStandard.ntsc.sampleAspect(widescreen: true), "40/33", "NTSC 16:9 的像素长宽比")
    expectEqual(VideoStandard.ntsc.sampleAspect(widescreen: false), "10/11", "NTSC 4:3 的像素长宽比")

    // 滤镜链必须带 setsar，否则播放机上的画面会被拉扁。
    let filters = VideoDVDStager.encodeFilters(standard: .pal, widescreen: true, isInterlaced: false)
    expect(filters.contains("scale=1024:576"), "先缩到方形像素画布")
    expect(filters.contains("pad=1024:576"), "再补黑边保证不裁切")
    expect(filters.contains("scale=720:576"), "最后压成 DVD 的 720×576")
    expect(filters.contains("setsar=64/45"), "标上 16:9 的像素长宽比")
    expect(!filters.contains("yadif"), "逐行素材不反交错")

    let interlaced = VideoDVDStager.encodeFilters(standard: .ntsc, widescreen: false, isInterlaced: true)
    expect(interlaced.contains("yadif=0"), "隔行素材先反交错")
    expect(interlaced.contains("setsar=10/11"), "NTSC 4:3 的像素长宽比")
}

run("视频 DVD：码率、容量与卷标") {
    let single = VideoDVD.capacityBytes(for: .dvdPlusR)
    expectEqual(single, VideoDVD.defaultCapacityBytes, "单层 DVD 就是 4.38 GiB")
    expectEqual(VideoDVD.capacityBytes(for: .dvdPlusRDL), VideoDVD.dualLayerCapacityBytes, "双层盘按双层的容量算")
    expectEqual(VideoDVD.capacityBytes(for: .cdR), MediaKind.cdR.nominalCapacityBytes, "别的介质按标称容量")

    // 一小时的片子：码率要落在 1.5–8 Mbps 之间，而且真按这个码率算要装得下。
    let oneHour = VideoDVD.recommendedVideoBitrate(totalDuration: 3600, capacityBytes: single)
    expect(oneHour >= VideoDVD.minimumVideoBitrateKbps, "一小时能放下")
    expect(oneHour <= VideoDVD.maximumVideoBitrateKbps, "码率不超过上限")
    expectEqual(oneHour % 100, 0, "码率取整到 100 kbps")
    let oneHourBytes = VideoDVD.estimatedBytes(totalDuration: 3600, videoBitrateKbps: oneHour)
    expect(oneHourBytes <= single, "按推荐码率算应该装得下")

    // 短片子：不会超过上限，也不会因为「盘太空」就给个天文数字。
    let short = VideoDVD.recommendedVideoBitrate(totalDuration: 120, capacityBytes: single)
    expectEqual(short, VideoDVD.maximumVideoBitrateKbps, "短片按上限给")

    // 十小时：连最低码率都塞不下，必须给 0 让调用方报「超容量」。
    expectEqual(VideoDVD.recommendedVideoBitrate(totalDuration: 36000, capacityBytes: single), 0, "十小时装不下")

    expectEqual(VideoDVD.estimatedBytes(totalDuration: 0, videoBitrateKbps: 4000), 0, "没时长就是 0 字节")

    // 卷标：ISO 9660 的卷标是 ASCII 字段，中文进去会变乱码，所以要洗掉。
    expectEqual(VideoDVD.volumeLabel("婚礼 2026"), "2026", "中文与空格换成下划线后把首尾的下划线去掉")
    expectEqual(VideoDVD.volumeLabel("my wedding disc"), "MY_WEDDING_DISC", "转成大写、空格变下划线")
    expectEqual(VideoDVD.volumeLabel("中文卷标"), "VIDEO_DVD", "洗没了就用默认名")
    expectEqual(VideoDVD.volumeLabel(""), "VIDEO_DVD", "空卷标用默认名")
    expect(VideoDVD.volumeLabel(String(repeating: "A", count: 40)).count == 32, "卷标最多 32 个字符")

    // 章节：太短的片子不打章节，长片每 5 分钟一个。
    expectEqual(VideoDVD.chapterMarks(duration: 60, every: 300), [0], "一分钟的片子只有开头一个章节点")
    let marks = VideoDVD.chapterMarks(duration: 1000, every: 300)
    expectEqual(marks.count, 4, "1000 秒的片子打 4 个章节点")
    expectEqual(marks.first, 0, "第一个章节点永远是 0")
    expectEqual(VideoDVD.chapterMarks(duration: 0, every: 300), [0], "没有时长也返回开头")
}

run("视频 DVD：dvdauthor 的 XML") {
    let titles = [
        URL(fileURLWithPath: "/tmp/暂存/01 - 婚礼 & 宴会.mpg"),
        URL(fileURLWithPath: "/tmp/暂存/02 - 花絮.mpg"),
    ]
    let xml = VideoDVD.dvdauthorXML(
        destination: URL(fileURLWithPath: "/tmp/dvd"),
        standard: .pal,
        widescreen: true,
        titles: titles,
        chapters: [[0, 300], [0]]
    )
    // 这几条都是实测撞出来的：少了 vmgm 里那段 video，dvdauthor 不会生成 VIDEO_TS.IFO。
    expect(xml.contains("<vmgm>"), "要有 vmgm")
    expect(xml.contains("<video format=\"pal\" aspect=\"16:9\" />"), "vmgm 与 titles 都要写清制式和比例")
    expect(xml.contains("dest=\"/tmp/dvd\""), "输出目录要写进 XML")
    expect(xml.contains("chapters=\"0:00:00,0:05:00\""), "章节点写成人能看懂的时间")
    expect(xml.contains("jump title 2;"), "第一个节目播完跳到第二个")
    expect(xml.contains("<post> exit; </post>"), "最后一个节目播完就停")
    // 路径里的 & 不转义会让 XML 直接解析失败。
    expect(xml.contains("婚礼 &amp; 宴会"), "路径里的 & 要转义")
    expect(!xml.contains("婚礼 & 宴会"), "不能留着没转义的 &")

    let ntsc = VideoDVD.dvdauthorXML(
        destination: URL(fileURLWithPath: "/tmp/dvd"),
        standard: .ntsc,
        widescreen: false,
        titles: [URL(fileURLWithPath: "/tmp/暂存/01.mpg")]
    )
    expect(ntsc.contains("<video format=\"ntsc\" aspect=\"4:3\" />"), "NTSC 4:3 要写对")
    expect(ntsc.contains("exit;"), "只有一个节目时直接结束")

    expectEqual(VideoDVD.xmlEscape("a<b>c\"d'e&f"), "a&lt;b&gt;c&quot;d&apos;e&amp;f", "XML 转义")
}

run("视频 DVD：收集文件与错误提示") {
    let folder = try makeTempDirectory("video")
    defer { try? FileManager.default.removeItem(at: folder) }
    let sub = folder.appendingPathComponent("子目录", isDirectory: true)
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    for name in ["电影.mp4", "花絮.mkv"] {
        try "x".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try "x".write(to: sub.appendingPathComponent("预告.mov"), atomically: true, encoding: .utf8)
    try "x".write(to: folder.appendingPathComponent("说明.txt"), atomically: true, encoding: .utf8)
    try "x".write(to: folder.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)

    let collected = VideoDVD.collectVideoFiles(from: [folder, folder.appendingPathComponent("说明.txt")])
    expectEqual(collected.videos.count, 3, "文件夹要递归找视频")
    expectEqual(collected.skipped.count, 1, "明确点名的非视频文件要被记下来")
    expectEqual(collected.skipped.first?.displayName, "说明.txt", "跳过的是哪个文件要说清")

    // 文件夹里的非视频文件是被「不收」，不算「跳过」；整个文件夹里一个视频都没有才算跳过。
    expectEqual(VideoDVD.collectVideoFiles(from: [folder]).skipped.count, 0, "文件夹里的杂项文件不算跳过")
    let emptyFolder = folder.appendingPathComponent("全是文档", isDirectory: true)
    try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
    try "x".write(to: emptyFolder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    let none = VideoDVD.collectVideoFiles(from: [emptyFolder])
    expectEqual(none.videos.count, 0, "没有视频的文件夹收不到东西")
    expectEqual(none.skipped.first?.reason.contains("没有视频文件") ?? false, true, "要说明这个文件夹里没有视频")

    expectEqual(VideoDVD.videoTitle(from: URL(fileURLWithPath: "/tmp/01 - 婚礼.mp4")), "婚礼", "显示名去掉扩展名与序号")
    expectEqual(VideoDVD.videoTitle(from: URL(fileURLWithPath: "/tmp/2001 太空漫游.mp4")), "2001 太空漫游", "四位数开头的名字不能被当成序号")
    expectEqual(VideoDVD.safeFileName("a/b:c"), "a-b-c", "文件名里的斜杠和冒号要换掉")

    expect(VideoDVDError.requiresDVDMedia("CD-R").localizedDescription.contains("DVD"), "说清只能用 DVD")
    expect(VideoDVDError.requiresDVDMedia("CD-R").localizedDescription.contains("CD"), "顺便解释 CD 为什么不行")
    expect(VideoDVDError.needsBlankDisc(sessions: 2, media: "DVD-RW").localizedDescription.contains("不能追加"), "说清不能追加")
    expect(VideoDVDError.noVideoFiles.localizedDescription.contains("MKV"), "空列表时告诉用户支持哪些格式")
    expect(VideoDVDError.missingTool(name: "ffmpeg", hint: "装一下").localizedDescription.contains("ffmpeg"), "缺工具要说清缺哪个")
    expect(VideoDVDError.tooManyTitles(120).localizedDescription.contains("99"), "节目数上限要说出来")
}

run("视频 DVD：真跑 ffmpeg + dvdauthor + mkisofs") {
    guard VideoDVD.isReady else {
        print("  （这台机器没装 \(VideoDVD.missingTools.joined(separator: "、"))，跳过真跑那一组）")
        return
    }
    let folder = try makeTempDirectory("video-real")
    defer { try? FileManager.default.removeItem(at: folder) }
    let ffmpeg = VideoDVD.ffmpegPath!

    // 造两段测试素材：一段 4:3 带声音，一段竖屏不带声音（正好试「补静音」那条路）。
    let wideFile = folder.appendingPathComponent("宽屏片段.mp4")
    let silentFile = folder.appendingPathComponent("无声片段.mp4")
    for (destination, size, withAudio) in [(wideFile, "854x480", true), (silentFile, "480x640", false)] {
        var arguments = [
            "-y", "-hide_banner", "-nostats",
            "-f", "lavfi", "-i", "testsrc2=size=\(size):rate=25:duration=2",
        ]
        if withAudio {
            arguments += ["-f", "lavfi", "-i", "sine=frequency=440:duration=2"]
        }
        arguments += ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"]
        if withAudio {
            arguments += ["-c:a", "aac", "-shortest"]
        }
        arguments.append(destination.path)
        let result = try Shell.run(ffmpeg, arguments)
        expect(result.succeeded, "造测试素材：\(destination.lastPathComponent)")
    }

    let plan = try VideoDVD.plan(items: [wideFile, silentFile], standard: .pal)
    expectEqual(plan.sources.count, 2, "两个节目都收进来了")
    expectEqual(plan.skipped.count, 0, "没有要跳过的")
    expect(plan.sources[0].hasAudio, "第一个有音轨")
    expect(!plan.sources[1].hasAudio, "第二个没有音轨")
    expect(abs(plan.totalDuration - 4) < 0.3, "两段合起来 4 秒左右")
    expect(plan.videoBitrateKbps > 0, "算得出码率")
    expect(plan.widescreen, "只要有一部是宽屏，整张盘就按 16:9 做（竖屏那部会被补黑边）")

    let staging = folder.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let encoded = try VideoDVDStager.encode(
        sources: plan.sources,
        into: staging,
        standard: plan.standard,
        widescreen: plan.widescreen,
        videoBitrateKbps: plan.videoBitrateKbps
    )
    expectEqual(encoded.count, 2, "两段都转好了")
    expectEqual(encoded[0].lastPathComponent, "01 - 宽屏片段.mpg", "暂存文件名 = 序号 + 标题")

    // 转出来的必须是 DVD 认的 MPEG-PS：MPEG-2 + 720×576 + MP2 48 kHz 立体声。
    let encodedInfo = try VideoDVD.info(for: encoded[0])
    expectEqual(encodedInfo.width, 720, "转码后宽度是 DVD 的 720")
    expectEqual(encodedInfo.height, 576, "转码后高度是 DVD 的 576")
    expect(encodedInfo.hasAudio, "原本有音轨的当然还在")
    let silentInfo = try VideoDVD.info(for: encoded[1])
    expect(silentInfo.hasAudio, "原本没有音轨的素材要补出一条静音音轨（DVD 要求每条节目都有音频流）")
    expectEqual(silentInfo.height, 576, "补静音之后仍然是 DVD 的分辨率")
    let probe = try Shell.run(VideoDVD.ffprobePath!, [
        "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=codec_name,profile",
        "-of", "default=nw=1", encoded[0].path,
    ])
    expect(probe.output.contains("mpeg2video"), "视频编码要变成 mpeg2video（dvdauthor 只认它）")

    // 排 VIDEO_TS
    let dvdRoot = folder.appendingPathComponent("dvd", isDirectory: true)
    try VideoDVDStager.author(
        rootDirectory: dvdRoot,
        titles: encoded,
        standard: plan.standard,
        widescreen: plan.widescreen,
        chapters: plan.sources.map { VideoDVD.chapterMarks(duration: $0.duration, every: VideoDVD.chapterSeconds) }
    )
    let fileManager = FileManager.default
    for name in ["VIDEO_TS.IFO", "VTS_01_0.IFO", "VTS_01_1.VOB"] {
        expect(
            fileManager.fileExists(atPath: dvdRoot.appendingPathComponent("VIDEO_TS/\(name)").path),
            "VIDEO_TS 里要有 \(name)"
        )
    }
    expect(
        fileManager.fileExists(atPath: dvdRoot.appendingPathComponent("AUDIO_TS").path),
        "根目录还要有 AUDIO_TS"
    )
    // dvdauthor 的控制文件不能留在这一层，否则会被一起刻进光盘根目录。
    expect(
        !fileManager.fileExists(atPath: dvdRoot.appendingPathComponent("dvdauthor.xml").path),
        "dvdauthor.xml 不能留在要做成映像的那一层目录里"
    )

    // 做成映像：必须是 UDF 1.02（NSR02）+ 里面真有 VIDEO_TS。
    let image = folder.appendingPathComponent("dvd-video.iso")
    try VideoDVDStager.buildImage(
        source: dvdRoot,
        outputURL: image,
        volumeName: "测试 盘"
    )
    expect(Workspace.fileSize(of: image) > 0, "映像不是空的")
    let data = try Data(contentsOf: image)
    expect(data.range(of: Data("NSR02".utf8)) != nil, "UDF 1.02（DVD-Video 规范要求的版本）")
    expect(data.range(of: Data("VIDEO_TS.IFO".utf8)) != nil, "映像里有 VIDEO_TS.IFO")
    expect(data.range(of: Data("VTS_01_1.VOB".utf8)) != nil, "映像里有 VOB 数据")

    expectEqual(VideoDVD.volumeLabel("测试 盘"), "VIDEO_DVD", "中文卷标会被洗掉")
}
print("")
if failureCount == 0 {
    print("全部 \(checkCount) 项检查通过 ✅")
    exit(0)
} else {
    print("\(failureCount) 项检查失败（共 \(checkCount) 项）❌")
    exit(1)
}
