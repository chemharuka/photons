import XCTest
import PhotonsCore
@testable import PhotonsUI

/// 439 — the frame keys' **bytes**, recorded before the identity facts were moved.
///
/// The matrix below is the frame-key identity contract: four documents (neutral / exposure + crop /
/// straighten + flip / keystone in canvas-space crop) × three cameras (fit / 1:1 centred / 3.2×
/// offset) × two frame modes (edited / compare) × two canvas roles × two headrooms. Every case pins
/// both `BackdropCache.Key.identity` and `CanvasFrameCache.Key.identity`.
///
/// This file is deliberately written against the **pre-439** spelling of the facts (`decodeInputs
/// .key`, `Histogram.editDigest`, `geometryFingerprint`, the camera/mode tokens) so the literals can
/// be recorded before any product code moves. The refactor that follows must leave every byte here
/// untouched.
final class FrameKeyGoldenTests: XCTestCase {

    private struct Case {
        let label: String
        let backdrop: String
        let canvas: String
        /// 440 — the same two identities through `LoupeFrameFacts` (the production path). The golden
        /// literals leave them empty; `matrix()` fills them in, and the test compares both paths
        /// against the same recorded bytes.
        var factsBackdrop: String = ""
        var factsCanvas: String = ""
    }

    private static let photo = "golden-photo|asset-439"
    private static let viewport = ImageSize(width: 2560, height: 1600)
    private static let fitScale = 0.9
    private static let decodeScale = 1.0
    private static let ceiling = HighlightCeiling.defaultLinear
    private static let primaries = OutputPrimaries.displayP3

    private static func edit(_ variant: Int) -> EditModel {
        var edit = EditModel.neutral
        switch variant {
        case 0:
            break
        case 1:
            edit.light.exposure = 1.25
            edit.geometry.crop = NormalizedRect(x: 0.12, y: 0.08, width: 0.62, height: 0.71)
            edit.geometry.aspectLock = .threeTwo
        case 2:
            edit.geometry.rotationDegrees = -3.7
            edit.geometry.flipHorizontal = true
        case 3:
            edit.geometry.crop = NormalizedRect(x: 0.10, y: 0.15, width: 0.70, height: 0.60)
            edit.geometry.perspectiveVertical = 35
            edit.geometry.perspectiveHorizontal = -12
            edit.geometry.cropSpace = .canvas
        default:
            break
        }
        return edit
    }

    private static func camera(_ variant: Int) -> LoupeViewState {
        switch variant {
        case 0:
            return .fit
        case 1:
            return LoupeViewState(mode: .actual, zoom: 1, centerX: 3120, centerY: 2080)
        default:
            return LoupeViewState(mode: .actual, zoom: 3.2, centerX: 1450.25, centerY: 3800.75)
        }
    }

    private static let modes: [LoupeFrameMode] = [
        .edited,
        .compare(CompareSplit(axis: .vertical, fraction: 0.42)),
    ]

    private static func matrix() -> [Case] {
        var cases: [Case] = []
        for variant in 0..<4 {
            let edit = edit(variant)
            for cameraVariant in 0..<3 {
                let camera = camera(cameraVariant)
                for mode in modes {
                    for role in [CanvasRole.document, .export] {
                        for headroom in [1.0, 4.0] {
                            let cropIsActive = variant != 0
                            let highlightWarning = variant == 2
                            let backdrop = BackdropCache.Key(
                                photo: photo,
                                develop: edit.decodeInputs.key,
                                digest: Histogram.editDigest(edit),
                                ceiling: ceiling,
                                geometry: edit.geometryFingerprint)
                            let backdropFacts = BackdropCache.Key(facts: LoupeFrameFacts(
                                documentOnly: photo, edit: edit, ceiling: ceiling))
                            let canvas = CanvasFrameCache.Key(
                                photo: photo,
                                decodeInputs: edit.decodeInputs.key,
                                editDigest: Histogram.editDigest(edit),
                                geometry: edit.geometryFingerprint,
                                cameraState: LoupeController.canvasCacheCameraToken(camera),
                                viewport: viewport,
                                mode: LoupeController.canvasCacheModeToken(mode),
                                fitScale: fitScale,
                                canvasRole: role.rawValue,
                                cropIsActive: cropIsActive,
                                highlightWarning: highlightWarning,
                                headroom: headroom,
                                decodeScale: decodeScale,
                                primaries: primaries.rawValue,
                                highlightCeiling: ceiling)
                            let canvasFacts = CanvasFrameCache.Key(facts: LoupeFrameFacts(
                                canvas: photo, edit: edit, camera: camera, viewport: viewport,
                                mode: mode, fitScale: fitScale, canvasRole: role,
                                cropIsActive: cropIsActive, highlightWarning: highlightWarning,
                                headroom: headroom, decodeScale: decodeScale, primaries: primaries,
                                ceiling: ceiling, digestSuffix: ""))
                            let label = "e\(variant)-c\(cameraVariant)-m\(modeLabel(mode))"
                                + "-r\(role.rawValue)-h\(headroom)"
                            cases.append(Case(label: label,
                                              backdrop: backdrop.identity,
                                              canvas: canvas.identity,
                                              factsBackdrop: backdropFacts.identity,
                                              factsCanvas: canvasFacts.identity))
                        }
                    }
                }
            }
        }
        return cases
    }

    private static func modeLabel(_ mode: LoupeFrameMode) -> String {
        switch mode {
        case .edited: return "edited"
        case .original: return "original"
        case .compare: return "compare"
        }
    }

    func testFrameKeyIdentities() {
        let cases = Self.matrix()
        XCTAssertEqual(cases.count, Self.golden.count)
        for (recorded, golden) in zip(cases, Self.golden) {
            XCTAssertEqual(recorded.label, golden.label)
            // 440 — two paths per identity: the facts path (production) and the direct one (bytes).
            XCTAssertEqual(recorded.factsBackdrop, golden.backdrop,
                           "backdrop facts path moved: \(golden.label)")
            XCTAssertEqual(recorded.backdrop, golden.backdrop, "backdrop key moved: \(golden.label)")
            XCTAssertEqual(recorded.factsCanvas, golden.canvas,
                           "canvas facts path moved: \(golden.label)")
            XCTAssertEqual(recorded.canvas, golden.canvas, "canvas key moved: \(golden.label)")
        }
    }

    // BEGIN GOLDEN
    private static let golden: [Case] = [
        Case(label: "e0-c0-medited-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|fit|z=1|cx=0|cy=0|2560x1600|edited|fit=0.90000000000000002|role=document|crop=0|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c0-medited-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|fit|z=1|cx=0|cy=0|2560x1600|edited|fit=0.90000000000000002|role=document|crop=0|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c0-medited-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|fit|z=1|cx=0|cy=0|2560x1600|edited|fit=0.90000000000000002|role=export|crop=0|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c0-medited-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|fit|z=1|cx=0|cy=0|2560x1600|edited|fit=0.90000000000000002|role=export|crop=0|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c0-mcompare-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|fit|z=1|cx=0|cy=0|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=0|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c0-mcompare-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|fit|z=1|cx=0|cy=0|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=0|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c0-mcompare-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|fit|z=1|cx=0|cy=0|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=0|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c0-mcompare-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|fit|z=1|cx=0|cy=0|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=0|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c1-medited-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|actual|z=1|cx=3120|cy=2080|2560x1600|edited|fit=0.90000000000000002|role=document|crop=0|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c1-medited-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|actual|z=1|cx=3120|cy=2080|2560x1600|edited|fit=0.90000000000000002|role=document|crop=0|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c1-medited-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|actual|z=1|cx=3120|cy=2080|2560x1600|edited|fit=0.90000000000000002|role=export|crop=0|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c1-medited-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|actual|z=1|cx=3120|cy=2080|2560x1600|edited|fit=0.90000000000000002|role=export|crop=0|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c1-mcompare-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|actual|z=1|cx=3120|cy=2080|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=0|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c1-mcompare-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|actual|z=1|cx=3120|cy=2080|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=0|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c1-mcompare-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|actual|z=1|cx=3120|cy=2080|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=0|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c1-mcompare-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|actual|z=1|cx=3120|cy=2080|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=0|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c2-medited-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|edited|fit=0.90000000000000002|role=document|crop=0|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c2-medited-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|edited|fit=0.90000000000000002|role=document|crop=0|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c2-medited-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|edited|fit=0.90000000000000002|role=export|crop=0|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c2-medited-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|edited|fit=0.90000000000000002|role=export|crop=0|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c2-mcompare-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=0|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c2-mcompare-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=0|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c2-mcompare-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=0|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e0-c2-mcompare-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|ceil=4.9246",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|f444fd3255cbdb05|-|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=0|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c0-medited-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|fit|z=1|cx=0|cy=0|2560x1600|edited|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c0-medited-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|fit|z=1|cx=0|cy=0|2560x1600|edited|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c0-medited-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|fit|z=1|cx=0|cy=0|2560x1600|edited|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c0-medited-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|fit|z=1|cx=0|cy=0|2560x1600|edited|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c0-mcompare-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|fit|z=1|cx=0|cy=0|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c0-mcompare-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|fit|z=1|cx=0|cy=0|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c0-mcompare-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|fit|z=1|cx=0|cy=0|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c0-mcompare-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|fit|z=1|cx=0|cy=0|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c1-medited-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|actual|z=1|cx=3120|cy=2080|2560x1600|edited|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c1-medited-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|actual|z=1|cx=3120|cy=2080|2560x1600|edited|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c1-medited-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|actual|z=1|cx=3120|cy=2080|2560x1600|edited|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c1-medited-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|actual|z=1|cx=3120|cy=2080|2560x1600|edited|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c1-mcompare-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|actual|z=1|cx=3120|cy=2080|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c1-mcompare-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|actual|z=1|cx=3120|cy=2080|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c1-mcompare-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|actual|z=1|cx=3120|cy=2080|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c1-mcompare-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|actual|z=1|cx=3120|cy=2080|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c2-medited-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|edited|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c2-medited-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|edited|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c2-medited-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|edited|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c2-medited-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|edited|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c2-mcompare-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c2-mcompare-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c2-mcompare-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e1-c2-mcompare-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|ceil=4.9246|geo=crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|ff52bfcafa158b19|crop=0.12000,0.08000,0.62000,0.71000;rot=0.00000;flip=00|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c0-medited-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|fit|z=1|cx=0|cy=0|2560x1600|edited|fit=0.90000000000000002|role=document|crop=1|warn=1|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c0-medited-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|fit|z=1|cx=0|cy=0|2560x1600|edited|fit=0.90000000000000002|role=document|crop=1|warn=1|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c0-medited-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|fit|z=1|cx=0|cy=0|2560x1600|edited|fit=0.90000000000000002|role=export|crop=1|warn=1|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c0-medited-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|fit|z=1|cx=0|cy=0|2560x1600|edited|fit=0.90000000000000002|role=export|crop=1|warn=1|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c0-mcompare-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|fit|z=1|cx=0|cy=0|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=1|warn=1|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c0-mcompare-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|fit|z=1|cx=0|cy=0|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=1|warn=1|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c0-mcompare-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|fit|z=1|cx=0|cy=0|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=1|warn=1|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c0-mcompare-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|fit|z=1|cx=0|cy=0|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=1|warn=1|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c1-medited-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|actual|z=1|cx=3120|cy=2080|2560x1600|edited|fit=0.90000000000000002|role=document|crop=1|warn=1|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c1-medited-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|actual|z=1|cx=3120|cy=2080|2560x1600|edited|fit=0.90000000000000002|role=document|crop=1|warn=1|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c1-medited-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|actual|z=1|cx=3120|cy=2080|2560x1600|edited|fit=0.90000000000000002|role=export|crop=1|warn=1|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c1-medited-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|actual|z=1|cx=3120|cy=2080|2560x1600|edited|fit=0.90000000000000002|role=export|crop=1|warn=1|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c1-mcompare-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|actual|z=1|cx=3120|cy=2080|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=1|warn=1|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c1-mcompare-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|actual|z=1|cx=3120|cy=2080|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=1|warn=1|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c1-mcompare-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|actual|z=1|cx=3120|cy=2080|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=1|warn=1|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c1-mcompare-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|actual|z=1|cx=3120|cy=2080|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=1|warn=1|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c2-medited-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|edited|fit=0.90000000000000002|role=document|crop=1|warn=1|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c2-medited-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|edited|fit=0.90000000000000002|role=document|crop=1|warn=1|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c2-medited-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|edited|fit=0.90000000000000002|role=export|crop=1|warn=1|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c2-medited-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|edited|fit=0.90000000000000002|role=export|crop=1|warn=1|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c2-mcompare-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=1|warn=1|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c2-mcompare-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=1|warn=1|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c2-mcompare-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=1|warn=1|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e2-c2-mcompare-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|ceil=4.9246|geo=crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|cbb02a1641f42e58|crop=0.00000,0.00000,1.00000,1.00000;rot=-3.70000;flip=10|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=1|warn=1|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c0-medited-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|fit|z=1|cx=0|cy=0|2560x1600|edited|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c0-medited-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|fit|z=1|cx=0|cy=0|2560x1600|edited|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c0-medited-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|fit|z=1|cx=0|cy=0|2560x1600|edited|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c0-medited-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|fit|z=1|cx=0|cy=0|2560x1600|edited|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c0-mcompare-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|fit|z=1|cx=0|cy=0|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c0-mcompare-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|fit|z=1|cx=0|cy=0|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c0-mcompare-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|fit|z=1|cx=0|cy=0|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c0-mcompare-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|fit|z=1|cx=0|cy=0|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c1-medited-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|actual|z=1|cx=3120|cy=2080|2560x1600|edited|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c1-medited-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|actual|z=1|cx=3120|cy=2080|2560x1600|edited|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c1-medited-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|actual|z=1|cx=3120|cy=2080|2560x1600|edited|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c1-medited-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|actual|z=1|cx=3120|cy=2080|2560x1600|edited|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c1-mcompare-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|actual|z=1|cx=3120|cy=2080|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c1-mcompare-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|actual|z=1|cx=3120|cy=2080|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c1-mcompare-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|actual|z=1|cx=3120|cy=2080|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c1-mcompare-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|actual|z=1|cx=3120|cy=2080|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c2-medited-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|edited|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c2-medited-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|edited|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c2-medited-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|edited|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c2-medited-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|edited|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c2-mcompare-rdocument-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c2-mcompare-rdocument-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=document|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c2-mcompare-rexport-h1.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=1|s=1|prim=displayP3|ceil=4.9245776533796661"),
        Case(label: "e3-c2-mcompare-rexport-h4.0",
             backdrop: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|ceil=4.9246|geo=crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1",
             canvas: "golden-photo|asset-439|recipe=v4-auto409;ver=auto;scale=1.0000|8703d23948b6f806|crop=0.10000,0.15000,0.70000,0.60000;rot=0.00000;flip=00;pvy=350;phx=-120;cs=1|actual|z=3.2000000000000002|cx=1450.25|cy=3800.75|2560x1600|compare(vertical,0.41999999999999998)|fit=0.90000000000000002|role=export|crop=1|warn=0|hr=4|s=1|prim=displayP3|ceil=4.9245776533796661"),
    ]
    // END GOLDEN
}
