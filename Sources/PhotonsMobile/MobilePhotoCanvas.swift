#if os(iOS)
import PhotonsLocalization
import SwiftUI
import UIKit
import PhotonsCore

struct MobileDetailRequest: Equatable, Sendable {
    /// Top-left normalized coordinates in the edited output, not the original sensor frame.
    var rect: CGRect
    var scale: Double
}
struct MobileDetailFrame: @unchecked Sendable {
    var image: CGImage
    var rect: CGRect
}

/// Percentages refer to image pixels per physical display pixel. Fit is a separate mode,
/// even when a small photograph's Fit scale happens to exceed 100%.
enum MobileZoomGeometry {
    static func fit(pixels: CGSize, viewport: CGSize, screenScale: CGFloat) -> CGFloat {
        min(viewport.width / max(1,pixels.width),viewport.height / max(1,pixels.height)) * screenScale
    }
    static func validPercent(_ text: String) -> Double? {
        guard let value = Double(text), value.isFinite, (10...800).contains(value) else { return nil }
        return value / 100
    }
}

struct MobilePhotoCanvas: View {
    let image: CGImage
    let hdr: Bool
    let identity: String
    var accessibilityID = "photo-canvas"
    var fullSize: CGSize? = nil
    var detail: MobileDetailFrame? = nil
    var detailStatus = ""
    var onViewportChange: (MobileDetailRequest?) -> Void = { _ in }
    var onNavigate: (Int) -> Void = { _ in }
    @AppStorage("photons.mobile.zoomTarget") private var zoomTarget = 1.0
    @State private var command = MobileZoomCommand()
    @State private var isFit = true
    @State private var actualScale = 1.0
    @State private var custom = false
    @State private var customText = "100"
    var body: some View {
        ZStack(alignment: .topTrailing) {
            MobilePhotoViewport(image: image,hdr: hdr,identity: identity,
                pixels: fullSize ?? CGSize(width: image.width,height: image.height), detail: detail,
                target: zoomTarget,command: command,onViewportChange: onViewportChange,
                onNavigate: onNavigate,onZoom: { scale,fit in actualScale = scale; isFit = fit })
                .accessibilityIdentifier(accessibilityID)
            VStack(alignment: .trailing,spacing: 6) {
                HStack(spacing: 12) {
                    Text(isFit ? L10n.tr("53c9aca4b68c") : String(format: "%.0f%%",actualScale * 100))
                        .monospacedDigit().accessibilityIdentifier("zoom-state")
                    Button(L10n.tr("53c9aca4b68c")) { command = .init(scale: nil) }.accessibilityIdentifier("zoom-fit")
                    Menu {
                        ForEach([0.5,1,2],id: \.self) { value in
                            Button(String(format: "%.0f%%",value * 100)) { choose(value) }
                        }
                        Button(L10n.tr("ipad.c4e69d543a44")) { customText = String(format: "%.0f",zoomTarget * 100); custom = true }
                    } label: { Text(String(format: "↔ %.0f%%",zoomTarget * 100)) }
                    .accessibilityIdentifier("zoom-options").accessibilityLabel(L10n.tr("ipad.f8308849679f"))
                }.font(.caption).padding(10).background(.ultraThinMaterial,in: Capsule())
                if !detailStatus.isEmpty { Text(detailStatus).font(.caption2).padding(6).background(.ultraThinMaterial,in: RoundedRectangle(cornerRadius: 6)) }
            }.padding(8)
        }
        .sheet(isPresented: $custom) {
            NavigationStack {
                Form {
                    TextField(L10n.tr("ipad.6211faaf785b"),text: $customText)
                        .keyboardType(.decimalPad).accessibilityIdentifier("zoom-custom-input")
                    Text(L10n.tr("ipad.3e8fb0033f67")).font(.caption).foregroundStyle(.secondary)
                }.navigationTitle(L10n.tr("ipad.689b97e52438")).navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("cameraBodies.cancel")) { custom = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.tr("63c73c4730f4")) {
                                if let value = MobileZoomGeometry.validPercent(customText) { choose(value); custom = false }
                            }.disabled(MobileZoomGeometry.validPercent(customText) == nil)
                                .accessibilityIdentifier("zoom-custom-apply")
                        }
                    }
            }.presentationDetents([.medium,.large]).preferredColorScheme(.dark)
        }
    }
    private func choose(_ value: Double) {
        zoomTarget = value
        if !isFit { command = .init(scale: value) }
    }
}

private struct MobileZoomCommand: Equatable {
    var id = UUID()
    var scale: Double? = nil
}
private struct MobilePhotoViewport: UIViewRepresentable {
    let image: CGImage
    let hdr: Bool
    let identity: String
    let pixels: CGSize
    let detail: MobileDetailFrame?
    let target: Double
    let command: MobileZoomCommand
    let onViewportChange: (MobileDetailRequest?) -> Void
    let onNavigate: (Int) -> Void
    let onZoom: (Double,Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> MobilePhotoScrollView {
        let scroll = MobilePhotoScrollView()
        scroll.backgroundColor = .clear; scroll.delegate = context.coordinator
        scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never; scroll.bouncesZoom = true
        scroll.addSubview(context.coordinator.imageView)
        context.coordinator.imageView.addSubview(context.coordinator.detailView)
        context.coordinator.detailView.isHidden = true
        let tap = UITapGestureRecognizer(target: context.coordinator,action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2; scroll.addGestureRecognizer(tap)
        for direction: UISwipeGestureRecognizer.Direction in [.left,.right] {
            let swipe = UISwipeGestureRecognizer(target: context.coordinator,action: #selector(Coordinator.swipe(_:)))
            swipe.direction = direction; swipe.delegate = context.coordinator
            scroll.addGestureRecognizer(swipe); scroll.panGestureRecognizer.require(toFail: swipe)
        }
        scroll.onLayout = { [weak scroll, weak coordinator = context.coordinator] in
            if let scroll { coordinator?.layout(scroll) }
        }
        return scroll
    }
    func updateUIView(_ scroll: MobilePhotoScrollView,context: Context) {
        let c = context.coordinator
        c.onViewportChange = onViewportChange; c.onNavigate = onNavigate; c.onZoom = onZoom
        c.target = min(8,max(0.1,target)); c.hdr = hdr
        let reset = c.identity != identity || c.pixels != pixels
        c.identity = identity; c.pixels = pixels
        c.imageView.present(image,hdr: hdr)
        scroll.hdr = hdr; scroll.updateDisplayNotice()
        if reset { c.needsReset = true; c.detailView.isHidden = true }
        c.layout(scroll)
        if c.lastCommand != command { c.lastCommand = command; c.setZoom(command.scale,scroll: scroll,animated: false) }
        if let detail {
            c.detailView.present(detail.image,hdr: hdr)
            let size = c.imageView.bounds.size
            c.detailView.frame = CGRect(x: detail.rect.minX * size.width,y: detail.rect.minY * size.height,
                                       width: detail.rect.width * size.width,height: detail.rect.height * size.height)
            c.detailView.isHidden = false
        } else { c.detailView.isHidden = true }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        let imageView = MobilePreviewSurface(), detailView = MobilePreviewSurface()
        var identity = "", pixels = CGSize.zero, target = 1.0, hdr = false
        var fitScale: CGFloat = 1, lastBounds = CGSize.zero, needsReset = true, layingOut = false
        var lastCommand: MobileZoomCommand?
        var lastRequest: MobileDetailRequest?
        var onViewportChange: (MobileDetailRequest?) -> Void = { _ in }
        var onNavigate: (Int) -> Void = { _ in }
        var onZoom: (Double,Bool) -> Void = { _,_ in }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        func isFit(_ scroll: UIScrollView) -> Bool { abs(scroll.zoomScale - fitScale) < 0.005 }
        func layout(_ scroll: UIScrollView) {
            guard !layingOut, scroll.bounds.width > 0, scroll.bounds.height > 0, pixels.width > 0 else { return }
            layingOut = true; defer { layingOut = false }
            let bounds = scroll.bounds.size, screenScale = scroll.window?.screen.scale ?? 2
            if needsReset || bounds != lastBounds {
                let wasFit = needsReset || isFit(scroll), oldScale = scroll.zoomScale
                scroll.minimumZoomScale = 0.01; scroll.maximumZoomScale = 100
                scroll.setZoomScale(1,animated: false)
                imageView.frame = CGRect(origin: .zero,size: CGSize(width: pixels.width / screenScale,height: pixels.height / screenScale))
                fitScale = MobileZoomGeometry.fit(pixels: pixels,viewport: bounds,screenScale: screenScale)
                scroll.minimumZoomScale = min(0.1,fitScale); scroll.maximumZoomScale = max(8,fitScale)
                scroll.setZoomScale(wasFit ? fitScale : oldScale,animated: false)
                lastBounds = bounds; needsReset = false
                if wasFit { scroll.contentOffset = .zero }
            }
            center(scroll); publish(scroll)
        }
        func center(_ scroll: UIScrollView) {
            let size = imageView.frame.size
            scroll.contentInset = UIEdgeInsets(top: max(0,(scroll.bounds.height-size.height)/2),left: max(0,(scroll.bounds.width-size.width)/2),bottom: 0,right: 0)
        }
        func setZoom(_ value: Double?,scroll: UIScrollView,animated: Bool) {
            guard !needsReset else { return }
            let scale = value.map { CGFloat(min(8,max(0.1,$0))) } ?? fitScale
            let center = scroll.convert(CGPoint(x: scroll.bounds.midX,y: scroll.bounds.midY),to: imageView)
            let rect = CGRect(x: center.x - scroll.bounds.width / scale / 2,y: center.y - scroll.bounds.height / scale / 2,
                              width: scroll.bounds.width / scale,height: scroll.bounds.height / scale)
            scroll.zoom(to: rect,animated: animated)
            if !animated { self.center(scroll); publish(scroll) }
        }
        @objc func doubleTap(_ tap: UITapGestureRecognizer) {
            guard let scroll = tap.view as? UIScrollView else { return }
            if !isFit(scroll) { setZoom(nil,scroll: scroll,animated: true); return }
            let center = tap.location(in: imageView), scale = CGFloat(target)
            scroll.zoom(to: CGRect(x: center.x-scroll.bounds.width/scale/2,y: center.y-scroll.bounds.height/scale/2,
                                   width: scroll.bounds.width/scale,height: scroll.bounds.height/scale),animated: true)
        }
        @objc func swipe(_ gesture: UISwipeGestureRecognizer) { onNavigate(gesture.direction == .left ? 1 : -1) }
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let scroll = gesture.view as? UIScrollView else { return false }; return isFit(scroll)
        }
        func scrollViewDidZoom(_ scroll: UIScrollView) { if !layingOut { center(scroll); publish(scroll) } }
        func scrollViewDidScroll(_ scroll: UIScrollView) { if !layingOut { publish(scroll) } }
        func scrollViewDidEndZooming(_ scroll: UIScrollView,with view: UIView?,atScale scale: CGFloat) { publish(scroll) }
        func publish(_ scroll: UIScrollView) {
            guard !needsReset else { return }
            let fit = isFit(scroll), scale = Double(scroll.zoomScale)
            let visible = scroll.convert(scroll.bounds,to: imageView).intersection(imageView.bounds)
            var request: MobileDetailRequest?
            if !fit && !visible.isNull && !visible.isEmpty {
                let size = imageView.bounds.size
                request = MobileDetailRequest(rect: CGRect(x: visible.minX/size.width,y: visible.minY/size.height,width: visible.width/size.width,height: visible.height/size.height),scale: min(1,scale))
            }
            let changed = request != lastRequest; lastRequest = request
            // UIKit layout can run during a SwiftUI update; publish on the next main turn.
            DispatchQueue.main.async { [weak self] in
                self?.onZoom(scale,fit)
                if changed { self?.onViewportChange(request) }
            }
        }
    }
}
#endif
