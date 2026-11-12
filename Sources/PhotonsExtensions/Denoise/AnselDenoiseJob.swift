//
//  AnselDenoiseJob.swift
//
//  §390 的端到端链路：**两个路径，一次调用**。
//
//      DNG → AnselDenoiseClient.denoiseImage(model:input:output:) → DNG
//
//  这段之前是本文件里约 480 行的「读 DNG → 归一化 → 写 f32 → 调工具 → 读回 f32 →
//  反归一化 → 写 DNG」。工具侧（`ansel-denoise-swift` `image in.dng --out out.dng`，d03fa25）
//  现在自己读文件、自己写文件，所以宿主侧的搬运没有意义：60 MP 上那 284 s 的搬运在工具侧
//  变成 2.1 s 读 + 0.9 s 写，总耗时从 350 s 降到 42 s。
//
//  为什么搬走是对的：归一化要用的黑/白电平、CFA 相位、ActiveArea 全在**输入文件**里。以前
//  宿主读一遍、工具按宿主给的数字理解噪声，两边就有两个关于同一张图的看法；现在两边读的是
//  同一个文件，不可能不一致。分块策略（切不切、切几块、怎么羽化）同样是工具自己的内存特性，
//  宿主复刻它只会得到一份会漂移的副本。
//
//  本文件剩下的职责只有三件：命名（`-denoised.dng` / `-denoised-2.dng` 递增）、失败不留垃圾
//  （先写临时名再改名）、以及把工具的 JSON 报告翻译成 `Outcome`。
//
//  GPL 边界不变：本文件只调 `AnselDenoiseClient` 的公开 API，`ansel-denoise-swift` 始终是
//  子进程，没有任何一行被链接进来。
//

import Foundation

// MARK: - 文案（菜单、tooltip 与失败报告共用一份）

/// 一句提示只写一次。菜单灰掉的 tooltip、`lastDenoiseError` 和测试断言读的都是这里，
/// 三处不会漂移。
public enum AnselDenoiseNotices {
    public static let singlePhotoOnly = "模型降噪只处理单张照片"
    public static let toolMissing = "未找到 ansel-denoise-swift"
    public static let notADNG = "只支持 DNG"
    public static func onlyDNG(_ filename: String) -> String { "只支持 DNG：\(filename)" }
    public static func modelMissing(_ expectedPath: String) -> String {
        "未找到降噪模型：\(expectedPath)"
    }
    public static let noLibrary = "未打开库"
    public static let alreadyRunning = "已有一次模型降噪在进行"
}

// MARK: - 模型 / 工具的定位（四级可注入）

/// 工具与模型在哪儿 —— §2.3 的四级解析顺序，**产品代码里没有个人路径**。
///
/// 工具：直接复用 `AnselDenoiseClient` 自己的解析（显式 → `$ANSEL_DENOISE_SWIFT` →
/// app bundle `Contents/Resources/bin/` → Homebrew → `/usr/local/bin`），这里不另写一套。
///
/// 模型（高 → 低）：
///   1. `$PHOTONS_ANSEL_MODEL`
///   2. app bundle `Contents/Resources/bin/models/<modelFileName>` —— **模型的正式位置**：
///      权重是那个 GPL 工具的数据，跟着可执行文件走（387 打包口径），不混进 Photons 自己的
///      顶层 `Resources/`。
///   3. app bundle `Contents/Resources/models/<modelFileName>` —— 兼容早先的位置，留着不删，
///      因为它读起来最直观，将来若有人手工塞进去也不该失效。
///   4. `~/Library/Application Support/Photons/models/<modelFileName>` —— 用户换变体
///      （half/large/multi）放这里，app 不用重打包。
///   5. 都没有 ⇒ 抛错，并且 **错误里带完整期望路径**（菜单的 tooltip 就要这几个字）。
public struct AnselDenoiseLocation: Sendable, Equatable {

    /// 显式可执行文件。`nil` = 走 `AnselDenoiseClient` 的解析顺序。
    public var executableURL: URL?
    /// 显式模型。`nil` = 走下面的搜索顺序。测试用它把一个不存在的路径塞进来。
    public var modelURL: URL?
    public var variant: AnselDenoiseVariant

    public init(executableURL: URL? = nil,
                modelURL: URL? = nil,
                variant: AnselDenoiseVariant = .quarter) {
        self.executableURL = executableURL
        self.modelURL = modelURL
        self.variant = variant
    }

    public var modelFileName: String { variant.modelFileName }

    /// `$PHOTONS_ANSEL_MODEL` —— 唯一的环境变量名，写在这里以免两边拼错。
    public static let environmentKey = "PHOTONS_ANSEL_MODEL"

    /// `~/Library/Application Support/Photons/models` —— 用户放模型的地方。
    public static func userModelDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Photons/models", isDirectory: true)
    }

    /// 找不到模型时，tooltip 里必须出现的那个路径 —— **app 自带的那个位置**。
    ///
    /// 2026-11-12（用户口径「modelURL应该存在于photons app内部，因为现在photons打包是包含模型的」）：
    /// 模型随 app 打包（`bundle-ansel-models.sh` 把它放进 `Contents/Resources/bin/models/`），
    /// 所以「缺失」指的是**打包漏了**，不是「用户还没下载」。tooltip 因此要指向 app 内部，
    /// 让人一眼看出是打包问题；告诉用户往 `~/Library/Application Support` 放文件，等于建议他用
    /// 一个我们本来就不指望他填的位置。
    ///
    /// 只有在 `bundle.resourceURL` 拿不到时（单元测试的非 app 宿主）才退回用户目录 —— 那里是
    /// 用户**换变体**（half/large/multi）时才用的位置，不是默认模型的来源。
    public static func expectedModelPath(variant: AnselDenoiseVariant,
                                        bundle: Bundle = .main,
                                        fileManager: FileManager = .default) -> URL {
        if let resources = bundle.resourceURL {
            return resources.appendingPathComponent("bin/models/\(variant.modelFileName)")
        }
        return userModelDirectory(fileManager: fileManager)
            .appendingPathComponent(variant.modelFileName)
    }

    /// 按优先级返回所有候选（explicit 覆盖优先），保证 tooltip 与真正查找的顺序是同一份。
    public func searchedModelURLs(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  bundle: Bundle = .main,
                                  fileManager: FileManager = .default) -> [URL] {
        if let modelURL { return [modelURL] }
        var out: [URL] = []
        if let env = environment[Self.environmentKey], !env.isEmpty {
            out.append(URL(fileURLWithPath: (env as NSString).expandingTildeInPath))
        }
        if let resources = bundle.resourceURL {
            // 387 — the weights ship **inside the ansel-denoise-swift module's own directory**,
            // next to the executable. They are that GPL tool's data, not Photons' resource: the app
            // spawns the binary and passes this path as an argument, and never reads it itself. So
            // the bundle layout keeps the licence boundary visible — `Resources/bin/` is the
            // aggregate, top-level `Resources/` is Photons' own.
            out.append(resources.appendingPathComponent("bin/models/\(modelFileName)"))
            // The pre-387 location, kept so a hand-placed weight there keeps working.
            out.append(resources.appendingPathComponent("models/\(modelFileName)"))
        }
        out.append(Self.expectedModelPath(variant: variant, fileManager: fileManager))
        return out
    }

    /// 第一个真实存在的模型；`nil` 表示这个功能今天不可用（菜单灰）。
    public func resolvedModel(environment: [String: String] = ProcessInfo.processInfo.environment,
                              bundle: Bundle = .main,
                              fileManager: FileManager = .default) -> URL? {
        searchedModelURLs(environment: environment, bundle: bundle, fileManager: fileManager)
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    /// 菜单 tooltip 用的「期望路径」：显式给了就用它，否则是 app 自带的那条完整路径。
    public func modelPathHint(bundle: Bundle = .main,
                              fileManager: FileManager = .default) -> String {
        (modelURL ?? Self.expectedModelPath(variant: variant, bundle: bundle,
                                            fileManager: fileManager)).path
    }

    /// `AnselDenoiseClient` 的解析结果。注意它会把一条**不存在**的显式路径原样收下，
    /// 所以「工具真的在」这件事必须自己按 `isExecutableFile` 再问一次。
    public func client(environment: [String: String] = ProcessInfo.processInfo.environment,
                       bundle: Bundle = .main) -> AnselDenoiseClient? {
        try? AnselDenoiseClient(resolvingExplicit: executableURL,
                                environment: environment,
                                bundle: bundle)
    }

    public func requireClient(environment: [String: String] = ProcessInfo.processInfo.environment,
                              bundle: Bundle = .main,
                              fileManager: FileManager = .default) throws -> AnselDenoiseClient {
        guard let client = client(environment: environment, bundle: bundle),
              fileManager.isExecutableFile(atPath: client.executableURL.path)
        else {
            throw AnselDenoiseJobError.toolMissing(searched: executableSearchHint())
        }
        return client
    }

    public func requireModel(environment: [String: String] = ProcessInfo.processInfo.environment,
                             bundle: Bundle = .main,
                             fileManager: FileManager = .default) throws -> URL {
        guard let model = resolvedModel(environment: environment, bundle: bundle,
                                        fileManager: fileManager) else {
            throw AnselDenoiseJobError.modelMissing(
                expectedPath: modelPathHint(bundle: bundle, fileManager: fileManager))
        }
        return model
    }

    private func executableSearchHint() -> [String] {
        if let executableURL { return [executableURL.path] }
        return ["\(Bundle.main.resourceURL?.path ?? "<bundle>")/bin/ansel-denoise-swift",
                "/opt/homebrew/bin/ansel-denoise-swift",
                "/usr/local/bin/ansel-denoise-swift"]
    }
}

// MARK: - 失败

/// 宿主侧还会失败的四种情形。**读文件失败不在这里**：解码、缺 tag、坏 CFA 相位现在都是工具
/// 自己的错误（它读那个文件，所以它报那一份），经 `AnselDenoiseFailure` 原样变成 `.denoise`。
public enum AnselDenoiseJobError: Error, CustomStringConvertible, Sendable {
    case notADNG(String)
    case toolMissing(searched: [String])
    case modelMissing(expectedPath: String)
    case denoise(String)
    case move(String)

    public var description: String {
        switch self {
        case .notADNG(let name):
            return "只支持 DNG：\(name)"
        case .toolMissing:
            return AnselDenoiseNotices.toolMissing
        case .modelMissing(let path):
            return AnselDenoiseNotices.modelMissing(path)
        case .denoise(let message):
            return "降噪失败：\(message)"
        case .move(let message):
            return "产物落盘失败：\(message)"
        }
    }
}

// MARK: - 任务

/// 一张 DNG 进，`<原名>-denoised.dng` 出。**阻塞**，调用方负责放到后台队列。
public struct AnselDenoiseJob: Sendable {

    public struct Outcome: Sendable {
        /// 产物：与原文件同目录的 `<原名>-denoised.dng`（同名已存在时 `<原名>-denoised-2.dng`）。
        public let output: URL
        public let width: Int
        public let height: Int
        /// **不再由工具回报**：黑白电平留在文件自己的 tag 里（工具整份复制），这条 DNG 路径
        /// 上没有任何东西需要把它们单独抬出来。留着字段是因为 `Outcome` 是公开 API 且
        /// `CatalogSession` 会把它抄进 `DenoiseReport`；值为 `0`，不要当读数用。
        public let whiteLevel: Double
        /// 同上，恒为 `[]`。
        public let blackLevels: [Double]
        /// 文件声明的 CFA 相位（tag 33422），工具读出来的那一个。
        public let cfa: String
        /// 保留字段：与 `pieces` 同值（386 的菜单/报告都叫它 tile 数）。
        public let tiles: Int
        /// Pieces the tool used; 1 means a single pass and therefore no seams.
        public let pieces: Int
        public let seams: Int
        public let seconds: Double
        public let backend: String
        public let byteCount: Int
        /// 这次是从哪个文件读的（`output` 是它的兄弟）。
        public let source: URL
    }

    public var location: AnselDenoiseLocation
    public var options: AnselDenoiseOptions

    public init(location: AnselDenoiseLocation = AnselDenoiseLocation(),
                options: AnselDenoiseOptions = AnselDenoiseOptions()) {
        self.location = location
        self.options = options
    }

    // MARK: 命名（§3 ②）

    /// `<原名>-denoised.dng`，同目录、扩展名小写；已存在则 `-denoised-2`、`-denoised-3`…
    ///
    /// 选「递增」而不是「覆盖」，理由和 `HDRMergeService.uniqueURL` 一样：一次降噪可能跑几分钟，
    /// 静默覆盖掉上一次的产物是唯一不可撤销的失败。也不 `-1`：后缀前面那串就是第一次。
    public static func outputURL(for source: URL, fileManager: FileManager = .default) -> URL {
        let directory = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent("\(stem)-denoised.dng")
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem)-denoised-\(n).dng")
            n += 1
        }
        return candidate
    }

    // MARK: 跑

    /// 一次完整链路：**把两个路径交给工具**，然后一次改名。
    ///
    /// 工具写的是临时名，所以任何一步失败都不会在源目录留下半个 `-denoised.dng`（§3 ④）：
    /// 工具自己失败时不会写出文件，写出来了但没退出 0 时 `defer` 会把它删掉，只有 JSON 报告
    /// 与文件都存在之后才改成最终名。
    ///
    /// CFA 不再作为参数传：文件里有（tag 33422），工具自己读。宿主传错才是 bug —— 一个坏相位
    /// 会让整张图变棋盘格，而宿主没有任何办法比工具更清楚这个文件。
    public func run(source: URL,
                    progress: ((String) -> Void)? = nil) throws -> Outcome {
        let fm = FileManager.default
        guard source.pathExtension.lowercased() == "dng", fm.fileExists(atPath: source.path) else {
            throw AnselDenoiseJobError.notADNG(source.lastPathComponent)
        }
        let client = try location.requireClient()
        let model = try location.requireModel()
        // 协议门槛：没有 `image-dng` 的工具只能做 f32 搬运，而宿主这边已经不搬了。与其让它
        // 猜一个形状不同的参数表，不如在这里说清「工具太旧」。
        guard (try? client.supportsDNG()) == true else {
            throw AnselDenoiseJobError.toolMissing(searched: [client.executableURL.path])
        }

        var options = self.options
        // 噪声参数：本单先用默认（`Var = a·x + b`），ISO 自适应留给下一单（§2.1）。
        if options.noiseA.isEmpty { options.noiseA = [0.0004, 0.0003, 0.0004] }
        if options.noiseB.isEmpty { options.noiseB = [3e-6, 1e-6, 1e-6] }

        let finalURL = Self.outputURL(for: source, fileManager: fm)
        let temp = finalURL.deletingLastPathComponent()
            .appendingPathComponent(".denoise-\(UUID().uuidString).dng")
        defer { try? fm.removeItem(at: temp) }

        progress?("降噪 \(source.lastPathComponent)…")
        let report: AnselDenoiseDNGReport
        do {
            report = try client.denoiseImage(model: model, input: source, output: temp, options: options)
        } catch let failure as AnselDenoiseFailure {
            // `tool_failed` 的 message 就是工具的 stderr，本身已经是给用户看的那句中文
            // （「解码 RAW 失败：…」）。再套一层 `code:` 只会让菜单那句读起来像日志。
            throw AnselDenoiseJobError.denoise(
                failure.code == "tool_failed" ? failure.message : failure.description)
        } catch {
            throw AnselDenoiseJobError.denoise("\(error)")
        }
        if report.backend != "gpu" && options.useGPU {
            // 不致命（CPU 上结果仍然正确），但这是唯一能把「跑 7 分钟」和「跑 40 秒」区分开的
            // 地方，所以它必须出现在进度文案里，而不是只躺在报告里等人去读。
            progress?("降噪完成（CPU：--gpu 未生效）")
        }
        do {
            try? fm.removeItem(at: finalURL)
            try fm.moveItem(at: temp, to: finalURL)
        } catch {
            throw AnselDenoiseJobError.move("\(error)")
        }

        return Outcome(output: finalURL, width: report.width, height: report.height,
                       whiteLevel: 0, blackLevels: [], cfa: report.cfa,
                       tiles: report.pieces, pieces: report.pieces, seams: report.seams,
                       seconds: report.seconds, backend: report.backend,
                       byteCount: report.outputBytes, source: source)
    }
}
