import Foundation

/// The **shipped** white-balance preview table (118).
///
/// Measured 2026-10-29 on five bodies (Leica SL3, Fuji X-T5, Panasonic DC-S5M2, Canon EOS R5,
/// Sony A7M4): every frame decoded at a fixed grid of absolute white-balance pairs *against a
/// 6000 K / tint 0 decode of the same frame*, then per-node **medians across the bodies**, so the
/// numbers are not tied to one camera.
///
/// Why one table is enough *per channel* matters (measured 2026-10-29, 4000 K anchor, SL3 vs EOS R5):
///
/// - **R and G agree to 1-2 %** across 2500-5500 K. The "cold end spreads 1.7x" we saw earlier was a
///   coordinate artefact: those tables were anchored at five different as-shot points.
/// - **Blue drifts with distance from the anchor**: 1.19x at +500 K, 1.28x at +1000 K, 1.41x at
///   +1500 K (and 0.86x at -1500 K). That is a real per-body difference in the blue channel
///   (CFA / IR-filter spectral response), Canon being the largest outlier here.
///
/// So a drag preview drawn from this table has the **right direction** everywhere and a magnitude
/// error that grows with how far the target is from the frame's as-shot. That is acceptable for a
/// preview and is the reason a per-body table, when present, still wins.
///
/// 6000 K / tint 0 is a node with the identity gain: it is the reference every measurement was
/// taken against, so its value needs no measurement.
extension WhiteBalancePreviewTable {
    public static let shipped: WhiteBalancePreviewTable = {
        let temperatures: [Double] = [3500, 4500, 5500, 6000, 6500, 8000, 10000, 12000]
        let tints: [Double] = [-40, -20, 0, 20, 40, 60]
        var gains: [[[Double]]] = []
        gains.append([
            [0.36498, 0.98727, 1.32808],
            [0.38250, 0.94457, 1.55986],
            [0.39989, 0.89146, 1.86917],
            [0.41672, 0.82340, 2.25524],
            [0.43219, 0.73273, 2.77256],
            [0.44481, 0.60542, 3.50508],
        ])
        gains.append([
            [0.61203, 1.01697, 1.05211],
            [0.65533, 0.98469, 1.18294],
            [0.70084, 0.94729, 1.35085],
            [0.74869, 0.90443, 1.54006],
            [0.79898, 0.85432, 1.76286],
            [0.85179, 0.79480, 2.03104],
        ])
        gains.append([
            [0.78215, 1.04309, 0.88564],
            [0.84621, 1.01565, 0.98116],
            [0.91460, 0.98551, 1.08644],
            [0.98773, 0.95225, 1.20472],
            [1.06202, 0.91535, 1.33663],
            [1.14747, 0.87416, 1.48538],
        ])
        gains.append([
            [1.00000, 1.00000, 1.00000],
            [1.00000, 1.00000, 1.00000],
            [1.00000, 1.00000, 1.00000],
            [1.00000, 1.00000, 1.00000],
            [1.00000, 1.00000, 1.00000],
            [1.00000, 1.00000, 1.00000],
        ])
        gains.append([
            [0.91247, 1.06353, 0.78063],
            [0.98999, 1.03879, 0.85340],
            [1.07546, 1.01216, 0.93260],
            [1.16959, 0.98317, 1.01710],
            [1.27167, 0.95178, 1.10959],
            [1.38275, 0.91758, 1.21046],
        ])
        gains.append([
            [1.02514, 1.07801, 0.67319],
            [1.12287, 1.05586, 0.72775],
            [1.23070, 1.03214, 0.78543],
            [1.34874, 1.00666, 0.84649],
            [1.47850, 0.97922, 0.91637],
            [1.62182, 0.94955, 0.98007],
        ])
        gains.append([
            [1.12192, 1.08893, 0.58806],
            [1.23647, 1.06817, 0.63057],
            [1.36248, 1.04591, 0.67483],
            [1.50177, 1.02198, 0.72093],
            [1.65653, 0.99613, 0.76899],
            [1.82950, 0.96809, 0.82398],
        ])
        gains.append([
            [1.18426, 1.09527, 0.53649],
            [1.30883, 1.07506, 0.57269],
            [1.44660, 1.05333, 0.61004],
            [1.59977, 1.02988, 0.64860],
            [1.77107, 1.00442, 0.68840],
            [1.96393, 0.97666, 0.73124],
        ])
        return WhiteBalancePreviewTable(camera: "generic", decoderVersion: "*",
                                        asShot: .init(temperature: 6000, tint: 0),
                                        temperatures: temperatures, tints: tints, gains: gains)
    }()
}
