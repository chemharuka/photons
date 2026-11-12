//
//  AnselDenoiseJob.swift
//
//  §386 的端到端链路：**一个函数从文件到文件**。
//
//      DNG → SourceDNGDecode.readMosaic(UInt16)
//          → 归一化（减黑电平、除以白电平-黑电平）
//          → AnselDenoiseService.denoise（阻塞，务必 off-main）
//          → 反归一化回 UInt16
//          → DNGRawWriter.write(from: 原文件, to: 产物)   ← tag 全量复制
//          → <同目录>/<原名>-denoised.dng
//
//  为什么归一化在这里而不是在四个既有文件里：`SourceDNGDecode` 给的是文件自己的
//  `UInt16` 原始样本（**黑电平没有减**），`DNGRawWriter` 要的也是同一量级的 `UInt16`，
//  中间那层归一化只对 `AnselDenoiseService` 有意义（它按 [0,1] 的 `Var = a·x + b`
//  理解噪声）。所以「除/乘」属于调用方 —— 也就是本文件。两边都不改，插件的行为一个字节不动。
//
//  GPL 边界不变：本文件只调 `AnselDenoiseClient` / `AnselDenoiseService` 的公开 API，
//  `ansel-denoise-swift` 始终是子进程。
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

    /// 找不到模型时，tooltip 里必须出现的那个路径（第 3 级，用户能自己放文件的一级）。
    public static func expectedModelPath(variant: AnselDenoiseVariant,
                                        fileManager: FileManager = .default) -> URL {
        userModelDirectory(fileManager: fileManager)
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

    /// 菜单 tooltip 用的「期望路径」：显式给了就用它，否则是第 3 级那条完整路径。
    public func modelPathHint(fileManager: FileManager = .default) -> String {
        (modelURL ?? Self.expectedModelPath(variant: variant, fileManager: fileManager)).path
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
            throw AnselDenoiseJobError.modelMissing(expectedPath: modelPathHint(fileManager: fileManager))
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

// MARK: - 归一化

/// 一张 DNG 自己的「黑电平 / 白电平」，以及两个方向的换算。
///
/// 黑电平按 CFA 相位取值（`BlackLevelRepeatDim` 2×2 ⇒ 4 个值，Leica 是 4×512），
/// 白电平是标量。归一化就是 `(v − black)/(white − black)`，与 DNG 规范里 CFA 数据的
/// 定义一致 —— 这也是 `AnselDenoiseService` 的输入契约（黑已减、除过白电平）。
///
/// **往返必须是恒等**（§3 ④）：`normalize` 存 `Float`，`denormalize` 在 `Double` 里乘回去再
/// 四舍五入。`Float` 的相对误差 ≤ 2⁻²⁴，乘上 15871 的码值跨度后远小于 0.5 码，所以对任何
/// 落在 `[black, white]` 里的样本都精确还原（测试逐样本断言，容差 0）。
public struct MosaicNormalization: Sendable, Equatable {

    /// 每个 CFA 相位的黑电平，行优先。
    public let blackByPhase: [Double]
    public let repeatRows: Int
    public let repeatCols: Int
    public let white: Double

    public init(blackByPhase: [Double], repeatRows: Int = 2, repeatCols: Int = 2, white: Double) {
        precondition(!blackByPhase.isEmpty, "black levels must not be empty")
        precondition(white > blackByPhase.max()!, "white level must exceed every black level")
        self.blackByPhase = blackByPhase
        self.repeatRows = max(1, repeatRows)
        self.repeatCols = max(1, repeatCols)
        self.white = white
    }

    /// 单值黑电平的常见情形（`BlackLevel` 只有一个值）。
    public init(black: Double, white: Double) {
        self.init(blackByPhase: [black], repeatRows: 1, repeatCols: 1, white: white)
    }

    public var range: Double { white - blackByPhase[0] }

    public func black(row: Int, col: Int) -> Double {
        let r = row % repeatRows, c = col % repeatCols
        let index = r * repeatCols + c
        return blackByPhase[min(index, blackByPhase.count - 1)]
    }

    @inline(__always)
    public func normalize(_ value: UInt16, row: Int, col: Int) -> Float {
        Float((Double(value) - black(row: row, col: col)) / range)
    }

    @inline(__always)
    public func denormalize(_ value: Float, row: Int, col: Int) -> UInt16 {
        guard value.isFinite else { return UInt16(black(row: row, col: col).rounded()) }
        let raw = Double(value) * range + black(row: row, col: col)
        if raw <= 0 { return 0 }
        if raw >= Double(UInt16.max) { return UInt16.max }
        return UInt16(raw.rounded())
    }

    public func normalized(_ samples: [UInt16], width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: samples.count)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                out[row + x] = normalize(samples[row + x], row: y, col: x)
            }
        }
        return out
    }

    public func quantized(_ mosaic: [Float], width: Int, height: Int) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: mosaic.count)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                out[row + x] = denormalize(mosaic[row + x], row: y, col: x)
            }
        }
        return out
    }
}

// MARK: - 失败

public enum AnselDenoiseJobError: Error, CustomStringConvertible, Sendable {
    case notADNG(String)
    case noRawImage(String)
    case missingTag(String, Int)
    case missingCFAPattern
    case badCFAPattern(String)
    case toolMissing(searched: [String])
    case modelMissing(expectedPath: String)
    case decode(String)
    case denoise(String)
    case write(String)
    case move(String)

    public var description: String {
        switch self {
        case .notADNG(let name):
            return "只支持 DNG：\(name)"
        case .noRawImage(let name):
            return "\(name) 里没有 CFA RAW 数据（已去马赛克的线性 DNG 无法降噪）"
        case .missingTag(let what, let tag):
            return "源文件缺少 \(what)（tag \(tag)），无法做黑/白电平归一化"
        case .missingCFAPattern:
            return "源文件缺少 CFAPattern（tag 33422），无法确定 Bayer 相位"
        case .badCFAPattern(let raw):
            return "无法解析 CFA 相位：\(raw)"
        case .toolMissing:
            return AnselDenoiseNotices.toolMissing
        case .modelMissing(let path):
            return AnselDenoiseNotices.modelMissing(path)
        case .decode(let message):
            return "解码 RAW 失败：\(message)"
        case .denoise(let message):
            return "降噪失败：\(message)"
        case .write(let message):
            return "写入降噪后的 DNG 失败：\(message)"
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
        public let whiteLevel: Double
        public let blackLevels: [Double]
        public let cfa: String
        public let tiles: Int
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

    // MARK: 读数（黑/白/CFA 都来自原文件自己）

    /// `BlackLevel` / `WhiteLevel` / `BlackLevelRepeatDim` / `CFAPattern`，全部按原文件。
    ///
    /// 一律 `Double`：`BlackLevel` 可能是 RATIONAL（Leica 写 `512/1`），也可能是 SHORT 数组。
    static func normalization(of doc: SourceDNG) throws -> MosaicNormalization {
        let blackEntry = doc.raw[50714] ?? doc.ifd0[50714]
        let whiteEntry = doc.raw[50717] ?? doc.ifd0[50717]
        let repeatEntry = doc.raw[50713] ?? doc.ifd0[50713]

        let blacks = numericValues(blackEntry)
        guard !blacks.isEmpty else { throw AnselDenoiseJobError.missingTag("BlackLevel", 50714) }
        guard let white = numericValues(whiteEntry).first else {
            throw AnselDenoiseJobError.missingTag("WhiteLevel", 50717)
        }
        let dims = numericValues(repeatEntry)
        let rows = dims.count >= 2 ? Int(dims[0]) : (blacks.count == 4 ? 2 : 1)
        let cols = dims.count >= 2 ? Int(dims[1]) : (blacks.count == 4 ? 2 : 1)
        guard white > (blacks.max() ?? 0) else {
            throw AnselDenoiseJobError.missingTag("WhiteLevel > BlackLevel", 50717)
        }
        return MosaicNormalization(blackByPhase: blacks, repeatRows: rows, repeatCols: cols,
                                   white: white)
    }

    /// `33422 CFAPattern` → `"rggb"` 这样的四字母。猜是不允许的：坏相位会让整张图变棋盘格，
    /// 所以标签缺失就直接报错，而不是假设 rggb。
    static func cfaPattern(of doc: SourceDNG) throws -> String {
        guard let entry = doc.raw[33422] ?? doc.ifd0[33422] else {
            throw AnselDenoiseJobError.missingCFAPattern
        }
        let values = numericValues(entry).map { Int($0) }
        guard values.count == 4 else {
            throw AnselDenoiseJobError.badCFAPattern("\(values)")
        }
        let letters = values.map { v -> Character in
            switch v {
            case 0: return "r"
            case 1: return "g"
            case 2: return "b"
            default: return "?"
            }
        }
        guard !letters.contains("?") else {
            throw AnselDenoiseJobError.badCFAPattern("\(values)")
        }
        return String(letters)
    }

    /// TIFF 的数值标签 → `Double`。只处理本文件真的会读的类型（BYTE/SHORT/LONG/RATIONAL/
    /// SRATIONAL），别的类型返回空数组 —— 一个不认识的类型不该被猜成 0。
    static func numericValues(_ entry: TIFFEntry?) -> [Double] {
        guard let entry else { return [] }
        func u16(_ i: Int) -> Double { Double(UInt16(entry.value[i]) | (UInt16(entry.value[i + 1]) << 8)) }
        func u32(_ i: Int) -> Double {
            Double(UInt32(entry.value[i]) | (UInt32(entry.value[i + 1]) << 8)
                   | (UInt32(entry.value[i + 2]) << 16) | (UInt32(entry.value[i + 3]) << 24))
        }
        var out: [Double] = []
        switch entry.type {
        case 1:                                  // BYTE
            out = entry.value.prefix(entry.count).map(Double.init)
        case 3:                                  // SHORT
            var i = 0
            while i + 2 <= entry.value.count { out.append(u16(i)); i += 2 }
        case 4:                                  // LONG
            var i = 0
            while i + 4 <= entry.value.count { out.append(u32(i)); i += 4 }
        case 5, 10:                              // RATIONAL / SRATIONAL
            var i = 0
            while i + 8 <= entry.value.count {
                let num = Double(u32(i)), den = Double(u32(i + 4))
                out.append(den == 0 ? 0 : num / den)
                i += 8
            }
        default:
            break
        }
        return out
    }

    // MARK: 跑

    /// 一次完整链路。产物**先写临时名再改名**：任何一步失败都不会在源目录留下半个
    /// `-denoised.dng`（§3 ⑤）。
    public func run(source: URL,
                    progress: ((String) -> Void)? = nil) throws -> Outcome {
        let fm = FileManager.default
        guard source.pathExtension.lowercased() == "dng" else {
            throw AnselDenoiseJobError.notADNG(source.lastPathComponent)
        }
        guard fm.fileExists(atPath: source.path) else {
            throw AnselDenoiseJobError.notADNG(source.lastPathComponent)
        }
        let client = try location.requireClient()
        let model = try location.requireModel()

        // 1. 读 mosaic（UInt16，黑电平**还没**减）
        progress?("读取 RAW…")
        let data: Data
        let doc: SourceDNG
        let mosaicSamples: (samples: [UInt16], width: Int, height: Int)
        do {
            data = try Data(contentsOf: source, options: .alwaysMapped)
            doc = try SourceDNG(data: data)
            mosaicSamples = try doc.readMosaic(data: data)
        } catch let error as AnselDenoiseJobError {
            throw error
        } catch let error as SourceDNG.ReadError {
            // 没有 SubIFDs / 不是 CFA：这是「不是可降噪的 DNG」，不是像素解码坏了。
            if case .noRawSubIFD = error {
                throw AnselDenoiseJobError.noRawImage(source.lastPathComponent)
            }
            throw AnselDenoiseJobError.decode(error.description)
        } catch {
            throw AnselDenoiseJobError.decode("\(error)")
        }

        let normalization = try Self.normalization(of: doc)
        let cfa = try Self.cfaPattern(of: doc)
        let width = mosaicSamples.width, height = mosaicSamples.height
        guard width > 0, height > 0, mosaicSamples.samples.count == width * height else {
            throw AnselDenoiseJobError.decode("mosaic 尺寸与像素数不符")
        }

        // 2. 归一化 → 降噪 → 反归一化
        var options = self.options
        options.cfa = cfa
        // 噪声参数：本单先用默认（`Var = a·x + b`），ISO 自适应留给下一单（§2.1）。
        if options.noiseA.isEmpty { options.noiseA = [0.0004, 0.0003, 0.0004] }
        if options.noiseB.isEmpty { options.noiseB = [3e-6, 1e-6, 1e-6] }

        progress?("归一化 \(width)×\(height)…")
        let normalized = normalization.normalized(mosaicSamples.samples, width: width, height: height)

        progress?("降噪 \(width)×\(height)，tile \(options.tileSize)…")
        let service = AnselDenoiseService(client: client, modelURL: model)
        let outcome: AnselDenoiseOutcome
        do {
            outcome = try service.denoise(mosaic: normalized, width: width, height: height,
                                          options: options)
        } catch let failure as AnselDenoiseFailure {
            throw AnselDenoiseJobError.denoise(failure.description)
        } catch {
            throw AnselDenoiseJobError.denoise("\(error)")
        }

        progress?("写回 \(outcome.tiles) 个 tile 的 DNG…")
        let quantized = normalization.quantized(outcome.mosaic, width: width, height: height)

        // 3. 写 DNG：临时名 → 改名。`DNGRawWriter` 全量复制 tag（黑白电平、ActiveArea、
        //    DefaultCrop、OpcodeList2/3、XMP、EXIF/GPS、预览），所以产物能按原样渲染。
        let finalURL = Self.outputURL(for: source, fileManager: fm)
        let temp = finalURL.deletingLastPathComponent()
            .appendingPathComponent(".denoise-\(UUID().uuidString).dng")
        defer { try? fm.removeItem(at: temp) }

        let result: DNGRawWriter.Result
        do {
            result = try DNGRawWriter.write(samples: quantized, width: width, height: height,
                                            from: source, to: temp)
        } catch {
            throw AnselDenoiseJobError.write("\(error)")
        }
        do {
            try? fm.removeItem(at: finalURL)
            try fm.moveItem(at: temp, to: finalURL)
        } catch {
            throw AnselDenoiseJobError.move("\(error)")
        }

        return Outcome(output: finalURL, width: width, height: height,
                       whiteLevel: normalization.white, blackLevels: normalization.blackByPhase,
                       cfa: cfa, tiles: outcome.tiles, seconds: outcome.seconds,
                       backend: outcome.backend, byteCount: result.byteCount, source: source)
    }
}
