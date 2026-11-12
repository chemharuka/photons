import XCTest
import Foundation
@testable import PhotonsExtensions

/// §386 — 端到端 orchestrator（`AnselDenoiseJob`）的纯逻辑判据，**不需要真模型**。
///
/// The chain is `DNG → mosaic → 归一化 → denoise → 反归一化 → DNG`, and each numbered claim here
/// is one link that can silently be wrong:
///
///   ② 产物命名与位置 —— `/x/y/L1030552.dng` ⇒ `/x/y/L1030552-denoised.dng`；同名已存在则
///      `-denoised-2.dng`（策略：**递增，不覆盖** —— 一次降噪几分钟，覆盖是唯一不可撤销的失败）；
///   ④ 数值往返 —— 取一张真实 DNG 的 mosaic，走「归一化 → 反归一化」，**逐样本与原始 UInt16
///      相等（容差 0）**，并贴出最大偏差；
///   ⑤ 失败不留垃圾 —— 截断/非 TIFF 文件 ⇒ 抛错，磁盘上**不出现** `-denoised.dng`；
///   工具/模型的四级解析 —— 显式路径不存在 ⇒ 各自的 typed 错误，模型那条**带完整期望路径**；
///   以及一次**用假 tool 的整链**（假 tool 原样回抄 tile），证明除降噪本身之外的每一段接线都对。
final class AnselDenoiseJob386Tests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-denoise386-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/small-rggb.dng")
    }

    // MARK: - ② 命名与位置

    func testTheOutputIsASiblingNamedDenoised() {
        let source = URL(fileURLWithPath: "/x/y/L1030552.dng")
        let out = AnselDenoiseJob.outputURL(for: source)
        print("② \(source.path) → \(out.path)")
        XCTAssertEqual(out.path, "/x/y/L1030552-denoised.dng")
        XCTAssertEqual(out.deletingLastPathComponent().path, source.deletingLastPathComponent().path,
                       "② 必须与原文件同目录")
        XCTAssertEqual(out.pathExtension, "dng", "② 扩展名小写")
    }

    func testAnExistingProductIsNeverOverwritten() throws {
        let dir = workDir.appendingPathComponent("inc", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("L1030552.dng")
        try Data([0]).write(to: source)

        let first = AnselDenoiseJob.outputURL(for: source)
        XCTAssertEqual(first.lastPathComponent, "L1030552-denoised.dng")
        try Data([1]).write(to: first)

        let second = AnselDenoiseJob.outputURL(for: source)
        print("② 已存在 ⇒ 第二个产物名 \(second.lastPathComponent)")
        XCTAssertEqual(second.lastPathComponent, "L1030552-denoised-2.dng",
                       "② 策略是递增：绝不覆盖上一次的产物")
        try Data([2]).write(to: second)
        XCTAssertEqual(AnselDenoiseJob.outputURL(for: source).lastPathComponent,
                       "L1030552-denoised-3.dng")
    }

    // MARK: - ④ 归一化往返

    func testNormalizeDenormalizeIsExactForEverySample() throws {
        let source = Self.fixtureURL
        let data = try Data(contentsOf: source, options: .alwaysMapped)
        let doc = try SourceDNG(data: data)
        let mosaic = try doc.readMosaic(data: data)
        let norm = try AnselDenoiseJob.normalization(of: doc)

        print("④ 黑白电平来自文件自己：black=\(norm.blackByPhase) white=\(norm.white) "
              + "repeat=\(norm.repeatRows)×\(norm.repeatCols)")

        let normalized = norm.normalized(mosaic.samples, width: mosaic.width, height: mosaic.height)
        let back = norm.quantized(normalized, width: mosaic.width, height: mosaic.height)

        var maxDeviation = 0
        var mismatch = 0
        var normalizedMin = Float.greatestFiniteMagnitude
        var normalizedMax = -Float.greatestFiniteMagnitude
        for i in 0..<mosaic.samples.count {
            let d = abs(Int(back[i]) - Int(mosaic.samples[i]))
            if d != 0 { mismatch += 1 }
            maxDeviation = max(maxDeviation, d)
            normalizedMin = min(normalizedMin, normalized[i])
            normalizedMax = max(normalizedMax, normalized[i])
        }
        print("④ 样本数=\(mosaic.samples.count) 不相等=\(mismatch) 最大偏差=\(maxDeviation) 码 "
              + "归一化范围=[\(normalizedMin), \(normalizedMax)]")
        XCTAssertEqual(mismatch, 0, "④ 逐样本必须相等（容差 0）")
        XCTAssertEqual(maxDeviation, 0, "④ 最大偏差必须是 0 码")
        // The service's contract is [0,1]: the normalized visit must stay inside it (a value above
        // 1 would mean the white level read is wrong) and must actually spread, not sit at zero.
        XCTAssertGreaterThanOrEqual(normalizedMin, 0)
        XCTAssertLessThanOrEqual(normalizedMax, 1.0, "④ 归一化后不能超过 1，否则白电平读错了")
        XCTAssertGreaterThan(normalizedMax - normalizedMin, 0.1, "④ 归一化后要有真实动态范围")
    }

    /// `BlackLevel` 4 个相位（Leica 写 2×2 的 512）必须逐相位减，不能一律减 512 —— 一旦相位错，
    /// 反归一化也错，图就是棋盘格。这里用一个 1 码的倾斜探针证明「逐相位」真的生效。
    func testPerPhaseBlackLevelsAreHonoured() {
        let norm = MosaicNormalization(blackByPhase: [512, 600, 560, 640], repeatRows: 2, repeatCols: 2,
                                       white: 16383)
        XCTAssertEqual(norm.normalize(512, row: 0, col: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(norm.normalize(600, row: 0, col: 1), 0, accuracy: 1e-9)
        XCTAssertEqual(norm.normalize(560, row: 1, col: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(norm.normalize(640, row: 1, col: 1), 0, accuracy: 1e-9)
        for (row, col) in [(0, 0), (0, 1), (1, 0), (1, 1)] {
            let black = UInt16(norm.black(row: row, col: col))
            XCTAssertEqual(norm.denormalize(0, row: row, col: col), black)
        }
    }

    // MARK: - ⑤ 失败不留垃圾

    func testATruncatedFileThrowsAndLeavesNothingBehind() throws {
        let dir = workDir.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let broken = dir.appendingPathComponent("BROKEN.dng")
        try Data([0x49, 0x49, 0x2a, 0x00, 0x08]).write(to: broken)   // header cut short

        let fakeTool = try makeFakeTool()
        let model = try makeDummyModel()
        let job = AnselDenoiseJob(location: AnselDenoiseLocation(executableURL: fakeTool,
                                                                modelURL: model))
        XCTAssertThrowsError(try job.run(source: broken)) { error in
            let message = (error as? AnselDenoiseJobError)?.description ?? "\(error)"
            print("⑤ 截断文件 ⇒ \(message)")
            XCTAssertTrue(message.contains("解码 RAW 失败"), "⑤ 要中文原因，实际：\(message)")
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains("-denoised") }
        print("⑤ 目录里剩下的产物：\(leftovers)")
        XCTAssertTrue(leftovers.isEmpty, "⑤ 失败后不许出现 \(leftovers)")
    }

    func testANonDNGFileIsRefusedBeforeAnythingIsWritten() throws {
        let dir = workDir.appendingPathComponent("jpg", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jpeg = dir.appendingPathComponent("IMG_1.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: jpeg)
        let job = AnselDenoiseJob(location: AnselDenoiseLocation(executableURL: try makeFakeTool(),
                                                                modelURL: try makeDummyModel()))
        XCTAssertThrowsError(try job.run(source: jpeg)) { error in
            let message = (error as? AnselDenoiseJobError)?.description ?? "\(error)"
            print("⑤ JPEG ⇒ \(message)")
            XCTAssertEqual(message, "只支持 DNG：IMG_1.jpg")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["IMG_1.jpg"])
    }

    // MARK: - 工具 / 模型的四级解析

    func testAMissingToolIsNamedNotGuessed() {
        let location = AnselDenoiseLocation(executableURL: workDir.appendingPathComponent("no-tool"))
        XCTAssertFalse(location.client().map {
            FileManager.default.isExecutableFile(atPath: $0.executableURL.path)
        } ?? false, "不存在的显式路径必须被判成不可用")
        XCTAssertThrowsError(try location.requireClient()) { error in
            XCTAssertEqual((error as? AnselDenoiseJobError)?.description,
                           AnselDenoiseNotices.toolMissing)
        }
    }

    func testAMissingModelTooltipCarriesTheFullExpectedPath() {
        let expected = workDir.appendingPathComponent("no-model.anselnn")
        let location = AnselDenoiseLocation(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                            modelURL: expected)
        XCTAssertThrowsError(try location.requireModel()) { error in
            let message = (error as? AnselDenoiseJobError)?.description ?? "\(error)"
            print("③ 模型缺失 ⇒ \(message)")
            XCTAssertTrue(message.contains(expected.path), "③ tooltip 必须带完整期望路径")
            XCTAssertEqual(message, "未找到降噪模型：\(expected.path)")
        }
    }

    /// 四级顺序：env → bundle → Application Support。bundle 那一级在测试里拿不到资源目录，
    /// 所以这里只钉住「env 优先」和「都没有时给出第 3 级的完整路径」这两件事。
    func testModelResolutionPrefersTheEnvironmentThenTheUserDirectory() throws {
        let envModel = workDir.appendingPathComponent(AnselDenoiseVariant.quarter.modelFileName)
        try Data([0]).write(to: envModel)
        let location = AnselDenoiseLocation()

        let searched = location.searchedModelURLs(environment: [AnselDenoiseLocation.environmentKey: envModel.path])
        print("③ 候选顺序：\(searched.map { $0.path })")
        XCTAssertEqual(searched.first?.path, envModel.path, "环境变量优先")
        XCTAssertEqual(location.resolvedModel(environment: [AnselDenoiseLocation.environmentKey: envModel.path])?.path,
                       envModel.path)

        let expectedPath = AnselDenoiseLocation.expectedModelPath(variant: .quarter).path
        XCTAssertTrue(expectedPath.hasSuffix("Library/Application Support/Photons/models/"
                                             + AnselDenoiseVariant.quarter.modelFileName),
                      "第 3 级必须是 ~/Library/Application Support/Photons/models，实际 \(expectedPath)")
        XCTAssertEqual(location.modelPathHint(), expectedPath, "tooltip 写的路径就是用户该放文件的地方")
        // A path that does not exist anywhere resolves to nil, never to a guess.
        //
        // Only assert this when nothing is actually installed: on a machine where a model has
        // been put in the user directory (the normal state after using the feature) resolving to
        // that file is correct behaviour, not a bug in the resolver.
        let installed = FileManager.default.fileExists(atPath: expectedPath)
        if !installed {
            XCTAssertNil(location.resolvedModel(environment: [:]))
        }
    }

    // MARK: - 整链（假 tool：把输入 tile 原样抄成输出）

    func testTheWholeChainWritesALegalSiblingDNG() throws {
        let dir = workDir.appendingPathComponent("chain", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("L1030552.dng")
        try FileManager.default.copyItem(at: Self.fixtureURL, to: source)

        var options = AnselDenoiseOptions()
        let job = AnselDenoiseJob(location: AnselDenoiseLocation(executableURL: try makeFakeTool(),
                                                                modelURL: try makeDummyModel()),
                                  options: options)
        let outcome = try job.run(source: source)
        print("整链：output=\(outcome.output.lastPathComponent) \(outcome.width)×\(outcome.height) "
              + "cfa=\(outcome.cfa) white=\(outcome.whiteLevel) tiles=\(outcome.tiles) "
              + "bytes=\(outcome.byteCount)")

        XCTAssertEqual(outcome.output.deletingLastPathComponent().path, dir.path, "产物落同目录")
        XCTAssertEqual(outcome.output.lastPathComponent, "L1030552-denoised.dng")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.output.path))

        // 产物能被自己的读端重新读出来，且几何/黑白电平/相位与原图一致（§3 ⑧ 的纯逻辑版）。
        let writtenData = try Data(contentsOf: outcome.output, options: .alwaysMapped)
        let written = try SourceDNG(data: writtenData)
        let writtenMosaic = try written.readMosaic(data: writtenData)
        XCTAssertEqual(writtenMosaic.width, 1024)
        XCTAssertEqual(writtenMosaic.height, 1024)
        XCTAssertEqual(try AnselDenoiseJob.cfaPattern(of: written), "rggb", "CFA 相位不能变")
        XCTAssertEqual(try AnselDenoiseJob.normalization(of: written).white,
                       try AnselDenoiseJob.normalization(of: SourceDNG(data: Data(contentsOf: source, options: .alwaysMapped))).white,
                       "白电平不能被改写")
        XCTAssertEqual(written.ifd0[259]?.firstUInt32, 7, "压缩方式 7（lossless JPEG）")

        // 假 tool 是恒等的，所以像素应当几乎不变（浮点羽化后最多 1 码）。
        let originalData = try Data(contentsOf: source, options: .alwaysMapped)
        let original = try SourceDNG(data: originalData).readMosaic(data: originalData)
        var maxDeviation = 0
        for i in 0..<original.samples.count {
            maxDeviation = max(maxDeviation, abs(Int(writtenMosaic.samples[i]) - Int(original.samples[i])))
        }
        print("整链：假 tool 下与原图的最大像素偏差 = \(maxDeviation) 码")
        XCTAssertLessThanOrEqual(maxDeviation, 1)
    }

    // MARK: - ⑫ 反向门：⑨ 的度量必须有判别力

    /// 「根本没降噪」伪装成成功时，⑨ 必须先红。
    ///
    /// The identity stand-in tool is exactly that disguise: the whole chain runs, a legal DNG comes
    /// out, and **no samples were changed**. Here the same ⑨ metric the real test uses (flat-block
    /// adjacent-difference variance) is measured on that product: it must come back ≈ 1.0, i.e. it
    /// would fail ⑨'s `< 0.75` gate. That is what makes ⑨ evidence rather than decoration.
    func testTheNoiseMetricCannotBeFooledByARunThatChangedNothing() throws {
        let dir = workDir.appendingPathComponent("nofool", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("L1030552.dng")
        try FileManager.default.copyItem(at: Self.fixtureURL, to: source)

        var options = AnselDenoiseOptions()
        let job = AnselDenoiseJob(location: AnselDenoiseLocation(executableURL: try makeFakeTool(),
                                                                modelURL: try makeDummyModel()),
                                  options: options)
        let outcome = try job.run(source: source)

        let before = try SourceDNG(data: Data(contentsOf: source, options: .alwaysMapped))
            .readMosaic(data: try Data(contentsOf: source, options: .alwaysMapped))
        let product = try SourceDNG(data: Data(contentsOf: outcome.output, options: .alwaysMapped))
            .readMosaic(data: try Data(contentsOf: outcome.output, options: .alwaysMapped))

        func adjacentDifferenceVariance(_ samples: [UInt16], width: Int, x: Int, y: Int) -> Double {
            var energy = 0.0
            var n = 0
            for row in y..<(y + 128) {
                let base = row * width
                for col in x..<(x + 128) {
                    let d = Double(samples[base + col]) - Double(samples[base + col + 1])
                    energy += d * d
                    n += 1
                }
            }
            return energy / Double(n)
        }
        let x = 256, y = 256
        let beforeEnergy = adjacentDifferenceVariance(before.samples, width: before.width, x: x, y: y)
        let afterEnergy = adjacentDifferenceVariance(product.samples, width: product.width, x: x, y: y)
        let ratio = afterEnergy / beforeEnergy
        print("⑫ 恒等 tool：相邻差方差 \(beforeEnergy) → \(afterEnergy)，比值 \(ratio)")
        XCTAssertGreaterThan(ratio, 0.75,
                             "⑫ 「没降噪」时 ⑨ 的度量必须红；比值 \(ratio) 说明它没有判别力")
    }

    // MARK: - helpers

    /// A stand-in for the GPL binary: it does not denoise, it copies the tile file through, which
    /// is exactly enough to prove the host-side chain (normalize → service → writer → naming) works.
    private func makeFakeTool() throws -> URL {
        let url = workDir.appendingPathComponent("fake-ansel-denoise-swift")
        let script = """
        #!/bin/sh
        # fake ansel-denoise-swift: copy the tile payload to --out and report one JSON line.
        input="$3"
        out=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "--out" ]; then out="$2"; shift 2; continue; fi
          shift
        done
        if [ -z "$out" ] || [ ! -f "$input" ]; then exit 3; fi
        cp "$input" "$out" || exit 4
        bytes=$(wc -c < "$out" | tr -d ' ')
        echo "{\\\"pieces\\\":1,\\\"columns\\\":1,\\\"rows\\\":1,\\\"seams\\\":0,\\\"singlePass\\\":true,\\\"peakBytes\\\":$bytes,\\\"ms\\\":1.0,\\\"backend\\\":\\\"fake\\\",\\\"cfa\\\":\\\"rggb\\\"}"
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// The model only has to *exist*: the tool is the one that reads it, and the fake one ignores it.
    private func makeDummyModel() throws -> URL {
        let url = workDir.appendingPathComponent(AnselDenoiseVariant.quarter.modelFileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data(repeating: 0, count: 64).write(to: url)
        }
        return url
    }
}
