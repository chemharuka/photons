import Foundation
import PhotonsCore

// MARK: - 229 · 红眼 as a preset of 修复
//
// The card's segmented control flips this enum; the canvas keeps one heal gesture either way. The
// only differences are (a) which radius the click starts from and (b) whether the landed spot is
// `kind: .redeye` (rendered through S1.9's red gate).

/// 修复 / 红眼 — the 修复 card's tool preset.
public enum HealToolMode: String, Sendable, CaseIterable {
    case heal
    case redeye

    public var label: String {
        switch self {
        case .heal: return "修复"
        case .redeye: return "红眼"
        }
    }
}

extension CatalogSession {

    /// One red-eye click — **one snapshot**, whether a pupil was found or not.
    ///
    /// The negative gate is a *pixel* gate, not a history gate: a click on skin or an empty wall
    /// writes a spot with `redThreshold == RedEye.noopThreshold`, so the S1.9 pass changes zero
    /// pixels but ⌘Z can still take the click back. That is what lets three clicks on a photograph
    /// be exactly three history rows while the no-pupil acceptance stays byte-identical.
    ///
    /// `searchRadius` is in **short-edge units**. The controller derives it from the card's points
    /// and the live projection; a headless caller may pass it directly (omitted = 3 % of the short
    /// edge, a sensible click-sized fallback).
    ///
    /// 249 — `sourcePoint` is **S1 source-normalised** (the raw upright decode, the same frame
    /// `healFrameProvider` hands over), so the seed window no longer needs a crop conversion.
    @discardableResult
    public func addRedEyeSpot(at sourcePoint: NormalizedPoint,
                              searchRadius: Double? = nil,
                              threshold: Double = RedEye.defaultThreshold,
                              softness: Double = RedEye.defaultSoftness,
                              requireDetection: Bool = false) -> HealSpot? {
        guard sourcePoint.x >= 0, sourcePoint.x <= 1,
              sourcePoint.y >= 0, sourcePoint.y <= 1 else { return nil }
        let fallback = max(0.0015, min(searchRadius ?? redEyeRadiusPoints / 100, 0.5))
        let image = healFrameProvider?()
        var detection: RedEye.Detection?
        var seed = fallback

        if let image {
            let hints = redEyeFaceHintProvider?(image) ?? []
            seed = redEyeSeedRadius(hints: hints, click: sourcePoint, image: image, fallback: fallback)
            detection = RedEye.detect(in: image, near: sourcePoint,
                                      searchRadius: seed, threshold: threshold)
        }
        if requireDetection, detection == nil {
            setLastRedEyeDetection(nil)
            return nil
        }

        let center = detection?.center ?? sourcePoint
        let radius = detection?.radius ?? fallback
        let source = redEyeSource(in: image, center: center, radius: radius, threshold: threshold)
        let gate = detection == nil ? RedEye.noopThreshold : threshold
        let spot = HealSpot(center: center, radius: radius,
                            sourceOffset: source.offset,
                            mode: .heal,
                            // The red gate is the edge. The disk's own feather would blend red
                            // pixels back in at the rim, so red-eye spots use the hard disk.
                            feather: 0,
                            opacity: min(max(redEyeStrength, 0), 1),
                            kind: .redeye,
                            redThreshold: gate,
                            redSoftness: softness)
        var landed: HealSpot?
        applyEdit { landed = $0.addHealSpot(spot) }
        guard let landed else { return nil }
        commitEdit(label: "红眼", coalesce: false)
        selectedHealSpotID = landed.id
        setLastHealSource(source)
        setLastRedEyeDetection(detection)
        return landed
    }

    /// Grow the seed to the eye box when the click landed on an eye; an animal box gets only a
    /// box-sized seed (Vision has no dog/cat pupil landmarks). Never a pupil claim.
    private func redEyeSeedRadius(hints: [RedEyeFaceHint], click: NormalizedPoint,
                                  image: LinearImage, fallback: Double) -> Double {
        let w = Double(image.width), h = Double(image.height)
        let shortEdge = max(min(w, h), 1)
        let px = click.x * w, py = click.y * h

        for face in hints where face.kind == .face {
            for eye in face.eyeBounds {
                let ex0 = eye.x * w, ey0 = eye.y * h
                let ew = max(eye.width * w, 1), eh = max(eye.height * h, 1)
                let padX = 0.25 * ew, padY = 0.25 * eh
                guard px >= ex0 - padX, px <= ex0 + ew + padX,
                      py >= ey0 - padY, py <= ey0 + eh + padY else { continue }
                return max(fallback, 0.55 * max(ew, eh) / shortEdge)
            }
        }
        for animal in hints where animal.kind == .animal {
            let ax0 = animal.bounds.x * w, ay0 = animal.bounds.y * h
            let aw = animal.bounds.width * w, ah = animal.bounds.height * h
            guard px >= ax0, px <= ax0 + aw, py >= ay0, py <= ay0 + ah else { continue }
            return max(fallback, 0.06 * min(aw, ah) / shortEdge)
        }
        return fallback
    }

    /// Heal's own source search first; when it lands on something red, the non-red ring. With 自动
    /// 取源 off, the legacy `(2r, 0)` is what the renderer gets (the kernel still neutralises a red
    /// sample, so the result cannot be a second pupil copied into the first).
    private func redEyeSource(in image: LinearImage?, center: NormalizedPoint,
                              radius: Double, threshold: Double) -> HealSourceResult {
        guard autoHealSource, let image else {
            return .skipped(radius: radius)
        }
        let auto = HealSpot.searchSource(in: image, center: center, radius: radius)
        if auto.status == .found,
           RedEye.sourceIsNeutral(in: image, center: center, radius: radius,
                                  offset: auto.offset, threshold: threshold) {
            return auto
        }
        if let ring = RedEye.neutralSource(in: image, center: center,
                                           radius: radius, threshold: threshold) {
            return ring
        }
        return .skipped(radius: radius)
    }
}
