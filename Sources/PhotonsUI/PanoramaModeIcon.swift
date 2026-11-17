import SwiftUI

struct PanoramaModeIcon: View {
    var perspective = false
    var body: some View {
        ZStack {
            FrameShape(inset: perspective ? 0.18 : 0)
                .stroke(lineWidth: 1.5).frame(width: 22, height: 16).offset(x: -4, y: -3)
            FrameShape(inset: perspective ? 0.18 : 0)
                .fill(.background).frame(width: 22, height: 16).offset(x: 4, y: 3)
            FrameShape(inset: perspective ? 0.18 : 0)
                .stroke(lineWidth: 1.5).frame(width: 22, height: 16).offset(x: 4, y: 3)
        }.frame(width: 32, height: 24).accessibilityHidden(true)
    }

    private struct FrameShape: Shape {
        var inset: CGFloat
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.minY + r.height * inset))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.maxX - r.width * inset, y: r.midY))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY), control: CGPoint(x: r.midX, y: r.maxY - r.height * inset))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY), control: CGPoint(x: r.minX + r.width * inset, y: r.midY))
            p.closeSubpath()
            return p
        }
    }
}
