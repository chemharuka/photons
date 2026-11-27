import PhotonsLocalization
import AppKit
import Observation
import PhotonsCore
import PhotonsCatalog

/// 572 — 自动调整从 `LoupeController` 搬出来的家：自动裁剪、自动黑电平、自动明暗、自动白平衡、
/// 自动颜色，以及 448 的全档等待门与两个复合动作。
///
/// 这一单是**纯搬家**：注释、常量、时序都没改写；被搬的代码原来直接读 `LoupeController` 的
/// `frameState` / `session` / `frameSource` 等成员，现在都经 `host` 反向引用读同一份值。目标不是
/// 设计终态 —— 下一单再把需要的事实收成一个 `Frame` 值类型，去掉这个反向引用。
@MainActor
public final class AutoAdjustService {

    /// 572: the move is mechanical; the next lane removes the host back-reference.
    weak var host: LoupeController?

    init(host: LoupeController? = nil) {
        self.host = host
    }

    /// The 裁切 card's 「自动裁剪」 button. One document write (inside `CropToolController.autoCrop`),
    /// then the overlay and the picture are refreshed — the frame the user sees is the box the write
    /// stored, not a draft waiting for 应用.
    @discardableResult
    public func autoCrop() -> Bool {
        guard let host, let session = host.session, session.mode == .loupe,
              session.anchorID != nil else {
            NSSound.beep()
            return false
        }
        guard host.cropTool.autoCrop() else { return false }
        host.refreshCropTool()
        host.requestEditRender()
        return true
    }
    // MARK: 448 — 自动动作要等全档 RAW 解码

    /// `@Observable` so the inspector's two 自动 buttons can disable themselves while the click is
    /// waiting for the full rung. `LoupeController` is an `NSViewController`, not an observable model,
    /// so this tiny holder is the existing observation bridge for exactly this one bit.
    @Observable
    public final class AutoAdjustWaitState {
        public var isWaitingForDecode = false
        public init() {}
    }

    public let autoAdjustWait = AutoAdjustWaitState()
    /// The wait spelled the way the task names it. The observable bit above is what SwiftUI reads.
    public var isWaitingForDecode: Bool { autoAdjustWait.isWaitingForDecode }

    /// The click that is queued behind the full-rung decode. **Only the newest click survives** — a
    /// second press while waiting replaces this value and asks for no second development.
    public enum PendingAuto: Equatable, Sendable {
        case light
        case black
        case whiteBalance
        case color
        case all
        case allAuto
    }
    public private(set) var pendingAuto: PendingAuto?

    /// What the 448 acceptance reads: the photo whose graph the 明暗 measurement actually ran through.
    /// `nil` until an `autoLight()` measurement has happened.
    private(set) var lastAutoLightSampleIdentityForTesting: String?

    /// 453 — the `blackOffset` the last `AutoLight.plan` measurement was handed. The composite action
    /// stages the new black level before measuring 明暗, and this is the seam that proves it.
    private(set) var lastAutoLightBlackOffsetInputForTesting: Double?

    /// 453 — the 自动颜色 metrics the last run measured. `AutoColor` only raises, so a picture already
    /// above the calibrated target legitimately yields 0; this lets a test see that the step ran.
    private(set) var lastAutoColorMetricsForTesting: AutoColor.Metrics?

    /// 498 — the full two-degree-of-freedom plan (vibrance + saturation + what the guards did).
    private(set) var lastAutoColorPlanForTesting: AutoColor.Plan?

    /// 498 — why a press wrote nothing. `nil` means the last press did move (or none has run yet).
    /// A menu item reads this for its tooltip so a legitimate 0 + 0 is explained instead of silent.
    enum AutoColorNoOpReason: Equatable, Sendable {
        case tooGrey
        case alreadySaturated
    }
    private(set) var lastAutoColorNoOpReasonForTesting: AutoColorNoOpReason?

    /// 498 — how many fixed-point passes the last composite actually used (1…4). The owner asked for
    /// the measured number in the report.
    private(set) var lastAutoCompositePassCountForTesting = 0

    /// 498 — one 自动颜色 decision: both slider totals and the plan behind them.
    struct ColorCandidate: Equatable, Sendable {
        var vibrance: Double
        var saturation: Double
        var plan: AutoColor.Plan
    }

    /// 448 ④ — the frame on screen is the **full rung of the current anchor**. Same spelling as
    /// `measureHistogramNow`'s reuse gate: the photo and the document's decode inputs both name the
    /// rung, and the identity must be the rung's (`-s1.0`), not a preview's or the previous photo's.
    private func anchorFrameIsFullRung() -> Bool {
        guard let host else { return false }
        let frame = host.frameState
        guard frame.graph != nil, frame.scale == Double(DecodeLadder.fullScale) else { return false }
        guard let anchor = currentAnchorBaseIdentity(),
              let inputs = currentAnchorDecodeInputs() else { return false }
        guard frame.identity == anchor else { return false }
        let identity = LoupeController.rungIdentity(anchor, inputs: inputs)
        return frame.graphIdentity == "\(identity)-s\(DecodeLadder.fullScale)"
    }

    /// The anchor's photo identity (`contentHash|assetID`, or the harness's frame-source identity).
    private func currentAnchorBaseIdentity() -> String? {
        guard let host else { return nil }
        if let source = host.frameSource { return source.identity }
        guard let session = host.session, session.mode == .loupe,
              let asset = session.anchorAsset else { return nil }
        return host.ladderIdentity(asset)
    }

    /// The decode inputs of the document the anchor owns — what makes a rung *this* document's.
    private func currentAnchorDecodeInputs() -> DecodeInputs? {
        guard let host else { return nil }
        if let source = host.frameSource { return source.edit.decodeInputs }
        guard let session = host.session, session.mode == .loupe else { return nil }
        return session.edit.decodeInputs
    }

    /// True when this click must wait. A controller with **no anchor** is the URL-only unit seam
    /// (`AutoLightCardTests` / `BlackLevelCardTests` develop a file and call the action directly);
    /// the app always has an anchor in the loupe, so this legacy path cannot hide the gate there.
    private func autoAdjustMustWait() -> Bool {
        guard currentAnchorBaseIdentity() != nil else { return false }
        return !anchorFrameIsFullRung()
    }

    /// Queue the newest click and make sure a full-rung frame is on its way. The request goes through
    /// the ordinary viewport path (`renderFrame → requestDevelopment`), which is already coalesced and
    /// already asks for `DecodeLadder.fullScale` — no second decoder and no hand-built job.
    private func queuePendingAuto(_ action: PendingAuto) {
        let alreadyWaiting = pendingAuto != nil
        pendingAuto = action
        autoAdjustWait.isWaitingForDecode = true
        if !alreadyWaiting { host?.requestViewportRender(cacheable: true) }
    }

    /// 448 ④ — a different photo, leaving the loupe, or a document change while the click waits.
    func clearPendingAuto() {
        guard pendingAuto != nil else { return }
        pendingAuto = nil
        autoAdjustWait.isWaitingForDecode = false
    }

    /// Called from `presentCanvas` after the frame really reached the layer. The gate is checked again
    /// here: a preview frame presented while waiting changes nothing, and a full frame of another photo
    /// can never run a click that belonged to this one.
    func runPendingAutoIfReady() {
        guard let pending = pendingAuto, anchorFrameIsFullRung() else { return }
        pendingAuto = nil
        autoAdjustWait.isWaitingForDecode = false
        switch pending {
        case .light:
            _ = autoLight()
        case .black:
            _ = autoBlackOffset()
        case .whiteBalance:
            _ = autoWhiteBalance()
        case .color:
            _ = autoColor()
        case .all:
            _ = autoDevelop()
        case .allAuto:
            _ = autoAll()
        }
    }
    // MARK: 自动黑电平 (2026-10-28)

    /// 派单 105: the measurement-side decode, replaceable by the fallback test.
    ///
    /// Production leaves this `nil` and asks `RAWDecoder.decodeForMeasurement`; the test injects a
    /// throwing closure to prove that `autoBlackOffset()` still returns a value (from the display
    /// buffer) when the measurement decode fails.
    var measurementDecodeForTesting: ((URL, Double) throws -> LinearImage)?

    /// 自动黑电平：把解码缓冲的最小通道值拉到 0（一次文档写、一条历史）。返回写进去的值；没有解码图时 nil。
    ///
    /// The buffer is the **decoded** scene-linear one (`LinearImage.rgba`), not the rendered frame:
    /// S1's `blackOffset` is added before the gain, so this is the one place the shift is still
    /// additive on the samples. `−min` is rounded **up** to the document's 1/1000 grid — a half tick
    /// down would leave the darkest sample negative, which is exactly what the user asked to remove.
    /// A value already at zero (or any buffer that is already non-negative) is a no-op.
    ///
    /// 派单 105: the value is measured on a **measurement-only decode** (`decodeForMeasurement`,
    /// sharpening / colour NR / detail / lens correction all off), not on the display buffer, whose
    /// untouched Apple defaults (sharpness 0.5, colour NR 0.5) can manufacture a dozen single-pixel
    /// overshoots at strong edges. When that decode fails — or there is no source URL, as with the
    /// synthetic buffers the tests use — the display buffer is measured instead, with one log line.
    /// The estimator **is the minimum** — 用户 2026-10-29 14:20 明确「不加守卫」：不做任何按像素数
    /// 切换估计量的分支。干净解码之后最负的那颗就是电平该补的量，哪怕只有一颗。
    @discardableResult
    public func autoBlackOffset() -> Double? {
        guard let session = host?.session, let offset = blackOffsetCandidate() else { return nil }
        session.applyEdit { $0.light.blackOffset = offset }
        host?.requestEditRender()
        session.commitEdit(label: Loc.t("黑电平 · 自动"), coalesce: false)
        return offset
    }

    /// 453 — 自动黑电平的**测量**，不写文档、不提交。`autoBlackOffset()` 与 `autoDevelop()` 共用。
    /// `nil` 表示这一步该跳过（无图 / 门未满足 / 值未变）。
    public func blackOffsetCandidate() -> Double? {
        guard let host else { return nil }
        let frame = host.frameState
        guard let session = host.session, session.mode == .loupe else { return nil }
        // 448 — the click waits for the anchor's full rung. Until then the buffer on screen may be the
        // 0.5 preview (or the previous photo): measuring it is the reported "采到缩略图缓存".
        if autoAdjustMustWait() {
            queuePendingAuto(.black)
            return nil
        }
        guard let display = frame.image else { return nil }

        let measured: LinearImage
        if let url = frame.url, let image = try? measurementImage(url) {
            measured = image
        } else {
            print("AUTO BLACK · measurement decode failed, falling back")
            measured = display
        }

        let candidates = measured.blackCandidates(sampleStride: 5)
        let rawValue = candidates.min
        let offset = Self.autoBlackOffset(for: rawValue)
        print(String(format: Loc.t("AUTO BLACK · min %.6f · 候选 %d → %.4f"),
                     candidates.min, candidates.count, offset))
        if offset == LightGroup.blackOffsetRange.lowerBound
            || offset == LightGroup.blackOffsetRange.upperBound {
            print(String(format: Loc.t("AUTO BLACK · min %.6f → offset 钳到 ±0.01"), candidates.min))
        }
        guard abs(offset - session.edit.light.blackOffset) >= 1e-9 else { return nil }
        return offset
    }

    private func measurementImage(_ url: URL) throws -> LinearImage {
        if let measurementDecodeForTesting {
            return try measurementDecodeForTesting(url, 0.5)
        }
        return try RAWDecoder().decodeForMeasurement(url, scale: 0.5)
    }

    /// The value `autoBlackOffset()` measures: the minimum when there are enough genuinely extreme
    /// candidates for it to mean something, otherwise the candidate set's 0.1st percentile.
    ///
    /// 派单 105's guard: even at a measurement decode a few single-pixel overshoots can survive, and
    /// one of them must not decide the whole black point. Fewer than 50 candidates below −0.008 is
    /// treated as "noise, not signal".
    /// 估计量就是最小值（105 复核：用户要求不加守卫）。
    static func autoBlackRawValue(min: Float, p001: Float, extremeCount: Int) -> Float {
        _ = p001
        _ = extremeCount
        return min
    }

    /// The value `autoBlackOffset()` writes, as a pure function (the tests ask it without a decode).
    static func autoBlackOffset(for minChannel: Float) -> Double {
        let raw = minChannel >= 0 ? 0 : -Double(minChannel)
        let stepped = (raw * 1000).rounded(.up) / 1000
        return Swift.min(Swift.max(stepped, LightGroup.blackOffsetRange.lowerBound),
                         LightGroup.blackOffsetRange.upperBound)
    }
    // MARK: 自动调节 (422)

    /// 422 — the five reverse gates the algorithm is tested through. `AutoLight.Gates()` in production;
    /// a test sets one and shows the assertion that guards it going red. Never part of a key or a
    /// document, and read once per run.
    nonisolated(unsafe) static var autoLightGates = AutoLight.Gates()

    /// 明暗 · 自动 — one press writes the seven 明暗 fields and **one** history entry.
    ///
    /// The five steps live in `AutoLight.plan` (pure, testable without a GPU); this is the wiring: the
    /// frame's own graph is what measures, so the numbers are the ones the picture on screen is made of.
    /// `light.blackOffset` is **read, never written** — 黑电平 owns it, and step 4 only cancels its lift.
    ///
    /// Returns the plan (so a test can argue with every number it used), or `nil` when there is no
    /// frame to measure or when the plan equals the document it started from (a second press on a
    /// settled picture is a no-op, exactly like 自动黑电平).
    @discardableResult
    public func autoLight() -> AutoLight.Plan? {
        guard let session = host?.session, let plan = lightPlanCandidate() else { return nil }
        session.applyEdit { $0 = plan.apply(to: $0) }
        host?.requestEditRender()
        session.commitEdit(label: Loc.t("明暗 · 自动"), coalesce: false)
        return plan
    }

    /// 453 — 自动明暗的**测量**，不写文档、不提交。`autoLight()` 与 `autoDevelop()` 共用。
    ///
    /// `from` lets 复合动作 measure the document that *already carries the new black offset* without
    /// writing it first: order 黑电平 → 明暗 is load-bearing (`AutoLight` step 4 cancels the lift), and
    /// measuring the staged copy keeps the ordering while still committing exactly once. Standalone,
    /// this is still the very same call the card has always made: `AutoLight.plan(for: session.edit,`
    /// `gates:)`; the composite only substitutes the staged document.
    public func lightPlanCandidate() -> AutoLight.Plan? {
        lightPlanCandidate(from: nil)
    }

    func lightPlanCandidate(from document: EditModel?) -> AutoLight.Plan? {
        guard let host else { return nil }
        let frame = host.frameState
        guard let session = host.session, session.mode == .loupe else { return nil }
        // 448 — same gate as 自动黑电平 / 自动白平衡: never measure a preview rung or the previous
        // photo's graph. The click is queued and a full-rung frame is requested through the normal
        // viewport path; `runPendingAutoIfReady` calls this function again when that frame lands.
        if autoAdjustMustWait() {
            queuePendingAuto(.light)
            return nil
        }
        guard let graph = measurementGraph(from: frame, document: document ?? session.edit) else {
            return nil
        }
        lastAutoLightSampleIdentityForTesting = frame.graphPhoto ?? frame.identity
        let source = document ?? session.edit
        lastAutoLightBlackOffsetInputForTesting = source.light.blackOffset
        let gates = Self.autoLightGates
        let plan: AutoLight.Plan
        do {
            plan = try AutoLight.plan(for: source, gates: gates) { document in
                try graph.measureAutoLightSample(document)
            }
        } catch {
            print("AUTO LIGHT · measurement failed: \(error)")
            return nil
        }
        print(String(format: "AUTO LIGHT · p99 %.4f → EV %+.2f → p99 %.4f (p99.9/p99 %.2f, 回退 %d) · "
                     + "高光 %.0f (损失 %.2f%% / 门 %.1f%%) · 白色 %.0f · "
                     + "中间调 %.0f 阴影 %.0f · 黑色 %.0f (削底 %.2f%%) · 对比 %.0f · %d renders %.0f ms",
                     plan.report.baseP99, plan.report.exposureEV, plan.report.p99AfterExposure,
                     plan.report.p999OverP99AfterExposure, plan.report.exposureBackstops,
                     plan.highlights, plan.report.textureLoss * 100,
                     plan.report.textureLossThreshold * 100, plan.whites,
                     plan.midtones, plan.shadows, plan.blacks,
                     plan.report.clippedLowAfterBlacks * 100, plan.contrast,
                     plan.report.renderCount, plan.report.milliseconds))
        let next = plan.apply(to: source)
        guard next.light != source.light else { return nil }
        return plan
    }
    /// 571-A — a **one-shot** graph for a synchronous measurement on the main thread.
    ///
    /// It is built from the same resident whole-picture buffer and the same document inputs as the
    /// frame on screen, but it is deliberately **not** `frame.graph`: that object is driven by
    /// `photons.loupe.render` (`renderBackdrop`), and `RenderGraph.render` is not safe to call from two
    /// threads at once. Measuring 明暗/颜色 through the frame's graph was the 571-A crash (main-thread
    /// `AutoLight.plan` racing the render queue). The pixels and the edit are unchanged, so the
    /// numbers are still this photo's and 448's one-write/one-history timing does not move.
    private func measurementGraph(from frame: LoupeController.FrameSnapshot,
                                  document: EditModel) -> RenderGraph? {
        guard let image = frame.image else { return nil }
        let identity = frame.graphIdentity ?? "\(frame.identity ?? "measurement")-s\(frame.scale)"
        return try? RenderGraph(input: RenderInput(
            image: image, identity: identity, sourceURL: frame.url,
            whiteBalance: document.decodeInputs.whiteBalance,
            asShotPair: frame.capabilities?.asShotWhiteBalance ?? .asShot))
    }
    /// 448 — 自动白平衡 through the same full-rung gate. The measurement is the one the panel's
    /// 「预设 → 自动」 has always used (`averageSceneRGB` on the resident buffer, then the grey-world
    /// solve and one commit); only *when* it runs changed.
    @discardableResult
    public func autoWhiteBalance() -> WhiteBalanceSolve? {
        guard let host, let session = host.session, session.mode == .loupe else { return nil }
        if autoAdjustMustWait() {
            queuePendingAuto(.whiteBalance)
            return nil
        }
        guard let average = host.averageSceneRGB() else { return nil }
        let commands = WhiteBalanceCommands(
            session: session,
            asShot: host.asShotWhiteBalance ?? session.capabilities?.asShotWhiteBalance)
        return commands.applyAuto(average)
    }
    // MARK: 自动调整 (453)

    /// 453/498 — 自动颜色：measure the picture's OKLab chroma and decide both sliders.
    ///
    /// 518 removed the old `colorVibranceCandidate()` Double wrapper (and its `from:` overload): it had
    /// no callers and its "only raise" `guard` was dead policy sitting beside the live one. The live
    /// decision is `colorCandidate`, which carries both sliders and the plan's verdict.
    func colorCandidate() -> ColorCandidate? {
        colorCandidate(from: nil)
    }

    /// **498's two-degree-of-freedom decision.** `p50 → vibrance`, `p95 → saturation`, both measured
    /// on the same scene-linear sample and both measured against the document's current slider values
    /// (so the second press on a settled picture is a true no-op).
    func colorCandidate(from document: EditModel?) -> ColorCandidate? {
        guard let host else { return nil }
        let frame = host.frameState
        guard let session = host.session, session.mode == .loupe else { return nil }
        if autoAdjustMustWait() {
            queuePendingAuto(.color)
            return nil
        }
        guard let graph = measurementGraph(from: frame, document: document ?? session.edit) else {
            return nil
        }
        let source = document ?? session.edit
        // 2026-11-27（用户口径：「自动色彩的测量应当设置饱和度/自然饱和度为 0，然后再测量。
        // 现在如果饱和度手动 +20，自动色彩就不会修改了」）：测量必须在**两根归零**的文档上做。
        // 否则测出来的 p50/p95 已经含用户手改的那 +20，plan 说「够饱和」，下面的 `max(source…)`
        // 又把它钉在 20 以上 ⇒ 自动色彩永远是个 no-op。归零只用于测量与内部迭代，写回的仍是
        // **绝对**值（自动色彩是绝对求解，不是叠加）。
        var measuring = source
        measuring.color.saturation = 0
        measuring.color.vibrance = 0
        let initialMetrics: AutoColor.Metrics
        do {
            initialMetrics = AutoColor.metrics(from: try graph.measureLinearSample(measuring))
        } catch {
            print("AUTO COLOR · measurement failed: \(error)")
            return nil
        }
        lastAutoColorMetricsForTesting = initialMetrics

        // Measure → plan → re-measure on the staged document, up to three passes. 511's plan is a
        // **bounded, damped addition**, not an absolute solve: the second pass sees the first lift
        // in the picture, so its whole-unit lift is ≤ the value already staged and `max(floor, …)`
        // returns it. This loop still closes the GPU frame vs Double replay gap before the single
        // history write, so 连点两次 finds a true fixed point.
        var metrics = initialMetrics
        // 测量与迭代都从 **0/0** 起步（见上面 `measuring` 的理由）；`source` 的手改值只在最后
        // 用来判断「写回的值与文档相同就什么都不做」。
        var vibrance = 0.0
        var saturation = 0.0
        var plan = AutoColor.plan2D(metrics, currentVibrance: vibrance,
                                    currentSaturation: saturation,
                                    floorVibrance: 0,
                                    floorSaturation: 0)
        var finalMetrics = metrics
        for _ in 0 ..< 3 {
            let nextV = plan.vibrance
            let nextS = plan.saturation
            guard abs(nextV - vibrance) > 1e-9
                    || abs(nextS - saturation) > 1e-9 else { break }
            vibrance = nextV
            saturation = nextS
            var staged = measuring
            staged.color.vibrance = vibrance
            staged.color.saturation = saturation
            guard let sample = try? graph.measureLinearSample(staged) else { break }
            metrics = AutoColor.metrics(from: sample)
            finalMetrics = metrics
            plan = AutoColor.plan2D(metrics, currentVibrance: vibrance,
                                    currentSaturation: saturation,
                                    floorVibrance: 0,
                                    floorSaturation: 0)
        }
        // Report the plan that matches the values actually written, with the last guard diagnostics.
        var reported = plan
        reported.vibrance = vibrance
        reported.saturation = saturation
        lastAutoColorPlanForTesting = reported
        print(String(format: "AUTO COLOR · chroma p50 %.4f p95 %.4f · coloured %.1f%% "
                     + "→ vibrance %+.2f (was %+.2f) · saturation %+.2f (was %+.2f, unguarded %+.2f, "
                     + "new clip %d, skin %+.1f%%) · final p50 %.4f p95 %.4f",
                     initialMetrics.chromaP50, initialMetrics.chromaP95,
                     initialMetrics.coloredFraction * 100,
                     vibrance, source.color.vibrance,
                     saturation, source.color.saturation, reported.unguardedSaturation,
                     reported.newClippedPixels, reported.skinChromaChange * 100,
                     finalMetrics.chromaP50, finalMetrics.chromaP95))
        // 2026-11-27: **绝对**写回。plan 是从归零测量解出来的，所以用户手推到 +20 而 plan 说 +8 时，
        // 结果是 8（自动色彩覆盖手改值），不再是旧口径的「只升不降」。只有「与文档已相同」才是 no-op ——
        // 那也是连点两次的第二下成为真正不动点的原因。
        guard abs(vibrance - source.color.vibrance) > 1e-9
                || abs(saturation - source.color.saturation) > 1e-9 else {
            let reason: AutoColorNoOpReason = initialMetrics.coloredFraction < AutoColor.minimumColoredFraction
                ? .tooGrey : .alreadySaturated
            lastAutoColorNoOpReasonForTesting = reason
            print(reason == .tooGrey
                  ? "AUTO COLOR · 画面几乎没有颜色，未写入"
                  : "AUTO COLOR · 自动色彩的结果与当前数值相同，未写入")
            return nil
        }
        lastAutoColorNoOpReasonForTesting = nil
        return ColorCandidate(vibrance: vibrance, saturation: saturation, plan: reported)
    }
    // MARK: 自动调整 — 复合动作 (453)

    /// **490 / 498 — 自动颜色's own entry.** One document write of **both** `color.vibrance` and
    /// `color.saturation`, and one 「自动颜色」 history row. A press on a settled picture is a no-op
    /// (`colorCandidate` returns `nil`), exactly like 自动黑电平 / 自动明暗.
    @discardableResult
    public func autoColor() -> Double? {
        guard let session = host?.session, let candidate = colorCandidate() else { return nil }
        session.applyEdit {
            $0.color.vibrance = candidate.vibrance
            $0.color.saturation = candidate.saturation
        }
        host?.requestEditRender()
        session.commitEdit(label: Loc.t("自动颜色"), coalesce: false)
        return candidate.vibrance
    }

    /// **派单 453 — 自动调整.** 黑电平 → 明暗 → 自动颜色, **one** document write and **one** history row.
    ///
    /// The order is load-bearing: `AutoLight` step 4 reads `light.blackOffset` to cancel the lift, so
    /// 明暗 must measure the document that already carries the new black level. The three candidates
    /// are measured against staged copies and written together, so no intermediate document is ever
    /// committed (or observed) between them; a step whose candidate is `nil` is skipped.
    ///
    /// The full-rung gate is 448's: a click before the anchor's full frame queues `.all` and returns
    /// `false`; `runPendingAutoIfReady` calls this same verb when that frame lands.
    @discardableResult
    public func autoDevelop() -> Bool {
        runAutoComposite(label: Loc.t("自动调整"), pending: .all, converge: false)
    }

    /// **490 — 「全部自动」.** The same one-write pipeline as `autoDevelop()`, under its own label and
    /// its own pending intent. It is deliberately additive: `autoDevelop()` keeps its existing
    /// behaviour (黑电平 → 明暗 → 颜色), so the 编辑 menu and the new top-bar button can never drift.
    ///
    /// Unlike `autoDevelop()`, it re-measures 明暗/颜色 on the document the previous pass produced
    /// until that pair is a fixed point (at most four passes). Colour is written last and its vibrance
    /// changes the picture `AutoLight` measures, so a single pass is not necessarily the state a
    /// second press would leave; converging here is what makes 「连点两次」 the same one row.
    @discardableResult
    public func autoAll() -> Bool {
        runAutoComposite(label: Loc.t("全部自动"), pending: .allAuto, converge: true)
    }

    /// The one pipeline behind both composite verbs. 黑电平 → 明暗 → 自动颜色, measured on staged
    /// copies and written together; a converged step returns `nil` and is skipped, so a second press
    /// on a settled picture adds neither a document change nor a history row.
    private func runAutoComposite(label: String, pending: PendingAuto, converge: Bool) -> Bool {
        guard let session = host?.session, session.mode == .loupe else { return false }
        if autoAdjustMustWait() {
            queuePendingAuto(pending)
            return false
        }
        var staged = session.edit
        var changed = false
        // 1. 黑电平 — the floor the 明暗 measurement must see. It does not depend on the later steps,
        // so it is measured once even when the light/colour pair is iterated.
        if let black = blackOffsetCandidate(), black != staged.light.blackOffset {
            staged.light.blackOffset = black
            changed = true
        }
        // 2/3. 明暗 → 自动颜色. 颜色 is last, and both of its sliders change what 明暗 measures, so a
        // second press on the same picture would otherwise find a different plan. Iterate the pair
        // (still before any write) to its fixed point; four passes bound the work if a picture
        // oscillates.
        let passes = converge ? 4 : 1
        var usedPasses = 0
        for _ in 0 ..< passes {
            usedPasses += 1
            var passChanged = false
            if let plan = lightPlanCandidate(from: staged) {
                staged = plan.apply(to: staged)
                passChanged = true
            }
            if let color = colorCandidate(from: staged) {
                staged.color.vibrance = color.vibrance
                staged.color.saturation = color.saturation
                passChanged = true
            }
            changed = changed || passChanged
            if !passChanged { break }
        }
        lastAutoCompositePassCountForTesting = usedPasses
        guard changed else { return false }
        session.applyEdit { $0 = staged }
        host?.requestEditRender()
        session.commitEdit(label: label, coalesce: false)
        return true
    }
}
