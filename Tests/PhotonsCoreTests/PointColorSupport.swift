import Foundation
import simd

/// 285 test support: CIEDE2000 on **encoded sRGB** values, so the acceptance can speak in ΔE00
/// instead of channel codes. Kept in the test target only; no production code depends on it.
enum PointColorDeltaE {

    /// Encoded sRGB (0…1) → CIELAB D65.
    static func lab(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        func decode(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = decode(rgb.x), g = decode(rgb.y), b = decode(rgb.z)
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        func f(_ t: Double) -> Double {
            let e = 216.0 / 24389.0
            return t > e ? cbrt(t) : (24389.0 / 27.0 * t + 16) / 116
        }
        let fx = f(x), fy = f(y), fz = f(z)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// CIEDE2000 (kL = kC = kH = 1) between two encoded-sRGB colours.
    static func deltaE00(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let lab1 = lab(a), lab2 = lab(b)
        let l1 = lab1.x, a1 = lab1.y, b1 = lab1.z
        let l2 = lab2.x, a2 = lab2.y, b2 = lab2.z

        let c1 = (a1 * a1 + b1 * b1).squareRoot()
        let c2 = (a2 * a2 + b2 * b2).squareRoot()
        let cBar = (c1 + c2) / 2
        let cBar7 = pow(cBar, 7)
        let g = 0.5 * (1 - (cBar7 / (cBar7 + pow(25, 7))).squareRoot())
        let a1p = (1 + g) * a1
        let a2p = (1 + g) * a2
        let c1p = (a1p * a1p + b1 * b1).squareRoot()
        let c2p = (a2p * a2p + b2 * b2).squareRoot()

        func hue(_ b: Double, _ ap: Double) -> Double {
            guard ap != 0 || b != 0 else { return 0 }
            var h = atan2(b, ap) * 180 / .pi
            if h < 0 { h += 360 }
            return h
        }
        let h1p = hue(b1, a1p)
        let h2p = hue(b2, a2p)

        let dLp = l2 - l1
        let dCp = c2p - c1p
        var dhp = 0.0
        if c1p * c2p != 0 {
            dhp = h2p - h1p
            if dhp > 180 { dhp -= 360 }
            if dhp < -180 { dhp += 360 }
        }
        let dHp = 2 * (c1p * c2p).squareRoot() * sin(dhp * .pi / 360)

        let lBar = (l1 + l2) / 2
        let cBarP = (c1p + c2p) / 2
        let hBarP: Double
        if c1p * c2p == 0 {
            hBarP = h1p + h2p
        } else if abs(h1p - h2p) <= 180 {
            hBarP = (h1p + h2p) / 2
        } else if h1p + h2p < 360 {
            hBarP = (h1p + h2p + 360) / 2
        } else {
            hBarP = (h1p + h2p - 360) / 2
        }

        func rad(_ deg: Double) -> Double { deg * .pi / 180 }
        let t = 1 - 0.17 * cos(rad(hBarP - 30))
            + 0.24 * cos(rad(2 * hBarP))
            + 0.32 * cos(rad(3 * hBarP + 6))
            - 0.20 * cos(rad(4 * hBarP - 63))
        let dTheta = 30 * exp(-pow((hBarP - 275) / 25, 2))
        let cBarP7 = pow(cBarP, 7)
        let rC = 2 * (cBarP7 / (cBarP7 + pow(25, 7))).squareRoot()
        let sL = 1 + (0.015 * pow(lBar - 50, 2)) / (20 + pow(lBar - 50, 2)).squareRoot()
        let sC = 1 + 0.045 * cBarP
        let sH = 1 + 0.015 * cBarP * t
        let rT = -sin(rad(2 * dTheta)) * rC

        let lTerm = dLp / sL
        let cTerm = dCp / sC
        let hTerm = dHp / sH
        return (lTerm * lTerm + cTerm * cTerm + hTerm * hTerm
                + rT * cTerm * hTerm).squareRoot()
    }
}
