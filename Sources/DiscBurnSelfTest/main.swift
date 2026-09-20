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

print("")
if failureCount == 0 {
    print("全部 \(checkCount) 项检查通过 ✅")
    exit(0)
} else {
    print("\(failureCount) 项检查失败（共 \(checkCount) 项）❌")
    exit(1)
}
