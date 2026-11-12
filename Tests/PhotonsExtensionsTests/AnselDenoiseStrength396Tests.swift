import XCTest
import Foundation
@testable import PhotonsExtensions

/// §396 A —— 「模型降噪的默认强度修改为0.50，即 `--strength 0.50`」。
///
/// 判据（规格 §3 ①，以及 §5 风险 3 要求的那两个数）：
///
///   ① `AnselDenoiseOptions().strength == 0.50`，**并且**工具真的收到 `--strength 0.5`。
///      后半句不靠读代码：`RecordingTool` 是个把它自己的 `argv` 写进文件的假工具，跑完
///      `AnselDenoiseClient.denoiseImage` 之后从文件里读回来的就是子进程收到的那一行。
///      （`%.9g` 把 0.50 拼成 `"0.5"`，所以断言的是 `0.5` 而不是 `0.50` —— 字符串与
///      浮点数不是同一个东西，规格里那个 `0.50` 说的是**值**。）
///   ② 0.50 与 0.85 的**残余噪声**对比：§386 的暗部相邻差方差法。这一段要真工具 + 真模型 +
///      一张真 DNG，缺任何一样就 `XCTSkip`（工具是可选扩展，装不上的机器也该能跑整套）。
///
/// ⚠ 这一条**不是**「0.50 更好」的断言。降噪强度和噪点是一根滑杆的两端：0.50 的比值一定
/// 比 0.85 高（留下的噪声更多）。测试只钉住**单调性**（0 < 0.50 < 0.85 < 1 时比值递增），
/// 并把三个数原样打印出来，让用户自己看「0.50 是不是还该再调」——那是个审美判断，不是测试
/// 能替用户做的。
final class AnselDenoiseStrength396Tests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-denoise-strength396-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/small-rggb.dng")
    }

    // MARK: - ① the default

    /// ① — one number, and the comment above `strength` says why it is not 0.85 any more.
    ///
    /// 0.50 exactly, not 0.5-something: the ticket says `--strength 0.50`, and this is the value the
    /// CLI is built from. `XCTAssertEqual` on a `Double` without an accuracy is the right ruler here
    /// — a literal 0.50 is exactly representable, so a tolerance would only hide a re-typing.
    func testTheDefaultStrengthIs050() {
        let defaults = AnselDenoiseOptions()
        print("① AnselDenoiseOptions().strength = \(defaults.strength) "
              + "(String(format: \"%.9g\", …) = \(String(format: "%.9g", defaults.strength)))")
        XCTAssertEqual(defaults.strength, 0.50, "① 默认强度必须是 0.50（用户口径）")
        XCTAssertNotEqual(defaults.strength, 0.85, "① 反向门：改回 0.85 这条必须红")
    }

    /// ① 后半句 — **the argv the child process actually received**.
    ///
    /// The client builds its argument list privately and spawns it, so the only honest witness is
    /// the process on the other side. This tool records `$@` and then behaves like §390's stand-in
    /// (copy the DNG through, echo the report), which keeps the client's own contract intact.
    func testTheToolIsInvokedWithStrengthHalf() throws {
        let tool = try installRecordingTool()
        let client = AnselDenoiseClient(executableURL: tool)
        let output = workDir.appendingPathComponent("argv-out.dng")

        var options = AnselDenoiseOptions()
        options.noiseA = [0.0004, 0.0003, 0.0004]
        options.noiseB = [3e-6, 1e-6, 1e-6]
        _ = try client.denoiseImage(model: try makeDummyModel(), input: Self.fixtureURL,
                                   output: output, options: options)

        let argv = try recordedArgv()
        print("① 子进程收到的 argv = \(argv)")
        let strengthIndex = try XCTUnwrap(argv.firstIndex(of: "--strength"),
                                          "① argv 里没有 --strength")
        let value = try XCTUnwrap(argv[safe: strengthIndex + 1], "① --strength 后面没有值")
        print("① argv 里的 --strength 值 = \"\(value)\"")
        XCTAssertEqual(value, "0.5",
                       "① 默认值必须拼进 argv（`%.9g` 把 0.50 写成 0.5）；实际 \(value)")
        // 三个噪声参数也必须在：单独一个 --strength 0.5 说明不了这次跑的是什么。
        XCTAssertTrue(argv.contains("--a") && argv.contains("--b"), "① argv 缺噪声参数")
        XCTAssertEqual(argv.first, "image")
    }

    /// 选项还是可覆盖的：`strength` 只是个**默认值**，范围校验与 CLI 解析一个字都没动（§2.1）。
    func testAnExplicitStrengthStillWins() throws {
        let tool = try installRecordingTool()
        let client = AnselDenoiseClient(executableURL: tool)
        var options = AnselDenoiseOptions()
        options.noiseA = [0.0004, 0.0003, 0.0004]
        options.noiseB = [3e-6, 1e-6, 1e-6]
        options.strength = 0.85
        _ = try client.denoiseImage(model: try makeDummyModel(), input: Self.fixtureURL,
                                   output: workDir.appendingPathComponent("explicit.dng"),
                                   options: options)
        let argv = try recordedArgv()
        let value = try XCTUnwrap(argv[safe: (argv.firstIndex(of: "--strength") ?? -1) + 1])
        print("① 显式传 0.85 时 argv 的值 = \"\(value)\"")
        XCTAssertEqual(value, "0.85", "① 改默认值不许伤到显式传值的那条路")
    }

    // MARK: - ② 0.50 与 0.85 的残余噪声（§386 的暗部相邻差方差法）

    /// One flat dark patch, measured in the raw domain — §386's ruler, unchanged.
    private struct Block {
        let x: Int, y: Int, size: Int
        let mean: Double
        /// Mean of squared horizontal neighbour differences. Texture raises it, so only a *flat*
        /// block is an honest probe of what a denoiser did.
        let adjacentDifferenceVariance: Double
    }

    private func block(_ samples: [UInt16], width: Int, _ x: Int, _ y: Int, size: Int) -> Block {
        var sum = 0.0, energy = 0.0
        var n = 0
        for row in y..<(y + size) {
            let base = row * width
            for col in x..<(x + size) {
                sum += Double(samples[base + col])
                let d = Double(samples[base + col]) - Double(samples[base + col + 1])
                energy += d * d
                n += 1
            }
        }
        return Block(x: x, y: y, size: size, mean: sum / Double(n),
                     adjacentDifferenceVariance: energy / Double(n))
    }

    /// The four ratios, printed as raw numbers for the user to judge.
    ///
    /// Needs `PHOTONS_TEST_DENOISE_RAW` (or `~/Desktop/test/L1030433.dng`) + the model, exactly like
    /// §386's real test. Two full denoises of the frame: 0.50 is the new default, 0.85 the old one.
    func testTheDarkPatchVarianceAt050Versus085() throws {
        let rawPath = ProcessInfo.processInfo.environment["PHOTONS_TEST_DENOISE_RAW"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/test/L1030433.dng")
        guard FileManager.default.fileExists(atPath: rawPath) else {
            throw XCTSkip("② 没有 PHOTONS_TEST_DENOISE_RAW，跳过 0.50/0.85 实测")
        }
        var location = AnselDenoiseLocation()
        if let tool = ProcessInfo.processInfo.environment["ANSEL_DENOISE_SWIFT"] {
            location.executableURL = URL(fileURLWithPath: tool)
        }
        guard let model = location.resolvedModel() else {
            throw XCTSkip("② 没有 .anselnn 模型")
        }

        let dir = workDir.appendingPathComponent("strength", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("src.dng")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: rawPath), to: source)

        let sourceDoc = try SourceDNG(data: try Data(contentsOf: source, options: .alwaysMapped))
        let original = try sourceDoc.readMosaic(data: try Data(contentsOf: source, options: .alwaysMapped))

        // The same probe §386 uses: walk a diagonal grid, keep the darkest flat 256² block.
        let size = 256
        var darkest = block(original.samples, width: original.width, size, size, size: size)
        for k in 1...11 {
            let x = min(original.width - size - 1, size * 2 * k)
            let y = min(original.height - size - 1, size * 2 * k)
            let candidate = block(original.samples, width: original.width, x, y, size: size)
            if candidate.mean < darkest.mean { darkest = candidate }
        }

        func denoise(at strength: Double) throws -> Block {
            var options = AnselDenoiseOptions()
            options.strength = strength
            let job = AnselDenoiseJob(location: AnselDenoiseLocation(executableURL: location.executableURL,
                                                                     modelURL: model),
                                      options: options)
            let outcome = try job.run(source: source) { print("   … \($0)") }
            let data = try Data(contentsOf: outcome.output, options: .alwaysMapped)
            let doc = try SourceDNG(data: data)
            let mosaic = try doc.readMosaic(data: data)
            return block(mosaic.samples, width: mosaic.width, darkest.x, darkest.y, size: size)
        }

        let half = try denoise(at: 0.50)
        let shipped = try denoise(at: 0.85)

        func ratio(_ b: Block) -> Double {
            darkest.adjacentDifferenceVariance == 0
                ? 1 : b.adjacentDifferenceVariance / darkest.adjacentDifferenceVariance
        }
        print("② 平坦暗块 (\(darkest.x),\(darkest.y)) \(size)² 均值 \(String(format: "%.1f", darkest.mean))")
        print("② 原图   相邻差方差 \(String(format: "%.1f", darkest.adjacentDifferenceVariance))"
              + "（噪声码 \(String(format: "%.1f", darkest.adjacentDifferenceVariance.squareRoot()))）")
        print("② 0.50   相邻差方差 \(String(format: "%.1f", half.adjacentDifferenceVariance))"
              + " 比值 \(String(format: "%.3f", ratio(half)))"
              + " 均值 \(String(format: "%.1f", half.mean))")
        print("② 0.85   相邻差方差 \(String(format: "%.1f", shipped.adjacentDifferenceVariance))"
              + " 比值 \(String(format: "%.3f", ratio(shipped)))"
              + " 均值 \(String(format: "%.1f", shipped.mean))")

        // The contract, and only the contract: both strengths must denoise, and 0.50 must leave
        // MORE residual than 0.85 does (that is what "weak" means — the blur is linear in strength).
        XCTAssertLessThan(ratio(half), 1.0, "② 0.50 必须仍然降噪（比值 < 1）")
        XCTAssertLessThan(ratio(shipped), ratio(half),
                          "② 0.85 必须比 0.50 降得多；不成立说明 strength 没透到工具")
    }

    // MARK: - the recording tool

    private var argvFile: URL { workDir.appendingPathComponent("argv.txt") }

    /// A stand-in that records the argv it was handed and then copies the DNG through.
    ///
    /// It also **fails loudly when `--strength` is missing**, so the reverse gate (⑧) cannot pass by
    /// the client silently dropping the flag: the run itself breaks.
    private func installRecordingTool() throws -> URL {
        let tool = workDir.appendingPathComponent("record-ansel-denoise-swift")
        let log = argvFile.path
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(log)"
        if [ "$1" = "capabilities" ]; then
          echo '{"tool":{"name":"ansel-denoise-swift","protocol":2},"gpu":"Fake GPU","features":["image","image-dng","gpu"]}'
          exit 0
        fi
        # the whole point: no --strength on the command line ⇒ this run is not evidence
        found=0
        for a in "$@"; do if [ "$a" = "--strength" ]; then found=1; fi; done
        if [ "$found" = "0" ]; then echo "error: argv 里没有 --strength" >&2; exit 9; fi
        input="$3"
        out=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "--out" ]; then out="$2"; shift 2; continue; fi
          shift
        done
        if [ -z "$out" ] || [ ! -f "$input" ]; then exit 3; fi
        cp "$input" "$out" || exit 4
        echo '{"width":1024,"height":1024,"cfa":"rggb","mosaicCfa":"rggb","pieces":1,"columns":1,"rows":1,"seams":0,"seconds":0.01,"readSeconds":0.0,"inferenceSeconds":0.01,"writeSeconds":0.0,"backend":"fake","outputBytes":1}'
        """
        try script.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }

    private func recordedArgv() throws -> [String] {
        let text = try String(contentsOf: argvFile, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func makeDummyModel() throws -> URL {
        let model = workDir.appendingPathComponent(AnselDenoiseVariant.quarter.modelFileName)
        try Data(repeating: 0, count: 64).write(to: model)
        return model
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
