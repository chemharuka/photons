import Foundation

// MARK: - 细节 / 降噪（派单 031，数值口径按 040 归一化）
//
// 「降噪」和「细节」不是渲染后处理：它们是 **解码**参数，必须在 `CIRAWFilter` 输出像素之前
// 交给它（`luminanceNoiseReductionAmount` / `colorNoiseReductionAmount` / `sharpnessAmount` /
// `detailAmount`）。所以这一组值住在 `DecodeInputs` 里，改一个值就是一次新的 develop
// （60 MP 全尺寸 1–5 s），而不是一次新的 render。
//
// 本机实测（macOS 27.2，L1030433.dng / 908×606 缩放解码，每题一个新 `CIRAWFilter` + 新
// `CIContext` —— 复用 context 会缓存渲染结果，是这段代码最容易骗过自己的地方）：
//
//   · **回读永远等于所设**。四个属性都接受任意 Float（−0.5、2.0 原样保留，谁都不钳制），
//     所以「设进去 → 读回来」只能证明属性存在，**不能证明它影响了像素**。范围钳制必须是我们的。
//   · **不动手时的基线不是 0**：`luminanceNoiseReductionAmount` 0.000、`detailAmount` 0.000，
//     但 `colorNoiseReductionAmount` **0.500**、`sharpnessAmount` **0.500**。这正是「默认位置
//     = 不赋值」的原因：把 0 显式赋给色彩降噪会把 Apple 的默认一半降噪关掉（实测 1656830 个
//     采样变化）。
//   · **是否有效按解码器版本分裂**（同一文件）：v8 只有 `colorNoiseReductionAmount` 改变像素；
//     v8.dng 上 `luminanceNoiseReductionAmount`/`detailAmount` 生效；v9.dng 上
//     `luminanceNoiseReductionAmount`/`sharpnessAmount` 生效。默认走 v8（D2′），因此在本机
//     的 Leica 样张上「降噪/细节/锐化」三根滑杆**会**改变缓存键与解码调用，但 v8 不改变像素 ——
//     这是 Apple 解码器的行为，不是接线错误，`DetailTests` 把这条实测钉住，不让它悄悄变。
//
// 040 改的是**单位**，不是上面任何一条实测：滑杆显示 0…100（= 属性值 × 100），默认位置就是
// 该机身在那一根轴上的基线 × 100。于是「默认位置」不等于 0，同一个数字在 Leica 和 R5 上也不
// 代表同一件事 —— 这也是文档里必须存 `nil`（= 停在该机身的默认位置）而不是存 50 的原因。
public struct DetailSettings: Sendable, Hashable, Codable {

    /// 四根滑杆的位置，单位是**滑杆刻度** 0…100（属性值 = 位置 / 100）。
    ///
    /// `nil` = 「停在这个机身的默认位置」，不是 0：
    ///
    ///   · 它是 031「不碰 Apple 的默认降噪」那条纪律在归一化之后的唯一表达方式 ——
    ///     `colorNoiseReductionAmount` 的基线是 0.500，默认位置是 **50**，把 0 写进去等于关掉
    ///     Apple 的一半降噪；
    ///   · 而且它不能存成一个数字：默认位置是**机身**的属性（Leica 锐化 50、R5 锐化 100、
    ///     Sony 降噪 38），文档存 50 就等于把 Leica 的基线写死进每一份文档。
    public var luminanceNR: Double?
    public var colorNR: Double?
    public var sharpness: Double?
    public var detail: Double?

    /// 四根滑杆都不动 = 四个 `nil` = 与 031 之前的解码**逐字节相同**。
    public static let identity = DetailSettings()

    /// 四根滑杆的行程。040 起没有负半边（031 的 −100…+100 已删除，旧的负值在读文档时被钳到 0）。
    public static let range: ClosedRange<Double> = 0...100
    /// 滑杆量化：1 个单位（属性值 0.01）。缩到手再 commit，所以文档里只存整数。
    public static let step: Double = 1
    /// 面板与日志里的数字格式：整数，没有百分号（用户口径「显示 50」，不是「50%」）。
    public static let format = "%.0f"

    public init(luminanceNR: Double? = nil, colorNR: Double? = nil,
                sharpness: Double? = nil, detail: Double? = nil) {
        self.luminanceNR = luminanceNR
        self.colorNR = colorNR
        self.sharpness = sharpness
        self.detail = detail
    }

    /// 按轴取放，供面板与 `DetailAxis` 共用（`keyPath` 只有一份）。
    public subscript(_ axis: DetailAxis) -> Double? {
        get { self[keyPath: axis.keyPath] }
        set { self[keyPath: axis.keyPath] = newValue }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.init(luminanceNR: Self.position(in: c, "luminanceNR"),
                  colorNR: Self.position(in: c, "colorNR"),
                  sharpness: Self.position(in: c, "sharpness"),
                  detail: Self.position(in: c, "detail"))
    }

    /// 文档里的每个字段都必须有显式默认值（D9）：缺键 = `nil` = 默认位置，不是解码失败、也不是 NaN。
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        // `nil` 写成**缺键**，不是 `null`：一份从没碰过面板的文档因此连这四个键都没有。
        try c.encodeIfPresent(luminanceNR, forKey: AnyCodingKey("luminanceNR"))
        try c.encodeIfPresent(colorNR, forKey: AnyCodingKey("colorNR"))
        try c.encodeIfPresent(sharpness, forKey: AnyCodingKey("sharpness"))
        try c.encodeIfPresent(detail, forKey: AnyCodingKey("detail"))
    }

    /// 读一个位置并钳到 0…100。
    ///
    /// 旧文档（031 的 −100…+100）在这里落地：负值在新语义里不存在，只能意味着「比 Apple 的默认
    /// 更少」，而最接近的诚实状态就是那一根轴的默认位置 —— 所以负数读成 `nil`，正数读成它自己
    /// （被钳到 100）。文档还没发布，没有迁移代码；这条只是让旧的本地草稿不会悄悄关掉降噪。
    private static func position(in c: KeyedDecodingContainer<AnyCodingKey>, _ name: String) -> Double? {
        guard let v = try? c.decodeIfPresent(Double.self, forKey: AnyCodingKey(name)),
              v.isFinite, v > 0 else { return nil }
        return min(max(v, range.lowerBound), range.upperBound)
    }

    public var isIdentity: Bool { self == DetailSettings.identity }

    /// 钳制到滑杆行程。**不解码**，只保证映射的输入不越界。`nil` 仍是 `nil`。
    public func clamped() -> DetailSettings {
        func c(_ v: Double?) -> Double? {
            guard let v, v.isFinite else { return nil }
            return min(max(v, Self.range.lowerBound), Self.range.upperBound)
        }
        return DetailSettings(luminanceNR: c(luminanceNR), colorNR: c(colorNR),
                              sharpness: c(sharpness), detail: c(detail))
    }

    /// 量化到 `step`（1 个单位）再钳制 —— 唯一会被 commit 的形式。
    public func quantized() -> DetailSettings {
        func q(_ v: Double?) -> Double? {
            guard let v, v.isFinite else { return nil }
            return (v / Self.step).rounded() * Self.step
        }
        return DetailSettings(luminanceNR: q(luminanceNR), colorNR: q(colorNR),
                              sharpness: q(sharpness), detail: q(detail)).clamped()
    }

    // MARK: - 位置 ↔ 默认位置

    /// 面板上显示的位置：文档里的位置，或（`nil` 的那一半）这个机身的默认位置。
    public func position(_ axis: DetailAxis, in baseline: DetailBaseline) -> Double {
        self[axis] ?? axis.defaultPosition(in: baseline)
    }

    /// 一次拖动 / 一次输入的结果：量化到 1 个单位、钳到 0…100，**落在默认位置上就写回 `nil`**。
    ///
    /// 写回 `nil` 是这段代码的全部意义：拖回默认位置必须让解码缓存键回到原处（命中原来那份线性
    /// 缓冲），也必须让解码器重新接管这个属性 —— 而不是把一个「碰巧等于基线」的数字写进文档。
    public mutating func setPosition(_ value: Double, _ axis: DetailAxis, in baseline: DetailBaseline) {
        guard value.isFinite else { self[axis] = nil; return }
        let v = (value / Self.step).rounded() * Self.step
        let clamped = min(max(v, Self.range.lowerBound), Self.range.upperBound)
        self[axis] = clamped == axis.defaultPosition(in: baseline) ? nil : clamped
    }

    /// 这一个值给解码缓存键 / rung identity 的部分：`dt=nr·,c30,s·,d·`。
    ///
    /// `·` 是「这个滑杆停在该机身的默认位置」（文档里的 `nil`）。`nil`（全默认）而不是空串：默认
    /// 文档必须**什么都不追加**，否则每一个已经写在磁盘上的线性缓冲、每一个 rung identity 都会
    /// 变，而像素一个都没变（与白平衡 as shot 同一条纪律）。
    public var decodeComponent: String? {
        guard !isIdentity else { return nil }
        func f(_ v: Double?) -> String { v.map { String(format: Self.format, $0) } ?? "·" }
        return "dt=nr\(f(luminanceNR)),c\(f(colorNR)),s\(f(sharpness)),d\(f(detail))"
    }

    /// 一行给检查器/报告：`NR 30 · 色彩 默认 · 细节 默认 · 锐化 60`。
    public var summary: String {
        func f(_ v: Double?) -> String { v.map { String(format: Self.format, $0) } ?? "默认" }
        return "NR \(f(luminanceNR)) · 色彩 \(f(colorNR)) · 细节 \(f(detail)) · 锐化 \(f(sharpness))"
    }

    // MARK: - slider → CIRAWFilter value

    /// 一根滑杆的位置翻译成**该属性**要赋的值；`nil` = 不要碰这个属性。
    ///
    /// `baseline` 是解码器在什么都没赋值时报的值（每根轴、每台机身都不同：实测 Leica 亮度 0.0、
    /// 色度 0.5、锐化 0.5、细节 0.0；R5 锐化 1.0；Sony ARW 亮度 0.377）。因此：
    ///
    ///   · 位置 == 基线 × 100（半个步长以内）→ `nil`，解码器保持 Apple 自己的值（这也是
    ///     「默认文档像素不变」的实现）；
    ///   · 其余位置 → `位置 / 100`，是一个**绝对**的属性值：0 就是 0.0，100 就是 1.0。
    ///
    /// 结果一定落在 0…1（`CIRAWFilter` 自己不钳制：实测赋 2.0 会读回 2.0）。
    public static func decodeAmount(slider: Double?, baseline: Double) -> Double? {
        guard let slider, slider.isFinite else { return nil }
        let s = min(max(slider, range.lowerBound), range.upperBound)
        let b = min(max(baseline.isFinite ? baseline : 0, 0), 1)
        // 半个步长的容差：0.377 的基线显示成 38，38 就是默认位置，不是「0.38」。
        guard abs(s - b * range.upperBound) >= step / 2 else { return nil }
        return min(max(s / range.upperBound, 0), 1)
    }

    /// The four values one develop must assign, given what the filter reports before we touch it.
    public func decodeValues(baseline: DetailBaseline) -> DetailDecodeValues {
        let c = clamped()
        return DetailDecodeValues(
            luminanceNR: Self.decodeAmount(slider: c.luminanceNR, baseline: baseline.luminanceNR),
            colorNR: Self.decodeAmount(slider: c.colorNR, baseline: baseline.colorNR),
            sharpness: Self.decodeAmount(slider: c.sharpness, baseline: baseline.sharpness),
            detail: Self.decodeAmount(slider: c.detail, baseline: baseline.detail))
    }
}

// MARK: - the four axes

/// 四根滑杆的身份：标题、文档字段，以及「默认位置」这一条唯一的算术。
///
/// 面板不该自己算 50 或 100 —— 默认位置是**机身**的属性（`DetailBaseline`），所以它只有一个
/// 定义处，UI、测试和 CLI 探针都从这里取。
public enum DetailAxis: String, CaseIterable, Sendable, Hashable {

    case luminanceNR
    case colorNR
    case detail
    case sharpness

    /// 面板上的行标题（也就是 commit 时的 undo 标签）。
    public var title: String {
        switch self {
        case .luminanceNR: return "降噪"
        case .colorNR: return "色彩降噪"
        case .detail: return "细节"
        case .sharpness: return "锐化"
        }
    }

    /// 这个轴在 `CIRAWFilter` 上的属性名 —— 报错和探针都用它。
    public var propertyName: String {
        switch self {
        case .luminanceNR: return "luminanceNoiseReductionAmount"
        case .colorNR: return "colorNoiseReductionAmount"
        case .detail: return "detailAmount"
        case .sharpness: return "sharpnessAmount"
        }
    }

    public var keyPath: WritableKeyPath<DetailSettings, Double?> {
        switch self {
        case .luminanceNR: return \.luminanceNR
        case .colorNR: return \.colorNR
        case .detail: return \.detail
        case .sharpness: return \.sharpness
        }
    }

    var baselineKeyPath: KeyPath<DetailBaseline, Double> {
        switch self {
        case .luminanceNR: return \.luminanceNR
        case .colorNR: return \.colorNR
        case .detail: return \.detail
        case .sharpness: return \.sharpness
        }
    }

    /// 默认位置 = 该机身在这条轴上的基线 × 100，取整到滑杆的步长。
    ///
    /// 实测：Leica L1030433 → `0 / 50 / 0 / 50`；EOS R5（锐化基线 1.0）→ 锐化 **100**；
    /// Sony ARW（降噪基线 0.377）→ 降噪 **38**。所以四根滑杆的默认位置**不是**一个常数表，
    /// 写死 50 会让 R5 的锐化滑杆默认就削掉一半锐化、让 Sony 的降噪默认关掉。
    public func defaultPosition(in baseline: DetailBaseline) -> Double {
        let b = baseline[keyPath: baselineKeyPath]
        let raw = (b.isFinite ? b : 0) * DetailSettings.range.upperBound
        return min(max(raw.rounded(), DetailSettings.range.lowerBound), DetailSettings.range.upperBound)
    }

    /// 一条轴的四元组，按面板顺序（降噪 / 色彩降噪 / 细节 / 锐化）。
    public static let panelOrder = DetailAxis.allCases
}

/// What `CIRAWFilter` reports for the four axes **before** a document assigns anything.
///
/// Not a constant: it is per file and per decoder version, and it is what puts the default position
/// of each slider on the body's own numbers instead of a nominal 0.5 or a hard-coded 50.
public struct DetailBaseline: Sendable, Equatable {

    public var luminanceNR: Double
    public var colorNR: Double
    public var sharpness: Double
    public var detail: Double

    /// The four values measured on this machine with nothing assigned (Leica L1030433). Used by the
    /// tests and by any caller that has no filter to ask; a develop always reads the live filter.
    public static let measured = DetailBaseline(luminanceNR: 0, colorNR: 0.5,
                                               sharpness: 0.5, detail: 0)

    public init(luminanceNR: Double, colorNR: Double, sharpness: Double, detail: Double) {
        self.luminanceNR = luminanceNR
        self.colorNR = colorNR
        self.sharpness = sharpness
        self.detail = detail
    }

    /// The four slider positions this body sits at with nothing assigned: `0 / 50 / 0 / 50` on a
    /// Leica, `… / 100` for sharpness on an R5, `38 / …` for luminance NR on a Sony ARW.
    public var defaultPositions: [DetailAxis: Double] {
        Dictionary(uniqueKeysWithValues: DetailAxis.allCases.map { ($0, $0.defaultPosition(in: self)) })
    }
}

/// One develop's four assignments; `nil` means "leave that property alone".
public struct DetailDecodeValues: Sendable, Equatable {

    public var luminanceNR: Double?
    public var colorNR: Double?
    public var sharpness: Double?
    public var detail: Double?

    public init(luminanceNR: Double? = nil, colorNR: Double? = nil,
                sharpness: Double? = nil, detail: Double? = nil) {
        self.luminanceNR = luminanceNR
        self.colorNR = colorNR
        self.sharpness = sharpness
        self.detail = detail
    }

    /// Nothing to assign: the filter keeps Apple's own four values (the default document).
    public var isEmpty: Bool {
        luminanceNR == nil && colorNR == nil && sharpness == nil && detail == nil
    }

    /// `nr=0.30 c=– sh=– d=–` for a log line or a test failure message.
    public var summary: String {
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "–" }
        return "nr=\(f(luminanceNR)) c=\(f(colorNR)) sh=\(f(sharpness)) d=\(f(detail))"
    }
}
