import XCTest
import Foundation
@testable import PhotonsExtensions

/// §386 / §390 — end-to-end orchestrator (`AnselDenoiseJob`) 的纯逻辑判据，**不需要真模型**。
///
/// §390 把链路从「DNG → mosaic → 归一化 → f32 → 反归一化 → 写 DNG」压成「两个路径，一次调用」。
/// 于是这个文件里每条判据的范围也随之收窄，收窄的部分由工具侧自己的测试负责：
///
///   ② 产物命名与位置 —— `/x/y/L1030552.dng` ⇒ `/x/y/L1030552-denoised.dng`；同名已存在则
///      `-denoised-2.dng`（策略：**递增，不覆盖** —— 一次降噪几分钟，覆盖是唯一不可撤销的失败）；
///   ④ 失败不留垃圾 —— 截断/非 TIFF 文件、以及**写到一半才失败的 tool**，都不许在磁盘上留下
///      `-denoised.dng` 或 `.denoise-*.dng`；
///   工具/模型的四级解析 —— 显式路径不存在 ⇒ 各自的 typed 错误，模型那条**带完整期望路径**；
///   协议门槛 —— 不支持 `image-dng` 的旧工具必须在这里被拦住，而不是收到一张它读不懂的参数表；
///   以及一次**用假 tool 的整链**（假 tool 只把 DNG 抄过去），证明命名/改名/报告翻译都对。
///
/// **被删掉的判据**（连同它们的实现）：④ 归一化往返 `MosaicNormalization`、逐相位黑电平、
/// `cfaPattern(of:)`。那三样是宿主侧搬运的一部分，现在由工具读同一个文件、算同一份相位，
/// 测在它自己的仓库里（`DNGPipelineTests`）。
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

    // MARK: - ④ 失败不留垃圾

    func testATruncatedFileThrowsAndLeavesNothingBehind() throws {
        let dir = workDir.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let broken = dir.appendingPathComponent("BROKEN.dng")
        try Data([0x49, 0x49, 0x2a, 0x00, 0x08]).write(to: broken)   // header cut short

        // The stand-in refuses anything it cannot read, which is what the real tool does — the point
        // here is the host's behaviour around a failed call, not the tool's parser.
        let job = AnselDenoiseJob(location: AnselDenoiseLocation(executableURL: try makeFakeTool(),
                                                                modelURL: try makeDummyModel()))
        XCTAssertThrowsError(try job.run(source: broken)) { error in
            let message = (error as? AnselDenoiseJobError)?.description ?? "\(error)"
            print("④ 截断文件 ⇒ \(message)")
            XCTAssertTrue(message.contains("降噪失败"), "④ 必须是「降噪失败：…」，实际：\(message)")
        }
        try assertNoLeftovers(in: dir, besides: ["BROKEN.dng"])
    }

    /// The case the temp-name-then-rename arrangement exists for: a tool that **writes the output and
    /// then fails**. Without the rename (§390 反向门 ⑨) this leaves a complete-looking half product
    /// sitting where the final name would be, and nothing tells the user it is not the result.
    func testAToolThatWritesThenFailsLeavesNothingBehind() throws {
        let dir = workDir.appendingPathComponent("halfway", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("L1030552.dng")
        try FileManager.default.copyItem(at: Self.fixtureURL, to: source)

        let tool = try makeFakeTool(failAfterWriting: true)
        let job = AnselDenoiseJob(location: AnselDenoiseLocation(executableURL: tool,
                                                                modelURL: try makeDummyModel()))
        XCTAssertThrowsError(try job.run(source: source)) { error in
            let message = (error as? AnselDenoiseJobError)?.description ?? "\(error)"
            print("④ 写完后失败 ⇒ \(message)")
            XCTAssertTrue(message.contains("降噪失败"), "④ 必须是「降噪失败：…」，实际：\(message)")
        }
        try assertNoLeftovers(in: dir, besides: ["L1030552.dng"])
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
            print("④ JPEG ⇒ \(message)")
            XCTAssertEqual(message, "只支持 DNG：IMG_1.jpg")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["IMG_1.jpg"])
    }

    /// `-denoised.dng` 与临时名都不许留下。临时名以 `.` 开头，所以 `contentsOfDirectory` 会返回它 ——
    /// 正好，残留必须在这里被抓到。
    private func assertNoLeftovers(in dir: URL, besides allowed: Set<String>) throws {
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { !allowed.contains($0) }
        print("④ 目录里剩下的（除 \(allowed.sorted())）：\(leftovers)")
        XCTAssertTrue(leftovers.allSatisfy { !$0.contains("-denoised") },
                      "④ 失败后不许出现产物：\(leftovers)")
        XCTAssertTrue(leftovers.allSatisfy { !$0.hasPrefix(".denoise-") },
                      "④ 失败后不许留下临时文件：\(leftovers)")
        XCTAssertTrue(leftovers.isEmpty, "④ 除源文件外不该有任何东西：\(leftovers)")
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

    /// 四级顺序：env → app bundle 的 `bin/models/` → 顶层 `Resources/models/` → Application Support。
    /// 单测宿主里 `bundle.resourceURL` 指向 xcodebuild 目录（不是真的 app），所以「bundle 那一级」
    /// 在这里只能验路径**怎么拼**，验不了文件真的在 —— 那个由 `DenoiseShippedModel387Tests`
    /// 直接读磁盘上的 `.build/Photons.app` 来钉。
    /// 名字里的「then the bundle, then the user directory」是 2026-11-12 改的：模型随 app 打包之后，
    /// 搜索顺序不再以用户目录收尾 —— 第 2 级就是 app 内的 `bin/models/`，用户目录落到第 4 级，
    /// 只服务「换 half/large 变体」这一种用途。
    func testModelResolutionPrefersTheEnvironmentThenTheBundleThenTheUserDirectory() throws {
        let envModel = workDir.appendingPathComponent(AnselDenoiseVariant.quarter.modelFileName)
        try Data([0]).write(to: envModel)
        let location = AnselDenoiseLocation()

        let searched = location.searchedModelURLs(environment: [AnselDenoiseLocation.environmentKey: envModel.path])
        print("③ 候选顺序：\(searched.map { $0.path })")
        XCTAssertEqual(searched.first?.path, envModel.path, "环境变量优先")
        XCTAssertEqual(location.resolvedModel(environment: [AnselDenoiseLocation.environmentKey: envModel.path])?.path,
                       envModel.path)

        // 2026-11-12 — the expected path is the **app bundle's own** location, not the user
        // directory: the model ships inside Photons (`bundle-ansel-models.sh` puts it in
        // `Contents/Resources/bin/models/`), so a missing model means the bundle is wrong, and the
        // tooltip should say so rather than point at a directory the user is not expected to fill.
        let expectedPath = AnselDenoiseLocation.expectedModelPath(variant: .quarter).path
        let quarterName = AnselDenoiseVariant.quarter.modelFileName
        if let resources = Bundle.main.resourceURL {
            XCTAssertEqual(expectedPath,
                           resources.appendingPathComponent("bin/models/\(quarterName)").path,
                           "期望路径必须是 app 内的 bin/models，实际 \(expectedPath)")
        } else {
            XCTAssertTrue(expectedPath.hasSuffix("Library/Application Support/Photons/models/" + quarterName),
                          "没有 bundle 时退回用户目录，实际 \(expectedPath)")
        }
        XCTAssertEqual(location.modelPathHint(), expectedPath, "tooltip 写的路径就是模型该在的地方")
        // The user directory is still a legitimate *search* location — that is where someone drops
        // a half/large variant — so keep probing it separately from the tooltip's claim.
        let userCopy = AnselDenoiseLocation.userModelDirectory()
            .appendingPathComponent(quarterName).path
        // A path that does not exist anywhere resolves to nil, never to a guess.
        //
        // Only assert this when nothing is actually installed: on a machine where a model has
        // been put in the user directory (the normal state after using the feature) resolving to
        // that file is correct behaviour, not a bug in the resolver.
        let installed = FileManager.default.fileExists(atPath: userCopy)
        if !installed {
            XCTAssertNil(location.resolvedModel(environment: [:]))
        }
    }

    // MARK: - 协议门槛

    /// §390 — an old tool without `image-dng` must be refused **before** anything is spawned with a
    /// DNG argument list. The stand-in below reports the capabilities of the pre-390 tool.
    func testAToolWithoutDNGSupportIsRefusedUpFront() throws {
        let dir = workDir.appendingPathComponent("oldtool", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("L1030552.dng")
        try FileManager.default.copyItem(at: Self.fixtureURL, to: source)

        let tool = try makeFakeTool(supportsDNG: false)
        let job = AnselDenoiseJob(location: AnselDenoiseLocation(executableURL: tool,
                                                                modelURL: try makeDummyModel()))
        XCTAssertThrowsError(try job.run(source: source)) { error in
            let message = (error as? AnselDenoiseJobError)?.description ?? "\(error)"
            print("§390 旧工具（无 image-dng）⇒ \(message)")
            XCTAssertEqual(message, AnselDenoiseNotices.toolMissing)
        }
        try assertNoLeftovers(in: dir, besides: ["L1030552.dng"])
    }

    // MARK: - 整链（假 tool：把 DNG 原样抄成产物）

    func testTheWholeChainWritesALegalSiblingDNG() throws {
        let dir = workDir.appendingPathComponent("chain", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("L1030552.dng")
        try FileManager.default.copyItem(at: Self.fixtureURL, to: source)

        let job = AnselDenoiseJob(location: AnselDenoiseLocation(executableURL: try makeFakeTool(),
                                                                modelURL: try makeDummyModel()))
        let outcome = try job.run(source: source)
        print("整链：output=\(outcome.output.lastPathComponent) \(outcome.width)×\(outcome.height) "
              + "cfa=\(outcome.cfa) pieces=\(outcome.pieces) seams=\(outcome.seams) "
              + "seconds=\(outcome.seconds) backend=\(outcome.backend) bytes=\(outcome.byteCount)")

        XCTAssertEqual(outcome.output.deletingLastPathComponent().path, dir.path, "产物落同目录")
        XCTAssertEqual(outcome.output.lastPathComponent, "L1030552-denoised.dng")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.output.path))
        XCTAssertEqual(outcome.width, 1024)
        XCTAssertEqual(outcome.height, 1024)
        XCTAssertEqual(outcome.cfa, "rggb")
        XCTAssertEqual(outcome.pieces, 1, "假 tool 自报 1 piece")
        XCTAssertEqual(outcome.seams, 0)
        XCTAssertEqual(outcome.seconds, 1.0, accuracy: 1e-9, "工具自报的 seconds 要原样传出来")
        XCTAssertEqual(outcome.backend, "fake")
        XCTAssertGreaterThan(outcome.byteCount, 0)
        XCTAssertEqual(outcome.source, source)

        // 产物能被自己的读端重新读出来（几何不变、仍是 CFA 图）。
        let writtenData = try Data(contentsOf: outcome.output, options: .alwaysMapped)
        let written = try SourceDNG(data: writtenData)
        let writtenMosaic = try written.readMosaic(data: writtenData)
        XCTAssertEqual(writtenMosaic.width, 1024)
        XCTAssertEqual(writtenMosaic.height, 1024)
        XCTAssertEqual(written.ifd0[262]?.firstUInt32, 32803, "仍是 CFA 图")

        // 假 tool 是恒等的，所以像素应当一个不差。
        let originalData = try Data(contentsOf: source, options: .alwaysMapped)
        let original = try SourceDNG(data: originalData).readMosaic(data: originalData)
        var maxDeviation = 0
        for i in 0..<original.samples.count {
            maxDeviation = max(maxDeviation, abs(Int(writtenMosaic.samples[i]) - Int(original.samples[i])))
        }
        print("整链：假 tool 下与原图的最大像素偏差 = \(maxDeviation) 码")
        XCTAssertEqual(maxDeviation, 0)
    }

    /// ② 已有产物时整链落到 `-denoised-2.dng`，且第一个产物不被覆盖。
    func testTheWholeChainStepsToTheNextNameInsteadOfOverwriting() throws {
        let dir = workDir.appendingPathComponent("chain2", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("L1030552.dng")
        try FileManager.default.copyItem(at: Self.fixtureURL, to: source)
        let first = dir.appendingPathComponent("L1030552-denoised.dng")
        try Data([0xAB]).write(to: first)

        let job = AnselDenoiseJob(location: AnselDenoiseLocation(executableURL: try makeFakeTool(),
                                                                modelURL: try makeDummyModel()))
        let outcome = try job.run(source: source)
        print("② 整链：已存在首个产物 ⇒ 这次写到 \(outcome.output.lastPathComponent)")
        XCTAssertEqual(outcome.output.lastPathComponent, "L1030552-denoised-2.dng")
        XCTAssertEqual(try Data(contentsOf: first), Data([0xAB]), "首次产物必须原封不动")
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

        let job = AnselDenoiseJob(location: AnselDenoiseLocation(executableURL: try makeFakeTool(),
                                                                modelURL: try makeDummyModel()))
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
        let ratio = beforeEnergy == 0 ? 1 : afterEnergy / beforeEnergy
        print("⑫ 恒等 tool：相邻差方差 \(beforeEnergy) → \(afterEnergy)，比值 \(ratio)")
        XCTAssertGreaterThan(ratio, 0.75,
                             "⑫ 「没降噪」时 ⑨ 的度量必须红；比值 \(ratio) 说明它没有判别力")
    }

    // MARK: - helpers

    /// A stand-in for the GPL binary. It does not denoise: it copies the input DNG to `--out` and
    /// prints the JSON object the real `image in.dng --out out.dng --json` prints. That is exactly
    /// enough to prove the host side (naming → temp → rename → report translation) works.
    ///
    /// - Parameters:
    ///   - supportsDNG: `false` makes `capabilities` look like the pre-390 tool.
    ///   - failAfterWriting: copy the file, print nothing useful, exit 7 — the 「写了半个产物然后
    ///     失败」 case that ④ has to survive.
    private func makeFakeTool(supportsDNG: Bool = true,
                              failAfterWriting: Bool = false) throws -> URL {
        let name = "fake-ansel-denoise-swift-\(UUID().uuidString)"
        let url = workDir.appendingPathComponent(name)
        let features = supportsDNG ? "[\"image\",\"image-dng\",\"gpu\"]" : "[\"image\",\"gpu\"]"
        let jsonHead = "{\"width\":1024,\"height\":1024,\"cfa\":\"rggb\",\"mosaicCfa\":\"rggb\","
            + "\"pieces\":1,\"columns\":1,\"rows\":1,\"seams\":0,\"seconds\":1.0,"
            + "\"readSeconds\":0.0,\"inferenceSeconds\":0.0,\"writeSeconds\":0.0,"
            + "\"backend\":\"fake\",\"outputBytes\":"
        let tail = failAfterWriting
            ? "echo 'model exploded on purpose' >&2; exit 7"
            : "bytes=$(wc -c < \"$out\" | tr -d ' ')\n"
              + "printf '%s%s}\\n' '\(jsonHead)' \"$bytes\""
        let script = """
        #!/bin/sh
        # fake ansel-denoise-swift (§390): capabilities, then DNG in → DNG out.
        if [ "$1" = "capabilities" ]; then
          echo '{"tool":{"name":"ansel-denoise-swift","protocol":2},"gpu":"Fake GPU","features":\(features)}'
          exit 0
        fi
        if [ "$1" != "image" ]; then exit 2; fi
        input="$3"
        out=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "--out" ]; then out="$2"; shift 2; continue; fi
          shift
        done
        if [ -z "$out" ] || [ ! -f "$input" ]; then exit 3; fi
        # Refuse what the real tool refuses: a file too short to hold an IFD. (The real one parses
        # tags and says so; this stand-in only has to fail on the truncated fixture.)
        size=$(wc -c < "$input" | tr -d ' ')
        if [ "$size" -lt 1024 ]; then
          echo '解码 RAW 失败：文件被截断' >&2
          exit 5
        fi
        cp "$input" "$out" || exit 4
        \(tail)
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
