import PhotonsLocalization
import AppKit
import SwiftUI
import CoreImage
import PhotonsCore

/// The same half-float Metal surface used by the grid and loupe placeholder, fitted to
/// the entire panorama. SwiftUI's ordinary Image would flatten this into an SDR layer.
struct PanoramaHDRPreview: View {
    let image: CGImage
    @State private var headroom = DisplayHeadroom.sdr
    @Bindable private var preferences=ApplicationPreferences.shared

    var body: some View {
        PanoramaHDRSurface(image: image) { headroom = $0 }
            .allowsHitTesting(false)
            .overlay(alignment: .topLeading) {
                Button(preferences.hdrPreview ? "HDR":"SDR") {preferences.hdrPreview.toggle()}
                    .buttonStyle(.bordered).padding(12)
                    .help(L10n.tr("1241282e23af"))
                    .accessibilityIdentifier("panorama.dynamicRange")
            }
            .overlay(alignment: .topTrailing) {
                PanoramaPreviewHistogram(image:image,hdr:preferences.hdrPreview,headroom:headroom.headroom)
                    .frame(width:230,height:126).padding(6)
                    .background(.regularMaterial,in:RoundedRectangle(cornerRadius:8)).padding(12)
            }
            .overlay(alignment: .bottomLeading) {
                Text(preferences.hdrPreview ? L10n.tr("eb1c4475f146" , String(describing: (headroom.displayText))):L10n.tr("2e895f4004e4"))
                    .font(.caption).foregroundStyle(.secondary).padding(7)
                    .background(.regularMaterial,in:RoundedRectangle(cornerRadius:6)).padding(8).allowsHitTesting(false)
            }
    }
}

private struct PanoramaHDRSurface: NSViewRepresentable {
    let image: CGImage
    let onHeadroom: (DisplayHeadroom) -> Void
    func makeNSView(context: Context) -> PanoramaHDRPreviewView { PanoramaHDRPreviewView() }
    func updateNSView(_ view: PanoramaHDRPreviewView, context: Context) {
        view.onHeadroom = onHeadroom
        view.setImage(image)
    }
}

@MainActor
final class PanoramaHDRPreviewView: NSView {
    let surface = ThumbnailEDRView(cornerRadius: 0)
    private var source: CGImage?
    private var timer: Timer?
    private var headroom: DisplayHeadroom?
    private var preferencesObserver: NSObjectProtocol?
    var onHeadroom: ((DisplayHeadroom) -> Void)?
    private static let context = CIContext(options: [.cacheIntermediates: false])

    init() {
        super.init(frame: .zero)
        addSubview(surface)
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: .photonsPreferencesDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.updateHeadroom()
            }
    }
    required init?(coder: NSCoder) { fatalError("no nib") }
    deinit {
        timer?.invalidate()
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setImage(_ image: CGImage) {
        guard source !== image else { return }
        source = image
        let space = CanvasPresenter.Storage.linear16.colorSpace!
        if ThumbnailMetalRenderer.shared.isAvailable,
           image.bitsPerComponent == 16, image.bitmapInfo.contains(.floatComponents),
           image.colorSpace == space {
            surface.image = image
        } else {
            // ThumbnailMetalSurface's fast upload assumes half-float P3. Convert, do not
            // merely retag, if a future producer supplies another working colour space.
            let ci = CIImage(cgImage: image)
            let metal = ThumbnailMetalRenderer.shared.isAvailable
            surface.image = Self.context.createCGImage(ci, from: ci.extent,
                format: metal ? .RGBAh : .RGBA8,
                colorSpace: metal ? space : CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let source else { return }
        let scale = min(bounds.width / CGFloat(source.width), bounds.height / CGFloat(source.height))
        let size = CGSize(width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale)
        surface.frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                               width: size.width, height: size.height)
        surface.needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        updateHeadroom()
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window?.occlusionState.contains(.visible) == true else { return }
                self.updateHeadroom()
            }
        }
        timer?.tolerance = 0.2
    }

    private func updateHeadroom() {
        let value = DisplayHeadroom.current(for: window?.screen,
            layerAcceptsEDR: ThumbnailMetalRenderer.shared.isAvailable && ProcessingPreferences.hdrPreview)
        guard value != headroom else { return }
        headroom = value
        DispatchQueue.main.async { [weak self] in self?.onHeadroom?(value) }
    }
}

/// Bounded preview sampling: changing exposure or proof mode updates the same plot as the editor.
private struct PanoramaPreviewHistogram:NSViewRepresentable {
    let image:CGImage
    let hdr:Bool
    let headroom:Double
    func makeNSView(context:Context)->HistogramCardView {HistogramCardView()}
    func updateNSView(_ view:HistogramCardView,context:Context) {
        if context.coordinator.source !== image {
            let w=128,h=max(1,Int(Double(w)*Double(image.height)/Double(image.width)))
            let space=CGColorSpace(name:CGColorSpace.extendedLinearITUR_2020)!
            let ci=CIImage(cgImage:image).transformed(by:CGAffineTransform(scaleX:Double(w)/Double(image.width),y:Double(h)/Double(image.height)))
            var pixels=[Float16](repeating:0,count:w*h*4)
            Self.context.render(ci,toBitmap:&pixels,rowBytes:w*8,bounds:CGRect(x:0,y:0,width:w,height:h),format:.RGBAh,colorSpace:space)
            context.coordinator.sample=LinearSample(width:w,height:h,rgba:pixels)
            context.coordinator.source=image
        }
        if let sample=context.coordinator.sample {
            view.histogram=hdr ? Histogram.compute(sample,headroom:headroom):SDRProjection.histogram(sample,bins:256,rect:nil,primaries:.displayP3)
        }
        view.needsDisplay=true
    }
    private static let context=CIContext(options:[.cacheIntermediates:false])
    final class Coordinator {var source:CGImage?;var sample:LinearSample?}
    func makeCoordinator()->Coordinator {Coordinator()}
}
