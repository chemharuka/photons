import XCTest
import Metal
import PhotonsCore

/// Test scaffolding for the present pass (067).
///
/// The production type has **one** entry — `CanvasPresenter.present(PresentRequest, in:)` — and the
/// point of that is that no call site can forget the geometry. The tests need to say things like
/// "this texture, through this window, with the photograph filling it", which is an explicit
/// `PresentRequest`; spelling that out at forty call sites would bury what each test is about. So the
/// spelling lives here, once, and it is the *only* thing this file adds: it builds a request and hands
/// it to the real entry point. Nothing about the pass changes.
extension CanvasPresenter {

    /// Draw `texture` through `window` into `target`, with the photograph occupying `picture` inside
    /// the texture (default: all of it) and this session's storage format.
    @discardableResult
    func renderForTest(_ texture: MTLTexture, window: PresentWindow = .whole,
                       backdrop: MTLTexture? = nil, backdropWindow: PresentWindow = .whole,
                       picture: ImageRect? = nil, into target: MTLTexture,
                       linearize: Bool? = nil) -> Bool {
        render(requestForTest(texture, window: window, backdrop: backdrop,
                              backdropWindow: backdropWindow, picture: picture,
                              canvas: ImageSize(width: target.width, height: target.height)),
               into: target, linearize: linearize)
    }

    /// The on-screen entry, in the same spelling — for the handful of tests that exercise a real
    /// `CAMetalLayer` and cannot read the pixels back.
    @discardableResult
    func presentForTest(_ texture: MTLTexture, in layer: CAMetalLayer, wantsEDR: Bool = false,
                        drawableSize: ImageSize, window: PresentWindow = .whole,
                        backdrop: MTLTexture? = nil, backdropWindow: PresentWindow = .whole,
                        picture: ImageRect? = nil) -> Bool {
        present(requestForTest(texture, window: window, backdrop: backdrop,
                               backdropWindow: backdropWindow, picture: picture,
                               canvas: drawableSize),
                in: layer, wantsEDR: wantsEDR, drawableSize: drawableSize)
    }

    /// The request those two build: the photograph's rect inside the texture is the only geometry a
    /// caller gives, and `whole` means "the picture is the whole texture" — the old `photoRect: nil`
    /// spelled the same thing by *not* answering, which is how a call site could forget.
    func requestForTest(_ texture: MTLTexture, window: PresentWindow, backdrop: MTLTexture?,
                        backdropWindow: PresentWindow, picture: ImageRect?,
                        canvas: ImageSize) -> PresentRequest {
        PresentRequest(picture: texture,
                       photoRect: picture ?? ImageRect(x: 0, y: 0,
                                                         width: texture.width,
                                                         height: texture.height),
                       window: window, canvas: canvas, backdrop: backdrop,
                       backdropWindow: backdropWindow)
    }
}
