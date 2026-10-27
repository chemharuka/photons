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
// 040 改的是**单位**，不是上面任何一条实测：滑杆显示的是**位置**，位置 → 属性值是一根轴自己的
// 换算（`DetailAxis`）。默认位置就是该机身在那一根轴上的基线换算出来的位置。于是「默认位置」
// 不等于 0，同一个数字在 Leica 和 R5 上也不代表同一件事 —— 这也是文档里必须存 `nil`
// （= 停在该机身的默认位置）而不是存 50 的原因。
//
// 042 改的是**量程**，按轴分裂（Apple 头文件的口径，`CIRAWFilter.h`）：
//
//   · `luminanceNoiseReductionAmount` / `colorNoiseReductionAmount` / `sharpnessAmount`
//     是 **0…1**（h:115-122 / h:123-130 / h:131-138），滑杆 0…100，`位置 / 100`；
//   · `detailAmount` 是 **0…3**（h:148-154，「A value of 3 indicates maximum detail enhancement」），
//     滑杆 **0…30**，`位置 / 10`。
//
// 042 之前四根滑杆共用 0…100，细节因此在文档上限的 1/3 处就到顶了：全尺寸、v8、8 bit 实测，
// amount 1.0 的最大通道差 0.84 码（1017692 个采样点），amount 3.0 是 2.48 码（1605352 个）——
// 细节这根滑杆有三倍量程没被用上。`DetailTests.testTheDetailTravelOfThreeMovesThePixelsMoreThanTheOldCeilingDid`
// 每次跑都会打印这四个数，并在 amount 3.0 不再比 1.0 动得多时变红。
public struct DetailSettings: Sendable, Hashable, Codable {

    /// 四根滑杆的位置，单位是**滑杆刻度**：细节 0…30（amount 0…3），其余三根 0…100（amount 0…1）。
    /// 每根轴的行程、步长和位置 → amount 的换算都在 `DetailAxis` 上（`range` / `step` /
    /// `positionPerAmount`），这里只存位置本身。
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

    /// 042 的迁移用到的旧出行（schema-5 的细节滑杆是 0…100）。只给读文档的那一侧看，见
    /// `DetailAxis.decodeCeiling` 与 `migratePreSchema6Detail()`。
    static let legacyDetailCeiling: Double = 100

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
        self.init(luminanceNR: Self.position(in: c, .luminanceNR),
                  colorNR: Self.position(in: c, .colorNR),
                  sharpness: Self.position(in: c, .sharpness),
                  detail: Self.position(in: c, .detail))
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

    /// 读一个位置并钳到**这根轴**的出行。负数读成 `nil`（见下）。
    ///
    /// 上界用的是 `axis.decodeCeiling`，不是 `axis.range`：细节的位置在 schema-5 文档里是 0…100，
    /// 而版本号住在上一层的 `EditModel` —— 这里若直接按 0…30 钳，旧文档的 `100`（amount 1.0）
    /// 会先被压成 30 再 /10，观感就变了（amount 0.3）。所以解码只做「不破坏」的钳制，真正的迁移
    /// 与收口在 `EditModel.init(from:)`：先 `migratePreSchema6Detail()`，再 `clamped()`。
    ///
    /// 旧文档（031 的 −100…+100）也在这里落地：负值在新语义里不存在，只能意味着「比 Apple 的默认
    /// 更少」，而最接近的诚实状态就是那一根轴的默认位置 —— 所以负数读成 `nil`。
    private static func position(in c: KeyedDecodingContainer<AnyCodingKey>,
                                 _ axis: DetailAxis) -> Double? {
        guard let v = try? c.decodeIfPresent(Double.self, forKey: AnyCodingKey(axis.rawValue)),
              v.isFinite, v > 0 else { return nil }
        return min(max(v, axis.range.lowerBound), axis.decodeCeiling)
    }

    public var isIdentity: Bool { self == DetailSettings.identity }

    /// 042 — schema-5 → schema-6：细节的位置从 0…100 的出行搬到 0…30 的出行。
    ///
    /// **为什么是 `/10`**：旧位置 100 意味着 `detailAmount = 100/100 = 1.0`，新出行里 1.0 的位置是
    /// `1.0 × 10 = 10`。所以 `新位置 = 旧位置 / 10` 保持的是 **amount**，也就是保持**观感**——同一份
    /// 文档迁移前后画出同一张图（旧 100 → 新 10 → amount 1.0；旧 50 → 新 5 → amount 0.5）。
    /// 另外三根轴的出行没变，一根都不动。
    ///
    /// 唯一失真：旧出行 1 个单位是 0.01 的 amount，新出行是 0.1，所以非 10 的倍数的旧位置落到最近的
    /// 新刻度上（误差 ≤ 0.05 的 amount）。旧文档的位置都是整数（`setPosition` 量化过），这一条只影响
    /// 手改过的草稿。
    ///
    /// 注意它**不保缓存键**：`d100`（旧）与 `d10`（新）是两段不同的键文本，所以迁移后的文档会重新
    /// develop 一次 —— 那是必然的，位置换了刻度，键跟着位置走（键的**拼法**没变）。
    ///
    /// 返回是否真的动过（`false` = 没有细节位置、或它本来就 <= 0）：`EditModel` 用它决定要不要把
    /// 版本号推到 6。这一条是必需的 —— `/10` 不是幂等的，而「版本号是文档的，不是代码的」（
    /// `BlackLevelTests` 钉住旧文档重编码逐字节等于原文）意味着加载不改版本号；若一份迁移过的
    /// 文档仍以 5 保存回去，下次打开会把 10 再 /10 成 1。所以：**只有真的换算过的文档**才升版本，
    /// 没有细节的文档版本号与字节都不动。
    @discardableResult
    mutating func migratePreSchema6Detail() -> Bool {
        guard let old = detail else { return false }
        guard old.isFinite, old > 0 else { detail = nil; return false }
        let migrated = (old / 10).rounded()
        guard migrated != old else { return false }
        detail = migrated
        return true
    }

    /// 钳制到**每根轴**的行程。**不解码**，只保证映射的输入不越界。`nil` 仍是 `nil`。
    public func clamped() -> DetailSettings {
        var out = self
        for axis in DetailAxis.allCases {
            guard let v = self[axis], v.isFinite else { out[axis] = nil; continue }
            out[axis] = min(max(v, axis.range.lowerBound), axis.range.upperBound)
        }
        return out
    }

    /// 量化到每根轴的 `step` 再钳制 —— 唯一会被 commit 的形式。
    public func quantized() -> DetailSettings {
        var out = self
        for axis in DetailAxis.allCases {
            guard let v = self[axis], v.isFinite else { out[axis] = nil; continue }
            let q = (v / axis.step).rounded() * axis.step
            out[axis] = min(max(q, axis.range.lowerBound), axis.range.upperBound)
        }
        return out
    }

    // MARK: - 位置 ↔ 默认位置

    /// 面板上显示的位置：文档里的位置，或（`nil` 的那一半）这个机身的默认位置。
    public func position(_ axis: DetailAxis, in baseline: DetailBaseline) -> Double {
        self[axis] ?? axis.defaultPosition(in: baseline)
    }

    /// 一次拖动 / 一次输入的结果：量化到那根轴的 `step`、钳到它的出行，**落在默认位置上就写回 `nil`**。
    ///
    /// 写回 `nil` 是这段代码的全部意义：拖回默认位置必须让解码缓存键回到原处（命中原来那份线性
    /// 缓冲），也必须让解码器重新接管这个属性 —— 而不是把一个「碰巧等于基线」的数字写进文档。
    public mutating func setPosition(_ value: Double, _ axis: DetailAxis, in baseline: DetailBaseline) {
        guard value.isFinite else { self[axis] = nil; return }
        let v = (value / axis.step).rounded() * axis.step
        let clamped = min(max(v, axis.range.lowerBound), axis.range.upperBound)
        self[axis] = clamped == axis.defaultPosition(in: baseline) ? nil : clamped
    }

    /// 这一个值给解码缓存键 / rung identity 的部分：`dt=nr·,c30,s·,d·`。
    ///
    /// `·` 是「这个滑杆停在该机身的默认位置」（文档里的 `nil`）。`nil`（全默认）而不是空串：默认
    /// 文档必须**什么都不追加**，否则每一个已经写在磁盘上的线性缓冲、每一个 rung identity 都会
    /// 变，而像素一个都没变（与白平衡 as shot 同一条纪律）。
    public var decodeComponent: String? {
        guard !isIdentity else { return nil }
        func f(_ v: Double?) -> String { v.map { String(format: DetailAxis.positionFormat, $0) } ?? "·" }
        return "dt=nr\(f(luminanceNR)),c\(f(colorNR)),s\(f(sharpness)),d\(f(detail))"
    }

    /// 一行给检查器/报告：`NR 30 · 色彩 默认 · 细节 默认 · 锐化 60`。
    public var summary: String {
        func f(_ v: Double?) -> String { v.map { String(format: DetailAxis.positionFormat, $0) } ?? "默认" }
        return "NR \(f(luminanceNR)) · 色彩 \(f(colorNR)) · 细节 \(f(detail)) · 锐化 \(f(sharpness))"
    }

    // MARK: - slider → CIRAWFilter value

    /// 一根滑杆的位置翻译成**该属性**要赋的值；`nil` = 不要碰这个属性。
    ///
    /// 量程是**按轴**的（`CIRAWFilter.h` 的口径）：`detailAmount` 0…3（h:148-154），其余三个
    /// 0…1（h:115-138）。滑杆位置 = amount × `axis.positionPerAmount`，所以细节是 `位置 / 10`、
    /// 其余是 `位置 / 100` —— 一根轴一个换算，写在 `DetailAxis` 上，不是这里的三目运算。
    ///
    /// `baseline` 是解码器在什么都没赋值时报的值（每根轴、每台机身都不同：实测 Leica 亮度 0.0、
    /// 色度 0.5、锐化 0.5、细节 0.0；R5 锐化 1.0；Sony ARW 亮度 0.377）。因此：
    ///
    ///   · 位置 == 基线换算出来的默认位置（半个步长以内）→ `nil`，解码器保持 Apple 自己的值
    ///     （这也是「默认文档像素不变」的实现）。默认位置 = 基线 × 出行（`axis.defaultPosition`），
    ///     不是基线 × `positionPerAmount`：基线是「占满量程多少」，细节基线 0.5 的机身停在 15；
    ///   · 其余位置 → `位置 / positionPerAmount`，是一个**绝对**的属性值：0 就是 0.0，细节 30
    ///     就是 3.0，其余 100 就是 1.0。
    ///
    /// 结果一定落在 `0…axis.maxAmount`（`CIRAWFilter` 自己不钳制：实测赋 2.0 会读回 2.0）。
    public static func decodeAmount(slider: Double?, axis: DetailAxis,
                                    baseline: Double) -> Double? {
        guard let slider, slider.isFinite else { return nil }
        let range = axis.range
        let s = min(max(slider, range.lowerBound), range.upperBound)
        let b = min(max(baseline.isFinite ? baseline : 0, 0), 1)
        // 半个步长的容差：0.377 的基线显示成 38，38 就是默认位置，不是「0.38」。
        guard abs(s - b * range.upperBound) >= axis.step / 2 else { return nil }
        return min(max(s / axis.positionPerAmount, 0), axis.maxAmount)
    }

    /// The four values one develop must assign, given what the filter reports before we touch it.
    public func decodeValues(baseline: DetailBaseline) -> DetailDecodeValues {
        let c = clamped()
        return DetailDecodeValues(
            luminanceNR: Self.decodeAmount(slider: c.luminanceNR, axis: .luminanceNR,
                                           baseline: baseline.luminanceNR),
            colorNR: Self.decodeAmount(slider: c.colorNR, axis: .colorNR, baseline: baseline.colorNR),
            sharpness: Self.decodeAmount(slider: c.sharpness, axis: .sharpness,
                                         baseline: baseline.sharpness),
            detail: Self.decodeAmount(slider: c.detail, axis: .detail, baseline: baseline.detail))
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

    /// 默认位置 = 该机身在这条轴上的基线 × 这根轴的**出行**，取整到滑杆的步长。
    ///
    /// 基线是「Apple 那个属性的值」，也就是这根轴满量程的**比例**，所以位置 = 基线 × 出行：
    ///
    ///   · 0…100 的三根（满量程 amount 1）→ 基线 × 100；
    ///   · 细节（满量程 amount 3，出行 0…30）→ 基线 × 30。基线 0.5 的机身停在 15（= amount 1.5，
    ///     正好是 Apple 满量程的一半），不是 5 —— 位置只是那把尺子，基线始终是「占满量程多少」。
    ///
    /// 实测：Leica L1030433 → `0 / 50 / 0 / 50`；EOS R5（锐化基线 1.0）→ 锐化 **100**；
    /// Sony ARW（降噪基线 0.377）→ 降噪 **38**。所以四根滑杆的默认位置**不是**一个常数表，
    /// 写死 50 会让 R5 的锐化滑杆默认就削掉一半锐化、让 Sony 的降噪默认关掉。
    public func defaultPosition(in baseline: DetailBaseline) -> Double {
        let b = baseline[keyPath: baselineKeyPath]
        let raw = (b.isFinite ? b : 0) * range.upperBound
        return min(max(raw.rounded(), range.lowerBound), range.upperBound)
    }

    // MARK: - 042: per-axis travel

    /// 这根轴的滑杆出行（位置单位）：细节 **0…30**，其余三根 0…100。
    ///
    /// 分母是 Apple 头文件给的 amount 上限（见 `maxAmount`），所以「满格」在两根轴上意味着不同的
    /// amount —— 这正是 042 要的：细节以前只用到文档上限的 1/3。
    public var range: ClosedRange<Double> {
        switch self {
        case .detail: return 0...30
        case .luminanceNR, .colorNR, .sharpness: return 0...100
        }
    }

    /// 量化：1 个位置单位。细节的一格是 0.1 的 amount，其余三根是 0.01。
    ///
    /// 一根轴一个单位，是因为 `setPosition` 用量化后的位置和自己比较（拖回默认位置 = 写回 `nil`），
    /// 而位置本身必须是文档里的整数。
    public var step: Double { 1 }

    /// 面板与日志里的数字格式：整数，没有百分号（用户口径「显示 50」，不是「50%」）。
    public var format: String { Self.positionFormat }

    /// 所有轴共用的数字格式，`decodeComponent` / `summary` 直接用它（这两处不属于某一根轴）。
    public static let positionFormat = "%.0f"

    /// 这根轴在 `CIRAWFilter` 上的 amount 上限 —— **Apple 头文件的口径**：
    ///
    ///   · `detailAmount` **3**（`CIRAWFilter.h:148-154`：「A value of 3 indicates maximum detail
    ///     enhancement」）；
    ///   · `luminanceNoiseReductionAmount` / `colorNoiseReductionAmount` / `sharpnessAmount` **1**
    ///     （`h:115-122` / `h:123-130` / `h:131-138`：「A value of 1 indicates maximum …」）。
    public var maxAmount: Double {
        switch self {
        case .detail: return 3
        case .luminanceNR, .colorNR, .sharpness: return 1
        }
    }

    /// 位置 → amount 的除数：细节 10（30/3），其余 100（100/1）。`amount = 位置 / positionPerAmount`。
    public var positionPerAmount: Double { range.upperBound / maxAmount }

    /// 读文档时允许的最大位置。细节承认旧的 0…100 出行（schema-5 的文档就存在那里），因为版本号
    /// 住在上一层的 `EditModel`；`DetailSettings` 单独解码时看不到它，只能先不破坏，再由
    /// `EditModel.init(from:)` 迁移 + `clamped()` 收口。其余三根轴的旧出行与新出行相同。
    var decodeCeiling: Double { max(range.upperBound, DetailSettings.legacyDetailCeiling) }

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
