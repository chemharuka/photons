import Foundation
import PhotonsCore
import CryptoKit

/// 329 — **the empty-mask key vector, composed from the constants rather than typed.**
///
/// Two tests pin the nine M1 links of the same fixture (`MaskTests.testEmptyMasksProduceTheM1KeysByteForByte`
/// and `WindowTests.testNilWindowKeepsTheSevenM1KeysByteForByte`); they used to carry two hand-written
/// copies of the same fifty lines, and after 314/320/323 both copies were wrong in the same way. This
/// is the one composition, so they cannot drift apart:
///
///   · `alg=N` from `StageAlgorithmVersion.version(of:)` — 307 moved `.geometry` 3 → 5 (S0's canvas
///     gained a second role: the same crop/angle renders a different picture);
///   · `pv=N` from `EditModel.currentProcessVersion`;
///   · `ceil=…` from `DisplayOptions.ceilingKeyString` — 320 made the picture's ceiling an adjustable
///     number (+2.3 EV) and 323 made the tone-map link name it as well as the display link, so the
///     same document spells `ceil=4.9246` twice;
///   · the vignette's material reaches the S2 seed (329, `RenderKeyChain.links`): the pass runs
///     **before** the tone map (116) but its link used to be built below it, which is how a warmed
///     graph returned the previous frame for a 暗角 drag. It is spelled `…|vignette|vig=…` there.
///
/// What stays pinned is the **whole vector as one digest**: the parameters, their order, the separators,
/// the parent digests and every material's spelling. Anything that moves any of them fails one
/// assertion with the vector's hash — that is the deliberate re-pin signal (§3.2), and the reason lives
/// next to `pinnedDigest`.
enum M1KeyVector {

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func alg(_ stage: RenderStage) -> Int { StageAlgorithmVersion.version(of: stage) }

    /// The nine links, in chain order, as `(stage name, canonical text)`.
    static var stages: [(name: String, text: String)] {
        let pv = EditModel.currentProcessVersion
        let ceiling = DisplayOptions().ceilingKeyString
        func h(_ text: String) -> String { sha256(text) }

        let header = "photons-render-v1|keyvec-fixture|6000x4000|1500x1000|1500x1000"
        let geometry = "\(header)|pv=\(pv)"
            + ";crop=0.10000,0.05000,0.80000,0.75000;rot=1.50000;flip=10;alg=\(alg(.geometry))"
        let sceneLinear = "\(h(geometry))"
            + "|ev=0.75000;temp=5200.00000;tint=12.00000;hlr=0.40000;wh=10.00000;bl=-8.33333"
            + ";alg=\(alg(.sceneLinear))"
        // 030: the curve changed stage (`curve` before S2, `w=` instead of `rgb=`); 069: its axis is
        // the card's 0…2 and its points print six decimals.
        let curve = "\(h(sceneLinear))"
            + "|w=0.000000,0.000000;0.600000,0.500000;2.000000,2.000000"
            + "|r=0.000000,0.000000;2.000000,2.000000"
            + "|g=0.000000,0.000000;2.000000,2.000000"
            + "|b=0.000000,0.000000;2.000000,2.000000;alg=\(alg(.curve))"
        // 329: the vignette is key material for S2 — the pass runs between the curve and the tone map.
        let vignetteMaterial = "vig=-40.00000;mid=45.00000;fea=60.00000;alg=\(alg(.vignette))"
        let s2Seed = h("\(h(curve))|vignette|\(vignetteMaterial)")
        // 323: the ceiling is the tone map's own key material (the clamp runs at the end of S2).
        let toneMap = "\(s2Seed)|hi=-30.00000;sh=15.00000;alg=\(alg(.toneMap))|\(ceiling)"
        // 159/228: the contrast link is seeded by the tone map and feeds colour.
        let contrast = "\(h(toneMap))|contrast|con=20.00000;alg=\(alg(.contrast))"
        let color = "\(h(contrast))|vib=15.00000;sat=-10.00000;alg=\(alg(.color))"
        let hsl = "\(h(color))|hsl|hsl=bands=0.00000,0.00000,0.00000;0.00000,0.00000,0.00000"
            + ";0.00000,0.00000,0.00000;20.00000,0.00000,0.00000"
            + ";0.00000,0.00000,0.00000;0.00000,0.00000,0.00000"
            + ";0.00000,0.00000,0.00000;0.00000,0.00000,0.00000;alg=\(alg(.hsl))"
        // 314: 锐化's resting amount is 50, so S3.10 is in the chain and the `vignette` link — whose
        // place in the chain is historical, below S3.10 — is seeded by it. The material comes from
        // `SharpenGroup()`'s own resting values (not from a document), so a default that moves cannot
        // leave this line behind.
        let sharpenLink = h("\(h(hsl))|sharpen|"
                            + SharpenGroup().keyString + StageAlgorithmVersion.token(.sharpen))
        // `vignetteSeed` is the sharpen **text**, so the vignette's parent is its digest — which is
        // `sharpenLink` itself.
        let vignette = "\(sharpenLink)|\(vignetteMaterial)"
        let display = "\(h(vignette))|\(DisplayOptions().keyString)|1500x1000"

        return [("geometry", geometry), ("sceneLinear", sceneLinear), ("curve", curve),
                ("toneMap", toneMap), ("contrast", contrast), ("color", color), ("hsl", hsl),
                ("vignette", vignette), ("display", display)]
    }

    /// `sha256` of the nine canonical texts, joined by newlines.
    static var vectorDigest: String { sha256(stages.map(\.text).joined(separator: "\n")) }

    /// The pinned vector. **Re-pin only with the reason here.**
    ///
    /// 329 — re-pinned for the three migrations that moved these bytes and had no one to follow them:
    ///   · 307 (`.geometry` 3 → 5): S0's canvas gained a second role, so the same crop/angle renders
    ///     a different picture — S0's material names the new generation;
    ///   · 320 + 323 (`ceil=`): the picture's ceiling became an adjustable +2.3 EV and both the S2
    ///     link and the display link spell it;
    ///   · 329 (`…|vignette|vig=…`): the 暗角 material now reaches the S2 seed, which is what makes a
    ///     vignette drag miss the cached frame instead of returning it (see `RenderKeyChain.links`).
    /// 314 (锐化 default 50) moves **no key** — it moves the *pipeline* (`+s3.10`), not the chain.
    static let pinnedDigest = "2e39041e32d03fcdfcb2e51062189768ed7fde850b27db815eeea2e1cde091fa"
}
