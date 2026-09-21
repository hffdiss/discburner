import Foundation

/// 刻录速度建议。
public struct SpeedAdvice {
    /// 推荐倍速；nil 表示「没有依据，交给系统自动选」。
    public let recommended: Int?
    /// 一句话解释为什么是这个速度。
    public let reason: String
    /// 这类介质上「稳妥」的倍速上限；nil 表示没有经验上限。
    public let conservativeCap: Int?
    /// 驱动器给这张盘上报的可用倍速（已去重排序）。
    public let available: [Int]
    /// 内容很小的时候才有的一句话补充。
    public let hint: String?

    public init(
        recommended: Int?,
        reason: String,
        conservativeCap: Int?,
        available: [Int],
        hint: String? = nil
    ) {
        self.recommended = recommended
        self.reason = reason
        self.conservativeCap = conservativeCap
        self.available = available
        self.hint = hint
    }

    /// 手选的倍速是否高于建议值。
    public func isAboveRecommended(_ speed: Int) -> Bool {
        guard let recommended = recommended else { return false }
        return speed > recommended
    }

    /// 手选倍速的提醒语（没有风险就返回 nil）。
    public func caution(for speed: Int) -> String? {
        var lines: [String] = []

        // 驱动器上报过能力、却没有这一档：刻录有可能直接被拒绝（也可能被静默降速）。
        if !available.isEmpty, !available.contains(speed) {
            lines.append("驱动器上报的倍速是 \(availableText)，没有 \(speed)x：可能被直接拒绝。")
        }

        if isAboveRecommended(speed), let recommended = recommended {
            if let cap = conservativeCap, speed > cap {
                lines.append("\(speed)x 高于 \(cap)x 的稳妥上限：一次性写入介质上刻坏只能换盘。")
            } else {
                lines.append("比推荐的 \(recommended)x 更快，失败率会高一些。")
            }
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    public var availableText: String {
        available.isEmpty ? "驱动器未上报" : available.map { "\($0)x" }.joined(separator: " / ")
    }
}

/// 按介质类型和驱动器上报的能力给一个「稳妥但不磨叽」的刻录倍速。
///
/// 依据来自刻录介质的实际特性，而不是「越快越好」：
/// - 一次性写入介质（CD-R / DVD±R / BD-R）在额定倍速附近成功率最高，超过某个值后失败率明显上升；
/// - 双层介质（DVD+R DL、BD-R DL）本来就慢，4x 已经是常见上限；
/// - 可重写介质（RW / RE / RAM）推荐 2–6x；
/// - 内容很小的时候快慢差别只有几十秒，不值得为省这点时间去冒刻坏一张盘的风险。
public enum SpeedAdvisor {

    /// 界面上给用户挑的常用倍速档。
    ///
    /// 这几档覆盖了 CD / DVD / 蓝光实际会用到、且互相之间差别有意义的倍速：
    /// 1x 最稳，3x / 4x 是双层盘和可重写盘的常用值，6x 是 DVD±RW 的稳妥档，
    /// 8x 是 DVD±R 的稳妥档，16x / 24x / 48x 是 CD 盘的常见档位（驱动器不支持的档位选了也没用，
    /// 所以选择器会按驱动器上报的能力给提示）。
    public static let standardSpeeds = [1, 2, 3, 4, 6, 8, 16, 24, 48]

    /// 比 `speed` 低一档的常用倍速；已经是 1x 或更低时返回 nil。
    public static func lowerAlternative(to speed: Int) -> Int? {
        standardSpeeds.last { $0 < speed }
    }

    /// 各类介质的「稳妥上限」。
    public static func conservativeCap(for media: MediaKind) -> Int? {
        switch media {
        case .cdR: return 24
        case .cdRW: return 10
        case .cdROM: return nil
        case .dvdR, .dvdPlusR: return 8
        case .dvdRDL, .dvdPlusRDL: return 4
        case .dvdRW, .dvdPlusRW, .dvdRWDual: return 6
        case .dvdRAM: return 3
        case .dvdROM: return nil
        case .bdR, .bdRDL: return 4
        case .bdRE, .bdREDL, .bdRTriple: return 2
        case .bdROM: return nil
        case .unknown: return nil
        }
    }

    /// 驱动器没有上报倍速时的经验值。
    public static func sweetSpot(for media: MediaKind) -> Int? {
        switch media {
        case .cdR: return 16
        case .cdRW: return 8
        case .dvdR, .dvdPlusR: return 8
        case .dvdRDL, .dvdPlusRDL: return 4
        case .dvdRW, .dvdPlusRW, .dvdRWDual: return 4
        case .dvdRAM: return 2
        case .bdR, .bdRDL: return 4
        case .bdRE, .bdREDL, .bdRTriple: return 2
        case .cdROM, .dvdROM, .bdROM, .unknown: return nil
        }
    }

    public static func advise(
        media: MediaKind,
        reportedSpeeds: [Int],
        payloadBytes: Int64 = 0
    ) -> SpeedAdvice {
        let available = Array(Set(reportedSpeeds.filter { $0 > 0 })).sorted()
        let cap = conservativeCap(for: media)
        let sweet = sweetSpot(for: media)

        var recommended: Int?
        var reason: String

        if let cap = cap, let best = available.last(where: { $0 <= cap }) {
            recommended = best
            if best == available.last {
                reason = "\(media.displayName) 用驱动器支持的最高 \(best)x"
            } else {
                reason = "\(media.displayName) 建议不超过 \(cap)x，驱动器支持 \(available.map { "\($0)x" }.joined(separator: "/") )，取 \(best)x"
            }
        } else if let cap = cap, let lowest = available.first {
            // 驱动器上报的倍速全都高于稳妥上限，只能用它最低的那一档。
            recommended = lowest
            reason = "驱动器只支持 \(available.map { "\($0)x" }.joined(separator: "/") )，最低一档 \(lowest)x 也高于建议的 \(cap)x"
        } else if let cap = cap {
            recommended = sweet
            reason = "驱动器没有上报倍速，按 \(media.displayName) 的常用值取 \(sweet.map { "\($0)x" } ?? "自动")（建议不超过 \(cap)x）"
        } else if !available.isEmpty {
            // 介质类型不明（例如空白盘还没识别出来）：取中间值，别一上来就冲最高速。
            recommended = available[available.count / 2]
            reason = "驱动器支持 \(available.map { "\($0)x" }.joined(separator: "/") )，取中间值 \(recommended!)x"
        } else {
            recommended = nil
            reason = "没有介质信息，交给驱动器自动选择"
        }

        var hint: String?
        if let recommended = recommended, payloadBytes > 0 {
            let seconds = estimateDuration(payloadBytes: payloadBytes, speed: recommended, media: media)
            if seconds < 180, let slower = lowerAlternative(to: recommended) {
                hint = "内容只有 \(ByteText.human(payloadBytes))，用 \(slower)x 也只要多花不到一分钟，更稳妥。"
            }
        }

        return SpeedAdvice(
            recommended: recommended,
            reason: reason,
            conservativeCap: cap,
            available: available,
            hint: hint
        )
    }

    /// 粗估刻录耗时：数据量 ÷（1x 速率 × 倍速），再加固定开销（导入 / 导出 / 写 TOC）。
    /// 不含刻完后的校验。
    public static func estimateDuration(payloadBytes: Int64, speed: Int, media: MediaKind) -> TimeInterval {
        guard speed > 0, payloadBytes > 0 else { return 0 }
        let rate = media.bytesPerSecondAt1x * Double(speed)
        guard rate > 0 else { return 0 }
        return Double(payloadBytes) / rate + 45
    }

    /// 把秒数说成人话。
    public static func durationText(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) 秒" }
        let minutes = total / 60
        let rest = total % 60
        if minutes < 60 { return rest == 0 ? "\(minutes) 分钟" : "\(minutes) 分 \(rest) 秒" }
        let hours = minutes / 60
        return "\(hours) 小时 \(minutes % 60) 分"
    }

    /// 刻录过程中那条状态文字：「已用 X，预计还要 Y」。
    ///
    /// 剩余时间按估算值减已用时间算，估完之后会变成 0 或负数 ——
    /// 这时候不能说「预计还要 —」（`durationText(0)` 的占位符），那是「没算出来」的意思，
    /// 用户看到会以为程序坏了。收尾阶段改成「正在收尾…」。
    public static func progressText(elapsed: TimeInterval, remaining: TimeInterval) -> String {
        let used = "已用 \(durationText(elapsed))"
        if remaining <= 1 { return "\(used)，正在收尾…" }
        if remaining < 60 { return "\(used)，预计还要不到 1 分钟" }
        return "\(used)，预计还要 \(durationText(remaining))"
    }
}
